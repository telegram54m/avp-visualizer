/// Whether a key is major (brighter, more resolved) or minor (darker, more tense).
public enum Mode: String, Sendable, Equatable, CaseIterable {
    case major
    case minor

    /// A human-readable name, "major" or "minor".
    public var name: String { rawValue }
}

/// A musical key: a tonic pitch class plus a mode. For example, "C major".
public struct Key: Sendable, Equatable {
    public let tonic: PitchClass
    public let mode: Mode

    public init(tonic: PitchClass, mode: Mode) {
        self.tonic = tonic
        self.mode = mode
    }

    /// A human-readable name, e.g. "C major" or "F# minor".
    public var name: String { "\(tonic.name) \(mode.name)" }
}

/// A detected key together with how confident the detection is.
public struct KeyEstimate: Sendable, Equatable {
    public let key: Key

    /// Correlation score of the best-matching key template, roughly -1...1.
    /// Higher means a clearer, more confident match.
    public let confidence: Float

    public init(key: Key, confidence: Float) {
        self.key = key
        self.confidence = confidence
    }
}
