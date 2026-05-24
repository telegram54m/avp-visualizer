import Foundation

/// Streaming onset detector. The package's existing `OnsetDetector` runs over
/// a whole clip in one pass (peak-picking on a buffered spectral-flux curve),
/// which doesn't translate to a live-mic loop where we only see one buffer at
/// a time. This detector is the live-loop counterpart: an exponential-moving-
/// average of recent loudness with a refractory period, suitable for driving
/// real-time visualizer onsets at ~20-50 Hz.
///
/// It trades the offline detector's precision for low latency and a stateful
/// per-buffer API:
///
/// ```
/// let detector = RealtimeOnsetDetector()
/// for buffer in liveBuffers {
///     let result = detector.process(buffer)
///     if result.onset { ... }
/// }
/// ```
public final class RealtimeOnsetDetector {

    /// Ratio of instantaneous RMS to running-average RMS that counts as an
    /// onset. 1.5-2.0 is the useful range for percussive music. Higher =
    /// fewer false positives, more missed soft hits.
    public var threshold: Float

    /// Minimum spacing between successive onsets, in seconds. Prevents a
    /// single loud transient (which often has multiple sample-level peaks)
    /// from firing as several onsets back-to-back.
    public var refractory: Double

    /// EMA smoothing factor for the running-average baseline. Smaller =
    /// slower-adapting baseline = more sensitive to short bursts.
    public var baselineSmoothing: Float

    // Live state.
    private var baselineEnergy: Float = 0.001
    private var timeSinceLastOnset: Double = .infinity

    /// One smoothed loudness value the visualizer can read directly,
    /// independent of onset firing.
    public private(set) var smoothedLoudness: Float = 0
    /// Smoothing for the published `smoothedLoudness` output — higher than
    /// the internal baseline so it tracks energy more closely.
    public var loudnessSmoothing: Float

    public init(
        threshold: Float = 1.6,
        refractory: Double = 0.08,
        baselineSmoothing: Float = 0.05,
        loudnessSmoothing: Float = 0.25
    ) {
        self.threshold = threshold
        self.refractory = refractory
        self.baselineSmoothing = baselineSmoothing
        self.loudnessSmoothing = loudnessSmoothing
    }

    /// Process one buffer's worth of mono samples plus its duration, return
    /// the buffer's RMS and whether an onset crossed the threshold during it.
    public func process(_ samples: [Float], duration: Double) -> (rms: Float, onset: Bool) {
        timeSinceLastOnset += duration

        let rms = Self.rms(samples)
        let ratio = rms / max(baselineEnergy, 0.001)
        let onset = ratio > threshold && timeSinceLastOnset > refractory

        if onset { timeSinceLastOnset = 0 }
        baselineEnergy = (1 - baselineSmoothing) * baselineEnergy + baselineSmoothing * rms
        smoothedLoudness += (rms - smoothedLoudness) * loudnessSmoothing

        return (rms, onset)
    }

    /// Drop accumulated state — call when toggling the listener on so the
    /// first few buffers don't fire a flurry of false onsets from old state.
    public func reset() {
        baselineEnergy = 0.001
        timeSinceLastOnset = .infinity
        smoothedLoudness = 0
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }
}
