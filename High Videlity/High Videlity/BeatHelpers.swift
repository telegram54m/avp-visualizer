//
//  BeatHelpers.swift
//  High Videlity
//
//  Shared tempo / beat-tracker utilities, hoisted from
//  DodecahedronVisualizer when the dodec was the first (and only)
//  consumer. Now lives at the app level so other visualizers can
//  consume the same canonical tempo math without depending on the
//  dodec implementation. See [[dodecahedron]] for the porting
//  roadmap that motivated the hoist.
//

import Foundation

/// Shared beat-tracker / tempo-math utilities. Pure functions and
/// constants — no state, no I/O. Safe to call from any thread.
enum BeatHelpers {

    /// Canonical musical-BPM range. Anything outside this gets folded
    /// by halving/doubling until it lands inside. Spans roughly
    /// "slow ballad" through "very fast dance" — wider would let
    /// half/double-time interpretations slip through; narrower might
    /// fold legitimate genre tempos (e.g. 160 BPM punk → 80).
    static let canonicalBpmMin: Float = 70.0
    static let canonicalBpmMax: Float = 140.0

    /// Octave-fold a raw bpm into the canonical musical range. The
    /// `BeatTracker` regularly locks onto half-time or double-time
    /// interpretations of the perceived tempo (it's a known limit of
    /// IOI-based trackers — a song with strong hat eighths and a
    /// 110 BPM kick will often lock onto 220 BPM because the
    /// inter-onset intervals are equally regular). Folding restores
    /// the perceptual tempo so visual-treatment thresholds match what
    /// a listener feels.
    ///
    /// Returns 0 unchanged (for "no BPM available" signaling). Capped
    /// at 8 fold iterations as a safety net against pathological
    /// inputs that would otherwise never converge.
    static func octaveFoldBpm(_ raw: Float) -> Float {
        guard raw > 0 else { return 0 }
        var bpm = raw
        for _ in 0..<8 {
            if bpm > canonicalBpmMax {
                bpm *= 0.5
            } else if bpm < canonicalBpmMin {
                bpm *= 2.0
            } else {
                return bpm
            }
        }
        return bpm
    }
}
