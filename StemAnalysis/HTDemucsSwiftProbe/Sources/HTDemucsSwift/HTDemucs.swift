//
//  HTDemucs.swift — top-level HTDemucs model, htdemucs-flavor.
//
//  Mirrors mlx_htdemucs.HTDemucsMLX.__call__ for the production config:
//    sources=4, depth=4, nfft=4096, channels=48, growth=2, bottom=512,
//    cac=true, wiener_iters=0, freq_emb=0.2, t_layers=5, t_heads=8.
//
//  Wiener path is omitted (cac=true short-circuits to a real+imag
//  reshape). MultiWrap is omitted (multi_freqs=nil). last_freq path
//  is omitted (freqs > kernel_size at every depth). All confirmed
//  against the exported config JSON.
//

import Foundation
import MLX
import MLXNN

public final class HTDemucs: Module {
    public let sources: [String]
    public let audioChannels: Int
    public let samplerate: Int
    public let segment: Float
    public let nFft: Int
    public let hopLength: Int

    let depth: Int
    let bottomChannels: Int
    let freqEmbScale: Float

    let spectro: Spectro

    @ModuleInfo var encoder: [HEncLayer]
    @ModuleInfo var decoder: [HDecLayer]
    @ModuleInfo var tencoder: [HEncLayer]
    @ModuleInfo var tdecoder: [HDecLayer]

    @ModuleInfo(key: "freq_emb") var freqEmb: ScaledEmbedding?

    @ModuleInfo(key: "channel_upsampler") var channelUpsampler: Conv1dNCL?
    @ModuleInfo(key: "channel_downsampler") var channelDownsampler: Conv1dNCL?
    @ModuleInfo(key: "channel_upsampler_t") var channelUpsamplerT: Conv1dNCL?
    @ModuleInfo(key: "channel_downsampler_t") var channelDownsamplerT: Conv1dNCL?

    @ModuleInfo var crosstransformer: CrossTransformerEncoder?

