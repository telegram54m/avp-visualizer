import Foundation

/// An estimated tempo together with how confident the estimate is.
public struct TempoEstimate: Sendable, Equatable {
    /// Beats per minute.
    public let bpm: Double

    /// Strength of the autocorrelation peak, 0...1. Low values mean the clip
    /// has no clear regular pulse (free-time or arrhythmic music).
    public let confidence: Float
}

/// Estimates a clip's tempo from the periodicity of its onsets.
public enum TempoDetector {

    /// Detects tempo by autocorrelating the onset novelty curve.
    ///
    /// - Parameters:
    ///   - audio: the decoded clip.
    ///   - minBPM: slowest tempo to consider.
    ///   - maxBPM: fastest tempo to consider.
    /// - Returns: the estimate, or `nil` if the clip is too short to analyze.
    public static func detect(
        in audio: DecodedAudio,
        minBPM: Double = 60,
        maxBPM: Double = 200
    ) -> TempoEstimate? {
        let onsets = OnsetDetector.detect(in: audio)
        let novelty = onsets.noveltyCurve
        let frameDuration = onsets.frameDuration
        guard novelty.count > 16, frameDuration > 0 else { return nil }

        // Mean-center the curve so silence contributes nothing to correlation.
        let mean = novelty.reduce(0, +) / Float(novelty.count)
        let centered = novelty.map { $0 - mean }

        // A "lag" is a delay in frames; convert the BPM range into lag bounds.
        let minLag = max(1, Int((60.0 / maxBPM) / frameDuration))
        let maxLag = min(centered.count - 1, Int((60.0 / minBPM) / frameDuration))
        guard maxLag > minLag else { return nil }

        var bestLag = minLag
        var bestWeighted = -Float.infinity
        var bestRaw: Float = 0

        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in 0..<(centered.count - lag) {
                sum += centered[i] * centered[i + lag]
            }
            let raw = sum / Float(centered.count - lag)

            // Mild preference for tempi near 120 BPM — curbs octave errors
            // (mistaking half- or double-time for the real tempo).
            let bpm = 60.0 / (Double(lag) * frameDuration)
            let preference = Float(max(0.3, 1.0 - 0.5 * abs(log2(bpm / 120.0))))
            let weighted = raw * preference

            if weighted > bestWeighted {
                bestWeighted = weighted
                bestRaw = raw
                bestLag = lag
            }
        }

        let bpm = 60.0 / (Double(bestLag) * frameDuration)

        // Confidence: the winning correlation relative to the curve's energy.
        var zeroLag: Float = 0
        for value in centered { zeroLag += value * value }
        zeroLag /= Float(centered.count)
        let confidence = zeroLag > 0 ? min(1, max(0, bestRaw / zeroLag)) : 0

        return TempoEstimate(bpm: bpm, confidence: confidence)
    }
}
