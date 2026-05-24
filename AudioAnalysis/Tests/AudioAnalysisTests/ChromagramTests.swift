import Testing
@testable import AudioAnalysis

private let fftSize = 8192
private let sampleRate = 48_000.0

@Test("A pure A4 tone produces a chromagram peaking on A")
func chromagramIdentifiesA() {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: fftSize, sampleRate: sampleRate)
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )
    #expect(chroma.dominant == .a)
}

@Test("A pure middle-C tone produces a chromagram peaking on C")
func chromagramIdentifiesC() {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 261.63, sampleCount: fftSize, sampleRate: sampleRate)
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )
    #expect(chroma.dominant == .c)
}

@Test("A C major chord lights up exactly C, E and G")
func chromagramIdentifiesChord() {
    let fft = FFTProcessor(size: fftSize)!
    let c = ToneGenerator.sine(frequency: 261.63, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let e = ToneGenerator.sine(frequency: 329.63, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let g = ToneGenerator.sine(frequency: 392.00, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let chord = ToneGenerator.mix([c, e, g])

    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: chord),
        fft: fft,
        sampleRate: sampleRate
    )

    let topThree = Set(
        chroma.values.indices
            .sorted { chroma.values[$0] > chroma.values[$1] }
            .prefix(3)
    )
    let expected = Set([PitchClass.c.rawValue, PitchClass.e.rawValue, PitchClass.g.rawValue])
    #expect(topThree == expected)
}

@Test("Frequency-to-pitch-class mapping is correct for known notes")
func pitchClassMapping() {
    #expect(PitchClass.of(frequency: 440.0) == .a)      // A4
    #expect(PitchClass.of(frequency: 261.63) == .c)     // C4
    #expect(PitchClass.of(frequency: 329.63) == .e)     // E4
    #expect(PitchClass.of(frequency: 392.00) == .g)     // G4
    #expect(PitchClass.of(frequency: 880.0) == .a)      // A5 — same class, higher octave
}
