//
//  Onset.swift — mel-spectrogram spectral flux + librosa-style peak
//  picking. Matches `librosa.onset.onset_detect(y, sr, hop, units='frames')`
//  with defaults.
//
//  Pipeline (mirrors librosa source 0.10+):
//    1. mel_power = mel_filterbank @ |STFT|²
//    2. log_mel = power_to_db(mel_power, ref=np.max)
//    3. flux[t] = max(0, log_mel[:, t] - log_mel[:, t-1])  (rectified)
//    4. env[t] = mean(flux[:, t]) over mel bands
//    5. env /= max(env, 1e-10)                              (normalize=True)
//    6. peak_pick with sr/hop-derived defaults
//

import Accelerate
import Foundation

public final class OnsetDetector {
    public let sr: Int
    public let hop: Int
    public let nMels: Int
    public let nBins: Int
    /// Row-major (nMels × nBins).
    public let melFilterbank: [Float]

    public init(sr: Int, hop: Int, nBins: Int, melFilterbank: [Float], nMels: Int = 128) {
        precondition(melFilterbank.count == nMels * nBins,
                     "mel filterbank shape mismatch — expected \(nMels * nBins) floats")
        self.sr = sr
        self.hop = hop
        self.nMels = nMels
        self.nBins = nBins
        self.melFilterbank = melFilterbank
    }

