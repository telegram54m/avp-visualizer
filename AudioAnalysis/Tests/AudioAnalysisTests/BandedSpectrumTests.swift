import Testing
@testable import AudioAnalysis

private let fftSize = 8192
private let sampleRate = 48_000.0

@Test("A 60 Hz sine concentrates loudness in the sub band")
func subBandSineLoudness() {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 60, sampleCount: fftSize, sampleRate: sampleRate)
    let banded = BandedSpectrum(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )

    let dominant = banded.loudness.indices.max { banded.loudness[$0] < banded.loudness[$1] }
    #expect(dominant == FrequencyBand.sub.rawValue)
}

@Test("An 8 kHz sine concentrates loudness in the brilliance band")
func brillianceBandSineLoudness() {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 8000, sampleCount: fftSize, sampleRate: sampleRate)
    let banded = BandedSpectrum(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )

    let dominant = banded.loudness.indices.max { banded.loudness[$0] < banded.loudness[$1] }
    #expect(dominant == FrequencyBand.brilliance.rawValue)
}

@Test("A bass-octave C chord puts harmonic energy in the low-mid band's chromagram")
func bassChordLandsInLowMidChromagram() {
    let fft = FFTProcessor(size: fftSize)!
    // C2 = 65.4, E2 = 82.4, G2 = 98 — these are below 120 Hz (sub band)
    // for fundamentals; C3 = 130.8 sits in low-mid. Use a C3 chord so
    // the chromagram-relevant bins fall in low-mid.
    let c3 = ToneGenerator.sine(frequency: 130.81, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let e3 = ToneGenerator.sine(frequency: 164.81, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let g3 = ToneGenerator.sine(frequency: 196.00, sampleCount: fftSize, sampleRate: sampleRate, amplitude: 0.5)
    let chord = ToneGenerator.mix([c3, e3, g3])

    let banded = BandedSpectrum(
        spectrum: fft.magnitudeSpectrum(of: chord),
        fft: fft,
        sampleRate: sampleRate
    )

    let lowMidChroma = banded.chromagram[FrequencyBand.lowMid.rawValue]
    let topThree = Set(
        lowMidChroma.indices
            .sorted { lowMidChroma[$0] > lowMidChroma[$1] }
            .prefix(3)
    )
    let expected = Set([PitchClass.c.rawValue, PitchClass.e.rawValue, PitchClass.g.rawValue])
    #expect(topThree == expected)

    // And the sub band's chroma should be very nearly empty — those
    // bins fall below the chromagram's 65 Hz cutoff.
    let subChroma = banded.chromagram[FrequencyBand.sub.rawValue]
    let subTotal = subChroma.reduce(0, +)
    let lowMidTotal = lowMidChroma.reduce(0, +)
    #expect(subTotal < lowMidTotal * 0.05)
}

@Test("BandedSpectrum is the right shape")
func bandedSpectrumShape() {
    let fft = FFTProcessor(size: fftSize)!
    let tone = ToneGenerator.sine(frequency: 1000, sampleCount: fftSize, sampleRate: sampleRate)
    let banded = BandedSpectrum(
        spectrum: fft.magnitudeSpectrum(of: tone),
        fft: fft,
        sampleRate: sampleRate
    )
    #expect(banded.loudness.count == 4)
    #expect(banded.chromagram.count == 4)
    #expect(banded.chromagram.allSatisfy { $0.count == 12 })
}

@Test("BandedSpectrum.zero produces all-zero data of the right shape")
func bandedSpectrumZero() {
    let zero = BandedSpectrum.zero
    #expect(zero.loudness == [0, 0, 0, 0])
    #expect(zero.chromagram.count == 4)
    #expect(zero.chromagram.allSatisfy { $0.allSatisfy { $0 == 0 } })
}

@Test("BandedOnsetDetector fires the brilliance-band onset for a sudden hi-hat-like burst")
func bandedOnsetFiresOnHighBurst() {
    let fft = FFTProcessor(size: fftSize)!
    let detector = BandedOnsetDetector(
        fft: fft,
        sampleRate: sampleRate,
        onsetThreshold: 1.5,
        refractory: 0.05,
        baselineSmoothing: 0.05
    )

    // Establish a quiet baseline with several frames of near-silence
    // (very low-amplitude 10 Hz so the spectrum isn't literally zero).
    let dt = 1.0 / 30.0
    let quiet = ToneGenerator.sine(
        frequency: 50, sampleCount: fftSize,
        sampleRate: sampleRate, amplitude: 0.001
    )
    for _ in 0..<10 {
        _ = detector.process(spectrum: fft.magnitudeSpectrum(of: quiet), deltaTime: dt)
    }

    // Now a loud high-frequency burst — should fire brilliance.
    let burst = ToneGenerator.sine(
        frequency: 8000, sampleCount: fftSize,
        sampleRate: sampleRate, amplitude: 1.0
    )
    let onsets = detector.process(
        spectrum: fft.magnitudeSpectrum(of: burst),
        deltaTime: dt
    )

    #expect(onsets[FrequencyBand.brilliance.rawValue])
}

@Test("BandedOnsetDetector doesn't fire on the first spectrum (cold start)")
func bandedOnsetSkipsColdStart() {
    let fft = FFTProcessor(size: fftSize)!
    let detector = BandedOnsetDetector(fft: fft, sampleRate: sampleRate)
    let loud = ToneGenerator.sine(
        frequency: 60, sampleCount: fftSize,
        sampleRate: sampleRate, amplitude: 1.0
    )
    let onsets = detector.process(
        spectrum: fft.magnitudeSpectrum(of: loud),
        deltaTime: 1.0 / 30.0
    )
    #expect(onsets.allSatisfy { !$0 })
}

@Test("Offline analyzer populates per-band fields on every frame")
func offlineAnalyzerPopulatesBandFields() {
    // 1 second of mixed signal: bass + mid + high
    let bass = ToneGenerator.sine(frequency: 60, duration: 1.0, sampleRate: sampleRate, amplitude: 0.4)
    let mid = ToneGenerator.sine(frequency: 1000, duration: 1.0, sampleRate: sampleRate, amplitude: 0.4)
    let high = ToneGenerator.sine(frequency: 8000, duration: 1.0, sampleRate: sampleRate, amplitude: 0.4)
    let mix = ToneGenerator.mix([bass, mid, high])
    let audio = DecodedAudio(samples: mix, sampleRate: sampleRate)

    let frames = AnalysisTimeline.analyze(audio, frameRate: 30, windowSize: fftSize)
    #expect(!frames.isEmpty)
    for f in frames {
        #expect(f.bandLoudness.count == 4)
        #expect(f.bandChromagram.count == 4)
        #expect(f.bandOnset.count == 4)
    }
    // Every band should have non-zero loudness on this mix.
    let lastFrame = frames.last!
    #expect(lastFrame.bandLoudness[FrequencyBand.sub.rawValue] > 0)
    #expect(lastFrame.bandLoudness[FrequencyBand.highMid.rawValue] > 0)
    #expect(lastFrame.bandLoudness[FrequencyBand.brilliance.rawValue] > 0)
}

@Test("Streaming analyzer populates per-band fields on every emitted frame")
func streamingAnalyzerPopulatesBandFields() {
    let analyzer = StreamingAnalyzer(
        sampleRate: sampleRate,
        frameRate: 30,
        windowSize: fftSize
    )!
    let tone = ToneGenerator.sine(
        frequency: 1000, duration: 0.5,
        sampleRate: sampleRate, amplitude: 0.5
    )
    let frames = analyzer.append(tone)
    #expect(!frames.isEmpty)
    for f in frames {
        #expect(f.bandLoudness.count == 4)
        #expect(f.bandChromagram.count == 4)
        #expect(f.bandOnset.count == 4)
    }
    // The 1 kHz tone should dominate the high-mid band.
    let last = frames.last!
    let dominantBand = last.bandLoudness.indices.max { last.bandLoudness[$0] < last.bandLoudness[$1] }
    #expect(dominantBand == FrequencyBand.highMid.rawValue)
}
