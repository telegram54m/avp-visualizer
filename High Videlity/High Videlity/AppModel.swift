//
//  AppModel.swift
//  High Videlity
//
//  Created by Jesse Griffith on 5/18/26.
//

import SwiftUI
import AudioAnalysis
import AVFoundation
import Darwin.Mach
import MusicKit
import OSLog
import RealityKit
import ShazamKit

/// Subsystem-tagged logger for the leak-investigation diag snapshots.
/// Pull with `log show --predicate 'subsystem == "com.jessegriffith.HighVidelity" AND category == "diag"' --last 30m`.
///
/// RELEASE-CLEANUP: this entire diag instrumentation chain (this logger,
/// `AppModel.debugSceneRoot`, `startDiagLogging`/`stopDiagLogging`/
/// `logDiagSnapshot`/`countSceneEntities`, the `Darwin.Mach` import, the
/// `debugStats` accessor on `SystemAudioListener`, the `debugBufferStats`
/// accessor on `StreamingAnalyzer`, and the `appModel.debugSceneRoot = <root>`
/// assignments in each case of `VisualizerView`'s mode switch) was added
/// 2026-05-22 to diagnose the audio-thread OOM crash. Kept in-tree post-fix
/// for future leak investigations. **Excise before app-store release** —
/// grep for `RELEASE-CLEANUP` to find every site. Idle cost when no tap
/// source is on = zero (the diag task isn't started); active cost ≈ one
/// mach_task_info syscall + one oslog line every 10 s.
private let diagLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "diag")

