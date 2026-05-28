import Foundation

/// Per-frame output of ``BeatTracker``. All visualizers can read these
/// fields off ``FeatureFrame`` to drive rhythmically-locked animations
/// without each one rolling its own tempo estimator.
public struct BeatState: Sendable, Equatable, Codable {
    /// Currently estimated tempo in beats per minute. `0` while the tracker
    /// hasn't locked yet (need ≥ 4 onsets in a stable interval).
    public let bpm: Float

    /// Fractional position within the current beat, `0 ..< 1`. `0` is on
    /// the beat; `0.5` is halfway to the next beat. Useful for continuous
    /// animations (e.g. radius pulse = `1 + sin(phase × 2π) × strength`).
    public let phase: Float

    /// `true` on the frame a beat boundary was just crossed. Treat like
    /// ``FeatureFrame/onset`` but rhythmically smoothed — fires on the
    /// predicted beat grid, not on every percussive transient. Will fire
    /// during sustained chords with no actual onsets, as long as the
    /// tempo was previously established.
    public let beatTrigger: Bool

    /// `0 ..< 1` measure of how confident the tracker is in `bpm`.
    /// Visualizers should gate beat-locked behavior on this — below ~0.3
    /// the tempo estimate is too noisy to drive a steady pulse.
    public let confidence: Float

    public static let unknown = BeatState(
        bpm: 0, phase: 0, beatTrigger: false, confidence: 0
    )

    public init(bpm: Float, phase: Float, beatTrigger: Bool, confidence: Float) {
        self.bpm = bpm
        self.phase = phase
        self.beatTrigger = beatTrigger
        self.confidence = confidence
    }
}

/// Incremental, stateful beat tracker. Fed an onset signal + clock each
/// frame, emits a ``BeatState`` with estimated tempo, beat phase, a per-
/// frame beat trigger, and confidence.
///
/// Algorithm:
/// 1. Maintain a rolling window of the most-recent N onset times.
/// 2. Compute inter-onset intervals (IOIs), filter to a musical range
///    (40–300 BPM → 0.2–1.5 s).
/// 3. Pick the candidate beat period among {median, ½ median, 2× median}
///    that best aligns with the rest of the IOI distribution. This
///    handles the classic "half-time vs. real tempo" ambiguity.
/// 4. Smooth the period estimate over time so it doesn't snap on
///    every new onset.
/// 5. Maintain a ``lastBeatTime`` clock; advance it by ``beatPeriod``
///    whenever ``elapsedTime`` crosses the next beat. Fire
///    ``beatTrigger = true`` on those crossings.
/// 6. When an onset arrives near a predicted beat (within ±20% of
///    the period), gently re-anchor ``lastBeatTime`` to the onset.
///    This keeps the predicted beat grid locked to actual percussion.
///
/// Designed to be cheap (O(window size) per onset, O(1) per frame).
/// The window is small enough that adapting to a tempo change takes
/// 4–8 onsets — fast enough for typical music transitions.
public final class BeatTracker {

    /// Number of recent onset times kept for IOI analysis. Larger =
    /// more stable tempo estimate, slower to adapt to tempo changes.
    /// 16 onsets ≈ 4 bars at common tempos.
    public var historySize: Int = 16

    /// Fraction of the beat period an onset can be off and still count as
    /// "on beat" for re-anchoring (and for downstream visual purposes).
    public var beatTolerance: Float = 0.20

    /// EMA factor for tempo smoothing. Lower = more stable but slower to
    /// adapt to tempo changes.
    public var tempoSmoothing: Float = 0.30

    /// Min/max beat periods accepted as plausible tempos (seconds per beat).
    /// 0.2 s ≈ 300 BPM, 1.5 s ≈ 40 BPM. Outside this range, candidate
    /// intervals are ignored.
    public var minBeatPeriod: Double = 0.20
    public var maxBeatPeriod: Double = 1.50

    private var recentOnsets: [Double] = []
    private var beatPeriod: Double = 0
    private var lastBeatTime: Double = 0
    private var confidence: Float = 0
    private var hasLock: Bool = false

    public init() {}

    /// Reset all state — call when starting a new clip / track.
    public func reset() {
        recentOnsets.removeAll(keepingCapacity: true)
        beatPeriod = 0
        lastBeatTime = 0
        confidence = 0
        hasLock = false
    }

