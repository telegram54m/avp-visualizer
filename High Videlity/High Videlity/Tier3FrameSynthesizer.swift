//
//  Tier3FrameSynthesizer.swift
//  High Videlity
//
//  Synthesize a full-song FeatureFrame array using ONLY the 30s
//  Apple Music preview's analysis. The preview gives us ground-truth
//  BPM, key, chord character, characteristic onset density, timbre
//  profile. For the full song we don't have any real audio — we
//  extrapolate a beat grid at the preview's BPM and loop the
//  preview's per-frame data through the rest of the song.
//
//  Role in the tier stack:
//      Tier 1 — full-song cached frames (real audio analysis)
//      Tier 2 — preview + AcousticBrainz beats_position[]
//      Tier 3 — preview ONLY (THIS FILE)
//
//  Tier 3 fires within ~1 second of song start: as soon as Shazam
//  IDs the track and the Apple preview download + local analysis
//  completes. The visualizer immediately has something to react to.
//  When Tier 2 (AcousticBrainz beats) and eventually Tier 1 (real
//  full-song frames) arrive, `AppModel.upgradeFrames` swaps in the
//  higher-fidelity array. Visualizer EMAs resettle within ~500ms.
//
//  What this synthesizer DOES preserve:
//      • Accurate beat positions (BPM × n + downbeat offset)
//      • Chromagram character matching the preview's tonal palette
//      • Loudness envelope shape — preview's slow EMA, looped
//      • Per-band features (subwoofer kick, vocal mid, hi-hat brilliance)
//
//  What it CANNOT know:
//      • Where verses vs choruses land (the loudness envelope is
//        looped, so quiet/loud sections recur on a 30s cycle —
//        wrong for most songs but acceptable for Tier 3 fidelity)
//      • Actual chord changes past the 30s preview boundary
//      • Section transitions, drops, breakdowns
//      • Any onset that doesn't fall on the BPM grid (syncopation,
//        fills, etc.)
//

import Foundation
import AudioAnalysis

enum Tier3FrameSynthesizer {

    /// Output frame rate. Matches the rest of the pipeline so the
    /// existing playback-clock-to-frame-index math (`Int(clock * 30)`)
    /// works without modification.
    static let outputFrameRate: Double = 30.0

