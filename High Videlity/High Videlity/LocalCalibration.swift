//
//  LocalCalibration.swift
//  High Videlity
//
//  iOS-only: derive `previewStartInSong` for the currently-playing
//  library track WITHOUT needing live mic capture, by matching the
//  decoded song file directly against the 30-second iTunes preview's
//  signature.
//
//  Why this exists: the [[ios-system-music-pivot]] gives us
//  frame-accurate alignment by reading `MPMusicPlayerController.
//  currentPlaybackTime` and mapping it through the cached
//  `previewStartInSong` value. But the cache only populates on
//  devices where the user has previously listened to that song with
//  mic-Shazam custom-catalog matching active (typically macOS, since
//  iOS mic mode fights `.playAndRecord` ducking). A user who only
//  ever uses iOS system-music mode never builds up a useful cache.
//  [[cloudkit-cache-sync]] helps cross-device (Mac calibrates → iPhone
//  benefits) but doesn't help the never-calibrated-anywhere case.
//
//  This file closes that gap. When a new song starts on iOS and:
//    • the alignment cache is empty for it, AND
//    • `MPMediaItem.assetURL` is available (downloaded library track,
//      not a streaming-only Apple Music track),
//  we kick off `LocalCalibration.calibrate(...)` in the background.
//  It generates a signature for the preview, builds a dedicated
//  custom catalog + SHSession around it, then pumps the entire song
//  file through `matchStreamingBuffer`. When Shazam fires a match,
//  `predictedCurrentMatchOffset` tells us the preview-time the
//  matched-moment corresponds to; combined with how much song-audio
//  we've fed so far, we derive `previewStartInSong` and persist it
//  via the existing ShazamPhase2 cache path (which auto-pushes to
//  CloudKit via #1).
//
//  Why a dedicated SHSession (not the one in ShazamController):
//   • The main custom session's catalog signature is built against
//     the mic's PCM format (see `ShazamPhase2.generateSignature`).
//     We're feeding decoded song audio, not mic input — needs a
//     different format-aligned catalog.
//   • Concurrent SHSessions don't interfere; each keeps its own
//     accumulating buffer state.
//
//  Realistic timing: signature gen ~100-500ms for the preview;
//  pumping a 3-minute song faster than realtime is a few seconds
//  of MLX/CPU. Total ~3-8 seconds end-to-end per song. Runs in the
//  background; the visualizer keeps using modulo-wrap alignment in
//  the meantime and seamlessly upgrades to cache-derived alignment
//  on the very next playbackTime read after calibration succeeds.
//

#if os(iOS)
import AVFoundation
import Foundation
import OSLog
import ShazamKit

private let calibLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "local-calib")

enum LocalCalibration {

    /// Result of a successful calibration: the preview's start
    /// position within the full song, in seconds. Negative would be
    /// pathological (preview starts before the song — impossible),
    /// so we reject those.
    struct CalibrationResult {
        let previewStartInSong: TimeInterval
    }

    enum CalibrationError: Error {
        case previewSignatureFailed
        case songFileOpenFailed
        case noMatchBeforeTimeout
        case implausibleOffset
    }

