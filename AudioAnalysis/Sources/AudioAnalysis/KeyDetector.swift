import Foundation

/// Detects the musical key of a chromagram using the Krumhansl-Schmuckler
/// key-finding algorithm: correlate the chromagram against all 24 key
/// templates and pick the best match.
public enum KeyDetector {

    /// A candidate key and how well it matched the chromagram.
    public struct Candidate: Sendable, Equatable {
        public let key: Key
        public let correlation: Double
    }

    /// Scores every one of the 24 keys against a chromagram, best match first.
    public static func rankedCandidates(
        from chromagram: Chromagram,
        profile: KeyProfile = .temperley
    ) -> [Candidate] {
        let chroma = chromagram.values.map(Double.init)
        var scored: [Candidate] = []
        for tonicIndex in 0..<12 {
            for mode in Mode.allCases {
                let baseProfile = (mode == .major) ? profile.major : profile.minor
                let template = rotate(baseProfile, by: tonicIndex)
                let key = Key(tonic: PitchClass(rawValue: tonicIndex)!, mode: mode)
                scored.append(Candidate(key: key, correlation: pearson(chroma, template)))
            }
        }
        return scored.sorted { $0.correlation > $1.correlation }
    }

    /// Detects the most likely key of a chromagram.
    ///
    /// - Parameters:
    ///   - chromagram: the pitch-class energy distribution to analyze.
    ///   - profile: the key-weight templates to match against.
    ///   - bassHint: an optional pitch class believed to be the tonic. It acts
    ///     purely as a tie-breaker: it can promote a key only if that key is
    ///     already within `tieMargin` of the top candidate. A wrong hint
    ///     therefore cannot override a clear winner.
    ///   - tieMargin: how close (in correlation) a candidate must be to the
    ///     top for the bass hint to be allowed to promote it.
    /// - Returns: the detected key and a confidence (the winning correlation).
    public static func detect(
        from chromagram: Chromagram,
        profile: KeyProfile = .temperley,
        bassHint: PitchClass? = nil,
        tieMargin: Double = 0.08
    ) -> KeyEstimate {
        let ranked = rankedCandidates(from: chromagram, profile: profile)
        guard let top = ranked.first else {
            return KeyEstimate(key: Key(tonic: .c, mode: .major), confidence: 0)
        }

        var winner = top
        if let hint = bassHint,
           let promoted = ranked.first(where: {
               $0.key.tonic == hint && (top.correlation - $0.correlation) <= tieMargin
           }) {
            winner = promoted
        }

        return KeyEstimate(key: winner.key, confidence: Float(winner.correlation))
    }

    /// Rotates a 12-element profile so its element 0 moves to position `offset`.
    static func rotate(_ profile: [Double], by offset: Int) -> [Double] {
        (0..<12).map { profile[(($0 - offset) % 12 + 12) % 12] }
    }

    /// Pearson correlation coefficient between two equal-length vectors.
    ///
    /// Returns a value in roughly -1...1: 1 means the two shapes move
    /// perfectly together, 0 means no relationship.
    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for i in x.indices {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }

        let denominator = (varianceX * varianceY).squareRoot()
        return denominator == 0 ? 0 : covariance / denominator
    }
}