    public init(
        sources: [String] = ["drums", "bass", "other", "vocals"],
        audioChannels: Int = 2,
        channels: Int = 48,
        growth: Int = 2,
        nFft: Int = 4096,
        depth: Int = 4,
        kernelSize: Int = 8,
        stride: Int = 4,
        context: Int = 1,
        contextEnc: Int = 0,
        dconvDepth: Int = 2,
        dconvCompress: Float = 8,
        freqEmb: Float = 0.2,
        embScale: Float = 10,
        bottomChannels: Int = 512,
        tLayers: Int = 5,
        tHeads: Int = 8,
        tHiddenScale: Float = 4.0,
        samplerate: Int = 44100,
        segment: Float = 7.8
    ) {
        self.sources = sources
        self.audioChannels = audioChannels
        self.samplerate = samplerate
        self.segment = segment
        self.nFft = nFft
        self.hopLength = nFft / 4
        self.depth = depth
        self.bottomChannels = bottomChannels
        self.freqEmbScale = freqEmb
        self.spectro = Spectro(nFft: nFft, hop: nFft / 4)

        // Build encoder/decoder/tencoder/tdecoder.
        var enc: [HEncLayer] = []
        var dec: [HDecLayer] = []
        var tenc: [HEncLayer] = []
        var tdec: [HDecLayer] = []

        var chin = audioChannels                  // mono/stereo
        var chinZ = audioChannels * 2             // cac=true doubles channels
        var chout = channels                      // freq path output
        var choutZ = channels                     // spectral path output
        var freqs = nFft / 2                       // 2048 → 512 → 128 → 32 (for htdemucs)

        for index in 0 ..< depth {
            // For htdemucs depth=4 + stride=4 + kernel=8: freqs > kernel
            // at every level, so freq=true, last_freq=false everywhere.
            let freq = freqs > 1
            precondition(freq, "non-freq path at depth \(index) not implemented")

            let encL = HEncLayer(
                chin: chinZ, chout: choutZ,
                kernelSize: kernelSize, stride: stride,
                freq: true, dconv: true,
                context: contextEnc,
                dconvDepth: dconvDepth, dconvCompress: dconvCompress
            )
            enc.append(encL)

            // Time encoder (parallel to spectral, freq=false).
            let tencL = HEncLayer(
                chin: chin, chout: chout,
                kernelSize: kernelSize, stride: stride,
                freq: false, dconv: true,
                context: contextEnc,
                dconvDepth: dconvDepth, dconvCompress: dconvCompress
            )
            tenc.append(tencL)

            // After first encoder, the source-mask reshapes channels.
            var chinDec = chinZ
            var chinDecT = chin
            if index == 0 {
                chinDec = audioChannels * sources.count * 2  // cac
                chinDecT = audioChannels * sources.count
            }

            // Decoders. Built bottom-up, inserted at front of list so
            // decoder[0] ends up being the deepest layer.
            let decL = HDecLayer(
                chin: choutZ, chout: chinDec,
                kernelSize: kernelSize, stride: stride,
                freq: true, dconv: true,
                context: context,
                last: index == 0,
                dconvDepth: dconvDepth, dconvCompress: dconvCompress
            )
            dec.insert(decL, at: 0)

            let tdecL = HDecLayer(
                chin: chout, chout: chinDecT,
                kernelSize: kernelSize, stride: stride,
                freq: false, dconv: true,
                context: context,
                last: index == 0,
                dconvDepth: dconvDepth, dconvCompress: dconvCompress
            )
            tdec.insert(tdecL, at: 0)

            // Update for next iteration.
            chin = chout
            chinZ = choutZ
            chout = growth * chout
            choutZ = growth * choutZ
            if freqs > kernelSize {
                freqs /= stride
            } else {
                freqs = 1
            }
        }

        self._encoder.wrappedValue = enc
        self._decoder.wrappedValue = dec
        self._tencoder.wrappedValue = tenc
        self._tdecoder.wrappedValue = tdec

        // freq_emb: built after first encoder where chinZ becomes the
        // post-mask channel count (8*2=16 for htdemucs). Number of
        // embeddings = freqs at the encoder.0 output (= nFft/2/stride =
        // 2048/4 = 512 for htdemucs).
        if freqEmb > 0 {
            let initialFreqs = nFft / 2 / stride  // 512 for htdemucs
            // We need the post-iter chinZ from the first depth — that's
            // already what encoder.0 outputs. Hmm: looking at the
            // Python source, freq_emb is ScaledEmbedding(freqs_post,
            // chin_z_post). After iteration 0: freqs=512,
            // chin_z=audio_channels*len(sources)*(cac?2:1)=16. But the
            // safetensors shows [512, 48] for freq_emb.embedding.weight,
            // meaning embedding_dim=48 (= chout_z at that point, BEFORE
            // chinZ update). Looking again at the Python:
            //   `self.freq_emb = ScaledEmbedding(freqs, chin_z, ...)`
            //   ... where `chin_z` was just set to 16, but `freqs`
            //   was already divided.
            // Wait, the safetensors says [512, 48]. embedding_dim=48.
            // So embedding_dim follows chout_z=48 at index 0 (after
            // append). Re-read the Python:
            //   at index 0: enc=HEncLayer(chin_z=4, chout_z=48); append.
            //   if index==0: chin=8; chin_z=16.   <-- mask reshape
            //   dec; insert.
            //   chin=chout; chin_z=chout_z;  <-- chin_z = 48 here
            //   chout = 2*chout = 96; chout_z = 2*chout_z = 96.
            //   freqs //= stride  <-- 2048/4 = 512
            //   if index == 0 and freq_emb:
            //       self.freq_emb = ScaledEmbedding(freqs, chin_z, ...)
            // So chin_z at this point = 48 (= chout_z BEFORE growth). ✓
            // embedding shape [512, 48] confirms.
            self._freqEmb.wrappedValue = ScaledEmbedding(
                numEmbeddings: initialFreqs, embeddingDim: channels,
                scale: embScale
            )
        }

        // Channel up/downsampler 1×1 convs for the bottleneck.
        // transformer_channels = channels * growth^(depth-1) = 48 * 8 = 384.
        let transformerChannels = channels * Int(pow(Float(growth), Float(depth - 1)))
        if bottomChannels > 0 {
            self._channelUpsampler.wrappedValue = Conv1dNCL(
                inputChannels: transformerChannels,
                outputChannels: bottomChannels,
                kernelSize: 1
            )
            self._channelDownsampler.wrappedValue = Conv1dNCL(
                inputChannels: bottomChannels,
                outputChannels: transformerChannels,
                kernelSize: 1
            )
            self._channelUpsamplerT.wrappedValue = Conv1dNCL(
                inputChannels: transformerChannels,
                outputChannels: bottomChannels,
                kernelSize: 1
            )
            self._channelDownsamplerT.wrappedValue = Conv1dNCL(
                inputChannels: bottomChannels,
                outputChannels: transformerChannels,
                kernelSize: 1
            )
        }

        if tLayers > 0 {
            self._crosstransformer.wrappedValue = CrossTransformerEncoder(
                dim: bottomChannels > 0 ? bottomChannels : transformerChannels,
                hiddenScale: tHiddenScale, numHeads: tHeads,
                numLayers: tLayers, crossFirst: false
            )
        }

        super.init()
    }

