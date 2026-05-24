import Testing
@testable import AudioAnalysis

@Test("FFT size must be a power of two")
func fftRejectsNonPowerOfTwo() {
    #expect(FFTProcessor(size: 1000) == nil)
    #expect(FFTProcessor(size: 0) == nil)
    #expect(FFTProcessor(size: 4096) != nil)
}

@Test("FFT finds the frequency of a pure tone")
func fftFindsPureTone() {
    let fftSize = 4096
    let sampleRate = 48_000.0
    let fft = FFTProcessor(size: fftSize)!

    let tone = ToneGenerator.sine(
        frequency: 440,
        sampleCount: fftSize,
        sampleRate: sampleRate
    )
    let detected = fft.dominantFrequency(of: tone, sampleRate: sampleRate)

    // The FFT can only resolve frequency to within one bin width.
    let binWidth = sampleRate / Double(fftSize)
    #expect(abs(detected - 440) < binWidth)
}

@Test("FFT distinguishes a low tone from a high tone")
func fftDistinguishesTones() {
    let fftSize = 4096
    let sampleRate = 48_000.0
    let fft = FFTProcessor(size: fftSize)!
    let binWidth = sampleRate / Double(fftSize)

    let low = ToneGenerator.sine(frequency: 200, sampleCount: fftSize, sampleRate: sampleRate)
    let high = ToneGenerator.sine(frequency: 5000, sampleCount: fftSize, sampleRate: sampleRate)

    #expect(abs(fft.dominantFrequency(of: low, sampleRate: sampleRate) - 200) < binWidth)
    #expect(abs(fft.dominantFrequency(of: high, sampleRate: sampleRate) - 5000) < binWidth)
}

@Test("The magnitude spectrum has one value per frequency bin")
func fftSpectrumHasHalfSizeBins() {
    let fftSize = 2048
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: fftSize)
    #expect(fft.magnitudeSpectrum(of: tone).count == fftSize / 2)
}