    public convenience init(
        sr: Int, hop: Int, nBins: Int,
        melFilterbankPath: URL, nMels: Int = 128
    ) throws {
        let data = try Data(contentsOf: melFilterbankPath)
        let count = data.count / MemoryLayout<Float>.stride
        precondition(count == nMels * nBins,
                     "mel filterbank file size mismatch — expected \(nMels * nBins), got \(count)")
        let arr: [Float] = data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.bindMemory(to: Float.self).baseAddress!,
                count: count
            ))
        }
        self.init(sr: sr, hop: hop, nBins: nBins, melFilterbank: arr, nMels: nMels)
    }

    /// Compute the onset envelope from the magnitude spectrogram (row-major
    /// [nFrames × nBins]).
    public func onsetEnvelope(magnitude mag: [Float], nFrames: Int) -> [Float] {
        precondition(mag.count == nFrames * nBins)

        // Power spectrogram |S|²
        var power = [Float](repeating: 0, count: mag.count)
        vDSP_vsq(mag, 1, &power, 1, vDSP_Length(mag.count))

        // mel_power = power @ melFilterbank.T → (nFrames × nMels), row-major
        var melPower = [Float](repeating: 0, count: nFrames * nMels)
        power.withUnsafeBufferPointer { pPtr in
        melFilterbank.withUnsafeBufferPointer { fbPtr in
        melPower.withUnsafeMutableBufferPointer { mPtr in
            cblas_sgemm(
                CblasRowMajor,
                CblasNoTrans, CblasTrans,
                Int32(nFrames), Int32(nMels), Int32(nBins),
                1.0,
                pPtr.baseAddress!, Int32(nBins),
                fbPtr.baseAddress!, Int32(nBins),
                0.0,
                mPtr.baseAddress!, Int32(nMels)
            )
        }}}

        // power_to_db with ref=np.max:
        //   db = 10 * log10(power / max(power))  clipped at -80
        // librosa uses max across ALL of mel_power, not per-frame.
        var globalMax: Float = 0
        vDSP_maxv(melPower, 1, &globalMax, vDSP_Length(melPower.count))
        let refValue = max(globalMax, 1e-10)
        let amin: Float = 1e-10  // librosa default
        let topDb: Float = 80    // librosa default
        var logMel = [Float](repeating: 0, count: melPower.count)
        for i in 0 ..< melPower.count {
            let p = max(melPower[i], amin)
            logMel[i] = 10 * log10f(p / refValue)
        }
        // Clip at -top_db relative to its own max (which is 0 since we
        // divided by ref).
        let floor: Float = -topDb
        for i in 0 ..< logMel.count {
            if logMel[i] < floor { logMel[i] = floor }
        }

        // Spectral flux: flux[m, t] = max(0, logMel[t, m] - logMel[t-1, m]).
        // logMel is row-major (nFrames × nMels) — same orientation as
        // melPower above. So accessing frame t at mel m is
        // logMel[t * nMels + m].
        //
        // librosa pads with a leading zero column so the envelope length
        // equals nFrames (frame 0 → 0).
        var env = [Float](repeating: 0, count: nFrames)
        for t in 1 ..< nFrames {
            var acc: Float = 0
            for m in 0 ..< nMels {
                let d = logMel[t * nMels + m] - logMel[(t - 1) * nMels + m]
                if d > 0 { acc += d }
            }
            env[t] = acc / Float(nMels)
        }
        // env[0] = 0 (no prior frame)
        return env
    }

    /// Onset frame indices (boolean per frame).
    public func detect(magnitude mag: [Float], nFrames: Int) -> [Bool] {
        var env = onsetEnvelope(magnitude: mag, nFrames: nFrames)
        // Normalize (librosa default normalize=True).
        var envMax: Float = 0
        vDSP_maxv(env, 1, &envMax, vDSP_Length(env.count))
        let divisor = max(envMax, 1e-10)
        var inv = 1.0 / divisor
        vDSP_vsmul(env, 1, &inv, &env, 1, vDSP_Length(env.count))

        // librosa default peak_pick parameters, computed from sr/hop.
        let preMax = Int((0.03 * Double(sr) / Double(hop)).rounded())
        let postMax = Int((0.00 * Double(sr) / Double(hop) + 1).rounded())
        let preAvg = Int((0.10 * Double(sr) / Double(hop)).rounded())
        let postAvg = Int((0.10 * Double(sr) / Double(hop) + 1).rounded())
        let wait = Int((0.03 * Double(sr) / Double(hop)).rounded())
        let delta: Float = 0.07

        return Self.peakPick(
            env,
            preMax: preMax, postMax: postMax,
            preAvg: preAvg, postAvg: postAvg,
            delta: delta, wait: wait
        )
    }

    /// librosa.util.peak_pick port. Returns bool[] (true at peak indices).
    ///
    /// A sample i is a peak iff:
    ///   (a) x[i] == max(x[max(0, i-preMax+1) ... min(N, i+postMax)])
    ///   (b) x[i] >= mean(x[max(0, i-preAvg+1) ... min(N, i+postAvg)]) + delta
    ///   (c) i is at least `wait + 1` samples after the previous peak
    ///
    /// (The right end of each window is *exclusive*, matching numpy slicing.)
    public static func peakPick(
        _ x: [Float],
        preMax: Int, postMax: Int,
        preAvg: Int, postAvg: Int,
        delta: Float, wait: Int
    ) -> [Bool] {
        let n = x.count
        var peaks = [Bool](repeating: false, count: n)
        var lastPeak: Int = -wait - 1  // so the first eligible index passes (c)

        for i in 0 ..< n {
            // (a) local max
            let maxLo = max(0, i - preMax + 1)
            let maxHi = min(n, i + postMax)  // exclusive
            if maxHi <= maxLo { continue }
            var windowMax: Float = -.infinity
            for j in maxLo ..< maxHi {
                if x[j] > windowMax { windowMax = x[j] }
            }
            if x[i] != windowMax { continue }

            // (b) above moving mean + delta
            let avgLo = max(0, i - preAvg + 1)
            let avgHi = min(n, i + postAvg)  // exclusive
            if avgHi <= avgLo { continue }
            var sum: Float = 0
            for j in avgLo ..< avgHi { sum += x[j] }
            let mean = sum / Float(avgHi - avgLo)
            if x[i] < mean + delta { continue }

            // (c) wait window
            if i - lastPeak <= wait { continue }

            peaks[i] = true
            lastPeak = i
        }
        return peaks
    }
}
