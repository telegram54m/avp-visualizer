//
//  Tier2FrameSynthesizer.swift
//  High Videlity
//
//  Synthesize a full-song FeatureFrame array using the 30s preview's
//  analysis PLUS AcousticBrainz's full-song `rhythm.beats_position`
//  array. Tier 2 differs from Tier 3 in one critical way:
//
//    • Tier 3 EXTRAPOLATES beats: `beatTime[n] = downbeat + n × (60/bpm)`.
//      Drift accumulates over the song if the preview BPM is slightly
//      off, and any tempo changes within the song are missed entirely.
//
//    • Tier 2 USES REAL beats: AB analyzed the master recording and
//      gave us the exact second-precise timestamp for every beat.
//      Tempo changes, ritardandos, fermatas — all preserved.
//
//  Coverage: AcousticBrainz froze in 2018, so this path lights up for
//  ~70-80% of pre-2018 catalog tracks. For everything else, Tier 3
//  remains the fallback. The preview chromagram still loops on a 30s
//  cycle (no per-section data from AB), but the BEAT GRID is real.
//
//  Plugs into the tier ladder: when `TunebatBpmFetcher.lookup()` returns
//  a result with `beatPositions != nil`, AppModel calls
//  `Tier2FrameSynthesizer.synthesize(...)` and promotes via
//  `upgradeFrames(.tier2)`. If Tier 3 has already landed, this
//  replaces it; if Tier 1 has landed first (live mic / system tap),
//  the upgrade is rejected by the tier-ordering guard and Tier 2
//  doesn't fire (correct — we don't downgrade fidelity).
//

import Foundation
import AudioAnalysis

enum Tier2FrameSynthesizer {

    /// Output frame rate. Matches the rest of the pipeline (30 fps).
    static let outputFrameRate: Double = 30.0

    /// Build a full-song FeatureFrame array from preview frames + AB
    /// beats. Returns nil if synthesis isn't possible (no preview
    /// frames, no beats, invalid duration).
    ///
    /// The chromagram/loudness/timbre fields are LOOPED from the
    /// preview (same as Tier 3) — AB doesn't expose those per-time.
    /// The rhythmic fields (`onset`, `beat`, `bandOnset`) are
    /// **re-derived from `beatPositions`**, replacing Tier 3's
    /// BPM-extrapolated grid with AB's real beat moments.
    static func synthesize(
        previewFrames: [FeatureFrame],
        beatPositions: [Double],
        fullSongDuration: TimeInterval
    ) -> [FeatureFrame]? {
        guard !previewFrames.isEmpty,
              !beatPositions.isEmpty,
              fullSongDuration > 1.0
        else { return nil }

        let outputFrameCount = Int(fullSongDuration * outputFrameRate)
        guard outputFrameCount > 0 else { return nil }

        // Pre-compute the set of frame indices that fall ON a beat.
        // Each AB beat timestamp gets snapped to the nearest 30fps
        // frame. Beats outside the song duration (AB occasionally
        // includes a trailing beat past the actual end) are dropped.
        var beatFrameIndices = Set<Int>()
        var beatOrdinal: [Int: Int] = [:]  // frameIdx → ordinal beat number
        for (i, t) in beatPositions.enumerated() {
            if t < 0 || t > fullSongDuration { continue }
            let idx = Int((t * outputFrameRate).rounded())
            guard idx < outputFrameCount else { continue }
            beatFrameIndices.insert(idx)
            beatOrdinal[idx] = i
        }

        // Estimate BPM from the median inter-beat interval. Used to
        // fill the BeatState.bpm field (some visualizers consume it
        // directly via tempoIntensityScale etc).
        let intervals: [Double] = zip(beatPositions, beatPositions.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0.1 && $0 < 3.0 }  // 20-600 BPM bounds
        let medianInterval = intervals.sorted()[max(0, intervals.count / 2)]
        let bpm = medianInterval > 0 ? Float(60.0 / medianInterval) : 120.0

        var output = [FeatureFrame]()
        output.reserveCapacity(outputFrameCount)
        let previewCount = previewFrames.count
        let beatConfidence: Float = 0.85  // AB-derived = high confidence

        // For beat phase computation, find the nearest previous beat
        // for each frame. Pre-build a sorted array for binary search.
        let sortedBeats = beatPositions.sorted()

        for i in 0..<outputFrameCount {
            let p = previewFrames[i % previewCount]
            let onBeat = beatFrameIndices.contains(i)

            // Phase within current beat = (now - prev_beat) /
            // (next_beat - prev_beat). Some visualizers consume this
            // for continuous beat-locked animations.
            let frameTime = Double(i) / outputFrameRate
            let (prevBeat, nextBeat) = bracketingBeats(
                time: frameTime, sortedBeats: sortedBeats
            )
            let beatPhase: Float = {
                guard nextBeat > prevBeat else { return 0 }
                return Float((frameTime - prevBeat) / (nextBeat - prevBeat))
            }()

            // Per-band onset heuristic, same as Tier 3:
            // sub fires on every beat (kick), highMid on beats 2 + 4
            // (snare backbeat), brilliance every 3 frames (hi-hat
            // shimmer ~10 Hz). lowMid stays off — AB doesn't have
            // bass-onset info to distinguish.
            let beatN = beatOrdinal[i] ?? -1
            let subOnset = onBeat
            let highMidOnset = onBeat && (beatN >= 0) && (beatN % 2 == 1)
            let brillianceOnset = (i % 3 == 0)
            let lowMidOnset = false

            let synthBeat = BeatState(
                bpm: bpm,
                phase: beatPhase,
                beatTrigger: onBeat,
                confidence: beatConfidence
            )

            let frame = FeatureFrame(
                time: frameTime,
                color: p.color,
                timbreBrightness: p.timbreBrightness,
                loudness: p.loudness,
                harmonicComplexity: p.harmonicComplexity,
                onset: onBeat,
                chromagram: p.chromagram,
                beat: synthBeat,
                bandLoudness: p.bandLoudness,
                bandChromagram: p.bandChromagram,
                bandOnset: [subOnset, lowMidOnset, highMidOnset, brillianceOnset]
            )
            output.append(frame)
        }

        return output
    }

    /// Find the two beats bracketing a given time. Linear scan is
    /// fine — beat arrays are typically a few hundred entries and
    /// we call this once per frame (7200 frames × 500 beats =
    /// ~3.6M comparisons for a 4-min song, still <100ms on iPhone).
    /// Could be binary-searched if perf demands.
    private static func bracketingBeats(
        time: Double, sortedBeats: [Double]
    ) -> (prev: Double, next: Double) {
        var prev = 0.0
        var next = sortedBeats.last ?? time + 1
        for b in sortedBeats {
            if b <= time { prev = b } else { next = b; break }
        }
        return (prev, next)
    }
}