    // MARK: - Spectral helpers (mirrors mlx_htdemucs._spec / _ispec / _magnitude / _mask)

    /// STFT with htdemucs's pre-pad + trim of low-freq + frame slicing.
    func spec(_ x: MLXArray) -> MLXArray {
        let hl = hopLength
        let le = Int(ceil(Double(x.shape.last!) / Double(hl)))
        let pad = hl / 2 * 3
        let padded = pad1d(x, paddings: (pad, pad + le * hl - x.shape.last!), mode: "reflect")
        // STFT → [B, C, F, N]
        var z = spectro.stft(padded)
        // Drop highest freq bin and trim time frames to [2 : 2+le].
        let F = z.shape[z.ndim - 2]
        z = z[.ellipsis, 0 ..< (F - 1), 2 ..< (2 + le)]
        return z
    }

    /// Inverse STFT, mirroring _ispec.
    func ispec(_ z: MLXArray, length: Int) -> MLXArray {
        let hl = hopLength
        // Pad freq dim (add the dropped bin) and time dim (add 2 frames each side).
        var z = z
        // Build pad widths per axis. z is 4-D [B, C, F, N] or 5-D [B, S, C, F, N].
        var widths: [IntOrPair]
        if z.ndim == 5 {
            widths = [
                IntOrPair(0), IntOrPair(0), IntOrPair(0),
                IntOrPair((0, 1)), IntOrPair((2, 2))
            ]
        } else {
            widths = [
                IntOrPair(0), IntOrPair(0),
                IntOrPair((0, 1)), IntOrPair((2, 2))
            ]
        }
        z = padded(z, widths: widths, mode: .constant)
        let pad = hl / 2 * 3
        let le = hl * Int(ceil(Double(length) / Double(hl))) + 2 * pad
        var x = spectro.istft(z, length: le)
        // Trim center padding to recover the original-length signal.
        x = x[.ellipsis, pad ..< (pad + length)]
        return x
    }

    /// CAC magnitude: stack real+imag along channel.
    func magnitude(_ z: MLXArray) -> MLXArray {
        // z: [B, C, F, T] complex. Output [B, 2*C, F, T] real.
        let B = z.shape[0]
        let C = z.shape[1]
        let F = z.shape[2]
        let T = z.shape[3]
        let stacked = MLX.stacked([z.realPart(), z.imaginaryPart()], axis: 2)
        // stacked shape: [B, C, 2, F, T] → reshape to [B, 2C, F, T]
        return stacked.reshaped(B, C * 2, F, T)
    }

