import Foundation

/// A color derived from musical content, in hue/saturation/brightness form.
///
/// This is the core of the visualizer's sound-to-color mapping. Rather than
/// classifying the music into a named key — which proved unreliable — it maps
/// the full chromagram directly into a color that is consistent and
/// expressive for any given clip.
public struct TonalColor: Sendable, Equatable {

    /// Position on the color wheel, 0...1.
    public let hue: Double

    /// How tonally focused the music is, 0...1. A single clear tonal center
    /// is vivid; energy spread evenly across all pitch classes is washed out.
    public let saturation: Double

    /// Lightness, 0...1. Driven by major/minor character.
    public let brightness: Double

    /// Maps a chromagram to a color using a circle-of-fifths hue layout.
    ///
    /// Each pitch class is a vector on the color wheel, pointing at its
    /// circle-of-fifths hue and scaled by its energy. Summing the vectors
    /// gives a resultant whose angle is the blended hue and whose magnitude
    /// (relative to total energy) is the saturation.
    ///
    /// - Parameters:
    ///   - chromagram: the pitch-class energy distribution.
    ///   - majorness: major/minor character (-1...1), driving brightness.
    public init(chromagram: Chromagram, majorness: Float = 0) {
        var x = 0.0
        var y = 0.0
        var total = 0.0

        for pitchClass in PitchClass.allCases {
            let weight = Double(chromagram.values[pitchClass.rawValue])
            let angle = pitchClass.circleOfFifthsHue * 2 * .pi
            x += weight * cos(angle)
            y += weight * sin(angle)
            total += weight
        }

        if total > 0 {
            var h = atan2(y, x) / (2 * .pi)
            if h < 0 { h += 1 }
            self.hue = h
            self.saturation = (x * x + y * y).squareRoot() / total
        } else {
            self.hue = 0
            self.saturation = 0
        }

        // Minor music sits darker, major brighter; clamped to a visible range.
        self.brightness = 0.6 + 0.4 * Double(majorness)
    }
}
