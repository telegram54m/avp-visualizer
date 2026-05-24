import Testing
@testable import AudioAnalysis

@Test("Silence has zero loudness")
func silenceHasZeroRMS() {
    let silence = [Float](repeating: 0, count: 1000)
    #expect(Loudness.rms(silence) == 0)
}

@Test("An empty signal has zero loudness")
func emptySignalHasZeroRMS() {
    #expect(Loudness.rms([]) == 0)
}

@Test("A full-scale sine wave has an RMS of about 0.7071")
func fullScaleSineHasExpectedRMS() {
    let tone = ToneGenerator.sine(frequency: 440, duration: 1.0)
    let rms = Loudness.rms(tone)
    #expect(abs(rms - 0.7071) < 0.001)
}

@Test("A quieter tone measures lower loudness than a louder one")
func quieterToneHasLowerRMS() {
    let loud = ToneGenerator.sine(frequency: 440, duration: 1.0, amplitude: 1.0)
    let quiet = ToneGenerator.sine(frequency: 440, duration: 1.0, amplitude: 0.5)
    #expect(Loudness.rms(quiet) < Loudness.rms(loud))
}
