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
    /// **Diag — visible on the iOS overlay.** Streaming-analyzer
    /// frames emitted since the last start(). Bumped (throttled to
    /// ~1Hz) from the polling task so SwiftUI doesn't thrash. Zero
    /// while mic is off, increments when frames are actually flowing
    /// through StreamingAnalyzer.
    private(set) var publishedFramesEmitted: Int = 0
    /// **Diag — visible on the iOS overlay.** Short summary of the
    /// audio session config the system actually gave us. Read once
    /// in start() after `setActive(true)` — the system may have
    /// downgraded what we requested.
    private(set) var publishedSessionInfo: String = ""
    /// **Diag — visible on the iOS overlay.** Raw tap-callback count
    /// since last start(). Distinguishes "no callbacks at all" (engine
    /// not running / no input route) from "callbacks fire but all
    /// samples are zero" (route silenced).
    private(set) var publishedTapCalls: Int = 0
    /// **Diag — visible on the iOS overlay.** Last-buffer peak abs
    /// sample value. Zero with non-zero `publishedTapCalls` means the
    /// route is being silenced (mic capture suppressed). Nonzero
    /// means audio IS arriving — any downstream loudness=0 is a
    /// detector/analyzer bug.
    private(set) var publishedTapPeak: Float = 0

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

    /// Streaming analyzer that emits full `FeatureFrame`s at 30 fps
    /// from the live mic PCM. Without this, mic mode would only
    /// produce loudness + onset signals — but the visualizers consume
    /// the rich frame data (chromagram, band-split, etc.). Mirrors
    /// the macOS SystemAudioListener's wiring so Crystal/Architecture/
    /// etc. show actual live reactivity instead of looping the last
    /// pre-analyzed song's 30s preview frames.
    @ObservationIgnored nonisolated(unsafe) private var streamingAnalyzer: StreamingAnalyzer?

    /// Feature frames emitted by `streamingAnalyzer` since the last
    /// drain. Audio thread appends; polling task drains under `lock`.
    @ObservationIgnored nonisolated(unsafe) private var pendingFrames: [FeatureFrame] = []

    /// Invoked on the main actor with each batch of new frames the
    /// streaming analyzer emits. The AppModel uses this to append
    /// into its rolling `frames` array so frame-based visualizers
    /// (Crystal, Architecture, etc.) get live data. Matches the
    /// signature of `SystemAudioListener.onNewFrames` on macOS.
    @ObservationIgnored
    var onNewFrames: (([FeatureFrame]) -> Void)?

    /// Diagnostic counter — total feature frames emitted by the
    /// streaming analyzer since the last `start()`. Used to verify
    /// frames are actually flowing in mic mode (the visible
    /// 30-second-loop bug would manifest as this stuck at 0).
    @ObservationIgnored nonisolated(unsafe) private var totalFramesEmitted: Int = 0
    /// Audio-thread-side counter — total tap callback invocations
    /// since the last `start()`. Mirror of `publishedTapCalls`
    /// updated from the polling task.
    @ObservationIgnored nonisolated(unsafe) private var totalTapCalls: Int = 0
    /// Audio-thread-side max abs sample seen in the most recent
    /// buffer. Zero with non-zero tap calls = route is silenced.
    @ObservationIgnored nonisolated(unsafe) private var lastBufferPeak: Float = 0

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

        // Audio session category — iterating on this is the recurring
        // pain. `.record + .mixWithOthers` empirically silences other
        // audio when user toggles mic FIRST, then tries to start AM
        // (only works in mic-second order). Reverting to
        // `.playAndRecord + .measurement + .mixWithOthers` which IS
        // documented to allow other audio to play, with `.measurement`
        // mode disabling the voice-call signal processing that
        // otherwise made Music.app drop to mono.
        //
        // macOS has no AVAudioSession; AVAudioEngine binds to the
        // default input device automatically.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
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
        totalFramesEmitted = 0
        publishedFramesEmitted = 0
        totalTapCalls = 0
        lastBufferPeak = 0
        publishedTapCalls = 0
        publishedTapPeak = 0
        #if !os(macOS)
        // Diagnostic: confirm what session we ended up with — when
        // debugging mic/AM coexistence empirically it's hard to know
        // which config Apple's actually honoring without this.
        let s = AVAudioSession.sharedInstance()
        // Compact session summary surfaced through the in-app debug
        // overlay so we don't need Console.app to verify.
        let catShort = s.category.rawValue.replacingOccurrences(
            of: "AVAudioSessionCategory", with: "")
        let modeShort = s.mode.rawValue.replacingOccurrences(
            of: "AVAudioSessionMode", with: "")
        publishedSessionInfo = "\(catShort)/\(modeShort) sr=\(Int(s.sampleRate))"
        print("[Mic] AVAudioSession: cat=\(s.category.rawValue) mode=\(s.mode.rawValue) opts=\(s.categoryOptions) sr=\(s.sampleRate) inputCh=\(s.inputNumberOfChannels)")
        #else
        publishedSessionInfo = "macOS: \(format.sampleRate) Hz \(format.channelCount)ch"
        #endif
        print("[Mic] input format: sr=\(format.sampleRate) ch=\(format.channelCount)")
        // Build the streaming analyzer now that we know the tap's
        // sample rate. Resets any prior session's state so an old
        // novelty baseline doesn't bleed into the new capture.
        streamingAnalyzer = StreamingAnalyzer(
            sampleRate: format.sampleRate,
            frameRate: 30,
            windowSize: 8192
        )
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self = self else { return }
            let samples = MicListener.extractMono(from: buffer)
            let duration = Double(buffer.frameLength) / format.sampleRate
            // Audio-thread diag — measure raw peak BEFORE any processing
            // so we can distinguish "no callbacks" (totalTapCalls=0)
            // from "callbacks but all zeros" (totalTapCalls>0, peak=0,
            // = route silenced) from "real audio arriving"
            // (totalTapCalls>0, peak>0).
            self.totalTapCalls += 1
            var peak: Float = 0
            for s in samples { let a = abs(s); if a > peak { peak = a } }
            self.lastBufferPeak = peak
            let result = self.detector.process(samples, duration: duration)
            // Feed the streaming analyzer the same mono PCM. It emits
            // 0+ feature frames at 30 fps; we pass our realtime-onset
            // detector's onset bool as an override since it fires
            // more reliably on live PCM than the streaming spectral
            // flux detector once its EMA baseline saturates.
            let newFrames = self.streamingAnalyzer?.append(
                samples, onsetOverride: result.onset
            ) ?? []

            self.lock.lock()
            self.pendingLoudness = self.detector.smoothedLoudness
            if result.onset { self.pendingOnsets += 1 }
            if !newFrames.isEmpty {
                self.pendingFrames.append(contentsOf: newFrames)
            }
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
        onNewFrames = nil
        streamingAnalyzer = nil
        lock.lock()
        pendingLoudness = 0
        pendingOnsets = 0
        pendingFrames.removeAll(keepingCapacity: false)
        lock.unlock()
        // **Critical:** deactivate the audio session so any subsequent
        // playback path (ApplicationMusicPlayer, our own AVAudioPlayer)
        // can re-acquire it under `.playback`. Without this, the
        // session stays pinned at `.record` from start() above, and
        // the next playback attempt fails silently — exactly what
        // produced "song doesn't play after toggling off mic" in
        // playAppleMusicSong's flow. `.notifyOthersOnDeactivation`
        // gives any backgrounded audio app a chance to resume.
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
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
                let (loudness, onsets, newFrames) = self.lock.withLock { () -> (Float, Int, [FeatureFrame]) in
                    let l = self.pendingLoudness
                    let o = self.pendingOnsets
                    let f = self.pendingFrames
                    self.pendingOnsets = 0
                    self.pendingFrames.removeAll(keepingCapacity: true)
                    return (l, o, f)
                }

                self.smoothedLoudness = loudness
                if onsets > 0 { self.onsetCounter += onsets }
                // Surface the running emit count to the iOS debug
                // overlay. Mirror from the lock-protected counter to
                // an @Observable property so SwiftUI can re-render it.
                self.publishedFramesEmitted = self.totalFramesEmitted
                self.publishedTapCalls = self.totalTapCalls
                self.publishedTapPeak = self.lastBufferPeak

                // Forward freshly-emitted feature frames to the AppModel
                // (which appends them into its rolling `frames` array).
                // Without this, frame-based visualizers (Crystal,
                // Architecture, etc.) keep replaying whatever song was
                // last loaded, producing the visible 30-second loop.
                if !newFrames.isEmpty {
                    self.totalFramesEmitted += newFrames.count
                    if self.totalFramesEmitted % 30 == 0 {
                        // ~1 line per second of audio
                        print("[Mic] streaming frames so far: \(self.totalFramesEmitted)")
                    }
                    self.onNewFrames?(newFrames)
                }

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
