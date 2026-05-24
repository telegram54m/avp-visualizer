//
//  SystemAudioListener.swift
//  High Videlity
//
//  macOS-only: capture the system audio output stream (whatever the user is
//  playing — Apple Music, Spotify, browser, anything) directly from Core
//  Audio, without any third-party loopback driver. Uses
//  `AudioHardwareCreateProcessTap` (macOS 14.4+) to create a global tap
//  that excludes our own process (so the visualizer itself doesn't feed
//  back), then routes the tap through an aggregate device with an IOProc
//  that hands us PCM buffers on the audio thread.
//
//  This is the Ferromagnetic-killer feature on macOS: no BlackHole / Loopback
//  install required, just one TCC permission prompt and the visualizer reacts
//  to whatever is playing — frame-accurate, post-decode, including DRM-
//  protected content like Apple Music (the encrypted-stream protection
//  applies to file copying, not to the PCM bus the OS mixes before output).
//
//  Mirrors the public surface of `MicListener` so AppModel can swap between
//  mic input and system audio input transparently.
//
//  iOS / iPadOS / visionOS / tvOS have no equivalent of process taps. On
//  those platforms the mic remains the only "listen to whatever's playing"
//  fallback.
//

#if os(macOS)

import AudioToolbox
import AudioAnalysis
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import OSLog
import SwiftUI

/// Public-by-default logger for SystemAudioListener — values printed here go
/// to oslog without privacy redaction so external tooling (`log show`) can
/// read them. NSLog defaults to redacted-private which is the wrong default
/// for diagnostic data.
private let tapLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "tap")

// MARK: - TCC SPI for Audio Capture permission
//
// `AudioHardwareCreateProcessTap` returns success and the aggregate device
// starts, but the IOProc is never fed audio unless the calling process has
// explicitly been granted `kTCCServiceAudioCapture` via the TCC framework's
// permission-request flow. Simply toggling the app on in System Settings →
// Privacy → System Audio Recording Only is NOT sufficient — the system also
// requires a runtime `TCCAccessRequest` call to register the grant against
// the running process.
//
// Apple does not publish a public API for this. The official sample
// (insidegui/AudioCap on GitHub) loads the private TCC framework via dlopen
// and calls `TCCAccessRequest` / `TCCAccessPreflight` directly. We do the
// same.
//
// **App Store implications:** these are private SPIs and will be rejected
// for Mac App Store distribution. For our use case (development + indie
// distribution outside the App Store) this is fine. If MAS submission ever
// becomes a goal, we'll need to fall back to a microphone-acoustic-capture
// path on that build channel since no public alternative exists.