    /// CAC mask: undo the real+imag stacking on the model output.
    func mask(_ m: MLXArray) -> MLXArray {
        // m: [B, S, 2C, F, T] real → [B, S, C, F, T] complex.
        let B = m.shape[0]
        let S = m.shape[1]
        let C2 = m.shape[2]
        let F = m.shape[3]
        let T = m.shape[4]
        let C = C2 / 2
        // Reshape to [B, S, C, 2, F, T], move 2 to last → [B, S, C, F, T, 2]
        let r = m.reshaped(B, S, C, 2, F, T).transposed(0, 1, 2, 4, 5, 3)
        let real = r[.ellipsis, 0]
        let imag = r[.ellipsis, 1]
        // Build complex array. mlx-swift supports element-wise complex
        // construction via real + i*imag using `*` with a 1j scalar.
        // The cleanest path is to stack and reinterpret; for the
        // probe we just compute real + 1j*imag explicitly:
        let i = MLXArray([0.0, 1.0] as [Float])  // 0 + 1j as complex
        // Workaround: convert to complex via mlx.array on numpy
        // would require crossing FFI. Use the identity that
        // `mx.real(z) + 1j*mx.imag(z) == z` via constructing a
        // complex from two real parts.
        _ = i
        // mlx-swift doesn't expose a direct "make complex" op in the
        // primary API; route through irfft by reconstructing the
        // STFT-shape array. For Phase 0 parity we instead delay this
        // and pass real+imag separately through ispec via a helper
        // (see callAsFunction).
        // This stub will be unreachable because callAsFunction calls
        // `maskAndIspec` directly.
        preconditionFailure("mask() not used; use maskAndIspec()")
    }

    /// Combined CAC mask + iSTFT that keeps real/imag as separate
    /// arrays to dodge the "no make-complex" gap. Mirrors the Python
    /// `_mask` + `_ispec` pair but never constructs a complex array
    /// directly.
    func maskAndIspec(_ m: MLXArray, length: Int) -> MLXArray {
        let B = m.shape[0]
        let S = m.shape[1]
        let C2 = m.shape[2]
        let F = m.shape[3]
        let T = m.shape[4]
        let C = C2 / 2
        let r = m.reshaped(B, S, C, 2, F, T).transposed(0, 1, 2, 4, 5, 3)
        let real = r[.ellipsis, 0]  // [B, S, C, F, T]
        let imag = r[.ellipsis, 1]
        // We need to reconstruct complex for irfft. Use the FFT.irfft
        // path with a complex array built via mlx-swift's Complex init.
        // mlx-swift exposes `MLXArray(real:imaginary:)` for scalars only,
        // but `Complex<Float>` arrays can be constructed too. Easiest
        // path: irfft only needs `z = real + i*imag`, and we can run
        // ispec on the real path by recombining via the standard
        // `MLX.realImagToComplex` if exposed.
        // PHASE 0 SHIM: build the complex array by allocating
        // `[..., F, T]` complex zeros and adding real + i*imag pieces.
        // We do this by re-using a tiny helper.
        let z = realImagToComplex(real: real, imag: imag)
        return ispec(z, length: length)
    }

    // MARK: - Forward pass

    public func callAsFunction(_ mix: MLXArray) -> MLXArray {
        return self.forward(mix, profiler: nil)
    }

