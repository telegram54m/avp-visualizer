//
//  Spectro.swift — STFT / iSTFT for HTDemucs.
//
//  Hand-rolled on MLXFFT.rfft / .irfft because the Python reference
//  pulls in third-party `mlx_spectro` which is non-trivial to port
//  wholesale. We only need a single fixed config: n_fft=4096,
//  hop=1024, Hann window (periodic), center=true, onesided, complex
//  output for STFT and real output for iSTFT.
//
//  Reference: torch.stft / torch.istft semantics (which Demucs
//  matches via `mlx_spectro`'s `torch_like=True`).
//

import Foundation
import MLX
import MLXFFT

/// Cached, fixed-config STFT/iSTFT pair. One instance per (n_fft,
/// hop) — HTDemucs only ever uses (4096, 1024).
final class Spectro {
    let nFft: Int
    let hop: Int
    let window: MLXArray  // [n_fft]
    /// PyTorch's `torch.stft(..., normalized=True)` divides each frame
    /// by `sqrt(n_fft)`. demucs's `spec.py` uses `normalized=True` on
    /// both STFT and iSTFT. We mirror this so amplitudes match.
    let normFactor: Float

    init(nFft: Int = 4096, hop: Int = 1024) {
        self.nFft = nFft
        self.hop = hop
        // Periodic Hann window: 0.5 - 0.5*cos(2π n / N), n in [0, N-1].
        // Matches torch.hann_window(periodic=True) which Demucs uses.
        let n = MLXArray(0 ..< Int32(nFft)).asType(Float.self)
        self.window = 0.5 - 0.5 * MLX.cos(2.0 * Float.pi * n / Float(nFft))
        self.normFactor = Float(nFft).squareRoot()
    }

    /// STFT. Input `x` shape `[B, C, T]` (or `[B*C, T]` — caller
    /// handles the reshape). Output complex64 shape `[B, C, F, N]`
    /// where F = n_fft/2 + 1 and N = ceil(T/hop) + 1 with center
    /// padding.
    ///
    /// Mirrors torch.stft(x, n_fft, hop, win_length=n_fft,
    /// window=hann, center=True, pad_mode='reflect',
    /// normalized=False, onesided=True, return_complex=True).
    func stft(_ x: MLXArray) -> MLXArray {
        // Demucs feeds in 3-D (B, C, T) and flattens B*C internally.
        var x = x
        var leadShape: [Int] = []
        if x.ndim == 3 {
            leadShape = [x.shape[0], x.shape[1]]
            x = x.reshaped(x.shape[0] * x.shape[1], x.shape[2])
        }
        precondition(x.ndim == 2, "stft input must be 2-D or 3-D")

        // Center padding: reflect-pad n_fft/2 on each side of the last axis.
        let padAmt = nFft / 2
        let padded = pad1d(x, paddings: (padAmt, padAmt), mode: "reflect")
        // padded: [B, T + n_fft]

        // Frame into [B, N, n_fft] using mlx as_strided.
        // N = 1 + (T_padded - n_fft) / hop
        let T = padded.shape[1]
        let nFrames = 1 + (T - nFft) / hop
        precondition(nFrames > 0, "stft input too short")

        // Build frames via as_strided. mlx-swift's as_strided takes
        // shape + strides (in elements).
        let B = padded.shape[0]
        let cont = padded.contiguous()
        // Strides for [B, N, n_fft]: outer = T (row stride), middle = hop, inner = 1
        let strides = [T, hop, 1]
        let frames = MLX.asStrided(
            cont, [B, nFrames, nFft],
            strides: strides, offset: 0
        )

        // DEBUG: dump frame 0 stats once.
        if ProcessInfo.processInfo.environment["SPECTRO_DEBUG"] != nil {
            eval(frames)
            let f0 = frames[0, 0]  // [n_fft]
            let f0Sum = MLX.sum(f0)
            let f0WSum = MLX.sum(f0 * window)
            eval(f0Sum); eval(f0WSum)
            let f0First = frames[0, 0, 0..<5].asArray(Float.self)
            print("    SPECTRO: frame[0,0,0..5] =", f0First)
            print("    SPECTRO: sum(frame[0,0]) =", f0Sum.asArray(Float.self)[0])
            print("    SPECTRO: sum(frame[0,0]*window) =", f0WSum.asArray(Float.self)[0])
            // Dump padded[0, 0..5] to compare with PyTorch.
            let p5 = padded[0, 0..<5].asArray(Float.self)
            print("    SPECTRO: padded[0, 0..5] =", p5)
            print("    SPECTRO: padded shape =", padded.shape)

            // Now compute rfft of frame[0,0]*window directly and compare DC.
            let oneFrame = (f0 * window).contiguous()  // [n_fft]
            let oneSpec = MLXFFT.rfft(oneFrame, axis: -1)
            eval(oneSpec)
            let dc = oneSpec[0].realPart()
            eval(dc)
            print("    SPECTRO: rfft(f0*w)[0].real =", dc.asArray(Float.self)[0])
            // Also test the windowed array exposed to the full rfft path.
            let windowedFull = (frames * window).contiguous()
            eval(windowedFull)
            let specCheck = MLXFFT.rfft(windowedFull, axis: -1)
            eval(specCheck)
            let dcAll = specCheck[0, 0, 0].realPart()
            eval(dcAll)
            print("    SPECTRO: rfft(frames*window)[0,0,0].real =", dcAll.asArray(Float.self)[0])
            // Also dump frame 2 to compare with PyTorch's post-slice index 0.
            let dc2 = specCheck[0, 2, 0].realPart()
            eval(dc2)
            print("    SPECTRO: rfft(frames*window)[0,2,0].real =", dc2.asArray(Float.self)[0])
            // What does frame 2 start with?
            eval(frames)
            let f2 = frames[0, 2, 0..<5].asArray(Float.self)
            print("    SPECTRO: frame[0,2,0..5] =", f2)
            // And what's at padded indices that frame 2 should be reading?
            // Frame 2 starts at offset 2*hop = 2048.
            let pAt2hop = padded[0, 2048 ..< 2053].asArray(Float.self)
            print("    SPECTRO: padded[0, 2048..2053] =", pAt2hop)
        }
        // Apply window: broadcast [n_fft] over [B, N, n_fft].
        let windowed = frames * window

        // FFT along the last axis: rfft -> [B, N, n_fft/2 + 1]
        // Divide by sqrt(n_fft) to mirror torch.stft(normalized=True).
        let spec = MLXFFT.rfft(windowed, axis: -1) / normFactor
        // Demucs wants [B, F, N], so transpose last two.
        var out = spec.transposed(0, 2, 1)

        // Restore leading dims if input was 3-D.
        if !leadShape.isEmpty {
            out = out.reshaped(leadShape[0], leadShape[1], out.shape[1], out.shape[2])
        }
        return out
    }