private typealias TCCPreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
private typealias TCCRequestFunc = @convention(c)
    (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

private let tccFrameworkHandle: UnsafeMutableRawPointer? = {
    let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    return dlopen(path, RTLD_NOW)
}()

private let tccPreflight: TCCPreflightFunc? = {
    guard let handle = tccFrameworkHandle,
          let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(sym, to: TCCPreflightFunc.self)
}()

private let tccRequest: TCCRequestFunc? = {
    guard let handle = tccFrameworkHandle,
          let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
    return unsafeBitCast(sym, to: TCCRequestFunc.self)
}()

/// Synchronously check the current permission state without prompting.
/// Returns true if previously granted; false if denied or never asked.
private func audioCapturePermissionGranted() -> Bool {
    guard let preflight = tccPreflight else { return false }
    // TCCAccessPreflight returns 0 == authorized, 1 == denied, 2 == unknown
    return preflight("kTCCServiceAudioCapture" as CFString, nil) == 0
}

/// Trigger the TCC prompt (first time only) and resolve with the result.
/// On second-and-subsequent calls just resolves with the previously-recorded
/// decision without re-prompting.
private func requestAudioCapturePermission() async -> Bool {
    guard let request = tccRequest else { return false }
    return await withCheckedContinuation { cont in
        request("kTCCServiceAudioCapture" as CFString, nil) { granted in
            cont.resume(returning: granted)
        }
    }
}

/// One audio-producing process the user can pick to listen to.
struct AudioProcessCandidate: Identifiable, Hashable {
    let id: AudioObjectID    // CoreAudio process object ID (NOT the BSD PID)
    let pid: pid_t           // BSD PID — used for fuzzy-match across launches
    let name: String         // BSD process name (e.g. "Music", "Spotify", "Google Chrome")
    let isPlaying: Bool      // `kAudioProcessPropertyIsRunningOutput == 1`
}

@MainActor
@Observable
final class SystemAudioListener {

    /// Whether the tap is currently running.
    private(set) var isActive: Bool = false
    /// Whether the user has granted system-audio-capture permission. `nil`
    /// until first asked. Set to `true` if the tap creation succeeded, or
    /// `false` if `AudioHardwareCreateProcessTap` returned a permission
    /// error (the TCC prompt was rejected, or the user denied previously).
    private(set) var isAuthorized: Bool? = nil
    /// Smoothed loudness of the currently captured system audio (0…~1).
    private(set) var smoothedLoudness: Float = 0
    /// Monotonic counter — incremented once per detected onset. Visualizer
    /// compares to its own last-seen value to find new onsets without
    /// missing any.
    private(set) var onsetCounter: Int = 0
    /// Human-readable error string when the tap failed to start; surfaced
    /// in the UI so users have a fighting chance of debugging permissions.
    private(set) var errorMessage: String? = nil
    /// Snapshot of audio-producing processes from the last call to
    /// `refreshAvailableProcesses()`. The UI reads this to populate a
    /// picker. Sorted: currently-playing first (most useful), then the
    /// rest alphabetically.
    private(set) var availableProcesses: [AudioProcessCandidate] = []
    /// Name of the process we're currently tapping (or were last asked to
    /// tap). Surfaced for "now listening to: Music" UI labels.
    private(set) var tappedProcessName: String? = nil

    // --- Core Audio state ---------------------------------------------------
    @ObservationIgnored nonisolated(unsafe) private let detector = RealtimeOnsetDetector()
    /// Streaming chromagram/timbre/onset analyzer — fed the same PCM as
    /// `detector`. Initialized once the tap's stream format is known, so
    /// the analyzer's `sampleRate` matches the IOProc's data.
    @ObservationIgnored nonisolated(unsafe) private var streamingAnalyzer: StreamingAnalyzer?
    @ObservationIgnored private let queue = DispatchQueue(label: "HV.SystemAudioListener", qos: .userInitiated)
    @ObservationIgnored private var tapID: AudioObjectID = kAudioObjectUnknown
    @ObservationIgnored private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    @ObservationIgnored private var ioProcID: AudioDeviceIOProcID?
    @ObservationIgnored private var streamFormat: AVAudioFormat?

    // --- Audio-thread → main-thread handoff (same pattern MicListener uses) ---
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var pendingLoudness: Float = 0
    @ObservationIgnored nonisolated(unsafe) private var pendingOnsets: Int = 0
    /// Feature frames emitted by `streamingAnalyzer` since the last drain.
    /// Drained on the polling task and forwarded to `onNewFrames`, which
    /// AppModel uses to grow its rolling `frames` array.
    @ObservationIgnored nonisolated(unsafe) private var pendingFrames: [FeatureFrame] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Called on the main actor whenever new feature frames have been
    /// emitted by the streaming analyzer. AppModel sets this to append
    /// the frames into its rolling `frames` array.
    @ObservationIgnored var onNewFrames: (([FeatureFrame]) -> Void)?

    /// Audio-thread callback that receives an **owned** copy of each
    /// IOProc PCM buffer. AppModel sets this to feed Shazam directly
    /// from system-audio PCM (parallel to how `MicListener.bufferHandler`
    /// fans out mic buffers). Must be a copy — the buffer passed into
    /// the IOProc wraps transient CoreAudio data that's only valid for
    /// the duration of the IOProc call, and Shazam's `matchStreamingBuffer`
    /// dispatches to a different thread that would otherwise read freed
    /// memory.
    /// `AVAudioTime` is optional because Process Tap input timestamps
    /// don't supply a continuously-incrementing `mSampleTime` that
    /// ShazamKit's contiguity check accepts. The IOProc passes `nil`
    /// below, which tells `SHSession.matchStreamingBuffer(_:at:)` to
    /// treat audio as "arrives as available." See `ShazamController.feed`
    /// for the longer note.
    @ObservationIgnored nonisolated(unsafe) var audioBufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void)?

    /// Re-scan the system and update `availableProcesses` with the current
    /// audio-producing processes. Cheap (a single `AudioObjectGetPropertyData`
    /// pass + per-process metadata) so callers can invoke this on every
    /// picker open without worrying about cost.
    func refreshAvailableProcesses() {
        let candidates = listAudioProducingProcessesWithNames()
        // Sort: currently-playing audio producers first, alphabetically
        // within each group. Keep "?"-named entries (some macOS audio
        // services don't have BSD process names but ARE the actual audio
        // emitters for things like ApplicationMusicPlayer — filtering
        // them out hides exactly the process we'd need to tap).
        let playing = candidates.filter { $0.isPlaying }.sorted { $0.name < $1.name }
        let idle = candidates.filter { !$0.isPlaying }.sorted { $0.name < $1.name }
        availableProcesses = playing + idle
        let playingNames = playing.map { "\($0.name)(\($0.pid))" }.joined(separator: ", ")
        tapLog.info("HV-TAP refreshed available processes: total=\(self.availableProcesses.count, privacy: .public) playing=\(playing.count, privacy: .public) playingList=[\(playingNames, privacy: .public)]")
    }

    /// Start capturing system audio. Triggers the macOS TCC prompt the first
    /// time it runs unless the user has previously granted permission.
    ///
    /// `preferredName` lets the caller request a specific process by name —
    /// used by the picker UI to remember the user's last choice across
    /// launches. If the named process isn't currently a candidate, falls
    /// back to the built-in auto-pick policy.
    func start(preferredName: String? = nil) async {
        guard !isActive else { return }
        errorMessage = nil

        // STEP 0 — TCC permission via private SPI.
        //
        // The linchpin we missed for hours: `AudioHardwareCreateProcessTap`
        // succeeds and the aggregate device "starts" without ever calling
        // `TCCAccessRequest`, but the IOProc is silently never fed audio.
        // The grant in System Settings → Privacy & Security → System
        // Audio Recording Only is necessary but not sufficient; the process
        // has to ask via TCC for the OS to honour its grant. See
        // [[system-audio-tap]] memory for the full gotchas list.
        if !audioCapturePermissionGranted() {
            let granted = await requestAudioCapturePermission()
            if !granted {
                isAuthorized = false
                errorMessage = "System audio recording permission was denied. Allow 'High Videlity' under System Settings → Privacy & Security → System Audio Recording Only and try again."
                return
            }
        }

        do {
            try makeTapAndAggregate(preferredName: preferredName)
            try startIOProc()
            detector.reset()
            streamingAnalyzer?.reset()
            isAuthorized = true
            isActive = true
            startPolling()
        } catch {
            let msg = (error as? SystemAudioError)?.localizedDescription ?? String(describing: error)
            errorMessage = msg
            isAuthorized = false
            teardown()
        }
    }

    /// Diagnostic — current pending-frames queue length + capacity, plus
    /// the streaming analyzer's rolling-buffer stats. Used by AppModel's
    /// periodic leak-investigation logger to verify these stay bounded
    /// over long tap-mode sessions (the 16-minute SIGABRT crash on
    /// 2026-05-22 left it unclear which growable was the OOM trigger).
    /// RELEASE-CLEANUP — see top-of-file note in AppModel.swift.
    var debugStats: (pendingFrames: Int, pendingCap: Int, bufferCount: Int, bufferCap: Int) {
        var pf = 0
        var pc = 0
        lock.withLock {
            pf = pendingFrames.count
            pc = pendingFrames.capacity
        }
        let bs = streamingAnalyzer?.debugBufferStats ?? (count: -1, capacity: -1)
        return (pf, pc, bs.count, bs.capacity)
    }

    /// Reset the streaming analyzer's accumulated state (rolling sample
    /// buffer, EMA baseline, emitted-frame counter) without tearing down
    /// the tap itself. Call this when a track-change signal arrives so
    /// the visualizer's `frames` array can start fresh against the new
    /// song without restarting Core Audio.
    func resetLiveAnalysis() {
        lock.lock()
        pendingFrames.removeAll(keepingCapacity: true)
        lock.unlock()
        streamingAnalyzer?.reset()
        detector.reset()
    }

    /// Stop the tap and release Core Audio resources.
    func stop() {
        guard isActive else { return }
        pollTask?.cancel()
        pollTask = nil
        teardown()
        isActive = false
        smoothedLoudness = 0
        lock.lock()
        pendingLoudness = 0
        pendingOnsets = 0
        pendingFrames.removeAll(keepingCapacity: true)
        lock.unlock()
        streamingAnalyzer = nil
    }

    // MARK: - Core Audio plumbing

    /// Build the per-process tap + aggregate device. Doesn't start I/O yet —
    /// that's `startIOProc()`. `preferredName` (if provided) is the BSD
    /// process name the user wants to listen to, e.g. "Music" or "Spotify";
    /// falls through to an auto-pick policy if no match found.
    private func makeTapAndAggregate(preferredName: String?) throws {
        // Per-process tap mode (`stereoMixdownOfProcesses`) works where
        // global mode doesn't (see [[system-audio-tap]]). So we pick one
        // process to listen to.
        //
        // Picker policy:
        // 1. Preferred-by-name (the user's choice from the picker UI).
        // 2. Well-known music apps if no preference matched.
        // 3. Last candidate (skip low-objectID system daemons).
        let candidates = listAudioProducingProcessesWithNames()
        let defaultMusicNames = ["Music", "Spotify", "QuickTime Player", "Google Chrome", "Safari", "Firefox"]
        let chosen: AudioProcessCandidate
        if let name = preferredName,
           let c = candidates.first(where: { $0.name == name }) {
            chosen = c
        } else if let c = candidates.first(where: { $0.isPlaying }) {
            // No preference set — prefer whatever process is actually
            // producing audio right now. This is what catches in-app AM
            // (ApplicationMusicPlayer renders through a separate system
            // audio service, not our own process; the service shows up
            // as `isPlaying=true` in the process list).
            chosen = c
        } else if let c = candidates.first(where: { defaultMusicNames.contains($0.name) }) {
            chosen = c
        } else if let c = candidates.last {
            chosen = c
        } else {
            throw SystemAudioError.tapCreationFailed(status: -1)
        }
        tapLog.info("HV-TAP tapping process name=\(chosen.name, privacy: .public) pid=\(chosen.pid, privacy: .public)")
        self.tappedProcessName = chosen.name
        let firstProcess = chosen.id

        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: [firstProcess]
        )
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw SystemAudioError.tapCreationFailed(status: err)
        }
        self.tapID = newTapID

        // Pull the tap's stream format so the IOProc has the right shape to
        // work with. AudioCap stores this as an AudioStreamBasicDescription
        // and converts to AVAudioFormat on demand.
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(newTapID, &fmtAddress, 0, nil, &asbdSize, &asbd)
        guard err == noErr else {
            throw SystemAudioError.tapFormatUnavailable(status: err)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.formatBridgeFailed
        }
        self.streamFormat = format
        // Build the streaming analyzer now that we know the tap's sample
        // rate. Reset state so any prior session's novelty baseline /
        // emitted-frame counter doesn't bleed into this one.
        self.streamingAnalyzer = StreamingAnalyzer(
            sampleRate: format.sampleRate,
            frameRate: 30,
            windowSize: 8192
        )
        tapLog.info("HV-TAP created tapID=\(newTapID, privacy: .public) format=\(format, privacy: .public) sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")

        // Wrap the tap in an aggregate device. The aggregate also includes
        // the default system output device as a sub-device — this is what
        // ProcessTap does in AudioCap to keep the system output clock as the
        // master and avoid drift artifacts.
        let mainOutputDeviceID = try readDefaultSystemOutputDeviceID()
        let mainOutputUID = try readDeviceUID(deviceID: mainOutputDeviceID)

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey:           "HighVidelity-SystemTap",
            kAudioAggregateDeviceUIDKey:            UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey:  mainOutputUID,
            kAudioAggregateDeviceIsPrivateKey:      true,
            kAudioAggregateDeviceIsStackedKey:      false,
            kAudioAggregateDeviceTapAutoStartKey:   true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mainOutputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != kAudioObjectUnknown else {
            throw SystemAudioError.aggregateDeviceCreationFailed(status: err)
        }
        self.aggregateDeviceID = newAggregateID
    }

    /// Install the IOProc that receives PCM blocks on the audio thread and
    /// feeds them into the realtime analyzer.
    private func startIOProc() throws {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw SystemAudioError.aggregateDeviceCreationFailed(status: -1)
        }
        guard let format = streamFormat else {
            throw SystemAudioError.formatBridgeFailed
        }

        var newProcID: AudioDeviceIOProcID?
        // Counter for IOProc invocations — surfaced via tapLog every Nth
        // call so we can verify the audio thread is actually being fed.
        var ioCallCount = 0
        let createErr = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggregateDeviceID,
            queue
        ) { [weak self] _, inInputData, inInputTime, _, _ in
            // Audio thread — pull a mono buffer out of the tap and feed the
            // detector. Mirror MicListener's per-buffer protocol so any
            // future shared "real-time analysis" code can be agnostic to
            // source.
            guard let self else { return }
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else {
                ioCallCount += 1
                if ioCallCount % 100 == 1 {
                    tapLog.info("HV-TAP ioproc fired #\(ioCallCount, privacy: .public) BUT pcm-buffer-make failed")
                }
                return
            }

            let samples = SystemAudioListener.extractMono(from: pcm)
            let duration = Double(pcm.frameLength) / format.sampleRate
            // Quick peek at the raw input — average abs sample value as a
            // sanity check independent of the detector.
            var rawPeak: Float = 0
            for s in samples { let a = abs(s); if a > rawPeak { rawPeak = a } }

            let result = self.detector.process(samples, duration: duration)
            // Feed the streaming analyzer the same mono PCM. It returns
            // whatever feature frames have become available with this
            // chunk — usually 0 or 1 at IOProc cadence (~512 samples per
            // call vs ~1600 needed per frame at 48k/30fps). We also pass
            // the RealtimeOnsetDetector's onset bool as an override —
            // it fires reliably on live PCM where the streaming spectral-
            // flux detector under-fires once its EMA baseline catches up
            // to the music's average flux level.
            let newFrames = self.streamingAnalyzer?.append(
                samples,
                onsetOverride: result.onset
            ) ?? []

            // Fan out to any audio-thread consumer (e.g. Shazam). The
            // `pcm` above wraps CoreAudio's IOProc data which is freed
            // when this closure returns, so we must hand the consumer
            // an OWNED copy. Skipped entirely when no handler is set
            // (idle cost = a single nil-check) to avoid allocating per
            // IOProc call when nothing is listening.
            if let handler = self.audioBufferHandler,
               let copy = SystemAudioListener.copyPCMBuffer(pcm, format: format) {
                // Pass nil for the time. Constructing `AVAudioTime(audioTimeStamp:
                // inInputTime, sampleRate:)` produced AVAudioTime instances whose
                // `mSampleTime` doesn't continuously increment as Shazam's
                // contiguity check expects (Process Tap input timestamps are
                // host-time-anchored, not sample-counted), causing a stream of
                // ShazamKit Code=101 "audio is not contiguous" errors that
                // prevented any match from ever firing. Per Apple docs,
                // `matchStreamingBuffer(_:at:)` with nil treats audio as
                // arrives-as-available — the right semantics for a live tap.
                handler(copy, nil)
            }

            self.lock.lock()
            self.pendingLoudness = self.detector.smoothedLoudness
            if result.onset { self.pendingOnsets += 1 }
            if !newFrames.isEmpty {
                self.pendingFrames.append(contentsOf: newFrames)
            }
            self.lock.unlock()

            ioCallCount += 1
            // Light heartbeat — log on first call, then once every ~10
            // seconds (1024 calls × ~10 ms each). Useful for confirming
            // the tap is alive after a long-running visualization session
            // without flooding oslog.
            if ioCallCount == 1 || ioCallCount % 1024 == 0 {
                tapLog.info("HV-TAP ioproc #\(ioCallCount, privacy: .public) frames=\(pcm.frameLength, privacy: .public) rawPeak=\(rawPeak, privacy: .public)")
            }
        }
        guard createErr == noErr, let procID = newProcID else {
            throw SystemAudioError.ioProcCreationFailed(status: createErr)
        }
        self.ioProcID = procID

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            throw SystemAudioError.deviceStartFailed(status: startErr)
        }
        // Historical: there's an `AudioObjectGetPropertyData` call for
        // `kAudioDevicePropertyDeviceIsRunning` that's tempting to add as
        // a diagnostic. We tried it during the debug saga and it returns
        // 0 immediately after `AudioDeviceStart` returns noErr even when
        // the IOProc subsequently fires correctly — so the property isn't
        // useful as a "did the device actually start?" check. The real
        // ground truth is whether the IOProc block runs (see ioCallCount
        // logging above) and whether `rawPeak > 0` for known audio sources.
    }

    /// Tear down whatever Core Audio resources we've allocated. Safe to call
    /// multiple times — each step guards on validity.
    private func teardown() {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let procID = ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        ioProcID = nil

        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        streamFormat = nil
    }

    /// Drain audio-thread state into `@Observable` properties at ~30 Hz, same
    /// pattern MicListener uses to keep UI updates off the audio thread.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var lastLoggedLoudness: Float = 0
            var diagFrame = 0
            var totalFramesEmitted = 0
            while let self, self.isActive {
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

                if !newFrames.isEmpty {
                    totalFramesEmitted += newFrames.count
                    let last = newFrames.last!
                    let streamOnsets = newFrames.reduce(0) { $0 + ($1.onset ? 1 : 0) }
                    tapLog.info("HV-STREAM +\(newFrames.count, privacy: .public) frames total=\(totalFramesEmitted, privacy: .public) hue=\(last.color.hue, privacy: .public) loudness=\(last.loudness, privacy: .public) onsets=\(streamOnsets, privacy: .public)")
                    self.onNewFrames?(newFrames)
                }

                // Diagnostic — log only when loudness changes noticeably
                // (>0.01 delta) OR once every ~5s as a heartbeat. This
                // keeps oslog quiet when the tap is silent or steady and
                // makes it obvious when audio is actually arriving.
                diagFrame += 1
                let bigChange = abs(loudness - lastLoggedLoudness) > 0.01
                let heartbeat = diagFrame % 150 == 0     // ~5s @ 30 fps
                if bigChange || heartbeat {
                    tapLog.info("HV-TAP loudness=\(loudness, privacy: .public) onsetCounter=\(self.onsetCounter, privacy: .public)")
                    lastLoggedLoudness = loudness
                }

                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    // MARK: - Core Audio property helpers

    private func translatePIDToProcessObjectID(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var processObjectID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &processObjectID
        )
        guard err == noErr else {
            throw SystemAudioError.pidTranslationFailed(status: err)
        }
        return processObjectID
    }

    /// Enumerate every process from CoreAudio's process list, decorated
    /// with its BSD name + PID + currently-playing status. The picker UI
    /// uses this to populate a list of choices; the listener uses it to
    /// resolve a preferred-name back to an `AudioObjectID` at tap-creation
    /// time.
    private func listAudioProducingProcessesWithNames() -> [AudioProcessCandidate] {
        return listAllAudioProcesses().compactMap { processID in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &pidSize, &pid)
            var name = "?"
            if pid > 0 {
                var info = proc_bsdinfo()
                let r = withUnsafeMutablePointer(to: &info) {
                    proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0,
                                 Int32(MemoryLayout<proc_bsdinfo>.size))
                }
                if r > 0 {
                    name = withUnsafePointer(to: &info.pbi_name) { rawNamePtr in
                        rawNamePtr.withMemoryRebound(to: CChar.self,
                                                     capacity: Int(MAXCOMLEN) + 1) {
                            String(cString: $0)
                        }
                    }
                }
            }

            // Is this process actively producing audio output right now?
            // `kAudioProcessPropertyIsRunningOutput` returns 1 when the
            // process has at least one running output stream — gold for
            // showing "currently playing" badges in the picker.
            var isPlaying: UInt32 = 0
            var ipSize = UInt32(MemoryLayout<UInt32>.size)
            var ipAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(processID, &ipAddr, 0, nil, &ipSize, &isPlaying)

            return AudioProcessCandidate(
                id: processID, pid: pid, name: name,
                isPlaying: isPlaying == 1
            )
        }
    }

    /// All CoreAudio process objects on the system, including non-audio
    /// processes (filtered out at a higher level). Read from
    /// `kAudioHardwarePropertyProcessObjectList`.
    private func listAllAudioProcesses() -> [AudioObjectID] {
        // Read the full process list from the system audio object.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard err == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &processIDs
        )
        guard err == noErr else { return [] }
        return processIDs
    }

    private func readDefaultSystemOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr else {
            throw SystemAudioError.defaultDeviceUnavailable(status: err)
        }
        return deviceID
    }

    private func readDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio writes a +1-retained CFString reference into the pointer.
        // We use Unmanaged<CFString>? so we get a managed handle back without
        // accidentally aliasing a reference-type Swift variable as raw bytes.
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &uidRef
        )
        guard err == noErr, let uidRef else {
            throw SystemAudioError.deviceUIDUnavailable(status: err)
        }
        return uidRef.takeRetainedValue() as String
    }

    // MARK: - Sample conversion

    /// Copy a `bufferListNoCopy`-backed PCMBuffer into an owned one whose
    /// data outlives the IOProc call. Required for handing the buffer off
    /// to any consumer that processes asynchronously (Shazam's
    /// `matchStreamingBuffer` queues the work and reads later).
    fileprivate nonisolated static func copyPCMBuffer(
        _ source: AVAudioPCMBuffer, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: source.frameCapacity
        ) else { return nil }
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

    /// Downmix any-channel-count Float32 PCM into a mono `[Float]`. Matches
    /// MicListener's downmix so the realtime detector sees identically-shaped
    /// data regardless of source.
    private nonisolated static func extractMono(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let length = Int(buffer.frameLength)
        guard channelCount > 0, length > 0 else { return [] }
        var mono = [Float](repeating: 0, count: length)
        if channelCount == 1 {
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

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case tapCreationFailed(status: OSStatus)
    case tapFormatUnavailable(status: OSStatus)
    case formatBridgeFailed
    case pidTranslationFailed(status: OSStatus)
    case defaultDeviceUnavailable(status: OSStatus)
    case deviceUIDUnavailable(status: OSStatus)
    case aggregateDeviceCreationFailed(status: OSStatus)
    case ioProcCreationFailed(status: OSStatus)
    case deviceStartFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "AudioHardwareCreateProcessTap failed (\(s)). On first run, macOS shows a TCC dialog asynchronously — try toggling System Audio off and back on once you've granted permission."
        case .tapFormatUnavailable(let s):
            return "Couldn't read tap stream format (\(s))."
        case .formatBridgeFailed:
            return "Couldn't bridge tap stream format to AVAudioFormat."
        case .pidTranslationFailed(let s):
            return "Couldn't translate our PID to a Core Audio process object (\(s))."
        case .defaultDeviceUnavailable(let s):
            return "Couldn't read the default system output device (\(s))."
        case .deviceUIDUnavailable(let s):
            return "Couldn't read the output device UID (\(s))."
        case .aggregateDeviceCreationFailed(let s):
            return "AudioHardwareCreateAggregateDevice failed (\(s))."
        case .ioProcCreationFailed(let s):
            return "Couldn't create the audio device I/O proc (\(s))."
        case .deviceStartFailed(let s):
            return "Couldn't start the aggregate audio device (\(s))."
        }
    }
}

#endif // os(macOS)
