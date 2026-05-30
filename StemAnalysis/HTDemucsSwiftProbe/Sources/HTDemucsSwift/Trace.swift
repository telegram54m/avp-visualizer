//
//  Trace.swift — record intermediate activations from the forward
//  pass to disk, mirroring what tools/trace_pytorch.py captures.
//
//  When `HTDemucs.traceDir` is non-nil, the forward path writes each
//  named tensor as raw float32 + a JSON manifest of shapes/stats. The
//  Swift parity bisect (tools/compare_traces.py) then diffs the
//  manifests against the PyTorch reference.
//

import Foundation
import MLX

public final class TraceCollector {
    public let dir: URL
    private var manifest: [String: [String: Any]] = [:]

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    public func saveReal(_ arr: MLXArray, name: String) {
        eval(arr)
        let floats: [Float] = arr.asArray(Float.self)
        let data = floats.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        try? data.write(to: dir.appendingPathComponent("\(name).f32"))
        let info: [String: Any] = [
            "shape": arr.shape,
            "dtype": "\(arr.dtype)",
            "first5": floats.prefix(5).map { Double($0) },
            "last5": floats.suffix(5).map { Double($0) },
            "mean": Double(floats.reduce(0.0, { $0 + $1 }) / Float(floats.count)),
            "std": Double(stdOf(floats)),
            "min": Double(floats.min() ?? 0),
            "max": Double(floats.max() ?? 0),
        ]
        manifest[name] = info
    }

    /// Save a complex-valued array as interleaved real/imag floats,
    /// with shape gaining a trailing dimension of 2.
    public func saveComplex(_ arr: MLXArray, name: String) {
        eval(arr)
        let real = arr.realPart()
        let imag = arr.imaginaryPart()
        // Stack along last axis → [..., 2].
        let interleaved = MLX.stacked([real, imag], axis: -1).contiguous()
        eval(interleaved)
        let floats: [Float] = interleaved.asArray(Float.self)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: dir.appendingPathComponent("\(name).f32"))
        let realFloats: [Float] = real.asArray(Float.self)
        let imagFloats: [Float] = imag.asArray(Float.self)
        var sumAbs: Double = 0
        for i in 0 ..< realFloats.count {
            let r = Double(realFloats[i])
            let im = Double(imagFloats[i])
            sumAbs += (r * r + im * im).squareRoot()
        }
        let info: [String: Any] = [
            "shape": interleaved.shape,
            "dtype": "complex64_interleaved",
            "first5_real": realFloats.prefix(5).map { Double($0) },
            "first5_imag": imagFloats.prefix(5).map { Double($0) },
            "mean_abs": sumAbs / Double(realFloats.count),
        ]
        manifest[name] = info
    }

    public func writeManifest() throws {
        let json = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try json.write(to: dir.appendingPathComponent("manifest.json"))
    }

    private func stdOf(_ a: [Float]) -> Float {
        let n = Float(a.count)
        let m = a.reduce(0.0, { $0 + $1 }) / n
        var s2: Float = 0
        for v in a { s2 += (v - m) * (v - m) }
        return (s2 / n).squareRoot()
    }
}

// MARK: - Trace-mode forward variant

