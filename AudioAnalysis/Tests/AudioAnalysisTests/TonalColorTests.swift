import Testing
@testable import AudioAnalysis

@Test("Circle-of-fifths hue places fifths one step apart")
func circleOfFifthsHueLayout() {
    #expect(PitchClass.c.circleOfFifthsHue == 0.0)
    #expect(PitchClass.g.circleOfFifthsHue == 1.0 / 12.0)   // a fifth above C
    #expect(PitchClass.d.circleOfFifthsHue == 2.0 / 12.0)
    #expect(PitchClass.f.circleOfFifthsHue == 11.0 / 12.0)  // a fifth below C
}

@Test("A single pitch class makes a fully saturated color at its own hue")
func singlePitchClassColor() {
    var values = [Float](repeating: 0, count: 12)
    values[PitchClass.g.rawValue] = 1.0
    let color = TonalColor(chromagram: Chromagram(values: values))

    #expect(abs(color.hue - PitchClass.g.circleOfFifthsHue) < 0.001)
    #expect(abs(color.saturation - 1.0) < 0.001)
}

@Test("An even spread across all pitch classes is desaturated")
func flatChromagramIsDesaturated() {
    let color = TonalColor(chromagram: Chromagram(values: [Float](repeating: 1, count: 12)))
    #expect(color.saturation < 0.01)
}

@Test("Major-ness brightens the color, minor-ness darkens it")
func majornessAffectsBrightness() {
    var values = [Float](repeating: 0, count: 12)
    values[0] = 1
    let major = TonalColor(chromagram: Chromagram(values: values), majorness: 1.0)
    let minor = TonalColor(chromagram: Chromagram(values: values), majorness: -1.0)
    #expect(major.brightness > minor.brightness)
}

@Test("All color components stay within 0...1")
func colorComponentsBounded() {
    let fft = FFTProcessor(size: 8192)!
    let chord = ToneGenerator.tones(
        frequencies: [261.63, 329.63, 392.00],
        sampleCount: 8192
    )
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: chord),
        fft: fft,
        sampleRate: 48_000
    )
    let color = TonalColor(chromagram: chroma, majorness: 0.5)

    #expect((0...1).contains(color.hue))
    #expect((0...1).contains(color.saturation))
    #expect((0...1).contains(color.brightness))
}
