import Testing
@testable import AudioAnalysis

private let fftSize = 8192
private let sampleRate = 48_000.0

/// The timbre of a single pure tone.
private func timbre(ofTone frequency: Double) -> Timbre {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(
        frequency: frequency,
        sampleCount: fftSize,
        sampleRate: sampleRate
    )
    return Timbre(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )
}

@Test("A low tone is warm — low centroid, low brightness")
func lowToneIsWarm() {
    let result = timbre(ofTone: 200)
    #expect(result.centroidHz < 600)
    #expect(result.brightness < 0.35)
}

@Test("A high tone is bright — high centroid, high brightness")
func highToneIsBright() {
    let result = timbre(ofTone: 6000)
    #expect(result.centroidHz > 3000)
    #expect(result.brightness > 0.7)
}

@Test("Brightness rises with pitch")
func brightnessRisesWithPitch() {
    let low = timbre(ofTone: 200)
    let mid = timbre(ofTone: 1000)
    let high = timbre(ofTone: 6000)
    #expect(low.brightness < mid.brightness)
    #expect(mid.brightness < high.brightness)
}

@Test("Brightness stays within 0...1")
func brightnessBounded() {
    for frequency in [50.0, 200, 1000, 6000, 20_000] {
        let b = timbre(ofTone: frequency).brightness
        #expect(b >= 0 && b <= 1)
    }
}