    /// Feed one frame of input — current clock + whether an onset fired
    /// in this frame. Returns the per-frame beat state.
    public func update(time: Double, hadOnset: Bool) -> BeatState {
        if hadOnset {
            ingestOnset(at: time)
        }

        // Advance the beat clock until lastBeatTime catches up to the
        // current frame. Each crossing of a beat boundary is one trigger
        // event. We collapse multiple crossings into a single trigger
        // for this frame (rare unless a very long pause / time skip).
        var triggered = false
        if hasLock && beatPeriod > 0 {
            while time - lastBeatTime >= beatPeriod {
                lastBeatTime += beatPeriod
                triggered = true
            }
        }

        let phase: Float
        if hasLock && beatPeriod > 0 {
            let raw = (time - lastBeatTime) / beatPeriod
            phase = Float(max(0, min(0.9999, raw)))
        } else {
            phase = 0
        }

        let bpm: Float = beatPeriod > 0 ? Float(60.0 / beatPeriod) : 0
        return BeatState(
            bpm: bpm,
            phase: phase,
            beatTrigger: triggered,
            confidence: confidence
        )
    }

    /// Force the tracker to a known tempo + beat-time anchor. Used by
    /// the offline pipeline, which can compute tempo over the whole clip
    /// up front via ``TempoDetector`` before any frames are emitted.
    public func setTempo(bpm: Double, anchorTime: Double, confidence: Float) {
        let period = 60.0 / bpm
        guard period >= minBeatPeriod, period <= maxBeatPeriod else { return }
        self.beatPeriod = period
        self.lastBeatTime = anchorTime
        self.confidence = max(0, min(1, confidence))
        self.hasLock = self.confidence > 0
    }

    // MARK: - Internals

    private func ingestOnset(at time: Double) {
        recentOnsets.append(time)
        if recentOnsets.count > historySize {
            recentOnsets.removeFirst(recentOnsets.count - historySize)
        }
        updateTempoEstimate()
        reanchorIfNearBeat(onsetTime: time)
    }

    private func updateTempoEstimate() {
        guard recentOnsets.count >= 4 else { return }
        // Pairwise consecutive IOIs in the musical range.
        var intervals: [Double] = []
        intervals.reserveCapacity(recentOnsets.count)
        for i in 1..<recentOnsets.count {
            let dt = recentOnsets[i] - recentOnsets[i - 1]
            if dt >= minBeatPeriod, dt <= maxBeatPeriod {
                intervals.append(dt)
            }
        }
        guard intervals.count >= 3 else { return }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]

        // Disambiguate half / true / double tempo by counting how many
        // intervals cluster near each candidate.
        let candidates: [Double] = [median, median * 0.5, median * 2.0]
        var bestCandidate = median
        var bestScore = 0
        for candidate in candidates {
            guard candidate >= minBeatPeriod, candidate <= maxBeatPeriod else { continue }
            var score = 0
            for iv in intervals {
                // Count this interval if it's close to candidate OR an
                // integer multiple of it (so eighth notes still vote for
                // the quarter-note period, etc.).
                for n in 1...3 {
                    let target = candidate * Double(n)
                    if abs(iv - target) / target < Double(beatTolerance) {
                        score += 1
                        break
                    }
                }
            }
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        // Smooth toward the new candidate. On first lock, snap to it.
        if !hasLock {
            beatPeriod = bestCandidate
            lastBeatTime = recentOnsets.last ?? 0
            hasLock = true
        } else {
            let s = Double(tempoSmoothing)
            beatPeriod = beatPeriod * (1 - s) + bestCandidate * s
        }

        // Confidence: fraction of intervals that align with the chosen
        // candidate. Scales smoothly with how locked the rhythm is.
        let rawConfidence = Float(bestScore) / Float(intervals.count)
        // EMA-smooth confidence so it doesn't flicker frame-to-frame.
        confidence = confidence * 0.7 + rawConfidence * 0.3
    }

    private func reanchorIfNearBeat(onsetTime: Double) {
        guard hasLock, beatPeriod > 0 else { return }
        let dt = onsetTime - lastBeatTime
        let beats = dt / beatPeriod
        let nearestBeatIndex = beats.rounded()
        let nearestBeatTime = lastBeatTime + nearestBeatIndex * beatPeriod
        let offset = abs(onsetTime - nearestBeatTime)
        if offset / beatPeriod < Double(beatTolerance) {
            // Pull lastBeatTime gently toward the onset's beat. We anchor
            // on the beat NEAREST to this onset, not necessarily the
            // next one — onsets can land on any beat in the bar.
            let target = nearestBeatTime
                       + (onsetTime - nearestBeatTime) * 0.5
            // Convert back to a `lastBeatTime` that's at most one beat
            // behind the current onset, so the next `update()` will
            // detect the upcoming crossing correctly.
            let beatsBehind = (target - lastBeatTime) / beatPeriod
            lastBeatTime += beatsBehind.rounded(.down) * beatPeriod
            // Soft pull on the remainder.
            let residual = target - lastBeatTime
            lastBeatTime += residual * 0.3
        }
    }
}
