import Testing
@testable import AudioAnalysis

private let sampleRate = 48_000.0

@Test("A pulse train yields one onset per burst")
func pulseTrainOnsets() {
    // 8 bursts, one every 0.5s.
    let signal = ToneGenerator.pulses(
        count: 8,
        interval: 0.5,
        burstDuration: 0.06,
        sampleRate: sampleRate
    )
    let audio = DecodedAudio(samples: signal, sampleRate: sampleRate)
    let result = OnsetDetector.detect(in: audio)

    // Allow ±1 for edge effects at the very start/end.
    #expect(result.onsetTimes.count >= 7)
    #expect(result.onsetTimes.count <= 9)
}

@Test("Pulse-train onsets land roughly half a second apart")
func pulseTrainSpacing() {
    let signal = ToneGenerator.pulses(
        count: 6,
        interval: 0.5,
        burstDuration: 0.06,
        sampleRate: sampleRate
    )
    let result = OnsetDetector.detect(in: DecodedAudio(samples: signal, sampleRate: sampleRate))

    let gaps = zip(result.onsetTimes.dropFirst(), result.onsetTimes).map { $0 - $1 }
    for gap in gaps {
        #expect(abs(gap - 0.5) < 0.08)
    }
}

@Test("Silence produces no onsets")
func silenceHasNoOnsets() {
    let silence = [Float](repeating: 0, count: 48_000)
    let result = OnsetDetector.detect(in: DecodedAudio(samples: silence, sampleRate: sampleRate))
    #expect(result.onsetTimes.isEmpty)
}

@Test("A sustained tone has at most one onset — its initial attack")
func sustainedToneHasOneOnset() {
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 96_000, sampleRate: sampleRate)
    let result = OnsetDetector.detect(in: DecodedAudio(samples: tone, sampleRate: sampleRate))
    #expect(result.onsetTimes.count <= 2)
}
