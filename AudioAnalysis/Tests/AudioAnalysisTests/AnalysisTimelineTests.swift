import Testing
@testable import AudioAnalysis

@Test("Timeline analysis produces one frame per time step")
func timelineFrameCount() {
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 96_000, sampleRate: 48_000)
    let audio = DecodedAudio(samples: tone, sampleRate: 48_000)

    let frames = AnalysisTimeline.analyze(audio, frameRate: 30)

    // 2 seconds at 30 fps ≈ 60 frames.
    #expect(frames.count >= 55 && frames.count <= 60)
    #expect(frames.first?.time == 0)
}

@Test("Timeline frames carry consistent feature values")
func timelineFrameValues() {
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 96_000, sampleRate: 48_000)
    let frames = AnalysisTimeline.analyze(DecodedAudio(samples: tone, sampleRate: 48_000))

    for frame in frames {
        #expect((0...1).contains(frame.color.hue))
        #expect((0...1).contains(frame.color.saturation))
        #expect(frame.loudness >= 0)
    }
}
