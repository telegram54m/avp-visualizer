import Foundation

/// One of the twelve pitch classes in Western music — a note name
/// independent of octave. Middle C and the C an octave above are both `.c`.
public enum PitchClass: Int, CaseIterable, Sendable {
    case c, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    /// A short human-readable name, e.g. "C", "C#", "A".
    public var name: String {
        switch self {
        case .c: "C"
        case .cSharp: "C#"
        case .d: "D"
        case .dSharp: "D#"
        case .e: "E"
        case .f: "F"
        case .fSharp: "F#"
        case .g: "G"
        case .gSharp: "G#"
        case .a: "A"
        case .aSharp: "A#"
        case .b: "B"
        }
    }

    /// This pitch class's hue (0...1) under a circle-of-fifths color layout.
    ///
    /// Stepping by a perfect fifth (7 semitones) moves one notch around the
    /// color wheel, so harmonically related notes get neighboring colors.
    /// (7 is its own inverse modulo 12, so this both builds and indexes the
    /// circle of fifths.)
    public var circleOfFifthsHue: Double {
        Double((rawValue * 7) % 12) / 12.0
    }

    /// The pitch class a given frequency belongs to.
    ///
    /// Uses the MIDI note formula: concert A (440 Hz) is MIDI note 69.
    /// The note number modulo 12 gives the pitch class, octave discarded.
    public static func of(frequency: Double) -> PitchClass {
        let midi = 69.0 + 12.0 * log2(frequency / 440.0)
        // Modulo can be negative in Swift; the extra +12 keeps it 0...11.
        let index = ((Int(midi.rounded()) % 12) + 12) % 12
        return PitchClass(rawValue: index)!
    }
}