    /// Run the streaming match. Returns the derived
    /// `previewStartInSong` or throws `CalibrationError` on any
    /// failure — caller logs + moves on (no caching of failures
    /// here; on next play we'll just retry).
    ///
    /// Cost: signature gen + streaming the whole song through the
    /// fingerprint engine. ~3-8s typical. Run on a detached
    /// background task — don't block the main actor.
    static func calibrate(
        previewURL: URL,
        songAssetURL: URL,
        previewDuration: TimeInterval
    ) async throws -> CalibrationResult {
        // 1. Build the preview's reference signature in a neutral
        //    canonical format (44.1 kHz mono Float32). Both sides
        //    will be converted to this same format so the fingerprint
        //    extractor sees consistent input.
        let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!

        let previewSignature: SHSignature
        do {
            previewSignature = try await generateSignature(
                fileURL: previewURL,
                targetFormat: canonicalFormat
            )
        } catch {
            calibLog.notice("HV-CALIB preview signature gen failed: \(String(describing: error), privacy: .public)")
            throw CalibrationError.previewSignatureFailed
        }

        // 2. Build the custom catalog + dedicated session for this
        //    one-off calibration.
        let catalog = SHCustomCatalog()
        let mediaItem = SHMediaItem(properties: [
            .title: "calibration",
            .shazamID: UUID().uuidString
        ])
        try catalog.addReferenceSignature(previewSignature, representing: [mediaItem])

        // 3. Spin up the streaming match. The matchAccumulator
        //    bridges SHSession's delegate-based match callback into
        //    the structured-concurrency async/await world.
        let accumulator = MatchAccumulator()
        let session = SHSession(catalog: catalog)
        session.delegate = accumulator

        // 4. Pump the song file in 1-second contiguous buffers,
        //    tracking the cumulative song-time we've fed. Stop as
        //    soon as a match fires or the song runs out.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: songAssetURL)
        } catch {
            calibLog.notice("HV-CALIB song file open failed: \(String(describing: error), privacy: .public)")
            throw CalibrationError.songFileOpenFailed
        }
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: canonicalFormat) else {
            throw CalibrationError.songFileOpenFailed
        }

        // ~1s of canonical audio per pump.
        let pumpFrames = AVAudioFrameCount(canonicalFormat.sampleRate)
        // Source-side capacity sized for the rate ratio.
        let sourceFrames = AVAudioFrameCount(
            Double(pumpFrames) * sourceFormat.sampleRate / canonicalFormat.sampleRate
        ) + 1024

        var songTimeFed: TimeInterval = 0
        // Hard ceiling so a freak case (silent song, format
        // weirdness, signature mismatch) can't pump forever. Songs
        // longer than ~10 min are extreme outliers; abandon by then.
        let maxFedSeconds: TimeInterval = 600
        let timeoutTask = Task {
            // Extra wall-clock safety even if file reading hangs.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            accumulator.signalTimeout()
        }
        defer { timeoutTask.cancel() }

        while songTimeFed < maxFedSeconds {
            // Read one source chunk; on EOF, file.read returns
            // frameLength == 0 and we break out.
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: sourceFrames
            ), let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: canonicalFormat, frameCapacity: pumpFrames
            ) else {
                break
            }
            do {
                try file.read(into: inputBuffer)
            } catch {
                break
            }
            if inputBuffer.frameLength == 0 { break }

            // Convert source → canonical. One-shot per chunk.
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            var convErr: NSError?
            converter.convert(to: outputBuffer, error: &convErr, withInputFrom: inputBlock)
            if convErr != nil || outputBuffer.frameLength == 0 { break }

            // Feed to Shazam — nil AVAudioTime tells the session to
            // skip its contiguity check (same approach
            // ShazamPhase2.feedBoth uses for non-mic sources).
            session.matchStreamingBuffer(outputBuffer, at: nil)

            songTimeFed += Double(outputBuffer.frameLength) / canonicalFormat.sampleRate

            // Poll the accumulator BETWEEN pumps so a match found
            // mid-pump short-circuits the rest of the file.
            if let match = accumulator.matchedItem {
                let previewOffset = match.predictedCurrentMatchOffset
                // The match's `predictedCurrentMatchOffset` represents
                // the preview-second corresponding to the most-recently
                // fed buffer (which is now = songTimeFed).
                let previewStartInSong = songTimeFed - previewOffset
                guard previewStartInSong > -10, previewStartInSong < 600 else {
                    calibLog.notice("HV-CALIB implausible offset \(previewStartInSong, privacy: .public)s — reject")
                    throw CalibrationError.implausibleOffset
                }
                // Wrap negatives that come from streaming jitter
                // (offset slightly past 0 of the preview after wrap)
                // into the [0, previewDuration) window via the same
                // arithmetic ShazamPhase2 already uses elsewhere.
                let normalized = previewStartInSong < 0
                    ? previewStartInSong + previewDuration
                    : previewStartInSong
                calibLog.notice("HV-CALIB matched after \(songTimeFed, privacy: .public)s fed: previewStartInSong=\(normalized, privacy: .public)s")
                return CalibrationResult(previewStartInSong: normalized)
            }

            // Yield occasionally so the main actor + audio thread
            // aren't starved while we crunch through the song.
            await Task.yield()

            if accumulator.timedOut { break }
        }

        calibLog.notice("HV-CALIB no match after pumping \(songTimeFed, privacy: .public)s — preview likely doesn't appear in this song version")
        throw CalibrationError.noMatchBeforeTimeout
    }

    /// Generate an SHSignature from a complete audio file, converted
    /// into a chosen canonical format. Off the main actor — the
    /// signature gen for a 30s file is ~100–500ms and the decode +
    /// convert can take longer on lossy compressed source files.
    private nonisolated static func generateSignature(
        fileURL: URL, targetFormat: AVAudioFormat
    ) async throws -> SHSignature {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: fileURL)
            let sourceFormat = file.processingFormat
            let fileLength = AVAudioFrameCount(file.length)
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: fileLength) else {
                throw NSError(domain: "LocalCalibration", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Buffer / converter setup failed"])
            }
            try file.read(into: inputBuffer)

            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
            ) + 4096
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw NSError(domain: "LocalCalibration", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Output buffer alloc failed"])
            }

            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            var convErr: NSError?
            converter.convert(to: outputBuffer, error: &convErr, withInputFrom: inputBlock)
            if let err = convErr { throw err }

            let generator = SHSignatureGenerator()
            try generator.append(outputBuffer, at: nil)
            return generator.signature()
        }.value
    }
}

/// Bridges SHSession's delegate-based match callback into a
/// structured-concurrency-friendly polling shape. Calibration loop
/// reads `matchedItem` after every pumped buffer.
///
/// NSObject required for SHSessionDelegate conformance.
private final class MatchAccumulator: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _match: SHMatchedMediaItem?
    private var _timedOut: Bool = false

    var matchedItem: SHMatchedMediaItem? {
        lock.lock(); defer { lock.unlock() }
        return _match
    }
    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _timedOut
    }

    func signalTimeout() {
        lock.lock(); _timedOut = true; lock.unlock()
    }

    // SHSessionDelegate — note: per Apple docs these can fire on an
    // arbitrary queue, so we serialize access via lock.
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        lock.lock(); _match = item; lock.unlock()
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // Non-fatal — the streaming engine fires this when an
        // intermediate window doesn't match but accumulation
        // continues. We just keep pumping.
    }
}

#endif  // os(iOS)
