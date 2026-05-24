import Testing
@testable import AudioAnalysis

private let sampleRate = 48_000.0

/// A click track of `count` pulses spaced `interval` seconds apart.
private func clickTrack(count: Int, interval: Double) -> DecodedAudio {
    let signal = ToneGenerator.pulses(
        count: count,
        interval: interval,
        burstDuration: 0.05,
        sampleRate: sampleRate
    )
    return DecodedAudio(samples: signal, sampleRate: sampleRate)
}

@Test("A 120 BPM click track is detected as ~120 BPM")
func detects120BPM() {
    // 0.5s between pulses → 120 BPM.
    let estimate = TempoDetector.detect(in: clickTrack(count: 16, interval: 0.5))
    #expect(estimate != nil)
    #expect(abs((estimate?.bpm ?? 0) - 120) < 8)
}

@Test("A 100 BPM click track is detected as ~100 BPM")
func detects100BPM() {
    // 0.6s between pulses → 100 BPM.
    let estimate = TempoDetector.detect(in: clickTrack(count: 14, interval: 0.6))
    #expect(estimate != nil)
    #expect(abs((estimate?.bpm ?? 0) - 100) < 8)
}

@Test("A steady pulse is more confident than an arrhythmic tone")
func pulseTrainBeatsToneOnConfidence() {
    let pulseConfidence = TempoDetector.detect(in: clickTrack(count: 16, interval: 0.5))?.confidence ?? 0

    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 288_000, sampleRate: sampleRate)
    let toneConfidence = TempoDetector.detect(in: DecodedAudio(samples: tone, sampleRate: sampleRate))?.confidence ?? 1

    #expect(pulseConfidence > toneConfidence)
}
