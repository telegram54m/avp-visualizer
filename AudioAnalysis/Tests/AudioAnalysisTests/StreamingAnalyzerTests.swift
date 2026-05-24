import Testing
@testable import AudioAnalysis

@Test("StreamingAnalyzer emits roughly one frame per hop")
func streamingFrameCount() {
    // 4 seconds @ 48k of 440Hz sine — long enough for many frames at 30fps.
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 48_000 * 4, sampleRate: 48_000)
    let analyzer = StreamingAnalyzer(sampleRate: 48_000, frameRate: 30, windowSize: 8192)!

    // Feed in IOProc-sized chunks (512 frames) to mimic the live path.
    var emitted: [FeatureFrame] = []
    var i = 0
    while i < tone.count {
        let end = min(i + 512, tone.count)
        emitted.append(contentsOf: analyzer.append(Array(tone[i..<end])))
        i = end
    }

    // 4 seconds at 30fps = ~120 frames. The first hop's worth of audio is
    // consumed filling the rolling buffer before the first frame can fire,
    // so we expect slightly fewer than 120.
    #expect(emitted.count >= 110)
    #expect(emitted.count <= 122)
    #expect(emitted.first?.time == 0)
    // Monotonic time, spacing = 1/30s.
    if emitted.count >= 2 {
        let dt = emitted[1].time - emitted[0].time
        #expect(abs(dt - 1.0 / 30.0) < 1e-6)
    }
}

@Test("StreamingAnalyzer features land in expected ranges")
func streamingFeatureRanges() {
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 48_000 * 2, sampleRate: 48_000)
    let analyzer = StreamingAnalyzer(sampleRate: 48_000)!
    var frames: [FeatureFrame] = []
    for chunk in stride(from: 0, to: tone.count, by: 1024) {
        let end = min(chunk + 1024, tone.count)
        frames.append(contentsOf: analyzer.append(Array(tone[chunk..<end])))
    }
    #expect(!frames.isEmpty)
    for frame in frames {
        #expect((0...1).contains(frame.color.hue))
        #expect((0...1).contains(frame.color.saturation))
        #expect(frame.loudness >= 0)
        #expect(frame.harmonicComplexity >= 0)
    }
}

@Test("StreamingAnalyzer detects pulses as onsets")
func streamingOnsetDetection() {
    // 8 pulses at 0.5s spacing (16 BPS) — known ground truth.
    let pulses = ToneGenerator.pulses(
        count: 8,
        interval: 0.5,
        burstDuration: 0.05,
        frequency: 440,
        sampleRate: 48_000
    )
    let analyzer = StreamingAnalyzer(sampleRate: 48_000)!
    var frames: [FeatureFrame] = []
    for chunk in stride(from: 0, to: pulses.count, by: 512) {
        let end = min(chunk + 512, pulses.count)
        frames.append(contentsOf: analyzer.append(Array(pulses[chunk..<end])))
    }
    let onsets = frames.filter { $0.onset }.count
    // We expect 8 ground-truth onsets; allow a wide tolerance for the
    // streaming detector's EMA-baseline approximation (early pulses fire
    // strong, later ones may be smaller against a higher baseline).
    #expect(onsets >= 4)
    #expect(onsets <= 12)
}

@Test("StreamingAnalyzer reset clears state")
func streamingResetClearsState() {
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 48_000, sampleRate: 48_000)
    let analyzer = StreamingAnalyzer(sampleRate: 48_000)!
    _ = analyzer.append(tone)
    #expect(analyzer.emittedFrameCount > 0)
    analyzer.reset()
    #expect(analyzer.emittedFrameCount == 0)
    // After reset, time restarts from 0.
    let frames = analyzer.append(tone)
    #expect(frames.first?.time == 0)
}

@Test("StreamingAnalyzer and offline pipeline agree on loudness")
func streamingMatchesOfflineOnLoudness() {
    // Feed identical audio through both pipelines; loudness values should
    // track closely. Color/timbre may differ slightly due to onset alignment
    // and window-centering differences; loudness is the cleanest signal to
    // compare since it's just RMS of the windowed slice.
    let tone = ToneGenerator.sine(frequency: 440, sampleCount: 48_000 * 2, sampleRate: 48_000, amplitude: 0.5)
    let offline = AnalysisTimeline.analyze(DecodedAudio(samples: tone, sampleRate: 48_000), frameRate: 30, windowSize: 8192)

    let analyzer = StreamingAnalyzer(sampleRate: 48_000, frameRate: 30, windowSize: 8192)!
    var streaming: [FeatureFrame] = []
    for chunk in stride(from: 0, to: tone.count, by: 512) {
        let end = min(chunk + 512, tone.count)
        streaming.append(contentsOf: analyzer.append(Array(tone[chunk..<end])))
    }

    // Sustained sine: every frame should have very similar RMS.
    // Compare a middle frame (past the buffer-fill warmup) of each.
    guard offline.count > 20, streaming.count > 20 else {
        Issue.record("not enough frames to compare")
        return
    }
    let offlineLoudness = offline[20].loudness
    let streamingLoudness = streaming[20].loudness
    // Within 5% — both windows hold the same sustained tone.
    let delta = abs(offlineLoudness - streamingLoudness)
    #expect(delta < 0.05)
}
