import Testing
@testable import AudioAnalysis

private let fftSize = 8192

private func spectrum(of frequencies: [Double]) -> [Float] {
    let fft = FFTProcessor(size: fftSize)!
    let signal = ToneGenerator.tones(frequencies: frequencies, sampleCount: fftSize)
    return fft.magnitudeSpectrum(of: signal)
}

@Test("A pure tone has minimal harmonic complexity")
func pureToneIsSimple() {
    let hc = HarmonicComplexity(spectrum: spectrum(of: [440]))
    #expect(hc.peakCount <= 3)
    #expect(hc.value < 0.15)
}

@Test("A chord is more complex than a single tone")
func chordIsMoreComplexThanTone() {
    let tone = HarmonicComplexity(spectrum: spectrum(of: [440]))
    let chord = HarmonicComplexity(spectrum: spectrum(of: [262, 330, 392, 494, 587]))
    #expect(chord.peakCount > tone.peakCount)
}

@Test("More notes produce more spectral peaks")
func moreNotesMorePeaks() {
    let three = HarmonicComplexity(spectrum: spectrum(of: [262, 330, 392]))
    let six = HarmonicComplexity(spectrum: spectrum(of: [262, 330, 392, 494, 587, 659]))
    #expect(six.peakCount > three.peakCount)
}

@Test("Complexity value stays within 0...1")
func complexityBounded() {
    #expect(HarmonicComplexity(peakCount: 1000).value == 1.0)
    #expect(HarmonicComplexity(peakCount: 0).value == 0.0)
}
