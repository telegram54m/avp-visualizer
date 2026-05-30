//
//  STFT.swift — real-input short-time Fourier transform on top of
//  Accelerate vDSP. Provides the magnitude spectrogram that the
//  chromagram and onset-detection paths consume.
//
//  Conventions match numpy / librosa:
//    - Periodic Hann window (0.5 - 0.5 cos(2π n / N))
//    - center=True (reflect-pad input by n_fft/2 on each side)
//    - Magnitude bins 0 .. n_fft/2 inclusive (n_fft/2 + 1 bins)
//    - Unnormalized: bin amplitude = |Σ frame*window * e^{-j…}|
//

import Accelerate
import Foundation

public final class STFT {
    public let nFft: Int
    public let hop: Int
    public let nBins: Int  // n_fft/2 + 1
    public let window: [Float]

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    public init(nFft: Int, hop: Int) {
        precondition(nFft > 0 && (nFft & (nFft - 1)) == 0, "n_fft must be power of 2")
        precondition(hop > 0)
        self.nFft = nFft
        self.hop = hop
        self.nBins = nFft / 2 + 1
        // Periodic Hann, matches torch.hann_window(periodic=True) and
        // librosa's default scipy.signal.get_window('hann', N, fftbins=True).
        self.window = (0 ..< nFft).map { n in
            0.5 - 0.5 * cosf(2 * .pi * Float(n) / Float(nFft))
        }
        self.log2n = vDSP_Length(log2(Double(nFft)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for n_fft=\(nFft)")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Returns the magnitude spectrogram of `signal`. Output shape is
    /// [nFrames * nBins] in row-major (frame-major) order. Use
    /// `magnitudeAt(_:bin:)` semantics for indexing.
    public func magnitude(_ signal: [Float]) -> (nFrames: Int, mag: [Float]) {
        // center=True: reflect-pad by n_fft/2 on each side. librosa
        // (and torch.stft) both use this.
        let pad = nFft / 2
        let padded = STFT.reflectPad(signal, pad: pad)
        let T = padded.count
        guard T >= nFft else {
            return (0, [])
        }
        let nFrames = 1 + (T - nFft) / hop

        let halfN = nFft / 2
        var mag = [Float](repeating: 0, count: nFrames * nBins)

        // Scratch buffers reused across frames.
        var windowed = [Float](repeating: 0, count: nFft)
        var realIn = [Float](repeating: 0, count: halfN)
        var imagIn = [Float](repeating: 0, count: halfN)
        var realOut = [Float](repeating: 0, count: halfN)
        var imagOut = [Float](repeating: 0, count: halfN)
        var magScratch = [Float](repeating: 0, count: halfN)

        let log2n = self.log2n

        // vDSP_fft_zrip: in-place real FFT using split-complex storage.
        // Input frame of length N is interpreted as N/2 split-complex
        // samples by stuffing even samples into .realp and odd samples
        // into .imagp. The result is packed so that:
        //   - output[0].real = DC (real, X[0])
        //   - output[0].imag = Nyquist (real, X[N/2])
        //   - output[k].real / .imag for k in 1..N/2-1 = X[k]'s real/imag
        // and is scaled by 2 (Accelerate's convention).
        windowed.withUnsafeMutableBufferPointer { wPtr in
            padded.withUnsafeBufferPointer { padPtr in
                realIn.withUnsafeMutableBufferPointer { realInPtr in
                imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                magScratch.withUnsafeMutableBufferPointer { magPtr in
                window.withUnsafeBufferPointer { winPtr in
                mag.withUnsafeMutableBufferPointer { magOutPtr in
                    var inSplit = DSPSplitComplex(
                        realp: realInPtr.baseAddress!,
                        imagp: imagInPtr.baseAddress!
                    )
                    var outSplit = DSPSplitComplex(
                        realp: realOutPtr.baseAddress!,
                        imagp: imagOutPtr.baseAddress!
                    )
                    for f in 0 ..< nFrames {
                        let start = f * hop
                        // windowed = padded[start..<start+nFft] * window
                        vDSP_vmul(
                            padPtr.baseAddress! + start, 1,
                            winPtr.baseAddress!, 1,
                            wPtr.baseAddress!, 1,
                            vDSP_Length(nFft)
                        )
                        // Stuff into split-complex: even → realp, odd → imagp.
                        wPtr.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: halfN
                        ) { interleaved in
                            vDSP_ctoz(interleaved, 2, &inSplit, 1, vDSP_Length(halfN))
                        }
                        // Forward real FFT.
                        vDSP_fft_zrop(
                            fftSetup,
                            &inSplit, 1,
                            &outSplit, 1,
                            log2n, FFTDirection(FFT_FORWARD)
                        )

                        // Magnitudes.
                        //
                        // The N/2 packed bins decode to N/2+1 spectrum bins as:
                        //   spec[0]      = realOut[0] / 2
                        //   spec[N/2]    = imagOut[0] / 2  (Nyquist)
                        //   spec[k]      = (realOut[k] + j·imagOut[k]) / 2  for k in 1..N/2-1
                        //
                        // The /2 comes from vDSP's "twice the conventional value"
                        // packing. We compensate so amplitudes match numpy.fft.rfft.
                        //
                        // Magnitude for bins 1..halfN-1:
                        vDSP_zvabs(
                            &outSplit, 1,
                            magPtr.baseAddress!, 1,
                            vDSP_Length(halfN)
                        )
                        let scale: Float = 0.5
                        var halved = [Float](repeating: 0, count: halfN)
                        cblas_scopy(Int32(halfN), magPtr.baseAddress!, 1, &halved, 1)
                        vDSP_vsmul(halved, 1, [scale], &halved, 1, vDSP_Length(halfN))

                        let outBase = magOutPtr.baseAddress! + f * nBins
                        // DC and Nyquist come from the packed bin 0.
                        outBase[0] = abs(realOutPtr[0]) * 0.5
                        outBase[halfN] = abs(imagOutPtr[0]) * 0.5
                        // Bins 1..halfN-1: copy from halved[1..halfN-1].
                        for k in 1 ..< halfN {
                            outBase[k] = halved[k]
                        }
                    }
                }}}}}}}}
        }
        return (nFrames, mag)
    }

    /// numpy-style reflect padding on a 1-D Float buffer (mode='reflect').
    /// For [a,b,c,d,e] padded 2 left, 2 right → [c,b,a,b,c,d,e,d,c].
    public static func reflectPad(_ x: [Float], pad: Int) -> [Float] {
        if pad == 0 { return x }
        let n = x.count
        precondition(n >= 2, "reflect needs >= 2 samples")
        var out = [Float](repeating: 0, count: n + 2 * pad)
        // Left pad: reflect from index 1..pad
        for i in 0 ..< pad {
            out[i] = x[pad - i]
        }
        // Middle
        for i in 0 ..< n {
            out[pad + i] = x[i]
        }
        // Right pad: reflect from index n-2..n-pad-1
        for i in 0 ..< pad {
            out[pad + n + i] = x[n - 2 - i]
        }
        return out
    }
}
