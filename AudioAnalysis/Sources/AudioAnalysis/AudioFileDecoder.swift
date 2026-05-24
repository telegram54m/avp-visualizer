import AVFoundation

/// Raw audio decoded from a file: mono PCM samples plus their sample rate.
public struct DecodedAudio: Sendable {

    /// Mono PCM samples. Stereo files are downmixed by averaging channels.
    public let samples: [Float]

    /// Samples per second of the decoded audio (the file's native rate).
    public let sampleRate: Double

    /// Length of the audio in seconds.
    public var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Decodes audio files into raw samples our analyzers can consume.
public enum AudioFileDecoder {

    public enum DecodeError: Error, Equatable {
        /// The file could not be opened (missing, unreadable, unsupported format).
        case couldNotOpen
        /// The file opened but its audio data could not be read.
        case couldNotRead
        /// The file contains no audio frames.
        case emptyFile
    }

    /// Decodes a local audio file into mono PCM samples.
    ///
    /// Handles any container/codec AVFoundation supports — AAC (`.m4a`),
    /// MP3, WAV, AIFF, and others.
    ///
    /// - Parameter url: a local file URL. Network URLs are not supported;
    ///   download to a temp file first.
    public static func decode(contentsOf url: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError.couldNotOpen
        }

        // AVAudioFile's processing format is always non-interleaved Float32.
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw DecodeError.emptyFile }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw DecodeError.couldNotRead
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw DecodeError.couldNotRead
        }

        guard let channelData = buffer.floatChannelData else {
            throw DecodeError.couldNotRead
        }

        let channelCount = Int(format.channelCount)
        let length = Int(buffer.frameLength)

        // Downmix to mono: average every channel at each frame.
        var mono = [Float](repeating: 0, count: length)
        for frame in 0..<length {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(channelCount)
        }

        return DecodedAudio(samples: mono, sampleRate: format.sampleRate)
    }
}
