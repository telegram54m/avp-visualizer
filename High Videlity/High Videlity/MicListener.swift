//
//  MicListener.swift
//  High Videlity
//
//  Live microphone capture + real-time loudness/onset extraction. The DRM
//  workaround for visualizing whatever audio happens to be playing in the
//  room (Apple Music, Spotify, a record player, anything) when third-party
//  apps can't read those audio buffers directly. The visualizer reads
//  `smoothedLoudness` and `onsetCounter` instead of (or alongside) the
//  pre-analyzed song timeline.
//

import AVFoundation
import AudioAnalysis
import Foundation
import SwiftUI

@MainActor
@Observable
final class MicListener {

    /// Whether the engine is currently running.
    private(set) var isActive: Bool = false
    /// Whether the user has granted mic permission. `nil` until first asked.
    private(set) var isAuthorized: Bool? = nil
    /// Smoothed loudness (0…~1) of the live audio. Updated ~30 Hz.
    private(set) var smoothedLoudness: Float = 0
    /// Monotonic counter — incremented once per detected onset. The
    /// visualizer compares to its own last-seen value each frame to find
    /// "new" onsets without missing any.
    private(set) var onsetCounter: Int = 0

    // --- Audio-thread state, guarded by `lock` -----------------------------
    // The `@ObservationIgnored` keeps the @Observable macro from wrapping
    // these in change-tracking accessors, which would conflict with the
    // audio-thread reads/writes; the lock provides the actual safety.
    // DIAG-FPS-REVERT: temporarily reverted to eager-init engine to
    // test if lazy-init was causing the global 60fps cap. If FPS
    // recovers with this revert, we know the lazy pattern is the
    // culprit and we need a different way to defer the mic prompt.
    @ObservationIgnored nonisolated(unsafe) private let engine = AVAudioEngine()
    @ObservationIgnored nonisolated(unsafe) private let detector = RealtimeOnsetDetector()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var pendingLoudness: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingOnsets: Int = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Optional additional handler invoked with every captured audio buffer
    /// on the audio thread. Used by `ShazamController` to receive the same
    /// audio stream the loudness/onset detector sees, without installing a
    /// second tap (AVAudioEngine only allows one tap per input bus). Set
    /// before calling `start()`; cleared automatically on `stop()`.
    @ObservationIgnored
    nonisolated(unsafe) var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Request permission (if needed) and start capturing.
    func start() async {
        guard !isActive else { return }

        #if os(tvOS)
        // tvOS has no standalone microphone (Continuity Mic only). Surface
        // permission as denied so UI can hint at the limitation.
        isAuthorized = false
        return
        #else

        // Permission.
        let granted: Bool
        #if os(macOS)
        granted = await AVCaptureDevice.requestAccess(for: .audio)
        #else
        if #available(visionOS 1.0, iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission {
                    cont.resume(returning: $0)
                }
            }
        }
        #endif
        isAuthorized = granted
        guard granted else { return }

        // Audio session — playAndRecord with mixWithOthers so we don't duck
        // whatever the user is playing in Apple Music / Spotify / a speaker.
        // macOS has no AVAudioSession; AVAudioEngine binds to the default
        // input device automatically.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            print("[Mic] audio session setup failed: \(error)")
            return
        }
        #endif

        // Install the tap. The closure runs on the audio thread on every
        // buffer (~10-20 ms at the engine's default size); we just snapshot
        // the detector's outputs and a poll-task drains them on the main
        // thread at ~30 Hz to update @Observable state.
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("[Mic] input format has zero sample rate; aborting")
            return
        }

        detector.reset()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self = self else { return }
            let samples = MicListener.extractMono(from: buffer)
            let duration = Double(buffer.frameLength) / format.sampleRate
            let result = self.detector.process(samples, duration: duration)

            self.lock.lock()
            self.pendingLoudness = self.detector.smoothedLoudness
            if result.onset { self.pendingOnsets += 1 }
            self.lock.unlock()

            // Fan out to any additional consumer (ShazamKit). We must
            // hand them an OWNED copy of the buffer — `installTap`'s
            // buffer is backed by storage AVAudioEngine recycles on the
            // next callback, and `SHSession.matchStreamingBuffer` queues
            // work asynchronously inside the framework. Reading the
            // recycled buffer's data crashes with "Supplied audio format
            // ... unsupported" because the format description goes stale
            // before Shazam processes it. SystemAudioListener has the
            // same issue and copies via `copyPCMBuffer`.
            if let handler = self.bufferHandler,
               let copy = MicListener.copyPCMBuffer(buffer) {
                handler(copy, when)
            }
        }

        do {
            try engine.start()
        } catch {
            print("[Mic] engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            return
        }

        isActive = true
        startPolling()
        #endif // !os(tvOS)
    }

    /// Stop capturing and release the audio session.
    func stop() {
        guard isActive else { return }
        pollTask?.cancel()
        pollTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isActive = false
        smoothedLoudness = 0
        bufferHandler = nil
        lock.lock()
        pendingLoudness = 0
        pendingOnsets = 0
        lock.unlock()
    }

    /// Drain audio-thread state into the @Observable properties at ~30 Hz.
    /// Plenty for visualizer reactivity; cheaper than firing per-buffer.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self = self, self.isActive {
                // `withLock` is the async-safe scoped form. The closure runs
                // synchronously and returns the snapshot we need; no await
                // points cross the lock boundary.
                let (loudness, onsets) = self.lock.withLock { () -> (Float, Int) in
                    let l = self.pendingLoudness
                    let o = self.pendingOnsets
                    self.pendingOnsets = 0
                    return (l, o)
                }

                self.smoothedLoudness = loudness
                if onsets > 0 { self.onsetCounter += onsets }

                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    /// Copy a tap-callback PCMBuffer into an owned buffer whose backing
    /// store survives beyond the current callback. Required for any
    /// downstream consumer (e.g. ShazamKit's `matchStreamingBuffer`)
    /// that processes the buffer asynchronously — without copying, the
    /// engine recycles the storage on the next callback and the consumer
    /// reads stale/recycled data. Mirrors `SystemAudioListener.copyPCMBuffer`.
    private nonisolated static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = source.format
        guard let copy = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: source.frameCapacity)
        else { return nil }
        copy.frameLength = source.frameLength
        let channelCount = Int(format.channelCount)
        let frames = Int(source.frameLength)
        guard let srcCh = source.floatChannelData,
              let dstCh = copy.floatChannelData,
              channelCount > 0, frames > 0 else { return copy }
        let byteCount = frames * MemoryLayout<Float>.size
        for ch in 0..<channelCount {
            memcpy(dstCh[ch], srcCh[ch], byteCount)
        }
        return copy
    }

    /// Downmix any-channel-count Float32 PCM into a mono `[Float]`. Mirrors
    /// `AudioFileDecoder`'s downmix so the live path and the file path feed
    /// the analyzers identically-shaped input.
    private nonisolated static func extractMono(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        guard channelCount > 0, length > 0 else { return [] }

        var mono = [Float](repeating: 0, count: length)
        if channelCount == 1 {
            // Fast path — already mono.
            let src = channelData[0]
            for frame in 0..<length { mono[frame] = src[frame] }
        } else {
            for frame in 0..<length {
                var sum: Float = 0
                for ch in 0..<channelCount { sum += channelData[ch][frame] }
                mono[frame] = sum / Float(channelCount)
            }
        }
        return mono
    }
}
