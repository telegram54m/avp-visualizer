/// A pair of 12-element pitch-class weight templates — one for major keys,
/// one for minor — used by `KeyDetector` to score candidate keys.
///
/// Each array is ordered with index 0 as the tonic. Several published
/// profiles exist; they differ in how they were derived and in how well
/// they distinguish major from minor.
public struct KeyProfile: Sendable {

    public let name: String

    /// Weights for a major key, index 0 = tonic.
    public let major: [Double]

    /// Weights for a minor key, index 0 = tonic.
    public let minor: [Double]

    public init(name: String, major: [Double], minor: [Double]) {
        precondition(major.count == 12 && minor.count == 12, "Profiles have 12 weights")
        self.name = name
        self.major = major
        self.minor = minor
    }

    /// The original Krumhansl-Kessler (1982) profiles, from a listening
    /// experiment. Prone to confusing relative major and minor keys.
    public static let krumhanslKessler = KeyProfile(
        name: "Krumhansl-Kessler",
        major: [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
        minor: [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    )

    /// Temperley's Kostka-Payne-derived profiles. Designed to balance the
    /// weight of triad tones across major and minor, reducing the common
    /// relative-mode confusion.
    public static let temperley = KeyProfile(
        name: "Temperley-Kostka-Payne",
        major: [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
        minor: [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330]
    )

    /// Profiles derived from the Essen folksong corpus. Strong for major
    /// keys; minor weights are of less certain origin.
    public static let aardenEssen = KeyProfile(
        name: "Aarden-Essen",
        major: [17.7661, 0.145624, 14.9265, 0.160186, 19.8049, 11.3587,
                0.291248, 22.062, 0.145624, 8.15494, 0.232998, 4.95122],
        minor: [18.2648, 0.737619, 14.0499, 16.8599, 0.702494, 14.4362,
                0.702494, 18.6161, 4.56621, 1.93186, 7.37619, 1.75623]
    )

    /// Profiles derived by Bellman from a corpus of tonal music.
    public static let bellmanBudge = KeyProfile(
        name: "Bellman-Budge",
        major: [16.80, 0.86, 12.95, 1.41, 13.49, 11.93, 1.25, 20.28, 1.80, 8.04, 0.62, 10.57],
        minor: [18.16, 0.69, 12.99, 13.34, 1.07, 11.15, 1.38, 21.07, 7.49, 1.53, 0.92, 10.21]
    )
}