public extension HTDemucs {
    /// Trace-enabled forward. Saves each named intermediate to
    /// `collector` and returns the final output.
    func forwardTraced(_ mix: MLXArray, into collector: TraceCollector) -> MLXArray {
        var mix = mix
        var prePad: Int? = nil
        let trainingLength = Int(segment * Float(samplerate))
        if mix.shape.last! < trainingLength {
            prePad = mix.shape.last!
            mix = padded(
                mix,
                widths: [IntOrPair(0), IntOrPair(0), IntOrPair((0, trainingLength - prePad!))],
                mode: .constant
            )
        }
        collector.saveReal(mix, name: "mix_input")

        let z = spec(mix)
        collector.saveComplex(z, name: "spec")

        var x = magnitude(z)
        collector.saveReal(x, name: "mag")

        let B = x.shape[0]
        let Fq = x.shape[2]
        let T = x.shape[3]
        let meanX = MLX.mean(x, axes: [1, 2, 3], keepDims: true)
        let stdX = MLX.std(x, axes: [1, 2, 3], keepDims: true)
        x = (x - meanX) / (1e-5 + stdX)
        collector.saveReal(x, name: "mag_normed")

        var xt = mix
        let meanT = MLX.mean(xt, axes: [1, 2], keepDims: true)
        let stdT = MLX.std(xt, axes: [1, 2], keepDims: true)
        xt = (xt - meanT) / (1e-5 + stdT)
        collector.saveReal(xt, name: "xt_normed")

        var saved: [MLXArray] = []
        var savedT: [MLXArray] = []
        var lengths: [Int] = []
        var lengthsT: [Int] = []

        for (idx, enc) in encoder.enumerated() {
            lengths.append(x.shape.last!)
            let inject: MLXArray? = nil
            if idx < tencoder.count {
                lengthsT.append(xt.shape.last!)
                let tenc = tencoder[idx]
                xt = tenc(xt)
                collector.saveReal(xt, name: "tenc_\(idx)")
                savedT.append(xt)
            }
            x = enc(x, inject: inject)
            if idx == 0, let fe = freqEmb {
                let frs = MLXArray(0 ..< Int32(x.shape[2]))
                let emb = fe(frs).transposed(1, 0)
                let embReshaped = emb.reshaped(1, emb.shape[0], emb.shape[1], 1)
                x = x + freqEmbScale * embReshaped
            }
            collector.saveReal(x, name: "enc_\(idx)")
            saved.append(x)
        }

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
                collector.saveReal(x, name: "xtransformer_x_in")
                collector.saveReal(xt, name: "xtransformer_xt_in")
                let (xN, xtN) = ct(x, xt, trace: collector)
                x = xN
                xt = xtN
                collector.saveReal(x, name: "xtransformer_x")
                collector.saveReal(xt, name: "xtransformer_xt")
                let flatX = x.reshaped(b, bottomChannels, f * t)
                let dnX = channelDownsampler!(flatX)
                x = dnX.reshaped(b, c, f, t)
                xt = channelDownsamplerT!(xt)
            }
        }

        let offset = depth - tdecoder.count
        for (idx, dec) in decoder.enumerated() {
            let skip = saved.removeLast()
            let length = lengths.removeLast()
            let (xNew, _) = dec(x, skip: skip, length: length)
            x = xNew
            collector.saveReal(x, name: "dec_\(idx)")
            if idx >= offset {
                let tdec = tdecoder[idx - offset]
                let lengthT = lengthsT.removeLast()
                let skipT = savedT.removeLast()
                let (xtNew, _) = tdec(xt, skip: skipT, length: lengthT)
                xt = xtNew
                collector.saveReal(xt, name: "tdec_\(idx)")
            }
        }

        let S = sources.count
        x = x.reshaped(B, S, -1, Fq, T)
        x = x * stdX.expandedDimensions(axis: 1) + meanX.expandedDimensions(axis: 1)
        collector.saveReal(x, name: "x_pre_mask")

        // mask + ispec (combined via realImagToComplex)
        var xOut = maskAndIspec(x, length: trainingLength)
        collector.saveReal(xOut, name: "ispec")

        let actualLen = xt.shape.last!
        xt = xt.reshaped(B, S, -1, actualLen)
        xt = xt * stdT.expandedDimensions(axis: 1) + meanT.expandedDimensions(axis: 1)
        collector.saveReal(xt, name: "xt_unnorm")

        let xtLen = xt.shape.last!
        xOut = centerTrim(xOut, length: xtLen)
        xOut = xt + xOut
        collector.saveReal(xOut, name: "final_pre_trim")

        xOut = xOut[.ellipsis, 0 ..< trainingLength]
        if let pp = prePad {
            xOut = xOut[.ellipsis, 0 ..< pp]
        }
        collector.saveReal(xOut, name: "final")
        return xOut
    }
}
