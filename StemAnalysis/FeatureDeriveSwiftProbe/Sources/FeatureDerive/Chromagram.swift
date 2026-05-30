//
//  Chromagram.swift — apply librosa's chroma filterbank to a magnitude
//  spectrogram to produce a 12-pitch-class chromagram.
//
//  librosa.feature.chroma_stft computes |STFT|² (power), then multiplies
//  by a chroma filterbank that maps n_fft/2+1 frequency bins to 12 pitch
//  classes via gaussian-tuned overlapping filters. We skip reimplementing
//  the filterbank construction (`librosa.filters.chroma`) and instead
//  load the precomputed filterbank from disk — it's a pure function of
//  sr + n_fft + tuning, fixed for the lifetime of the app.
//

import Accelerate
import Foundation

public final class Chromagram {
    public let nBins: Int          // freq bins (n_fft/2 + 1)
    public let nPitches: Int = 12
    /// Row-major (12 * nBins) — pitch-class × freq bin.
    public let filterbank: [Float]

    public init(filterbank: [Float], nBins: Int) {
        precondition(filterbank.count == 12 * nBins,
                     "filterbank shape mismatch")
        self.filterbank = filterbank
        self.nBins = nBins
    }

    /// Load filterbank from a raw f32 file of shape (12, nBins).
    public convenience init(filterbankPath: URL, nBins: Int) throws {
        let data = try Data(contentsOf: filterbankPath)
        let count = data.count / MemoryLayout<Float>.stride
        precondition(count == 12 * nBins,
                     "filterbank file size mismatch — expected \(12 * nBins) floats, got \(count)")
        let arr: [Float] = data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.bindMemory(to: Float.self).baseAddress!,
                count: count
            ))
        }
        self.init(filterbank: arr, nBins: nBins)
    }

    /// Given a magnitude spectrogram (row-major [nFrames * nBins]),
    /// produce the max-bin-normalized chromagram in [nFrames * 12]
    /// row-major.
    ///
    /// IMPORTANT: librosa's chroma_stft uses the POWER spectrogram by
    /// default (|S|² before binning). Our magnitude input is |S|;
    /// the .square() step here matches librosa's `S = |S|²`.
    public func apply(magnitudeSpectrogram mag: [Float], nFrames: Int) -> [Float] {
        precondition(mag.count == nFrames * nBins)
        let nPitches = 12

        // 1) Square magnitudes → power (librosa default).
        var power = [Float](repeating: 0, count: mag.count)
        vDSP_vsq(mag, 1, &power, 1, vDSP_Length(mag.count))

        // 2) Per-frame normalization: librosa applies
        //    chroma_norm.normalize(power, norm=np.inf, axis=0) before
        //    multiplying by the filterbank. Specifically it divides each
        //    FRAME (column-wise in librosa's (n_bins, n_frames) layout)
        //    by the max of that frame's bins. Skip if max == 0.
        for f in 0 ..< nFrames {
            let base = f * nBins
            var frameMax: Float = 0
            vDSP_maxv(power.withUnsafeBufferPointer { $0.baseAddress! + base },
                      1, &frameMax, vDSP_Length(nBins))
            if frameMax > 0 {
                var inv = 1 / frameMax
                power.withUnsafeMutableBufferPointer { pPtr in
                    vDSP_vsmul(pPtr.baseAddress! + base, 1, &inv,
                               pPtr.baseAddress! + base, 1, vDSP_Length(nBins))
                }
            }
        }

        // 3) Matrix multiply: chroma_raw = filterbank @ power.T
        //    Where filterbank is (12, nBins) and power is (nFrames, nBins).
        //    We compute (12, nFrames) = filterbank @ power.T then
        //    transpose back to (nFrames, 12).
        //
        //    Equivalent: chroma[f, p] = Σ_k filterbank[p, k] * power[f, k]
        //    Using BLAS sgemm: A=power (nFrames × nBins, row-major),
        //                      B=filterbank (12 × nBins, row-major) viewed
        //                      as (nBins × 12) transposed,
        //                      C=chroma (nFrames × 12, row-major).
        var chroma = [Float](repeating: 0, count: nFrames * nPitches)
        power.withUnsafeBufferPointer { pPtr in
        filterbank.withUnsafeBufferPointer { fbPtr in
        chroma.withUnsafeMutableBufferPointer { cPtr in
            cblas_sgemm(
                CblasRowMajor,
                CblasNoTrans, CblasTrans,
                Int32(nFrames), Int32(nPitches), Int32(nBins),
                1.0,
                pPtr.baseAddress!, Int32(nBins),
                fbPtr.baseAddress!, Int32(nBins),
                0.0,
                cPtr.baseAddress!, Int32(nPitches)
            )
        }}}

        // 4) Per-frame max-bin normalize (sidecar convention).
        for f in 0 ..< nFrames {
            let base = f * nPitches
            var frameMax: Float = 0
            chroma.withUnsafeBufferPointer { cPtr in
                vDSP_maxv(cPtr.baseAddress! + base, 1, &frameMax, vDSP_Length(nPitches))
            }
            // Avoid divide-by-zero on silent frames; sidecar uses 1e-6.
            var divisor = max(frameMax, 1e-6)
            chroma.withUnsafeMutableBufferPointer { cPtr in
                vDSP_vsdiv(cPtr.baseAddress! + base, 1, &divisor,
                           cPtr.baseAddress! + base, 1, vDSP_Length(nPitches))
            }
        }

        return chroma
    }
}