/// Which visualizer mode is active. Mirrors the HTML's mode set (Crystal,
/// Clouds, Rings, Architecture) plus Slipstream — our first native
/// addition. Slipstream is forward-flight through a song corridor:
/// each onset spawns a ring of glow-particles at the spawn frontier,
/// rings slide toward the camera at constant speed, and the user's
/// past is literally behind them.
enum VisualizerMode: String, CaseIterable, Identifiable {
    case crystal
    case clouds
    case rings
    case architecture
    case slipstream
    case ambient
    case dodecahedron
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .crystal:       return "Crystal"
        case .clouds:        return "Clouds"
        case .rings:         return "Rings"
        case .architecture:  return "Architecture"
        case .slipstream:    return "Slipstream"
        case .ambient:       return "Ambient"
        case .dodecahedron:  return "Dodecahedron"
        }
    }
}

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    #if os(visionOS)
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
    #endif

    /// The analyzed song timeline that drives the visualization.
    ///
    /// NOTE: experimentally tried `@ObservationIgnored` here on 2026-05-22
    /// to fix cross-mode FPS drift (theory: per-append Observation
    /// invalidation × 30/sec on @Observable-tracked frames was burning
    /// cycles on UI re-evaluation). Result: broke initial preview load
    /// — SongLoader.load(term) appeared to never complete, no iTunes
    /// logs emitted, app stuck on "Analyzing preview..." indefinitely.
    /// Root cause unclear; possibly the Observation macro's expansion
    /// interacts badly with @ObservationIgnored on a mutable property
    /// also referenced from non-MainActor URLSession callbacks. Reverted.
    /// FPS drift remains an open investigation (see task #31).
    var frames: [FeatureFrame] = []

    /// Cadence-throttled snapshot of `frames.count` for UI consumers.
    /// Kept around for potential reuse if we revisit the Observation
    /// optimization through a different mechanism. Currently NOT
    /// the source of truth for UI — `frames.count` is read directly.
    var framesCount: Int = 0
    @ObservationIgnored private var lastFramesCountPublish: TimeInterval = 0

    var isLoadingSong = false

    /// Authoritative BPM from an external lookup (Tunebat) keyed on the
    /// most recent Shazam title + artist. When set, tempo-aware
    /// visualizers should prefer this value over `FeatureFrame.beat.bpm`
    /// — the live BeatTracker regularly locks onto half/double-time
    /// interpretations (see [[feedback_beat-tracker-octave]]), so a
    /// Shazam-verified canonical BPM is more reliable when we have one.
    ///
    /// Lifecycle: cleared on track changes; populated asynchronously
    /// from `handleShazamMatch` shortly after the song is identified
    /// (typically 10-20s of audio needed for Shazam to lock). Until
    /// then, this stays nil and visualizers fall back to the tracker.
    /// Cached per-song in UserDefaults so repeat plays of the same
    /// song skip the network call.
    var shazamBpmOverride: Float?
    /// Shazam-verified danceability score from GetSongBPM (0-100 from
    /// AcousticBrainz). Cleared on track changes; populated alongside
    /// `shazamBpmOverride` from the same lookup. Nil when:
    ///   • no Shazam ID yet
    ///   • lookup hasn't returned
    ///   • the song genuinely has no danceability in the database
    /// Tempo-aware visualizers combine this with the BPM-derived
    /// intensity scale — a 95 BPM song with danceability 90 (think
    /// disco-era groove) should read more energetic than its tempo
    /// alone would suggest.
    var shazamDanceabilityOverride: Float?
    /// Shazam-verified canonical Key (tonic pitch class + mode) from
    /// GetSongBPM. Cleared on track changes; populated alongside the
    /// other override values from the same lookup. Visualizers that
    /// care about pitch identity (e.g. Dodecahedron's 12 faces) use
    /// this to anchor the song's tonic to a distinct visual treatment,
    /// independent of which pitch class is loudest at any moment.
    var shazamKeyOverride: Key?
    /// Shazam-verified acousticness (0-100). From GetSongBPM's numeric
    /// `acousticness` field, OR from AcousticBrainz's binary
    /// `mood_acoustic` classifier mapped to the same scale. Higher =
    /// more acoustic, lower = more electronic. Visualizers use this
    /// alongside danceability + aggressiveness to characterize
    /// "what does this song feel like" beyond just tempo.
    var shazamAcousticnessOverride: Float?
    /// Shazam-verified aggressiveness (0-100). Derived from
    /// AcousticBrainz's binary `mood_aggressive` classifier; nil when
    /// only GetSongBPM has the song (they don't expose an equivalent).
    /// Higher = more aggressive / punchy / driving.
    var shazamAggressivenessOverride: Float?
    /// Generation counter for `shazamBpmOverride` lookups. Incremented
    /// every time a new Shazam match arrives. The Task that fetches
    /// the BPM captures its generation; on completion it only writes
    /// the result if its captured generation still matches the current
    /// counter. Prevents an old song's late-arriving lookup from
    /// stomping a newer song's override.
    @ObservationIgnored private var bpmLookupGeneration: Int = 0

    /// Bumped whenever live-mode `frames` is wiped because the source song
    /// changed (Shazam detected a new track in system-audio mode). Crystal/
    /// Architecture live state components compare this against their own
    /// `lastSeenResetCounter` each animate-tick — when they differ, they
    /// clear their spawned children and reset `lastSeenFrameIndex` /
    /// `liveShardCount` so the cluster starts fresh for the new song.
    var liveModeResetCounter: Int = 0

    // MARK: - Leak-investigation diagnostics
    //
    // Added 2026-05-22 after a SIGABRT in StreamingAnalyzer.append on the
    // Core Audio IOProc thread after 16 minutes of tap-mode runtime.
    // Heap was only 250 MB at crash (not absolute OOM) — likely fragmentation
    // or a slow leak in something unbounded. This snapshot lets us see
    // which growable's slope correlates with crash trajectory.
    //
    // VisualizerView's `make` closure sets `debugSceneRoot` to a weak
    // ref to the active scene root when the visualizer opens; the diag
    // task counts its descendants every 10 s. The closure also publishes
    // its own raw counter for sanity-checking against the recursive count.

    /// Set by VisualizerView's RealityView `make` closure. The diag
    /// snapshot dereferences this each tick to recursively count entities.
    /// `weak` so the visualizer's scene tree can release on mode-cycle
    /// teardown without the diagnostic anchor holding it alive.
    /// RELEASE-CLEANUP — see top-of-file note.
    @ObservationIgnored weak var debugSceneRoot: Entity?

    @ObservationIgnored private var diagTask: Task<Void, Never>?

    /// Start the periodic snapshot logger. Called when a tap-mode source
    /// (system audio or mic) turns on. Cancels any existing task first
    /// so toggling sources doesn't double-fire.
    func startDiagLogging() {
        diagTask?.cancel()
        diagTask = Task { @MainActor [weak self] in
            // Log immediately on start so we have a baseline before the
            // first 10-second sleep.
            self?.logDiagSnapshot(reason: "start")
            while let self {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                self.logDiagSnapshot(reason: "tick")
            }
        }
    }

    func stopDiagLogging() {
        diagTask?.cancel()
        diagTask = nil
        logDiagSnapshot(reason: "stop")
    }

    /// Emit one diag line to oslog with the ground-truth memory + every
    /// growable we want to track. Cheap (mach syscall + a few counts) so
    /// 10 s cadence is conservative — could go to 5 s if we need finer
    /// time resolution on the slope.
    private func logDiagSnapshot(reason: String) {
        // Resident & virtual memory via mach. The struct field offsets
        // differ between architectures; the canonical incantation is
        // task_info(MACH_TASK_BASIC_INFO).
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
            }
        }
        let residentMB = kr == KERN_SUCCESS
            ? Double(info.resident_size) / (1024 * 1024)
            : -1.0
        let virtualMB = kr == KERN_SUCCESS
            ? Double(info.virtual_size) / (1024 * 1024)
            : -1.0

        let framesCount = frames.count
        let framesCap = frames.capacity
        let (deepEntities, topEntities) = countSceneEntities()

        #if os(macOS)
        let stats = systemAudio.debugStats
        let pending = stats.pendingFrames
        let pendingCap = stats.pendingCap
        let bufferCount = stats.bufferCount
        let bufferCap = stats.bufferCap
        let onsetC = systemAudio.onsetCounter
        #else
        let pending = -1
        let pendingCap = -1
        let bufferCount = -1
        let bufferCap = -1
        let onsetC = micListener.onsetCounter
        #endif

        diagLog.info("""
            HV-DIAG reason=\(reason, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) \
            resident=\(String(format: "%.1f", residentMB), privacy: .public)MB \
            virt=\(String(format: "%.1f", virtualMB), privacy: .public)MB \
            frames=\(framesCount, privacy: .public)/\(framesCap, privacy: .public) \
            entities(top=\(topEntities, privacy: .public),deep=\(deepEntities, privacy: .public)) \
            pendingFrames=\(pending, privacy: .public)/\(pendingCap, privacy: .public) \
            streamBuf=\(bufferCount, privacy: .public)/\(bufferCap, privacy: .public) \
            onsetCounter=\(onsetC, privacy: .public) \
            resetCounter=\(self.liveModeResetCounter, privacy: .public)
            """)
    }

    /// Recursive entity count of `debugSceneRoot`. Returns (deep, top)
    /// where `deep` includes all descendants and `top` is just direct
    /// children. Returns (-1, -1) when no scene root is registered.
    private func countSceneEntities() -> (deep: Int, top: Int) {
        guard let root = debugSceneRoot else { return (-1, -1) }
        func walk(_ e: Entity) -> Int {
            var n = 1
            for c in e.children { n += walk(c) }
            return n
        }
        return (walk(root), root.children.count)
    }

    // MARK: - Debug FPS counter
    //
    // Updated by each visualizer's animate subscription via
    // `recordFrameDelta(_:)`. The raw delta is exponentially smoothed
    // every tick, but the OBSERVED `publishedFPS` only updates ~2 Hz
    // — at 60 Hz the smoothed value would trigger 60 SwiftUI redraws
    // per second on whichever view reads it, which is wasteful for a
    // debug pill. The 2 Hz cadence keeps the badge readable without
    // flooding the redraw cycle.
    var publishedFPS: Double = 60
    @ObservationIgnored private var smoothedFrameInterval: Double = 1.0 / 60.0
    @ObservationIgnored private var lastFPSPublish: TimeInterval = 0

    /// Beat-tracker observed values — surfaced for the debug `BeatBadge`
    /// so we can see in-app what bpm and confidence the visualizer is
    /// actually consuming from `FeatureFrame.beat`. Throttled to ~2 Hz
    /// via `lastBeatPublish` so the badge doesn't flicker every frame.
    /// 0 confidence = tracker hasn't locked yet (no valid bpm).
    var publishedBeatBpm: Float = 0
    var publishedBeatConfidence: Float = 0
    @ObservationIgnored private var lastBeatPublish: TimeInterval = 0

    /// Called once per render frame by each visualizer's animate
    /// subscription. `dt` is `event.deltaTime` from RealityKit's
    /// SceneEvents.Update — already in seconds.
    func recordFrameDelta(_ dt: Double) {
        // Clamp dt to avoid the first-frame spike (deltaTime can be
        // huge on first call, often the full time since scene-create)
        // from biasing the smoothed value low. 0.001..0.1s covers
        // 10-1000 fps; anything outside is a measurement artifact.
        let clamped = max(0.001, min(0.1, dt))
        let lerp = min(1.0, clamped * 2.0)
        smoothedFrameInterval += (clamped - smoothedFrameInterval) * lerp
        let now = CACurrentMediaTime()
        if now - lastFPSPublish > 0.5 {
            publishedFPS = 1.0 / smoothedFrameInterval
            lastFPSPublish = now
        }
    }

    /// Throttled publish of the beat tracker's bpm + confidence for the
    /// in-corner debug badge. Called from visualizer animate ticks at
    /// 30 Hz; throttles to ~2 Hz to avoid SwiftUI redraw flood.
    func recordBeat(bpm: Float, confidence: Float) {
        let now = CACurrentMediaTime()
        guard now - lastBeatPublish > 0.5 else { return }
        publishedBeatBpm = bpm
        publishedBeatConfidence = confidence
        lastBeatPublish = now
    }

    // MARK: - Frames-count publishing
    //
    // Cross-platform helpers (NOT inside any #if) for publishing the
    // observed `framesCount` snapshot at low cadence. The actual
    // `frames` array is @ObservationIgnored so it doesn't trigger
    // SwiftUI invalidation on every append. UI consumers read
    // `framesCount` instead.

    /// Cadence-throttled write to the observed `framesCount`. UI consumers
    /// see updates at ~1 Hz instead of ~30 Hz, eliminating the per-append
    /// Observation invalidation that was driving cross-mode FPS drift.
    /// Called from `appendLiveFrames` (live system-audio path).
    private func publishFramesCountIfDue() {
        let now = CACurrentMediaTime()
        if now - lastFramesCountPublish > 1.0 {
            framesCount = frames.count
            lastFramesCountPublish = now
        }
    }

    /// Force-publish on transitions (load song, wipe on track change, etc.)
    /// regardless of cadence so the UI snaps to the new count immediately.
    fileprivate func publishFramesCountNow() {
        framesCount = frames.count
        lastFramesCountPublish = CACurrentMediaTime()
    }

    /// Wall-clock time of the most-recent live-mode track-change reset.
    /// Used by `handleShazamMatch` to throttle resets — without this,
    /// Shazam's public catalog returns DIFFERENT recordings of the same
    /// piece on each match (e.g. Beethoven's Moonlight Sonata III matches
    /// a different performer's recording every ~10s, each with its own
    /// `shazamID`). The shazamID-based de-dupe would let every "new"
    /// recording wipe the live cluster every ~10s. We pair shazamID with
    /// (a) title-similarity matching and (b) a 60s minimum interval.
    @ObservationIgnored private var lastLiveResetTime: TimeInterval = 0
    /// Normalized title of the song that triggered the most-recent reset.
    /// Compared against incoming matches' normalized title — when they
    /// share enough significant words, the match is treated as the same
    /// song (just a different catalog recording) and reset is suppressed.
    @ObservationIgnored private var lastLiveResetTitle: String = ""

    /// Which visualizer the immersive view should show.
    var mode: VisualizerMode = .crystal

    /// Within Crystal mode: v1 (stacked cylinders) or v2 (HTML-faithful
    /// translucent shard + additive halo/core beams). v2 is the canonical
    /// implementation; v1 is kept around as the safety-net legacy path.
    var useCrystalV2 = true

    /// "Listen with mic" mode — when on, internal AVAudioPlayer is paused
    /// and the visualizer is driven by live mic input instead of the loaded
    /// song's timeline. Lets the visualizer react to Apple Music, Spotify,
    /// or anything playing in the room. When off, returns to internal
    /// playback driving the timeline.
    var useMic: Bool = false {
        didSet {
            guard useMic != oldValue else { return }
            if useMic {
                #if os(macOS)
                // Mutually exclusive with system audio mode.
                if useSystemAudio { useSystemAudio = false }
                #endif
                stopPlayback()
                heldClock = 0
                micClockOrigin = CACurrentMediaTime()
                // Start Shazam first so it has a session ready when audio
                // buffers begin flowing. Wire the mic's fan-out handler to
                // feed Shazam with the same buffers it's running the
                // realtime loudness/onset detector on.
                shazam.start()
                let shazam = shazam
                micListener.bufferHandler = { buffer, time in
                    shazam.feedBoth(buffer, at: time)
                }
                Task { await micListener.start() }
                startDiagLogging()
            } else {
                micListener.stop()
                shazam.stop()
                #if os(macOS)
                if !useSystemAudio { stopDiagLogging() }
                #else
                stopDiagLogging()
                #endif
            }
        }
    }

    /// Live mic capture + real-time loudness/onset detection. Used when the
    /// user is playing audio externally (a speaker, not the AVP itself).
    let micListener = MicListener()

    #if os(macOS)
    /// macOS-only: tap the system audio output directly via Core Audio's
    /// `AudioHardwareCreateProcessTap`. Lets the visualizer react frame-
    /// accurately to whatever app is currently playing (Music, Spotify,
    /// browser, etc.) with no third-party loopback driver required.
    let systemAudio = SystemAudioListener()

    /// "Listen to system audio" mode — macOS-only equivalent of the mic
    /// path, but reads the PCM mix the OS would send to the speakers instead
    /// of acoustically re-capturing it. When on, the visualizer is driven by
    /// `systemAudio.smoothedLoudness` / `systemAudio.onsetCounter` and
    /// internal playback / mic input are paused.
    var useSystemAudio: Bool = false {
        didSet {
            guard useSystemAudio != oldValue else { return }
            if useSystemAudio {
                // Mutually exclusive with mic — turning system audio on
                // automatically turns mic off (and vice versa via the mic's
                // didSet). Pause internal preview playback too.
                if useMic { useMic = false }
                stopPlayback()
                heldClock = 0
                micClockOrigin = CACurrentMediaTime()
                // Don't wipe `frames` here — ContentView gates its entire
                // control block on `!frames.isEmpty`, so clearing would
                // hide the very toggle that just turned this on. Live
                // frames append on top of whatever preview frames are
                // loaded; `playbackTime` for the live path returns the
                // index of the latest emitted frame, so visualizers
                // automatically follow live data. (Crystal additive
                // spawning in session 2 will revisit this.)
                let name = preferredSystemAudioProcessName
                // Forward streaming-analyzer frames into our rolling
                // `frames` array. SystemAudioListener calls this on the
                // main actor whenever its IOProc-side analyzer emits new
                // feature frames.
                systemAudio.onNewFrames = { [weak self] newFrames in
                    self?.appendLiveFrames(newFrames)
                }
                // Bridge system-audio PCM to Shazam so it can identify
                // whatever's currently playing (Music, Spotify, browser…)
                // without the user having to also enable mic. Shazam's
                // onMatch handler triggers the live-mode reset path that
                // wipes `frames` and bumps `liveModeResetCounter`, which
                // in turn clears the visualizer's spawned children for
                // the new song.
                shazam.start()
                let shazamRef = shazam
                // System-audio path feeds ONLY the public-catalog session
                // (Phase 1: song ID + track-change detection). The custom-
                // catalog session (Phase 2) is bound to a signature
                // generated against the MIC format (mono non-interleaved);
                // the tap delivers STEREO INTERLEAVED, which Shazam rejects
                // with "Audio format mismatch" and crashes. Since macOS
                // in-app AM mode uses the streaming analyzer (frame-
                // accurate live PCM) for the visualizer's color data,
                // Phase 2 alignment isn't needed here — the live frames
                // ARE the alignment.
                systemAudio.audioBufferHandler = { buf, time in
                    shazamRef.feed(buf, at: time)
                }
                // Seed the throttle clock so the very first Shazam match
                // (which arrives ~10s after start, identifying whatever's
                // currently playing) gets suppressed — we don't want it
                // to wipe the cluster just because Shazam confirmed what
                // we already knew was playing.
                lastLiveResetTime = CACurrentMediaTime()
                lastLiveResetTitle = ""
                Task { await systemAudio.start(preferredName: name) }
                startDiagLogging()
            } else {
                systemAudio.stop()
                systemAudio.onNewFrames = nil
                systemAudio.audioBufferHandler = nil
                shazam.stop()
                if !useMic { stopDiagLogging() }
            }
        }
    }

    /// Append a batch of live-mode feature frames to the rolling `frames`
    /// array. Called from `SystemAudioListener`'s polling task on the
    /// main actor.
    ///
    /// **Time-rewrite gotcha (2026-05-22):** the streaming analyzer's
    /// `time` field is its internal `emittedFrames / frameRate` — resets
    /// to 0 on every tap-on. But `playbackTime` for the live path is
    /// computed from the array index of `frames`, which already has the
    /// preview-loaded frames (897 of them) in it before the stream
    /// starts. So the analyzer's `time=0` ends up at array index 897,
    /// not 0 — `playbackTime ≈ 30s` while `frame.time = 0`. Any
    /// visualizer that computes physics from `clock - frame.time`
    /// (Slipstream's gate Z, Architecture's pop-in, Crystal's camera
    /// look-ahead) gets a 30-second-stale `time` and treats every
    /// freshly-spawned entity as ancient. Slipstream evicts them on the
    /// same tick they spawn.
    ///
    /// Fix: rewrite each appended frame's `time` to match its absolute
    /// array index. After this, `frame.time == Double(arrayIndex) / 30`
    /// and `playbackTime == Double(frames.count - 1) / 30` agree.
    private func appendLiveFrames(_ newFrames: [FeatureFrame]) {
        guard useSystemAudio else { return }
        let baseIndex = frames.count
        let frameRate = 30.0
        for (i, f) in newFrames.enumerated() {
            let absoluteTime = Double(baseIndex + i) / frameRate
            frames.append(f.withTime(absoluteTime))
        }
        publishFramesCountIfDue()
    }

    /// User's last-picked system-audio process (by BSD name). Persisted
    /// in `UserDefaults` so the next launch defaults to the same app.
    /// Cleared by selecting "Auto" in the picker.
    var preferredSystemAudioProcessName: String? {
        get { UserDefaults.standard.string(forKey: "preferredSystemAudioProcessName") }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "preferredSystemAudioProcessName")
            } else {
                UserDefaults.standard.removeObject(forKey: "preferredSystemAudioProcessName")
            }
        }
    }

    /// Restart the system-audio listener pointing at a different process —
    /// used by the picker UI to switch sources without flipping the toggle
    /// off and on. Persists the choice for next launch.
    func switchSystemAudioSource(toName name: String?) {
        preferredSystemAudioProcessName = name
        guard useSystemAudio else { return }
        systemAudio.stop()
        Task { await systemAudio.start(preferredName: name) }
    }
    #endif

    /// Apple Music playback + search via MusicKit. The primary path when
    /// the user is listening through the AVP — frame-accurate playback
    /// clock, no mic needed.
    let musicKit = MusicKitController()

    /// ShazamKit auto-identification — listens to mic input and tells us
    /// what song is playing. Replaces manual search in the mic path.
    let shazam = ShazamController()

    init() {
        // Auto-fetch the matching iTunes preview whenever Shazam identifies
        // a new song. ShazamController de-dupes repeat matches of the same
        // track so this only fires when the song actually changes.
        shazam.onMatch = { [weak self] item in
            self?.handleShazamMatch(item)
        }
        // Phase-2 alignment needs to know the current song clock at the
        // moment a custom-catalog match fires. Provide a closure that
        // returns AM's frame-accurate playbackTime when AM is playing,
        // or wall-clock as a fallback for mic-only listening.
        shazam.currentSongPositionProvider = { [weak self] in
            guard let self = self else { return (CACurrentMediaTime(), false) }
            if self.musicKit.isPlaying {
                return (self.musicKit.playbackTime, true)
            }
            return (CACurrentMediaTime(), false)
        }
    }

    private func handleShazamMatch(_ item: SHMatchedMediaItem) {
        let title = item.title ?? ""
        let artist = item.artist ?? ""
        let term = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return }

        // Fire-and-forget BPM lookup. Runs in parallel with the rest of
        // the match handling (preview fetch, live-mode reset, alignment
        // registration). When it completes, `shazamBpmOverride` becomes
        // non-nil and tempo-aware visualizers start using it. Cached
        // per-song so repeat plays skip the network call.
        //
        // The generation counter guards against late-arriving lookups
        // from a previous song: if a user track-changes faster than
        // network latency, the older Task's result won't be applied.
        shazamBpmOverride = nil
        shazamDanceabilityOverride = nil
        shazamKeyOverride = nil
        shazamAcousticnessOverride = nil
        shazamAggressivenessOverride = nil
        bpmLookupGeneration += 1
        let myGeneration = bpmLookupGeneration
        Task { @MainActor in
            if let result = await TunebatBpmFetcher.lookup(title: title, artist: artist) {
                guard myGeneration == self.bpmLookupGeneration else { return }
                self.shazamBpmOverride = result.bpm
                self.shazamDanceabilityOverride = result.danceability
                self.shazamKeyOverride = result.key
                self.shazamAcousticnessOverride = result.acousticness
                self.shazamAggressivenessOverride = result.aggressiveness
                let danceStr = result.danceability.map { ", dance \(Int($0))" } ?? ""
                let acoustStr = result.acousticness.map { ", acoust \(Int($0))" } ?? ""
                let aggroStr = result.aggressiveness.map { ", aggro \(Int($0))" } ?? ""
                let keyStr = result.key.map { ", \($0.name)" } ?? ""
                print("[HighVidelity] GetSongBPM \"\(title)\" — \(artist): \(result.bpm) BPM\(danceStr)\(acoustStr)\(aggroStr)\(keyStr)")
            }
        }

        #if os(macOS)
        // In live system-audio mode, treat a Shazam match as a possible
        // track-change signal. But Shazam's public catalog is messy: the
        // SAME piece (e.g. Beethoven's Moonlight Sonata III) matches a
        // DIFFERENT recording by a different performer every ~10s, each
        // with its own `shazamID`. Naive shazamID-based de-dup wipes the
        // live cluster on every recognition. Three guards:
        //   1. Same-shazamID handled by ShazamController (we never even
        //      see it here).
        //   2. Different shazamID but similar title → treat as same song.
        //   3. Even if titles differ, throttle resets to once per 60s as
        //      a final safety net (a user can't actually change tracks
        //      faster than that in any normal listening).
        if useSystemAudio {
            let normalized = normalizeTitle(term)
            let now = CACurrentMediaTime()
            let timeSinceLastReset = now - lastLiveResetTime
            let titlesSimilar = AppModel.titlesAreSimilar(normalized, lastLiveResetTitle)

            if !titlesSimilar && timeSinceLastReset >= 60 {
                print("[HighVidelity] Shazam new track \"\(term)\" — resetting live frames")
                frames = []
                publishFramesCountNow()
                systemAudio.resetLiveAnalysis()
                liveModeResetCounter += 1
                lastLiveResetTime = now
                lastLiveResetTitle = normalized
            } else {
                let reason = titlesSimilar
                    ? "same song (different recording)"
                    : "throttled (\(Int(60 - timeSinceLastReset))s remaining)"
                print("[HighVidelity] Shazam match \"\(term)\" suppressed: \(reason)")
            }
            return
        }
        #endif

        let matchTitle = item.title ?? ""
        let matchArtist = item.artist ?? ""
        Task { @MainActor in
            isLoadingSong = true
            defer { isLoadingSong = false }
            do {
                let loaded = try await SongLoader.load(term)
                frames = loaded.frames
            publishFramesCountNow()
                audioURL = loaded.audioURL
                await registerPreviewForAlignment(
                    audioURL: loaded.audioURL,
                    title: matchTitle,
                    artist: matchArtist,
                    frameCount: loaded.frames.count
                )
                print("[HighVidelity] Shazam matched \"\(term)\" → \(loaded.frames.count) preview frames")
            } catch {
                print("[HighVidelity] preview fetch for \"\(term)\" failed: \(error)")
            }
        }
    }

    /// Register the just-loaded preview with the Phase-2 alignment system.
    /// Generates the SHSignature, builds the custom catalog, primes the
    /// custom session, and tells it the preview's duration so it can
    /// modulo-wrap correctly. Called from every song-load entry point.
    private func registerPreviewForAlignment(
        audioURL: URL, title: String, artist: String, frameCount: Int
    ) async {
        let duration = Double(frameCount) / 30.0
        shazam.setPreviewDuration(duration)
        await shazam.registerForAlignment(
            audioURL: audioURL,
            title: title,
            artist: artist
        )
    }

    @ObservationIgnored private var audioURL: URL?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    /// Per-mode `SceneEvents.Update` subscription. The animate closure runs
    /// every render frame. When the user cycles modes, VisualizerView's
    /// `.id(appModel.mode)` modifier remounts the RealityView, which
    /// rebuilds the scene and assigns a NEW subscription here — overwriting
    /// the previous one.
    ///
    /// **The didSet is critical for FPS health.** RealityKit's
    /// `EventSubscription` does not auto-cancel on RC release alone; you
    /// must call `.cancel()` explicitly. Without this, every mode cycle
    /// leaks the prior subscription, which keeps firing per frame on its
    /// (now-detached) old entity tree. After 5 mode cycles you have 5
    /// concurrent animate loops running — measured: FPS halving per cycle
    /// (90 → 45 → 22 → 11). The didSet cancels the old subscription
    /// at the moment of overwrite, fixing the leak at the source.
    @ObservationIgnored var sceneUpdateSubscription: EventSubscription? {
        didSet {
            // EventSubscription is a value type, so every overwrite produces
            // a distinct prior instance. Always cancel.
            oldValue?.cancel()
        }
    }

    @ObservationIgnored private var heldClock: TimeInterval = 0
    /// Wall-clock anchor for the free-running timeline when in mic mode.
    @ObservationIgnored private var micClockOrigin: TimeInterval = 0

    /// The visualization clock. Sources, in priority order:
    /// 1. **MusicKit** ApplicationMusicPlayer playback time when AM is
    ///    actively playing — mapped into the preview's timeline range so
    ///    the analyzed 30s of colour/structure cycles as the full song plays.
    /// 2. **AVAudioPlayer** currentTime while internal playback is running
    ///    (the iTunes-preview demo, or a locally-imported file).
    /// 3. **Mic mode** free-running clock — loops through the analyzed
    ///    timeline at 1× real time so colour still varies even though we
    ///    have no exact sync to external audio.
    /// 4. The held last-known clock — so a finished visualization persists.
    var playbackTime: TimeInterval {
        #if os(macOS)
        // Live system-audio mode owns the clock — check first so a stray
        // AVAudioPlayer (e.g. left over from a preview that started before
        // the toggle) can't override us. `startPlayback` also guards
        // against starting the player in this mode, but defense-in-depth.
        if useSystemAudio && !frames.isEmpty {
            heldClock = Double(frames.count - 1) / 30.0
            return heldClock
        }
        #endif
        if musicKit.isPlaying && !frames.isEmpty {
            // Phase-2 alignment: when ShazamKit's custom-catalog session
            // has matched the live audio (via mic) against the preview,
            // we know exactly where the preview sits inside the full song.
            // Use that aligned offset rather than the naive `playbackTime
            // mod duration` which produces a 30s loop drifting against
            // the song. Falls back to naive modulo when no alignment
            // exists yet (Shazam takes 5-15s to match after audio starts).
            if let aligned = shazam.alignedPreviewTime(currentSongPosition: musicKit.playbackTime) {
                heldClock = aligned
                return heldClock
            }
            let duration = Double(frames.count) / 30.0
            heldClock = musicKit.playbackTime.truncatingRemainder(dividingBy: max(0.1, duration))
            return heldClock
        }
        if let player = audioPlayer, player.isPlaying {
            heldClock = player.currentTime
            return heldClock
        }
        if useMic && !frames.isEmpty {
            // Phase-2 alignment can give us the actual song position
            // here too when Shazam's custom session has matched the mic
            // audio. Wall-clock as the song clock since we don't have
            // a frame-accurate source. Falls back to free-running clock
            // before the first match arrives.
            let now = CACurrentMediaTime()
            if let aligned = shazam.alignedPreviewTime(currentSongPosition: now) {
                heldClock = aligned
                return heldClock
            }
            let duration = Double(frames.count) / 30.0
            let elapsed = now - micClockOrigin
            heldClock = elapsed.truncatingRemainder(dividingBy: max(0.1, duration))
            return heldClock
        }
        return heldClock
    }

    @ObservationIgnored private var smoothedLoudness: Float = 0

    // Eased crystal-mode camera state (the inverse-camera that reproduces the
    // HTML view for a stationary viewer).
    @ObservationIgnored var camPos = SIMD3<Float>(0, 0.5, 1)
    @ObservationIgnored var camLook = SIMD3<Float>(0, 0, 0)

    // Ambient draggable-camera state (windowed only — visionOS uses head
    // tracking instead). Yaw rotates around +Y; pitch around +X.
    //
    // Initial pitch is POSITIVE (~+10°, look DOWN) so the windowed view
    // starts framing the lake-and-sky composition with the horizon at
    // roughly 35% from the top. (Per the convention in VisualizerView's
    // gesture handler: positive pitch = look down.) Earlier streak-only
    // Ambient used negative initial pitch to look UP at the starfield;
    // the lake rewrite flipped that — there's now ground to look down at.
    //
    // VisualizerView's DragGesture writes these; the Ambient animate
    // closure reads them each tick and applies
    // `ambient.orientation = pitch_quat × yaw_quat`. Reset to these
    // defaults on every Ambient-case make-closure invocation so each
    // entry into Ambient starts from the curated framing.
    @ObservationIgnored var ambientDragYaw: Float = 0
    @ObservationIgnored var ambientDragPitch: Float = 0.17

    /// The song's loudness at the playback head, smoothed frame-to-frame.
    /// Mic loudness wins when mic mode is on — visualizer reacts to whatever
    /// is actually playing rather than the loaded preview's loudness curve.
    func currentEnergy() -> Float {
        #if os(macOS)
        if useSystemAudio {
            // System-audio tap delivers PCM with the full mix volume range
            // (not the heavily attenuated room-via-mic signal), so use a
            // smaller boost than the mic path's 4.0× to keep the visualizer
            // in a sensible 0…1 dynamic range.
            return min(1, systemAudio.smoothedLoudness * 2.0)
        }
        #endif
        if useMic {
            // Mic RMS lands in a much lower range than file-loudness; boost
            // so visualizer parameters land in roughly the same dynamic
            // range either way.
            return min(1, micListener.smoothedLoudness * 4.0)
        }
        guard !frames.isEmpty else { return 0 }
        let idx = min(frames.count - 1, max(0, Int(playbackTime * 30)))   // 30 fps timeline
        let raw = frames[idx].loudness
        smoothedLoudness += (raw - smoothedLoudness) * 0.15
        return smoothedLoudness
    }

    /// Onset counter the visualizer reads when mic mode is on. Compare to
    /// last-seen-value each frame to detect new onsets.
    var micOnsetCount: Int { micListener.onsetCounter }

    /// True when there is any kind of audio source for the visualizer:
    /// a loaded preview/file, an active MusicKit playback, or a live
    /// listener (mic or system audio). Used by ContentView to decide
    /// whether to show its control block — gating on `frames.isEmpty`
    /// alone would hide the controls during the brief window between
    /// the user starting an in-app Apple Music track and the streaming
    /// analyzer emitting its first frame.
    ///
    /// **Reads `framesCount`, NOT `frames`.** In tap mode the live frames
    /// array grows at 30 Hz; ContentView sits behind VisualizerView in
    /// the NavigationStack and its body re-evaluates on every observed
    /// change. Reading `frames.isEmpty` here would register an
    /// observation on the full array and invalidate ContentView's body
    /// 30 times per second — the root of the tap-mode-only FPS drift.
    /// `framesCount` is the 1 Hz throttled snapshot of `frames.count`
    /// (force-published on every wholesale wipe/load via
    /// `publishFramesCountNow`), so binary "has any frames" is correct.
    var hasAudioSource: Bool {
        if framesCount > 0 { return true }
        if musicKit.isPlaying { return true }
        if useMic { return true }
        #if os(macOS)
        if useSystemAudio { return true }
        #endif
        return false
    }

    /// Raw timbre brightness at the playback head. Drives the atmospheric
    /// grain overlay's alpha (HTML: `crispness(eTimbre) * 0.13`). Mic mode
    /// has no timbre signal so returns 0 — grain falls below the threshold
    /// and disappears, which matches the HTML's behaviour for silence.
    func currentTimbreBrightness() -> Float {
        if useMic { return 0 }
        guard !frames.isEmpty else { return 0 }
        let idx = min(frames.count - 1, max(0, Int(playbackTime * 30)))
        return frames[idx].timbreBrightness
    }

    /// Fetches and analyzes a song once, keeping its audio for playback.
    /// Idempotent on initial auto-load — re-call is a no-op once frames exist.
    func loadSong(_ term: String) async {
        guard frames.isEmpty, !isLoadingSong else { return }
        isLoadingSong = true
        defer { isLoadingSong = false }
        do {
            let loaded = try await SongLoader.load(term)
            frames = loaded.frames
            publishFramesCountNow()
            audioURL = loaded.audioURL
            await registerPreviewForAlignment(
                audioURL: loaded.audioURL,
                title: term,
                artist: "",
                frameCount: loaded.frames.count
            )
            let onsets = frames.filter { $0.onset }.count
            print("[HighVidelity] loaded \(frames.count) frames, \(onsets) onsets")
        } catch {
            print("[HighVidelity] song load failed: \(error)")
        }
    }

    /// Plays an Apple Music song through ApplicationMusicPlayer.
    ///
    /// On macOS, also enables the system-audio tap pointed at our own
    /// process — `ApplicationMusicPlayer` renders inside this app's
    /// process, so the streaming analyzer can capture the decoded PCM
    /// directly and drive the visualizer with live chromagram/timbre/
    /// loudness instead of cycling a separate 30s iTunes preview.
    /// CATap doesn't block self-taps; FairPlay's DRM protects the
    /// encrypted stream + decryption keys, not the post-decode PCM bus.
    ///
    /// On other platforms (iOS/visionOS/tvOS) CATap is unavailable, so
    /// we keep the original fetch-the-30s-preview path for tonal data.
    func playAppleMusicSong(_ song: MusicKit.Song) async {
        // Tear down any other audio sources so the visualizer clock cleanly
        // hands off to ApplicationMusicPlayer.
        stopPlayback()
        if useMic { useMic = false }
        frames = []
        publishFramesCountNow()
        audioURL = nil
        heldClock = 0
        smoothedLoudness = 0
        camPos  = SIMD3<Float>(0, 0.5, 1)
        camLook = SIMD3<Float>(0, 0, 0)

        // Kick off AM playback FIRST — empirically, ApplicationMusicPlayer
        // does NOT render through our own process's audio engine (the
        // self-tap returned no PCM in testing). Instead it routes through
        // a separate macOS audio service that shows up as `isPlaying=true`
        // in CoreAudio's process list once playback starts. Our picker's
        // auto-fallback prefers `isPlaying=true` candidates, so we just
        // need to make sure AM is actively emitting BEFORE we ask the tap
        // to pick a target.
        //
        // Pass the current search results as the playback context so the
        // queue holds more than one song — that's what makes next/prev
        // controls in the visualizer overlay do something useful.
        await musicKit.play(song, context: musicKit.searchResults)

        #if os(macOS)
        // ApplicationMusicPlayer renders through `RemotePlayerService`,
        // a macOS-side audio service — NOT through our own process and
        // NOT through Music.app. Empirically verified: refreshAvailable's
        // playingList included `RemotePlayerService` alongside other UI-
        // sound emitters like `backboardd`. Pin the tap to that process
        // explicitly; auto-pick alone would frequently grab the wrong
        // playing candidate (e.g. backboardd for system click sounds).
        preferredSystemAudioProcessName = "RemotePlayerService"
        // Brief delay so RemotePlayerService has time to register as
        // a process in CoreAudio's process list (only appears once AM
        // is actively emitting). Without this the picker can't find it.
        try? await Task.sleep(nanoseconds: 800_000_000)  // 0.8s
        if !useSystemAudio {
            useSystemAudio = true   // didSet wires Shazam + streaming analyzer
        } else {
            // Toggle is already on but tapping the wrong process — restart
            // with the RemotePlayerService preference.
            switchSystemAudioSource(toName: "RemotePlayerService")
        }
        // Deliberate user-initiated track change — bump the reset counter
        // so any open visualizer drops its previous cluster and starts
        // fresh for this song. Also re-seed the Shazam throttle clock so
        // the next match (likely arriving in ~10s, confirming THIS song)
        // gets suppressed rather than wiping the cluster we just primed.
        liveModeResetCounter += 1
        lastLiveResetTime = CACurrentMediaTime()
        lastLiveResetTitle = ""
        #endif

        #if !os(macOS)
        // Non-macOS platforms still need the preview for tonal data.
        // ALSO register it for ShazamKit-Phase-2 alignment so if the user
        // is in mic mode, custom-catalog matching can align preview's
        // 30-second timeline to the actual song position rather than
        // cycling out-of-sync.
        isLoadingSong = true
        defer { isLoadingSong = false }
        let term = "\(song.title) \(song.artistName)"
        do {
            let loaded = try await SongLoader.load(term)
            frames = loaded.frames
            publishFramesCountNow()
            audioURL = loaded.audioURL
            await registerPreviewForAlignment(
                audioURL: loaded.audioURL,
                title: song.title,
                artist: song.artistName,
                frameCount: loaded.frames.count
            )
            let onsets = frames.filter { $0.onset }.count
            print("[HighVidelity] AM \"\(term)\": \(frames.count) preview frames, \(onsets) onsets")
        } catch {
            print("[HighVidelity] preview fetch for \"\(term)\" failed: \(error)")
        }
        #endif
    }

    /// Loads and analyzes a full-length local audio file picked via
    /// `.fileImporter`. Replaces the currently-loaded song.
    func loadSong(from url: URL) async {
        guard !isLoadingSong else { return }
        // Stop any in-flight playback and reset state so the new song's
        // timeline starts cleanly.
        stopPlayback()
        frames = []
        publishFramesCountNow()
        audioURL = nil
        heldClock = 0
        smoothedLoudness = 0
        camPos  = SIMD3<Float>(0, 0.5, 1)
        camLook = SIMD3<Float>(0, 0, 0)

        isLoadingSong = true
        defer { isLoadingSong = false }
        do {
            let loaded = try await SongLoader.load(fileURL: url)
            frames = loaded.frames
            publishFramesCountNow()
            audioURL = loaded.audioURL
            // Imported files have no title/artist metadata from us —
            // use the filename as a placeholder for the catalog entry.
            await registerPreviewForAlignment(
                audioURL: loaded.audioURL,
                title: url.deletingPathExtension().lastPathComponent,
                artist: "",
                frameCount: loaded.frames.count
            )
            let onsets = frames.filter { $0.onset }.count
            print("[HighVidelity] imported \(url.lastPathComponent): \(frames.count) frames, \(onsets) onsets")
        } catch {
            print("[HighVidelity] file import failed: \(error)")
        }
    }

    /// Starts playing the loaded song from the beginning.
    ///
    /// **Apple Music coexistence:** when an AM song is already playing via
    /// `ApplicationMusicPlayer` (the playAppleMusicSong path), we do NOT
    /// start a local AVAudioPlayer here — that would play the 30s iTunes
    /// preview audio on top of AM's full-song playback, producing the
    /// "preview keeps playing after I open the visualizer" double-audio bug.
    /// The visualizer's clock prefers `musicKit.playbackTime` in
    /// `playbackTime` above, so reactivity stays correct off the
    /// ApplicationMusicPlayer position; we just need to not duplicate the
    /// audio. The local-file-import and mic-mode paths (where there's no
    /// AM playback in progress) still get the local AVAudioPlayer.
    func startPlayback() {
        guard let url = audioURL else { return }
        heldClock = 0
        if musicKit.isPlaying { return }
        #if os(macOS)
        // System-audio mode is its own clock source — don't re-start the
        // cached preview's AVAudioPlayer on top of it. Otherwise opening
        // the visualizer in live mode would silently kick off preview
        // playback, and `playbackTime` would prefer the player's clock
        // (0..30s preview range), pointing visualizers at preview frames
        // instead of the live frames we're appending.
        if useSystemAudio { return }
        #endif
        // Same guard for mic mode: if the user is listening via mic to
        // external speakers, we ABSOLUTELY don't want to play the preview
        // out of the speakers too — the mic would hear both songs and
        // Shazam would oscillate between matching them. Saw exactly this
        // in oslog during Phase 2 testing: `HV-ALIGN registered` flipping
        // between the actual song and various artist matches every few
        // seconds as Shazam latched onto whichever signal was clearer.
        if useMic { return }
        do {
            #if !os(macOS)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
        } catch {
            print("[HighVidelity] playback failed: \(error)")
        }
    }

    /// Stops playback and releases the player.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Apple Music transport controls (for the visualizer overlay)

    /// Restart the currently-playing AM song from the beginning.
    /// Resets the live visualizer cluster so the user sees a fresh
    /// build-up matching the song restart.
    func playerRestart() {
        #if os(macOS)
        if isControllingSystemMusic {
            Task { await systemMusicRestart() }
            return
        }
        #endif
        musicKit.restartCurrent()
        bumpLiveResetForTrackChange()
    }

    /// Skip to the next song in the queue (queued from search results).
    /// Skip to the next song in the current search results.
    ///
    /// ApplicationMusicPlayer's queue API (`Queue(for:startingAt:)`) was
    /// failing `prepareToPlay` with MPMusicPlayerControllerErrorDomain.6
    /// when we tried to queue multiple songs, so we stick to a single-song
    /// queue and implement prev/next by manually invoking `playAppleMusicSong`
    /// on the adjacent search result. Loses gapless playback (brief restart
    /// between tracks) but reliable.
    ///
    /// In system-audio-tap mode where the source is Music.app, dispatches
    /// to `SystemMusicPlayer.shared` so Music.app advances its own queue —
    /// the user gets transport control of an external app without us
    /// needing to know what's in its queue.
    func playerSkipToNext() async {
        #if os(macOS)
        if isControllingSystemMusic {
            await systemMusicSkipToNext()
            return
        }
        #endif
        guard let next = adjacentSong(offset: +1) else { return }
        await playAppleMusicSong(next)
    }

    /// Go back to the previous song in the current search results, or
    /// drive Music.app's previous track when tapping its system audio.
    func playerSkipToPrevious() async {
        #if os(macOS)
        if isControllingSystemMusic {
            await systemMusicSkipToPrevious()
            return
        }
        #endif
        guard let prev = adjacentSong(offset: -1) else { return }
        await playAppleMusicSong(prev)
    }

    /// Find the song at `nowPlayingIndex + offset` in the current search
    /// results, wrapping. Returns nil if no song is playing or search
    /// results are empty.
    private func adjacentSong(offset: Int) -> MusicKit.Song? {
        let results = musicKit.searchResults
        guard !results.isEmpty,
              let current = musicKit.nowPlaying,
              let idx = results.firstIndex(where: { $0.id == current.id })
        else { return nil }
        let count = results.count
        let next = ((idx + offset) % count + count) % count
        return results[next]
    }

    /// Toggle the AM player's pause/resume state. Visualizer doesn't
    /// reset on pause — same song, just a pause.
    func playerTogglePlayPause() async {
        #if os(macOS)
        if isControllingSystemMusic {
            await systemMusicTogglePlayPause()
            return
        }
        #endif
        await musicKit.togglePlayPause()
    }

    // MARK: - Music.app transport (system audio tap mode, macOS)

    #if os(macOS)
    /// True when system audio is being tapped from Music.app. While true,
    /// the user-facing `player*` methods dispatch to AppleScript commands
    /// against Music.app (MusicKit's `SystemMusicPlayer` is iOS-only — on
    /// macOS we drive the external Music.app via its scripting dictionary).
    /// Also drives `NowPlayingBadge` transport-control visibility — the
    /// badge shows prev/restart/play-pause/next when this is true, so
    /// the user can drive Music.app without leaving the visualizer.
    ///
    /// First AppleScript dispatch will trigger a one-time TCC Automation
    /// prompt asking the user to authorize "High Videlity" to control
    /// "Music." Required `Info.plist` key:
    /// `NSAppleEventsUsageDescription`.
    var isControllingSystemMusic: Bool {
        useSystemAudio && systemAudio.tappedProcessName == "Music"
    }

    /// Reflects whichever player drives the current audio source. For the
    /// in-app `ApplicationMusicPlayer` path, we have observable state. For
    /// Music.app via AppleScript we'd need to poll the script for player
    /// state (each call ~20-50ms) — skipping that for now and assuming
    /// "playing" since system audio + an identified song imply Music.app
    /// is producing audio. The play/pause toggle is bidirectional (Music's
    /// `playpause` command flips state regardless), so a slightly-stale
    /// icon doesn't break behavior.
    var isPlayingForUI: Bool {
        if isControllingSystemMusic {
            return systemAudio.isActive
        }
        return musicKit.isPlaying
    }

    /// Skip Music.app to its next track via AppleScript. Bumps
    /// `liveModeResetCounter` proactively so the visualizer resets
    /// immediately — without this, the visualizer would carry old-song
    /// state until Shazam detected the change (~10s typical, up to 60s
    /// if the throttle suppresses the first different-song match).
    private func systemMusicSkipToNext() async {
        MusicAppRemote.run("next track")
        bumpLiveResetForTrackChange()
    }

    private func systemMusicSkipToPrevious() async {
        MusicAppRemote.run("previous track")
        bumpLiveResetForTrackChange()
    }

    private func systemMusicTogglePlayPause() async {
        // Music.app's `playpause` flips state regardless of current
        // direction — no need to read state first.
        MusicAppRemote.run("playpause")
    }

    private func systemMusicRestart() async {
        MusicAppRemote.run("set player position to 0")
        bumpLiveResetForTrackChange()
    }
    #endif

    /// Shared reset routine for deliberate track changes. Wipes `frames`,
    /// resets the streaming analyzer, bumps the live reset counter so
    /// open visualizers drop their previous cluster, and re-seeds the
    /// Shazam throttle so the next match (confirming the new song)
    /// doesn't immediately re-fire reset.
    private func bumpLiveResetForTrackChange() {
        #if os(macOS)
        guard useSystemAudio else { return }
        frames = []
        publishFramesCountNow()
        systemAudio.resetLiveAnalysis()
        liveModeResetCounter += 1
        lastLiveResetTime = CACurrentMediaTime()
        lastLiveResetTitle = ""
        #endif
    }

    // MARK: - Track-change heuristics

    /// Lowercase the title and strip everything that isn't a letter or
    /// number — punctuation, parens, quotes, etc. Collapses runs of
    /// removed characters into a single space. Used to compare titles
    /// across Shazam matches of the same piece, where the formatting
    /// varies per catalog entry ("Piano Sonata No. 14..." vs
    /// "Beethoven: Sonata No.14 Op.27-2-..." vs "Moonlight Sonata").
    private func normalizeTitle(_ title: String) -> String {
        var out = ""
        var prevSpace = true
        for c in title.lowercased() {
            if c.isLetter || c.isNumber {
                out.append(c)
                prevSpace = false
            } else if !prevSpace {
                out.append(" ")
                prevSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Are these two normalized titles likely the same song? Shazam's
    /// public catalog returns wildly different titles for what a human
    /// recognizes as a single piece (different performers, different
    /// album notation, etc.). We treat them as the same song if their
    /// "significant" (4+ char) words overlap by at least 50% of the
    /// smaller title's significant word count.
    ///
    /// Examples on Moonlight Sonata III matches:
    ///   "piano sonata no 14 in c sharp minor op 27 no 2 moonlight iii presto agitato"
    ///   "beethoven sonata no 14 op 27 2 moonlight 3rd movement presto agitato"
    /// Shared 4+ char words: {sonata, moonlight, presto, agitato} = 4
    /// Smaller side's 4+ word count = 6 → ratio 0.67 → same song.
    ///
    /// Returns false if either title is empty (the first match after
    /// toggle has no prior to compare against).
    nonisolated private static func titlesAreSimilar(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        let aWords = Set(a.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let bWords = Set(b.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let smaller = min(aWords.count, bWords.count)
        guard smaller > 0 else { return false }
        let shared = aWords.intersection(bWords).count
        return Double(shared) / Double(smaller) >= 0.5
    }
}