    /// Stage-profiled forward. Side-channel timer: when `profiler` is
    /// non-nil, the forward pass calls `eval(...)` at stage boundaries
    /// and records wall-time per stage. The extra evals serialize the
    /// graph, so this is meaningfully slower than the lazy default —
    /// use only for profiling, not for production timing.
    public func forward(_ mix: MLXArray, profiler: StageProfiler?) -> MLXArray {
        let originalLength = mix.shape.last!
        var mix = mix
        var prePad: Int? = nil
        @inline(__always) func mark(_ name: String, _ arr: MLXArray) {
            profiler?.mark(name, arr)
        }

        // Use training segment length (segment * samplerate). Pad
        // mix on the right with zeros if input is shorter.
        let trainingLength = Int(segment * Float(samplerate))
        precondition(mix.shape.last! <= trainingLength,
                     "input length \(mix.shape.last!) > training length \(trainingLength)")
        if mix.shape.last! < trainingLength {
            prePad = mix.shape.last!
            mix = padded(
                mix,
                widths: [IntOrPair(0), IntOrPair(0), IntOrPair((0, trainingLength - prePad!))],
                mode: .constant
            )
        }

        profiler?.start()

        // Spectral path setup.
        let z = spec(mix)
        mark("spec", z)
        var x = magnitude(z)
        let B = x.shape[0]
        let C = x.shape[1]
        let Fq = x.shape[2]
        let T = x.shape[3]
        let meanX = MLX.mean(x, axes: [1, 2, 3], keepDims: true)
        let stdX = MLX.std(x, axes: [1, 2, 3], keepDims: true)
        x = (x - meanX) / (1e-5 + stdX)
        mark("mag+normalize", x)

        // Time path setup.
        var xt = mix
        let meanT = MLX.mean(xt, axes: [1, 2], keepDims: true)
        let stdT = MLX.std(xt, axes: [1, 2], keepDims: true)
        xt = (xt - meanT) / (1e-5 + stdT)

        // Encode (both branches in parallel, with cross-injection).
        var saved: [MLXArray] = []
        var savedT: [MLXArray] = []
        var lengths: [Int] = []
        var lengthsT: [Int] = []

        for (idx, enc) in encoder.enumerated() {
            lengths.append(x.shape.last!)
            var inject: MLXArray? = nil
            if idx < tencoder.count {
                lengthsT.append(xt.shape.last!)
                let tenc = tencoder[idx]
                xt = tenc(xt)
                // tenc.empty is always false in htdemucs.
                savedT.append(xt)
            }
            x = enc(x, inject: inject)
            if idx == 0, let fe = freqEmb {
                // x is [B, C, Fr, T] here. Compute freq embedding and
                // add along the freq axis.
                let frs = MLXArray(0 ..< Int32(x.shape[2]))
                let emb = fe(frs).transposed(1, 0)  // [C, Fr]
                let embReshaped = emb.reshaped(1, emb.shape[0], emb.shape[1], 1)
                x = x + freqEmbScale * embReshaped
            }
            saved.append(x)
            mark("enc_\(idx)", x)
        }

        // Cross-transformer bottleneck.
        if let ct = crosstransformer {
            if bottomChannels > 0 {
                let b = x.shape[0]
                let c = x.shape[1]
                let f = x.shape[2]
                let t = x.shape[3]
                let flat = x.reshaped(b, c, f * t)
                let upX = channelUpsampler!(flat)
                x = upX.reshaped(b, bottomChannels, f, t)
                xt = channelUpsamplerT!(xt)
                let (xN, xtN) = ct(x, xt)
                x = xN
                xt = xtN
                let flatX = x.reshaped(b, bottomChannels, f * t)
                let dnX = channelDownsampler!(flatX)
                x = dnX.reshaped(b, c, f, t)
                xt = channelDownsamplerT!(xt)
            } else {
                let (xN, xtN) = ct(x, xt)
                x = xN
                xt = xtN
            }
        }
        mark("cross_transformer", x)

        // Decode (both branches in parallel).
        let offset = depth - tdecoder.count
        for (idx, dec) in decoder.enumerated() {
            let skip = saved.removeLast()
            let length = lengths.removeLast()
            let (xNew, pre) = dec(x, skip: skip, length: length)
            x = xNew
            if idx >= offset {
                let tdec = tdecoder[idx - offset]
                let lengthT = lengthsT.removeLast()
                // tdec.empty always false here.
                let skipT = savedT.removeLast()
                let (xtNew, _) = tdec(xt, skip: skipT, length: lengthT)
                xt = xtNew
                _ = pre
            }
            mark("dec_\(idx)", x)
        }

        precondition(saved.isEmpty && lengthsT.isEmpty && savedT.isEmpty,
                     "skip connections not fully consumed")

        // Reshape spectral output to [B, S, 2*C, Fq, T] and unnormalize.
        let S = sources.count
        x = x.reshaped(B, S, -1, Fq, T)
        x = x * stdX.expandedDimensions(axis: 1) + meanX.expandedDimensions(axis: 1)

        // iSTFT on the CAC-masked spec.
        var xOut = maskAndIspec(x, length: trainingLength)
        mark("mask+ispec", xOut)

        // Reshape time output and unnormalize.
        let actualLen = xt.shape.last!
        xt = xt.reshaped(B, S, -1, actualLen)
        xt = xt * stdT.expandedDimensions(axis: 1) + meanT.expandedDimensions(axis: 1)

        // Center-trim x to match xt then sum.
        let xtLen = xt.shape.last!
        xOut = centerTrim(xOut, length: xtLen)
        xOut = xt + xOut

        // Final trim.
        xOut = xOut[.ellipsis, 0 ..< trainingLength]
        if let pp = prePad {
            xOut = xOut[.ellipsis, 0 ..< pp]
        }
        _ = originalLength
        return xOut
    }
}