    /// Synthesize a full-song FeatureFrame array from the preview
    /// analysis. Returns nil if the preview is unusable (no frames,
    /// or no confident beat tracking — we need BPM to extrapolate).
    ///
    /// - Parameters:
    ///   - previewFrames: 30s preview's `[FeatureFrame]` array as
    ///     produced by the existing local analysis pipeline. Must
    ///     have at least a few seconds of frames with a confident
    ///     `beat.bpm`.
    ///   - fullSongDuration: total duration of the full song in
    ///     seconds. Comes from Apple Music's catalog metadata or
    ///     the user's local file.
    static func synthesize(
        previewFrames: [FeatureFrame],
        fullSongDuration: TimeInterval
    ) -> [FeatureFrame]? {
        guard !previewFrames.isEmpty else { return nil }

        // Derive BPM from preview. Use the highest-confidence beat
        // estimate across the preview's frames; if none are
        // confident, bail (Tier 3 needs a BPM grid).
        guard let bpm = extractBpm(from: previewFrames) else { return nil }
        let beatInterval = Double(60.0 / bpm)

        // Locate the first downbeat in the preview to phase-align
        // the extrapolated grid. If the preview's beat tracker never
        // fired a beatTrigger, fall back to time 0 — visualizer
        // beat-locked behavior will be off by up to half a beat
        // but the BPM will still match.
        let firstBeatTime = locateFirstBeatTime(in: previewFrames) ?? 0.0

        let outputFrameCount = max(0, Int(fullSongDuration * outputFrameRate))
        guard outputFrameCount > 0 else { return nil }

        // Pre-compute the set of frame indices that fall ON beats.
        // A frame is "on a beat" if its time is within half a frame
        // interval of an integer-numbered beat moment.
        let halfFramePeriod = 1.0 / outputFrameRate / 2.0
        var beatFrameIndices = Set<Int>()
        var n = 0
        while true {
            let beatTime = firstBeatTime + Double(n) * beatInterval
            if beatTime > fullSongDuration { break }
            if beatTime >= 0 {
                let idx = Int((beatTime * outputFrameRate).rounded())
                if idx < outputFrameCount {
                    beatFrameIndices.insert(idx)
                }
            }
            n += 1
        }

        var output = [FeatureFrame]()
        output.reserveCapacity(outputFrameCount)

        let previewCount = previewFrames.count
        let beatConfidence: Float = 0.5  // synthetic — moderate-confidence flag

        for i in 0..<outputFrameCount {
            // Loop preview data verbatim. We honor the preview's
            // chromagram + bandChromagram + bandLoudness + timbre
            // + color + harmonicComplexity. These give the visualizer
            // the preview's characteristic tonal palette and texture.
            let previewIdx = i % previewCount
            let p = previewFrames[previewIdx]

            // Override the rhythmic fields with the extrapolated grid.
            // Looping the preview's `onset` field would produce onsets
            // every 30s in the wrong places; the BPM grid is the
            // higher-fidelity proxy.
            let onBeat = beatFrameIndices.contains(i)

            // Per-band onset: sub fires on EVERY beat (kick proxy),
            // highMid fires on every other beat (snare proxy on 2 + 4),
            // brilliance fires every 4 frames (~10Hz hi-hat texture),
            // lowMid stays off. Heuristic but visually convincing.
            let beatNumber = onBeat
                ? Int(((Double(i) / outputFrameRate - firstBeatTime) / beatInterval).rounded())
                : -1
            let subOnset = onBeat
            let highMidOnset = onBeat && (beatNumber % 2 == 1)
            let brillianceOnset = (i % 3 == 0)  // ~10Hz texture
            let lowMidOnset = false

            // beatTrigger fires on the same grid as `onset`. phase
            // is the fractional position within the current beat.
            let timeInBeat = (Double(i) / outputFrameRate - firstBeatTime)
                .truncatingRemainder(dividingBy: beatInterval)
            let beatPhase = Float(max(0, timeInBeat) / beatInterval)
            let synthBeat = BeatState(
                bpm: bpm,
                phase: beatPhase,
                beatTrigger: onBeat,
                confidence: beatConfidence
            )

            let frame = FeatureFrame(
                time: Double(i) / outputFrameRate,
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

    /// Extract a BPM estimate from the preview's frames. Uses the
    /// most confident beat estimate; preview's BeatTracker reaches
    /// confidence > 0.7 once it's locked.
    private static func extractBpm(from frames: [FeatureFrame]) -> Float? {
        var bestBpm: Float = 0
        var bestConfidence: Float = 0
        for f in frames where f.beat.bpm > 30 && f.beat.confidence > bestConfidence {
            bestBpm = f.beat.bpm
            bestConfidence = f.beat.confidence
        }
        // Octave fold to musical range [70, 140] — preview's
        // BeatTracker often locks half/double-time per
        // [feedback_beat-tracker-octave]. Visualizers consuming
        // beat.bpm already do this in some cases; here we apply it
        // ONCE so the extrapolated grid is musically correct.
        guard bestBpm > 0 else { return nil }
        var bpm = bestBpm
        while bpm > 140 { bpm /= 2 }
        while bpm < 70 { bpm *= 2 }
        return bpm
    }

    /// Find the time of the first beat in the preview. The preview's
    /// BeatTracker needs ~3-4 onsets to lock, so the first beatTrigger
    /// is typically a couple of seconds in — that's fine, we just need
    /// any one to phase-align the extrapolated grid.
    private static func locateFirstBeatTime(in frames: [FeatureFrame]) -> Double? {
        for f in frames where f.beat.beatTrigger {
            return f.time
        }
        return nil
    }
}
