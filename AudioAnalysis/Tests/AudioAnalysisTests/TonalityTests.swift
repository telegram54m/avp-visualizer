import Testing
@testable import AudioAnalysis

private let fftSize = 8192
private let sampleRate = 48_000.0

/// Builds a chord from (frequency, amplitude) pairs and returns its tonality.
/// Giving the root more amplitude mirrors real chords, where the root is
/// emphasized, and yields a stable tonal center.
private func tonality(of notes: [(frequency: Double, amplitude: Double)]) -> Tonality {
    let fft = FFTProcessor(size: fftSize)!
    let signals = notes.map { note in
        ToneGenerator.sine(
            frequency: note.frequency,
            sampleCount: fftSize,
            sampleRate: sampleRate,
            amplitude: note.amplitude
        )
    }
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: ToneGenerator.mix(signals)),
        fft: fft,
        sampleRate: sampleRate
    )
    return Tonality(of: chroma)
}

@Test("A C major chord reads as strongly major")
func cMajorChordIsMajor() {
    // C4 (root, loud), E4 major third, G4 fifth.
    let result = tonality(of: [(261.63, 1.0), (329.63, 0.5), (392.00, 0.5)])
    #expect(result.center == .c)
    #expect(result.majorness > 0.5)
}

@Test("A C minor chord reads as strongly minor")
func cMinorChordIsMinor() {
    // C4 (root, loud), Eb4 minor third, G4 fifth.
    let result = tonality(of: [(261.63, 1.0), (311.13, 0.5), (392.00, 0.5)])
    #expect(result.center == .c)
    #expect(result.majorness < -0.5)
}

@Test("A single tone with no third is tonally ambiguous")
func singleToneIsAmbiguous() {
    let result = tonality(of: [(261.63, 1.0)])
    #expect(result.center == .c)
    #expect(result.majorness == 0)
}

@Test("Major-ness stays within its -1...1 range")
func majornessIsBounded() {
    let major = tonality(of: [(261.63, 1.0), (329.63, 0.5), (392.00, 0.5)])
    let minor = tonality(of: [(261.63, 1.0), (311.13, 0.5), (392.00, 0.5)])
    #expect(major.majorness >= -1 && major.majorness <= 1)
    #expect(minor.majorness >= -1 && minor.majorness <= 1)
}
