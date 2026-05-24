import Testing
@testable import AudioAnalysis

private let fftSize = 8192
private let sampleRate = 48_000.0

/// Analyzes a chord and returns its detected key.
private func detectKey(ofChord frequencies: [Double]) -> KeyEstimate {
    let fft = FFTProcessor(size: fftSize)!
    let chord = ToneGenerator.tones(
        frequencies: frequencies,
        sampleCount: fftSize,
        sampleRate: sampleRate,
        amplitude: 0.5
    )
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: chord),
        fft: fft,
        sampleRate: sampleRate
    )
    return KeyDetector.detect(from: chroma)
}

@Test("Pearson correlation of a vector with itself is 1")
func pearsonSelfCorrelation() {
    let profile = KeyProfile.krumhanslKessler.major
    let r = KeyDetector.pearson(profile, profile)
    #expect(abs(r - 1.0) < 0.0001)
}

@Test("Rotating a profile by 12 returns the original")
func rotateFullCircle() {
    let profile = KeyProfile.krumhanslKessler.major
    #expect(KeyDetector.rotate(profile, by: 12) == profile)
}

@Test("A C major chord is detected as C major")
func detectsCMajor() {
    // C4, E4, G4
    let estimate = detectKey(ofChord: [261.63, 329.63, 392.00])
    #expect(estimate.key == Key(tonic: .c, mode: .major))
}

@Test("An A minor chord is detected as A minor")
func detectsAMinor() {
    // A4, C5, E5
    let estimate = detectKey(ofChord: [440.00, 523.25, 659.25])
    #expect(estimate.key == Key(tonic: .a, mode: .minor))
}

@Test("A D major chord is detected as D major")
func detectsDMajor() {
    // D4, F#4, A4
    let estimate = detectKey(ofChord: [293.66, 369.99, 440.00])
    #expect(estimate.key == Key(tonic: .d, mode: .major))
}

@Test("A confident detection reports a positive confidence score")
func confidenceIsPositive() {
    let estimate = detectKey(ofChord: [261.63, 329.63, 392.00])
    #expect(estimate.confidence > 0)
}