    /// Inverse STFT. Input shape `[B, C, F, N]` complex64 (4-D) or
    /// `[B, S, C, F, N]` (5-D). Output `[B, ..., length]` real.
    ///
    /// Reference: torch.istft with the same hann/center/onesided
    /// config. Uses overlap-add with the same window squared as
    /// the synthesis envelope.
    func istft(_ z: MLXArray, length: Int) -> MLXArray {
        var z = z
        var leadShape: [Int] = []
        if z.ndim == 5 {
            // [B, S, C, F, N] -> [B*S*C, F, N]
            leadShape = [z.shape[0], z.shape[1], z.shape[2]]
            z = z.reshaped(z.shape[0] * z.shape[1] * z.shape[2], z.shape[3], z.shape[4])
        } else if z.ndim == 4 {
            // [B, C, F, N] -> [B*C, F, N]
            leadShape = [z.shape[0], z.shape[1]]
            z = z.reshaped(z.shape[0] * z.shape[1], z.shape[2], z.shape[3])
        }
        precondition(z.ndim == 3, "istft input must be 3-, 4-, or 5-D")

        // z is [B, F, N]; transpose to [B, N, F] for irfft along last axis.
        // Multiply by sqrt(n_fft) to undo the forward STFT's normalization
        // — this matches torch.istft(normalized=True). NOTE: irfft also
        // divides by n_fft internally (numpy convention), so the net factor
        // applied to the input here is sqrt(n_fft)/n_fft = 1/sqrt(n_fft).
        let zNF = z.transposed(0, 2, 1) * normFactor
        // irfft -> [B, N, n_fft]
        let frames = MLXFFT.irfft(zNF, n: nFft, axis: -1)

        let N = frames.shape[1]
        let winSq = window * window  // envelope target
        let totalLen = (N - 1) * hop + nFft

        // Fused OLA kernel: single Metal launch replaces the Python-for-loop
        // (~2,700 graph ops) that was previously eating ~21% of forward time.
        let normalized = FusedKernels.fusedOverlapAddNormalize(
            frames: frames, window: window, windowSq: winSq,
            hop: hop, frame: nFft, outLen: totalLen
        )

        // Trim center padding: remove n_fft/2 on each side, then take `length` samples.
        let padAmt = nFft / 2
        let trimmed = normalized[0..., padAmt ..< (padAmt + length)]

        // Restore leading dims.
        if leadShape.count == 2 {
            return trimmed.reshaped(leadShape[0], leadShape[1], trimmed.shape[1])
        } else if leadShape.count == 3 {
            return trimmed.reshaped(
                leadShape[0], leadShape[1], leadShape[2], trimmed.shape[1])
        }
        return trimmed
    }
}
