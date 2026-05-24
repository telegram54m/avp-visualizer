import AVFoundation
import Foundation
import Testing
@testable import AudioAnalysis

/// Writes mono samples to a temporary WAV file and returns its URL.
/// WAV is uncompressed, so decoding it back is lossless — ideal for testing.
private func writeTempWAV(samples: [Float], sampleRate: Double) throws -> URL {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    )!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for i in samples.indices {
        buffer.floatChannelData![0][i] = samples[i]
    }
    try file.write(from: buffer)
    return url
}

@Test("Decoding a written WAV recovers the exact samples and rate")
func decodeRoundTrip() throws {
    let sampleRate = 44_100.0
    let original = ToneGenerator.sine(
        frequency: 440,
        sampleCount: 44_100,
        sampleRate: sampleRate
    )
    let url = try writeTempWAV(samples: original, sampleRate: sampleRate)
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try AudioFileDecoder.decode(contentsOf: url)

    #expect(decoded.sampleRate == sampleRate)
    // Audio I/O is not sample-exact: container framing can trim a partial
    // block (here ~1024 samples) off the end. A few ms of slack is expected.
    #expect(abs(decoded.samples.count - original.count) < 1024)
    #expect(abs(decoded.duration - 1.0) < 0.05)
}

@Test("The full pipeline detects the key of a decoded audio file")
func decodeThenDetectKey() throws {
    let sampleRate = 44_100.0
    let sampleCount = 16_384

    // A C major chord written to a real file...
    let chord = ToneGenerator.tones(
        frequencies: [261.63, 329.63, 392.00],
        sampleCount: sampleCount,
        sampleRate: sampleRate,
        amplitude: 0.5
    )
    let url = try writeTempWAV(samples: chord, sampleRate: sampleRate)
    defer { try? FileManager.default.removeItem(at: url) }

    // ...decoded back, then run through the whole analysis pipeline.
    let decoded = try AudioFileDecoder.decode(contentsOf: url)

    let fftSize = 8192
    let fft = FFTProcessor(size: fftSize)!
    let window = Array(decoded.samples.prefix(fftSize))
    let chroma = Chromagram(
        spectrum: fft.magnitudeSpectrum(of: window),
        fft: fft,
        sampleRate: decoded.sampleRate
    )
    let estimate = KeyDetector.detect(from: chroma)

    #expect(estimate.key == Key(tonic: .c, mode: .major))
}

@Test("Decoding a missing file throws")
func decodeMissingFileThrows() {
    let url = URL(fileURLWithPath: "/nonexistent/path/does-not-exist.wav")
    #expect(throws: AudioFileDecoder.DecodeError.self) {
        try AudioFileDecoder.decode(contentsOf: url)
    }
}
