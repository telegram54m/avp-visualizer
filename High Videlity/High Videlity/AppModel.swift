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
#if os(iOS)
import MediaPlayer
#endif

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
/// Fidelity tier of the `frames` array currently driving the
/// visualizer. Lower raw value = higher fidelity:
///   • `.tier1` — real audio analysis (mic loop / system tap /
///     cached full-song frames from a prior calibration). Every
///     frame's loudness, chromagram, onset is the ground truth.
///   • `.tier2` — preview chromagram + AcousticBrainz full-song
///     beat positions. Beat-accurate, melody scripted (chord
///     progression loops the preview).
///   • `.tier3` — preview only. BPM-extrapolated beat grid,
///     looped preview chromagram. Beat-grid drifts slightly over
///     long songs; chord progression repeats every 30s.
///   • `.none` — no frames loaded yet.
enum FrameTier: Int, Sendable {
    case tier1 = 1
    case tier2 = 2
    case tier3 = 3
    case none = 99
}

enum VisualizerMode: String, CaseIterable, Identifiable {
    case crystal
    case clouds
    case rings
    case slipstream
    case ambient
    case dodecahedron
    case fractal
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .crystal:       return "Crystal"
        case .clouds:        return "Clouds"
        case .rings:         return "Rings"
        case .slipstream:    return "Slipstream"
        case .ambient:       return "Ambient"
        case .dodecahedron:  return "Dodec Disco"
        case .fractal:       return "Fractal"
        }
    }
}

/// Append a line to a known log file regardless of how the app was
/// launched. `print()` is unreliable because:
///   • LaunchServices (`open`) routes stdout into the system log
///     pipeline where it can be lost or buffered.
///   • Direct binary launches redirect stdout to the launching
///     process — but those launches break TCC.
/// A plain file write is launch-method-agnostic.
///
/// Tail with: `tail -f ~/Library/Logs/HighVidelity-stems.log`
fileprivate let _stemLogFileQueue = DispatchQueue(label: "highvidelity.stemlog", qos: .utility)
fileprivate func stemLog(_ message: String) {
    print(message)  // preserve original print-to-stdout
    _stemLogFileQueue.async {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
        guard let logsDir else { return }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let path = logsDir.appendingPathComponent("HighVidelity-stems.log")
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let line = "\(fmt.string(from: Date()))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: path) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: path)
        }
    }
}

/// One queued separation that was abandoned in favor of a newer
/// kickoff. Held in AppModel.deferredKickoffs and processed when
/// Music.app is paused, so we don't waste the partial compute that
/// went into the abandoned track. See "idle-time requeue" in
/// [[stem-separation-phase0]].
struct DeferredKickoff: Sendable, Equatable {
    let cacheKey: String
    let fileURL: URL
    let title: String
    let artist: String
}

/// Provenance of the currently-active stem features for the playing
/// song. Read by the UI's `StemsBadge` so the user can tell whether
/// the disco-ball pulse is being driven by isolated drum onsets
/// (cached or freshly computed) or by the band-split fallback.
///
/// Equatable so SwiftUI's @Observable can short-circuit no-op writes
/// (assigning the same case repeatedly during steady state doesn't
/// fan out invalidation).
enum StemStatus: Equatable, Sendable {
    /// No separation has landed for the currently-playing song.
    /// Visualizer is on band-split (`bandOnset[sub]` for the kick lane,
    /// full-mix `chromagram` for pitch, etc.). Either we haven't fired
    /// a kickoff yet, or the audio source can't be separated
    /// (streaming-only Apple Music, non-Music.app source).
    case idle
    /// Kickoff fired; sidecar is running separation. `fraction` is
    /// non-nil when the throttled path is emitting progress events
    /// (set per chunk by `_separate_throttled`); nil during cache
    /// lookup, ramp-up, or the fast (non-throttled) path. UI can
    /// render "stems N%" when present, "stems …" otherwise.
    case computing(fraction: Double?)
    /// Stems are available + being consumed by visualizers.
    /// `fromCache=true` → instant SQLite hit; `false` → freshly
    /// computed this session.
    case ready(fromCache: Bool)
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
    /// **`@ObservationIgnored` is intentional and load-bearing.** The
    /// streaming-audio path (SystemAudioListener → appendLiveFrames)
    /// mutates this array ~30 Hz with `frames.append(...)`. Without
    /// `@ObservationIgnored`, those 30 Hz mutations trigger SwiftUI's
    /// Observation invalidation cascade through every view body that
    /// reads any property on AppModel — even via the throttled
    /// `framesCount` mirror, the cost compounded as AppModel grew more
    /// @Observable properties through the week. Empirical: 50 fps with
    /// @Observable, 100-110 fps with @ObservationIgnored, isolated by
    /// session-2026-05-28 bisection.
    ///
    /// Visualizer reads of `frames` happen inside RealityKit
    /// `SceneEvents.Update` closures, which are NOT SwiftUI view
    /// bodies and don't require Observation tracking — they read the
    /// current value directly. SwiftUI consumers that need to display
    /// a live count read `framesCount` (a 1 Hz throttled @Observable
    /// snapshot updated by `publishFramesCountIfDue`).
    ///
    /// A 2026-05-22 attempt at this fix was reverted after misdiagnosing
    /// an unrelated preview-load hang as caused by `@ObservationIgnored`;
    /// the same change applied today works correctly. The earlier hang
    /// was likely a stale-state issue unrelated to observation semantics.
    @ObservationIgnored
    var frames: [FeatureFrame] = []

    /// Fidelity level of the currently-loaded `frames` array. Lower
    /// raw value = higher fidelity (Tier 1 is best, Tier 3 is the
    /// preview-extrapolated fallback). `none` is the empty initial
    /// state. `upgradeFrames(_:to:)` only ever transitions toward
    /// lower numbers, so a late-arriving Tier 2 can't displace a
    /// Tier 1 result that already landed.
    var currentFrameTier: FrameTier = .none

    /// Raw preview frames retained alongside `frames` for Tier 2
    /// synthesis. When Tier 3 synthesis runs, we also stash the
    /// preview here so the later (async) AcousticBrainz beats
    /// lookup can re-synthesize at Tier 2 fidelity. Cleared on song
    /// change (via `frames.didSet` empty branch).
    @ObservationIgnored var previewSeedFrames: [FeatureFrame]?
    /// Song duration captured at the moment Tier 3 fires so Tier 2
    /// synthesis later doesn't have to re-query MusicKit / system-
    /// music (which may have advanced state by then).
    @ObservationIgnored var previewSeedSongDuration: TimeInterval?

    /// Atomically replace `frames` with a higher-fidelity tier's
    /// output. No-op if the requested tier is equal or LOWER fidelity
    /// than the current one. Safe to call from any actor — the read
    /// pattern in visualizers is "snapshot once per tick" so a
    /// mid-tick replacement just shows up on the next tick.
    func upgradeFrames(_ newFrames: [FeatureFrame], to tier: FrameTier) {
        guard tier.rawValue < currentFrameTier.rawValue else { return }
        let prev = currentFrameTier
        frames = newFrames
        framesCount = newFrames.count
        currentFrameTier = tier
        diagLog.info("HV-TIER \(String(describing: prev), privacy: .public) → \(String(describing: tier), privacy: .public) (\(newFrames.count) frames)")
    }

    /// Helper called from the TunebatBpmFetcher.lookup completion
    /// tasks. If the result includes AcousticBrainz beat positions
    /// AND we still have the preview seed (i.e. Tier 3 fired and
    /// hasn't been displaced by a higher tier yet), synthesize Tier 2
    /// frames and upgrade. The `upgradeFrames` guard handles the
    /// "already at Tier 1 or 2, don't downgrade" case.
    func tryTier2Upgrade(beatPositions: [Double]?) {
        guard let beats = beatPositions, !beats.isEmpty else { return }
        guard let seed = previewSeedFrames,
              let duration = previewSeedSongDuration
        else { return }
        guard currentFrameTier.rawValue > FrameTier.tier2.rawValue else { return }
        guard let tier2 = Tier2FrameSynthesizer.synthesize(
            previewFrames: seed,
            beatPositions: beats,
            fullSongDuration: duration
        ) else { return }
        upgradeFrames(tier2, to: .tier2)
        print("[HighVidelity] tier-2 synth: \(tier2.count) frames over \(duration)s using \(beats.count) AB beats")
    }

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
    /// Shazam-verified happiness (0-100). Derived from AcousticBrainz's
    /// binary `mood_happy` classifier (so only MB-fallback songs have
    /// it; GetSongBPM doesn't expose a happiness field). Higher =
    /// happier, lower = sadder. Visualizers use this to shift palette
    /// warmth, ORTHOGONAL to intensity — a happy song can be either
    /// energetic or chill; sadness has its own color temperature.
    var shazamHappinessOverride: Float?
    /// Shazam-verified vocal vs instrumental score (0-100, 100 =
    /// vocal). AcousticBrainz `voice_instrumental` classifier.
    /// Visualizers use this to bias melody-vs-texture treatments.
    var shazamVoiceVocalOverride: Float?
    /// Shazam-verified timbre brightness (0-100, 100 = bright).
    /// AcousticBrainz `timbre` classifier. Visualizers modulate
    /// HDR / saturation of expressive elements (faces, halos).
    var shazamTimbreBrightnessOverride: Float?
    /// Shazam-verified time signature ("4/4", "3/4", "6/8", etc.)
    /// from GetSongBPM. Visualizers can bias rotation cadence.
    var shazamTimeSigOverride: String?
    /// Shazam-verified party score (0-100, 100 = party vibe).
    /// AcousticBrainz `mood_party` classifier. Adds to the intensity
    /// blend alongside danceability + aggressiveness.
    var shazamPartyOverride: Float?
    /// Shazam-verified relaxed score (0-100, 100 = relaxed).
    /// AcousticBrainz `mood_relaxed` classifier. INVERTED in the
    /// intensity blend (high relaxed → low intensity contribution).
    var shazamRelaxedOverride: Float?
    /// Generation counter for `shazamBpmOverride` lookups. Incremented
    /// every time a new Shazam match arrives. The Task that fetches
    /// the BPM captures its generation; on completion it only writes
    /// the result if its captured generation still matches the current
    /// counter. Prevents an old song's late-arriving lookup from
    /// stomping a newer song's override.
    @ObservationIgnored private var bpmLookupGeneration: Int = 0
    /// Title that produced the currently-active override set. Used for
    /// VERSION-FLIP RESILIENCE: when Shazam re-IDs the same song with
    /// a different mix label (e.g. "How Deep Is Your Love" then "How
    /// Deep Is Your Love (Serban Mix)"), `handleShazamMatch` checks
    /// similarity against this title and SKIPS clearing the overrides
    /// if the new title is similar. The badge stays steady through
    /// the new lookup instead of flickering back to the BeatTracker
    /// fallback for the lookup duration (~500-1500ms).
    @ObservationIgnored private var lastOverrideTitle: String = ""

    // MARK: - Stem-separated features (Phase 1.4)

    /// Per-stem feature timelines from the demucs-mlx sidecar, when
    /// available for the currently-playing song. nil before the first
    /// match + lookup; populated asynchronously after each Shazam match
    /// (or directly via Music.app integration). Visualizers that opt in
    /// — currently just the dodec disco ball — prefer these over
    /// frequency-band signals when populated.
    ///
    /// Cached by Music.app persistentID (or Shazam ID if available)
    /// in `~/Library/Caches/HighVidelity/stem_features.sqlite` — so
    /// every play of a known song hits the cache in <1s. The first
    /// play of a never-heard song takes 30-90s of background work and
    /// stems land near or after the end of the song — visualizers
    /// gracefully fall back to band-split until then.
    ///
    /// `@ObservationIgnored` because the payload is ~1.3 MB of nested
    /// float arrays — letting SwiftUI's @Observable tracker register
    /// per-read dependencies at the visualizer's 60 fps animate cadence
    /// caused audio to pop on every track change as the observation
    /// machinery ran. Visualizers re-read this property each tick
    /// directly; no view-layer observation is needed.
    @ObservationIgnored
    var stemFeatures: StemSeparationResult?

    /// Lightweight observable mirror — flips when stems land/clear.
    /// Use this in SwiftUI views that just want to show "stems ready"
    /// status. Reading `stemFeatures` itself in a view body would
    /// re-introduce the per-read cost we explicitly avoided above.
    var hasStemFeatures: Bool = false

    /// Most-recent Music.app song-position snapshot from the polling
    /// task: (wallClock = CACurrentMediaTime() at capture moment,
    /// songPos = playerPositionSeconds at capture moment).
    ///
    /// `currentSongPosition` extrapolates from this using the wall-
    /// clock delta, so `stemFrameOffset` stays stable between polls
    /// even though polls now run only every ~3 sec. Without the
    /// extrapolation, the computed offset would drift by 90 frames
    /// (3 sec × 30 fps) between polls and the orb's alignment would
    /// oscillate.
    @ObservationIgnored
    var songPositionSnapshot: (wallClock: TimeInterval, songPos: Double)?

    /// Extrapolated current Music.app song position, derived from
    /// the snapshot + wall-clock delta. Assumes 1× continuous playback
    /// since the last poll — breaks briefly on pauses/scrubs until
    /// the next poll re-anchors (~3 sec window). Returns 0 when no
    /// snapshot yet.
    var currentSongPosition: Double {
        guard let snap = songPositionSnapshot else { return 0 }
        return snap.songPos + (CACurrentMediaTime() - snap.wallClock)
    }

    /// Offset (in frames at 30 fps) to add to a live-frame index when
    /// looking up stem-array values. Solves the time-base mismatch:
    /// stem arrays are indexed by SONG TIME (from track start, since
    /// the sidecar processes the full song file), but
    /// `appModel.frames` in live mode is indexed by LIVE CAPTURE TIME
    /// (from when system-audio mode turned on).
    ///
    /// Derived each access from `currentSongPosition` (snapshot +
    /// wall-clock extrapolation) and current `frames.count`. Stays
    /// stable between polls because both terms grow at ~30/sec under
    /// 1× playback. Earlier 2 Hz polling without extrapolation
    /// crushed FPS to 30 from continuous AppleScript contention; 3-sec
    /// polling + extrapolation gives equivalent alignment with 6× less
    /// background work.
    var stemFrameOffset: Int {
        // Only meaningful when a live capture is the source AND we
        // have a song-position snapshot from Music.app polling.
        // Without a snapshot, `currentSongPosition` is 0 and the
        // resulting offset (`0 - frames.count`) is a huge negative
        // number — out-of-bounds for every stem read, which broke
        // Slipstream on local-file playback (no drums, no vocals).
        //
        // For local file mode, `frames` IS the full-song timeline
        // (from AnalysisTimeline.analyze) and stems are also full-song
        // indexed — they already share a time base, so the offset is
        // literally zero. Returning 0 here makes
        // `stemI = liveFrameI + stemFrameOffset` collapse to
        // `stemI = liveFrameI`, which is correct for that mode.
        guard songPositionSnapshot != nil else { return 0 }
        return Int(currentSongPosition * 30) - frames.count
    }

    /// Diagnostic state of the stem-separation pipeline for the current
    /// song. Drives the in-UI `StemsBadge` so the user can see whether
    /// the visualizer is on stem-driven rendering (cached vs fresh
    /// compute) or falling back to band-split signals.
    ///
    /// State machine:
    ///   .idle      → no stems for this song. Visualizer uses band-split.
    ///   .computing → kickoff fired; separation in progress (cache miss
    ///                or force-refresh). Visualizer still on band-split
    ///                until result lands.
    ///   .ready(fromCache: true)  → instant cache hit; stems are
    ///                              available and being consumed.
    ///   .ready(fromCache: false) → fresh compute completed this session;
    ///                              stems are available and being consumed.
    var stemStatus: StemStatus = .idle

    /// Generation counter mirroring `bpmLookupGeneration`. Incremented
    /// on every track change so late-arriving stem results from a
    /// previous song don't stomp the current track's features.
    @ObservationIgnored private var stemLookupGeneration: Int = 0

    /// Bounded queue of separations that were abandoned in favor of a
    /// newer track. Processed by `idleDrainTimer` when Music.app is
    /// paused so we don't waste the partial compute. Capped at 5 to
    /// avoid pile-up if the user quick-skips through 50 tracks. Newest
    /// abandons go to the end; when full, the OLDEST entry is dropped.
    @ObservationIgnored private var deferredKickoffs: [DeferredKickoff] = []
    @ObservationIgnored private static let maxDeferredKickoffs = 5

    /// Observable mirror of `deferredKickoffs.count` for future UI
    /// surfacing (e.g., a "5 stems pending" pill). Updated whenever
    /// the queue changes.
    var deferredKickoffCount: Int = 0

    /// Periodic timer that drains the deferred queue when Music.app is
    /// paused. Only running while the queue is non-empty — started on
    /// first enqueue, stopped when drain succeeds and queue is empty.
    @ObservationIgnored private var idleDrainTimer: Timer?

    /// True when an idle-drain separation is currently in flight. Used
    /// to prevent the timer from kicking off a second one while the
    /// first is still processing.
    @ObservationIgnored private var idleDrainBusy: Bool = false

    /// Lazy provider. Spawned + started on the first separation request,
    /// then reused for subsequent songs. The Python sidecar process
    /// stays alive across track changes so model load / numba JIT
    /// costs are paid once per app session, not per song.
    @ObservationIgnored private var stemFeatureProvider: StemFeatureProvider?

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
                #if os(iOS)
                // Mutually exclusive with the metadata observer too —
                // mic and MPMusicPlayerController both want to drive
                // the visualizer's clock, and the user only wants one
                // at a time.
                if useSystemMusic { useSystemMusic = false }
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
                // Forward streaming-analyzer frames into our rolling
                // `frames` array — same pattern as macOS system-audio
                // mode. Without this, frame-based visualizers (Crystal,
                // Architecture, etc.) keep cycling whatever song was
                // last loaded (the 30s preview loop the user saw).
                micListener.onNewFrames = { [weak self] newFrames in
                    self?.appendLiveFrames(newFrames)
                }
                Task { await micListener.start() }
                startDiagLogging()
            } else {
                micListener.stop()
                micListener.onNewFrames = nil
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
    /// User's scanned audio library (folder of files, see
    /// AudioLibraryScanner). Shared instance so the library browser
    /// AND the visualizer's transport HUD can both access it — the
    /// HUD needs the sort + entry list to compute "next track" when
    /// the user hits skip-forward during library playback.
    let library = LibraryStore()
    #endif

    /// File URL of the library entry currently loaded for playback,
    /// or nil when the source is something else (mic, system audio,
    /// preview, imported one-off file). Set by `loadSong(from:title:
    /// artist:)` when called with library metadata; the visualizer's
    /// transport HUD uses this to scope the next-track button to
    /// library playback only.
    @ObservationIgnored
    private(set) var currentLibraryEntryURL: URL?

    /// Title + artist of the currently-playing track from whichever
    /// source set it. Surfaced in the visualizer HUD. Nil when nothing
    /// has explicit metadata (e.g., mic-only mode).
    private(set) var currentTrackTitle: String = ""
    private(set) var currentTrackArtist: String = ""

    /// iOS-side now-playing observer (MPMusicPlayerController). Watches
    /// whatever Apple Music / Music.app is playing on the device + polls
    /// the playhead. The visualizer uses this as its CLOCK on iOS — no
    /// audio capture, no mic-vs-output ducking conflict. See
    /// `ios-audio-session.md` for the rationale.
    ///
    /// Cross-platform property (class is a no-op outside iOS) so AppModel
    /// stays #if-free at the field-declaration level. iOS-only logic
    /// lives in the `useSystemMusic` didSet and the platform branches
    /// of `playbackTime` / `hasAudioSource`.
    let systemMusic = SystemMusicNowPlaying()

    /// "Read Apple Music now-playing position" mode — iOS-only. When on,
    /// the SystemMusicNowPlaying observer subscribes to Music.app track
    /// changes, the visualizer's clock follows `currentPlaybackTime`
    /// instead of looping a 30s preview, and track changes fetch a fresh
    /// preview + override pack.
    ///
    /// Mutually exclusive with `useMic`: capturing the mic on iOS attenuates
    /// both directions of the audio path (see [[ios-audio-session]]), so the
    /// metadata-only path is the strongly-preferred default on iOS. The mic
    /// toggle is still available for vinyl/jam-session use cases where the
    /// system player has no source to report.
    var useSystemMusic: Bool = false {
        didSet {
            guard useSystemMusic != oldValue else { return }
            #if os(iOS)
            if useSystemMusic {
                // Mic and SystemMusic are mutually exclusive — flipping
                // on either disables the other (matching the macOS
                // useSystemAudio / useMic pattern).
                if useMic { useMic = false }
                // Pause any in-app preview playback — Music.app is the
                // audio source now, our AVAudioPlayer would double-up.
                stopPlayback()
                heldClock = 0
                systemMusic.onTrackChange = { [weak self] title, artist, pid, duration in
                    self?.handleSystemMusicTrackChange(
                        title: title, artist: artist,
                        persistentID: pid, durationSeconds: duration
                    )
                }
                systemMusic.start()
            } else {
                systemMusic.stop()
                systemMusic.onTrackChange = nil
            }
            #endif
        }
    }

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
                startSongPositionPolling()
            } else {
                systemAudio.stop()
                systemAudio.onNewFrames = nil
                systemAudio.audioBufferHandler = nil
                shazam.stop()
                if !useMic { stopDiagLogging() }
                stopSongPositionPolling()
            }
        }
    }

    // MARK: - Music.app song-position polling (drives stemFrameOffset)
    //
    // The stem-time alignment depends on knowing where Music.app's
    // playhead currently is in the song. AppleScript's `player
    // position` query takes ~10-50ms — too slow to call every animate
    // tick at 60 fps. Instead, a background task polls at 2 Hz and
    // writes the result to `cachedSongPosition`. The computed
    // `stemFrameOffset` property then derives the per-tick offset
    // from `cachedSongPosition × 30 − frames.count`. Up to ~500 ms
    // staleness between polls is acceptable — the vocal-orb smoothing
    // and the stem-onset windowing both have similar time constants,
    // so the orb's reactivity wouldn't beat that resolution anyway.

    @ObservationIgnored private var songPositionPollTask: Task<Void, Never>?

    private func startSongPositionPolling() {
        #if os(macOS)
        songPositionPollTask?.cancel()
        songPositionPollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Synchronous AppleScript on this background task.
                // Explicit Optional unwrap — the inline
                // `case .ready(let t)` against `try?`-wrapped result
                // silently never matched (scrutinee was
                // Optional<MusicAppNowPlayingState>, not the bare enum).
                var pos: Double? = nil
                if let state = try? MusicAppNowPlaying().query() {
                    switch state {
                    case .ready(let t):
                        pos = t.playerPositionSeconds
                    case .streamingOnly(let t):
                        pos = t.playerPositionSeconds
                    case .noTrack, .musicAppNotRunning:
                        break
                    }
                }
                if let pos {
                    let wall = CACurrentMediaTime()
                    await MainActor.run { [weak self] in
                        self?.songPositionSnapshot = (wallClock: wall, songPos: pos)
                    }
                }
                // 5-second polling interval. cachedSongPosition is
                // extrapolated between polls using wall-clock delta
                // (see `currentSongPosition` computed property), so
                // alignment stays stable under 1× playback even
                // though we only re-anchor every 5 seconds. Each
                // AppleScript query produces a brief (~100ms) FPS
                // dip — at 3-sec polling that's a visible drop every
                // 3 sec. At 5 sec the dips are less frequent and
                // less noticeable. Pause/scrub in Music.app
                // misaligns the orb by up to 5 sec until next poll
                // re-anchors — acceptable trade-off for steady FPS.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        #endif
    }

    private func stopSongPositionPolling() {
        songPositionPollTask?.cancel()
        songPositionPollTask = nil
        songPositionSnapshot = nil
    }

    // appendLiveFrames moved OUT of the macOS-only block so iOS's
    // MicListener.onNewFrames callback can also use it. Definition
    // is just below the `#endif`.

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

    /// Append a batch of live-mode feature frames to the rolling `frames`
    /// array. Called from `SystemAudioListener` (macOS) or `MicListener`
    /// (iOS / iPadOS / visionOS) when their streaming analyzer emits new
    /// frames on the main actor.
    ///
    /// Gates on at least one live source being active to avoid late-
    /// arrival writes from a stopping listener.
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
    fileprivate func appendLiveFrames(_ newFrames: [FeatureFrame]) {
        let liveActive: Bool = {
            if useMic { return true }
            #if os(macOS)
            return useSystemAudio
            #else
            return false
            #endif
        }()
        guard liveActive else { return }
        let baseIndex = frames.count
        let frameRate = 30.0
        for (i, f) in newFrames.enumerated() {
            let absoluteTime = Double(baseIndex + i) / frameRate
            frames.append(f.withTime(absoluteTime))
        }
        publishFramesCountIfDue()
    }

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
        // Queue advance: when ApplicationMusicPlayer auto-advances at
        // end-of-song OR the user hits prev/next, the polling loop in
        // MusicKitController detects the currentEntry change and fires
        // this callback. We re-run the per-track visualizer pipeline so
        // the new song's preview / Tier 3 frames / metadata / cloud
        // stems land before the visualizer notices the audio changed.
        // Without this, songs 2..N of a queue play audio but the
        // visualizer stays stuck on song 1's frames — silently broken.
        musicKit.onTrackChange = { [weak self] song in
            self?.kickoffTrackPipeline(for: song)
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
        //
        // VERSION-FLIP RESILIENCE: if the new title is SIMILAR to the
        // currently-active override's source title (e.g. same song,
        // different "(Live)" or "(Remix)" mix label), DON'T clear the
        // existing overrides — keep them valid through the new lookup.
        // The badge stays steady; if the new lookup returns different
        // values, they apply on completion (same code path as a fresh
        // override). If the new lookup fails or matches the same song
        // in the cache, the old values just keep working. Without
        // this, a same-song re-ID briefly drops the override and the
        // visualizer flickers back to BeatTracker fallback for the
        // duration of the network call.
        let normalizedNewTitle = normalizeTitle(term)
        let sameSongAsActive = !lastOverrideTitle.isEmpty
            && AppModel.titlesAreSimilar(normalizedNewTitle, lastOverrideTitle)
        if !sameSongAsActive {
            shazamBpmOverride = nil
            shazamDanceabilityOverride = nil
            shazamKeyOverride = nil
            shazamAcousticnessOverride = nil
            shazamAggressivenessOverride = nil
            shazamHappinessOverride = nil
            shazamVoiceVocalOverride = nil
            shazamTimbreBrightnessOverride = nil
            shazamTimeSigOverride = nil
            shazamPartyOverride = nil
            shazamRelaxedOverride = nil
        }
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
                self.shazamHappinessOverride = result.happiness
                self.shazamVoiceVocalOverride = result.voiceVocal
                self.shazamTimbreBrightnessOverride = result.timbreBrightness
                self.shazamTimeSigOverride = result.timeSig
                self.shazamPartyOverride = result.party
                self.shazamRelaxedOverride = result.relaxed
                self.lastOverrideTitle = normalizedNewTitle
                // Tier 2 attempt: if the AB lookup landed beats, try
                // promoting from Tier 3 → Tier 2. No-op when there's
                // no preview seed (already past Tier 2), the beats
                // array is empty, or the current tier is already ≤ 2.
                self.tryTier2Upgrade(beatPositions: result.beatPositions)
            }
        }

        // ---- Stem-separation kickoff (Phase 1.4) ----------------------
        // Independent from the metadata lookup above — runs in parallel.
        // Mirrors the same generation-counter cancellation pattern so a
        // late-arriving result for a previous song can't stomp current
        // features. Same-song re-ID skips the wipe so visualizers keep
        // the previous stems through a brief mis-match.
        if !sameSongAsActive {
            stemFeatures = nil
            hasStemFeatures = false
            // stemFrameOffset is computed from cachedSongPosition +
            // frames.count, both of which the track-change reset
            // updates separately — no per-track stale offset to clear.
            // Status flips to .computing as soon as we kick off below
            // (and to .ready/.idle when the result lands or the
            // kickoff bails early). Leaving as .idle here gives a
            // brief flash to .idle on track change before kickoff
            // sets .computing — desirable: makes track changes
            // visible in the badge.
            stemStatus = .idle
        }
        stemLookupGeneration += 1
        let stemGen = stemLookupGeneration

        // Debounce: if a separation is already in flight from a prior
        // track, signal it to abandon so we don't compound 50s+ of
        // wasted compute on songs the user has skipped past. The
        // current task will throw `.abandoned` at its next chunk
        // boundary; the actor's serialization queues the new
        // separate() call right after so it starts as soon as the
        // old one releases. Fire-and-forget — we don't await the
        // abandon ack here. Provider is captured to avoid touching
        // self from the detached task.
        if let providerForAbandon = stemFeatureProvider {
            Task.detached(priority: .utility) {
                try? await providerForAbandon.abandon()
            }
        }

        // Task.detached — kickoffStemSeparation contains a synchronous
        // AppleScript query (~10-50ms) that we DON'T want on the main
        // thread; the actor `provider.separate` call dispatches to the
        // sidecar's executor regardless of caller thread. We hop back
        // to main only for the final property assignment.
        Task.detached(priority: .utility) { [weak self] in
            await self?.kickoffStemSeparation(
                title: title,
                artist: artist,
                shazamID: item.shazamID,
                generation: stemGen
            )
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

    /// iOS-only: called when MPMusicPlayerController.systemMusicPlayer's
    /// nowPlayingItem changes (or on first start, to seed). Loads the
    /// 30s iTunes preview for the new song so frame-based visualizers
    /// have data to scan, registers the preview with the alignment
    /// system so `playbackTime` can map the song's real position into
    /// the preview's 30s window, and fires the same metadata-override
    /// lookup that Shazam matches do.
    ///
    /// Mirrors the structure of `handleShazamMatch` but skips the
    /// Shazam-specific quirks (mis-ID throttling, same-piece
    /// different-recording handling) — MPMediaItem.persistentID is
    /// authoritative for "is this the same song" so we just trust the
    /// observer's de-dup.
    ///
    /// Empty title means the system player went idle (track was
    /// cleared). Treat as no-op for now — the previous preview frames
    /// stay loaded so the visualizer doesn't snap to black mid-song
    /// when the user momentarily pauses + skips.
    fileprivate func handleSystemMusicTrackChange(
        title: String,
        artist: String,
        persistentID: String,
        durationSeconds: Double
    ) {
        guard !title.isEmpty else {
            print("[HighVidelity] system music: track cleared")
            return
        }
        let term = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        print("[HighVidelity] system music: new track \"\(term)\"")

        // Bump the live-mode reset counter so visualizers in additive
        // live modes (Crystal v2, Architecture, Slipstream) drop their
        // previously-spawned cluster + start fresh for the new song.
        // Mirrors the macOS bumpLiveResetForTrackChange path. No need
        // to wipe `frames` here — the preview-load below will replace
        // it via the publishFramesCountNow path.
        liveModeResetCounter += 1

        // VERSION-FLIP RESILIENCE (mirrors handleShazamMatch): if the
        // new title is similar to the currently-active override's
        // source title, keep the overrides — they're still valid.
        let normalizedNewTitle = normalizeTitle(term)
        let sameSongAsActive = !lastOverrideTitle.isEmpty
            && AppModel.titlesAreSimilar(normalizedNewTitle, lastOverrideTitle)
        if !sameSongAsActive {
            shazamBpmOverride = nil
            shazamDanceabilityOverride = nil
            shazamKeyOverride = nil
            shazamAcousticnessOverride = nil
            shazamAggressivenessOverride = nil
            shazamHappinessOverride = nil
            shazamVoiceVocalOverride = nil
            shazamTimbreBrightnessOverride = nil
            shazamTimeSigOverride = nil
            shazamPartyOverride = nil
            shazamRelaxedOverride = nil
        }
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
                self.shazamHappinessOverride = result.happiness
                self.shazamVoiceVocalOverride = result.voiceVocal
                self.shazamTimbreBrightnessOverride = result.timbreBrightness
                self.shazamTimeSigOverride = result.timeSig
                self.shazamPartyOverride = result.party
                self.shazamRelaxedOverride = result.relaxed
                self.lastOverrideTitle = normalizedNewTitle
                // Tier 2 attempt: if the AB lookup landed beats, try
                // promoting from Tier 3 → Tier 2. No-op when there's
                // no preview seed (already past Tier 2), the beats
                // array is empty, or the current tier is already ≤ 2.
                self.tryTier2Upgrade(beatPositions: result.beatPositions)
            }
        }

        // Load the preview + register with alignment. After registration,
        // attempt to synthesize alignment immediately from the Shazam
        // Phase-3 cache (UserDefaults-backed `previewStartInSong` for
        // this song). If the user has previously listened to this track
        // with mic-Shazam custom-catalog matching active (on macOS or
        // in iOS mic mode), the cache holds the preview's offset within
        // the full song — combined with `systemMusic.currentPlaybackTime`
        // that gives us frame-accurate alignment WITHOUT needing the
        // mic on. `recordPublicCatalogMatchForAlignment` guards on the
        // cache being non-nil, so first-time-heard songs gracefully
        // fall back to modulo wrap (handled by `playbackTime` directly).
        Task { @MainActor in
            isLoadingSong = true
            defer { isLoadingSong = false }
            do {
                let loaded = try await SongLoader.load(term)
                // Tier-3 synthesis (preview-only extrapolation). On iOS
                // system-music we can't do real-time analysis (no system
                // tap, no mic loop), so the visualizer's options are
                // "loop the 30s preview with modulo wrap" (old default)
                // or "synthesize a full-song frame array from preview
                // + extrapolated BPM grid" (new Tier 3). Tier 3 gives
                // beat-accurate visuals across the whole song; chord
                // progression still loops the preview, but no playback-
                // time modulo wrap. Falls back to the old direct-
                // assignment behavior when synthesis isn't possible
                // (no BPM lock yet, no song duration, etc.).
                let songDuration = self.systemMusic.durationSeconds
                if songDuration > 60.0,
                   let tier3 = Tier3FrameSynthesizer.synthesize(
                       previewFrames: loaded.frames,
                       fullSongDuration: songDuration
                   ) {
                    // Reset to .none so upgradeFrames's "lower-only"
                    // guard accepts the new tier (otherwise the
                    // preview's `frames = loaded.frames` would have
                    // auto-marked it `.tier1` via didSet).
                    frames = []
                    // Stash the preview + duration so the later
                    // AcousticBrainz beats lookup can synthesize at
                    // Tier 2 fidelity without re-fetching anything.
                    previewSeedFrames = loaded.frames
                    previewSeedSongDuration = songDuration
                    upgradeFrames(tier3, to: .tier3)
                    print("[HighVidelity] tier-3 synth: \(tier3.count) frames over \(songDuration)s from \(loaded.frames.count)-frame preview")
                } else {
                    frames = loaded.frames
                }
                publishFramesCountNow()
                audioURL = loaded.audioURL
                await registerPreviewForAlignment(
                    audioURL: loaded.audioURL,
                    title: title,
                    artist: artist,
                    frameCount: loaded.frames.count
                )
                // Read system-music position AT THIS MOMENT (not at
                // kickoff) — the preview load + signature gen above
                // can take 1-2s, during which the song advanced.
                #if os(iOS)
                let songPosNow = self.systemMusic.currentPlaybackTime
                self.shazam.recordPublicCatalogMatchForAlignment(
                    pcmo: songPosNow,
                    songMatchesCurrentRegistration: true
                )
                // If cache was empty (currentSongPreviewStartInSong
                // still nil after registerForAlignment), and we have
                // a downloaded library track (assetURL non-nil), run
                // local-decode calibration in the background. See
                // [[LocalCalibration]]. Streaming-only Apple Music
                // tracks have no assetURL and are skipped — they
                // remain on modulo-wrap until they get calibrated on
                // another device + CloudKit-synced here.
                if self.shazam.currentSongPreviewStartInSong == nil,
                   let assetURL = MPMusicPlayerController.systemMusicPlayer
                       .nowPlayingItem?.assetURL {
                    self.kickoffLocalCalibration(
                        previewURL: loaded.audioURL,
                        songAssetURL: assetURL,
                        previewDuration: Double(loaded.frames.count) / 30.0,
                        title: title, artist: artist
                    )
                }
                // Cross-user stem cache lookup. iOS streaming-AM can't
                // run the Mac kickoffStemSeparation path (no AppleScript
                // Music.app, no local fileURL, no sidecar) — but it
                // CAN benefit from stems any other user fresh-computed,
                // since the preview audio is enough to derive the
                // cross-device shazamID cache key. See
                // [[kickoffCloudOnlyStems]]. Cache miss is silent.
                self.kickoffCloudOnlyStems(
                    audioURL: loaded.audioURL,
                    title: title,
                    artist: artist
                )
                #endif
                print("[HighVidelity] system music preview loaded: \(loaded.frames.count) frames")
            } catch {
                print("[HighVidelity] system music preview fetch failed for \"\(term)\": \(error)")
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

    #if os(iOS)
    /// iOS-only background calibration: when a new song starts and
    /// the alignment cache is empty (and we have an `MPMediaItem.
    /// assetURL`), pump the song through the preview's signature
    /// match locally so we can derive `previewStartInSong` without
    /// needing live mic capture. On success the result lands in the
    /// same cache mic-Shazam would have populated, so it
    /// CloudKit-syncs to other devices automatically. See
    /// [[LocalCalibration]].
    private func kickoffLocalCalibration(
        previewURL: URL,
        songAssetURL: URL,
        previewDuration: TimeInterval,
        title: String, artist: String
    ) {
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await LocalCalibration.calibrate(
                    previewURL: previewURL,
                    songAssetURL: songAssetURL,
                    previewDuration: previewDuration
                )
                await MainActor.run {
                    self?.shazam.applyExternalAlignmentCalibration(
                        previewStartInSong: result.previewStartInSong,
                        title: title, artist: artist
                    )
                }
            } catch {
                // Calibration failures are non-fatal — the visualizer
                // just stays on modulo-wrap for this song. Common
                // causes: song version differs from preview (live
                // recording vs studio), preview download was the
                // wrong track, or the song is too short for Shazam's
                // fingerprint window. LocalCalibration logs the
                // specific cause.
                _ = error
            }
        }
    }
    #endif

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
        #if os(iOS)
        // iOS system-music observer path. The visualizer's clock follows
        // MPMusicPlayerController's playhead — that's the whole point of
        // the pivot away from mic capture. Two stages:
        //   1. Alignment available (custom-catalog Shazam mic-match has
        //      landed for THIS song) → map song-position into preview
        //      timeline cleanly. Doesn't happen on iOS in the
        //      mic-disabled default, but the code path stays correct
        //      for a future iteration that drives alignment from the
        //      MPMediaItem itself rather than mic-Shazam.
        //   2. No alignment → naive modulo wrap. Preview's 30s loops
        //      as the song plays. Color/structure cycles through the
        //      analyzed preview repeatedly but at least stays in sync
        //      with the song position (visualizer's "where am I" maps
        //      to the same frame on every replay of the preview window).
        if useSystemMusic && systemMusic.isPlaying && !frames.isEmpty {
            let songPos = systemMusic.currentPlaybackTime
            if let aligned = shazam.alignedPreviewTime(currentSongPosition: songPos) {
                heldClock = aligned
                return heldClock
            }
            let duration = Double(frames.count) / 30.0
            heldClock = songPos.truncatingRemainder(dividingBy: max(0.1, duration))
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
        #if os(iOS)
        if useSystemMusic { return true }
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

    /// Per-track visualizer-pipeline kickoff. Called for EVERY new
    /// ApplicationMusicPlayer track, regardless of whether the user
    /// tapped play in the search UI, the queue auto-advanced at
    /// end-of-song, or the user hit prev/next.
    ///
    /// What it does:
    /// 1. Resets visualizer state (frames, smoothed loudness, clocks)
    ///    so the new song doesn't inherit the previous song's tail
    /// 2. Wipes Shazam-driven metadata overrides UNLESS the new title
    ///    matches the previous one closely (version-flip resilience —
    ///    "Song (Live)" → "Song" shouldn't drop the override mid-play)
    /// 3. Bumps `liveModeResetCounter` so additive viz modes drop
    ///    their previously-spawned cluster
    /// 4. Eagerly fires the metadata-override lookup
    ///    (TunebatBpmFetcher → GetSongBPM + MB → AcousticBrainz). We
    ///    already know title + artist from MusicKit so there's no
    ///    reason to wait for Shazam streaming match. Tier 2 frame
    ///    upgrade triggers from inside the lookup completion when
    ///    AB returns beats_position.
    /// 5. On non-macOS: loads the 30s iTunes preview, synthesizes
    ///    Tier 3 frames, registers for Phase-2 alignment, kicks off
    ///    the cross-user CloudKit stem-cache lookup. Same chain the
    ///    SystemMusicNowPlaying observer runs on iOS — but this one
    ///    is driven by our in-app player, so it fires the moment a
    ///    queue advance happens (no waiting for Shazam streaming).
    /// 6. On macOS: the system-audio tap continues uninterrupted
    ///    across the queue advance (same RemotePlayerService process
    ///    emits the new song's PCM). Shazam will re-identify within
    ///    ~10s and trigger `handleShazamMatch`, which kicks off the
    ///    macOS stem-separation pipeline. So this function does the
    ///    visualizer-state reset and the eager metadata lookup; the
    ///    rest of the macOS flow is handled by the streaming path.
    ///
    /// Sync entry point — internal Tasks handle async work. Safe to
    /// call from the MusicKitController polling loop on every
    /// detected track change.
    @MainActor
    func kickoffTrackPipeline(for song: MusicKit.Song) {
        let title = song.title
        let artist = song.artistName
        let term = "\(title) \(artist)"

        // 1. Visualizer state reset.
        frames = []
        publishFramesCountNow()
        heldClock = 0
        smoothedLoudness = 0
        // Drop any prior song's preview-seed / duration so a stale
        // Tier 2 upgrade can't promote into the new song's tier-3
        // synth using the OLD song's preview tonal content.
        previewSeedFrames = nil
        previewSeedSongDuration = nil

        // 2. Override wipe (version-flip resilient).
        let normalizedNewTitle = normalizeTitle(term)
        let sameSongAsActive = !lastOverrideTitle.isEmpty
            && AppModel.titlesAreSimilar(normalizedNewTitle, lastOverrideTitle)
        if !sameSongAsActive {
            shazamBpmOverride = nil
            shazamDanceabilityOverride = nil
            shazamKeyOverride = nil
            shazamAcousticnessOverride = nil
            shazamAggressivenessOverride = nil
            shazamHappinessOverride = nil
            shazamVoiceVocalOverride = nil
            shazamTimbreBrightnessOverride = nil
            shazamTimeSigOverride = nil
            shazamPartyOverride = nil
            shazamRelaxedOverride = nil
        }

        // 3. Bump live-mode reset counter (additive viz modes drop
        //    their previous cluster).
        liveModeResetCounter += 1
        #if os(macOS)
        lastLiveResetTime = CACurrentMediaTime()
        lastLiveResetTitle = ""
        #endif

        // 4. Eager metadata-override lookup. Mirrors the structure of
        //    handleShazamMatch but doesn't need a Shazam match first
        //    — we already have authoritative title/artist from
        //    MusicKit. Generation counter cancels stale lookups
        //    from a previous (rapidly-skipped) song.
        bpmLookupGeneration += 1
        let myGeneration = bpmLookupGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let result = await TunebatBpmFetcher.lookup(title: title, artist: artist) {
                guard myGeneration == self.bpmLookupGeneration else { return }
                self.shazamBpmOverride = result.bpm
                self.shazamDanceabilityOverride = result.danceability
                self.shazamKeyOverride = result.key
                self.shazamAcousticnessOverride = result.acousticness
                self.shazamAggressivenessOverride = result.aggressiveness
                self.shazamHappinessOverride = result.happiness
                self.shazamVoiceVocalOverride = result.voiceVocal
                self.shazamTimbreBrightnessOverride = result.timbreBrightness
                self.shazamTimeSigOverride = result.timeSig
                self.shazamPartyOverride = result.party
                self.shazamRelaxedOverride = result.relaxed
                self.lastOverrideTitle = normalizedNewTitle
                self.tryTier2Upgrade(beatPositions: result.beatPositions)
            }
        }

        // 5. Non-macOS: preview chain (load → tier 3 → alignment →
        //    cloud stems lookup). macOS uses the system-audio tap
        //    instead, so the preview load is redundant there.
        #if !os(macOS)
        if useMic { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoadingSong = true
            defer { self.isLoadingSong = false }
            do {
                let loaded = try await SongLoader.load(term)
                let songDuration: TimeInterval = song.duration ?? 0
                if songDuration > 60.0,
                   let tier3 = Tier3FrameSynthesizer.synthesize(
                       previewFrames: loaded.frames,
                       fullSongDuration: songDuration
                   ) {
                    self.frames = []
                    self.previewSeedFrames = loaded.frames
                    self.previewSeedSongDuration = songDuration
                    self.upgradeFrames(tier3, to: .tier3)
                    print("[HighVidelity] AM tier-3 synth: \(tier3.count) frames over \(songDuration)s from \(loaded.frames.count)-frame preview (\"\(term)\")")
                } else {
                    self.frames = loaded.frames
                    let onsets = self.frames.filter { $0.onset }.count
                    print("[HighVidelity] AM \"\(term)\": preview-only path, \(self.frames.count) frames, \(onsets) onsets (tier-3 synth unavailable, duration=\(songDuration))")
                }
                self.publishFramesCountNow()
                self.audioURL = loaded.audioURL
                await self.registerPreviewForAlignment(
                    audioURL: loaded.audioURL,
                    title: title,
                    artist: artist,
                    frameCount: loaded.frames.count
                )
                self.kickoffCloudOnlyStems(
                    audioURL: loaded.audioURL,
                    title: title,
                    artist: artist
                )
            } catch {
                print("[HighVidelity] preview fetch for \"\(term)\" failed: \(error)")
            }
        }
        #endif
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
        // On macOS, mic-mode and ApplicationMusicPlayer don't mix —
        // macOS uses the system-audio CATap path for live frames from
        // AM, so mic-mode is redundant + conflicting. Force-disable.
        //
        // On iOS / iPadOS / visionOS, CATap doesn't exist. Mic-mode
        // is the ONLY way to get live (not 30s-preview-loop) frames
        // for AM playback — mic just captures the speakers. The two
        // are complementary, NOT conflicting. Keep mic on.
        #if os(macOS)
        if useMic { useMic = false }
        #endif
        audioURL = nil
        camPos  = SIMD3<Float>(0, 0.5, 1)
        camLook = SIMD3<Float>(0, 0, 0)

        // Kick off AM playback — empirically, ApplicationMusicPlayer
        // does NOT render through our own process's audio engine (the
        // self-tap returned no PCM in testing). Instead it routes through
        // a separate macOS audio service that shows up as `isPlaying=true`
        // in CoreAudio's process list once playback starts. Our picker's
        // auto-fallback prefers `isPlaying=true` candidates, so we just
        // need to make sure AM is actively emitting BEFORE we ask the tap
        // to pick a target.
        //
        // Pass the current search results as the playback context so the
        // queue holds more than one song — that's what makes prev/next
        // controls AND auto-advance walk through results sequentially.
        await musicKit.play(song, context: musicKit.searchResults)

        // The per-track pipeline (visualizer state reset, metadata
        // lookup, iOS preview chain) runs for ALL track changes
        // including queue auto-advance via `musicKit.onTrackChange`.
        // For the initial user-tap we fire it explicitly here — the
        // polling-loop's diff check `s.id != nowPlaying?.id` won't
        // fire because `musicKit.play(_:)` already set nowPlaying
        // eagerly before our polling cycles.
        kickoffTrackPipeline(for: song)

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
        #endif
    }

    /// Loads and analyzes a full-length local audio file picked via
    /// `.fileImporter`. Replaces the currently-loaded song.
    ///
    /// **iOS audio-session coexistence:** local files play through our
    /// own `AVAudioPlayer` which needs the `.playback` category. If
    /// mic mode is on we'd be in `.record` (input-only) — those are
    /// incompatible, so `startPlayback()` would silently bail at the
    /// `if useMic { return }` guard and nothing would play. Auto-
    /// disable mic when the user explicitly imports a local file —
    /// importing audio is a STRONG signal they want playback, not
    /// listening-via-mic.
    func loadSong(
        from url: URL,
        title providedTitle: String? = nil,
        artist providedArtist: String? = nil,
        libraryEntry: URL? = nil
    ) async {
        guard !isLoadingSong else { return }
        if useMic {
            useMic = false  // surface the conflict resolution to the UI
        }
        // Track which library entry (if any) this load was driven by,
        // so the visualizer HUD's next-track button knows the context.
        // Nil when loaded from .fileImporter or any non-library source.
        currentLibraryEntryURL = libraryEntry
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
            // Title falls back to filename when caller didn't supply
            // one (the .fileImporter path). Library browser entries
            // always have ID3-derived title + artist.
            let title = providedTitle?.isEmpty == false
                ? providedTitle!
                : url.deletingPathExtension().lastPathComponent
            let artist = providedArtist ?? ""
            self.currentTrackTitle = title
            self.currentTrackArtist = artist
            await registerPreviewForAlignment(
                audioURL: loaded.audioURL,
                title: title,
                artist: artist,
                frameCount: loaded.frames.count
            )
            let onsets = frames.filter { $0.onset }.count
            print("[HighVidelity] imported \(url.lastPathComponent): \(frames.count) frames, \(onsets) onsets")

            // Library-browser path: when we have title + artist, fire
            // the same metadata + stem-cache lookups that organic
            // playback (Music.app / Shazam-driven) gets. This is what
            // gives the visualizer BPM/key overrides + stem features
            // for files imported from the library browser.
            if !title.isEmpty, !artist.isEmpty {
                kickoffMetadataAndStemsForLocalFile(
                    fileURL: loaded.audioURL,
                    title: title,
                    artist: artist
                )
            }
        } catch {
            print("[HighVidelity] file import failed: \(error)")
        }
    }

    /// Library-file analog of the Shazam-match path: fires
    /// TunebatBpmFetcher metadata lookup + stem-cache resolution for
    /// a song where we already know title + artist (from ID3) but
    /// haven't gone through MusicAppNowPlaying / Shazam. The metadata
    /// lookup populates `shazam*Override` (which the visualizers read
    /// for BPM / key / mood axes). The stem cache lookup uses the
    /// content-hash key the batch cacher writes under, so any song
    /// the user previously batch-cached lights up its stems badge.
    @MainActor
    private func kickoffMetadataAndStemsForLocalFile(
        fileURL: URL, title: String, artist: String
    ) {
        // 1. Metadata override generation counter (mirrors the
        //    handleShazamMatch / handleSystemMusicTrackChange pattern).
        bpmLookupGeneration += 1
        let myGen = bpmLookupGeneration
        Task { @MainActor in
            if let result = await TunebatBpmFetcher.lookup(title: title, artist: artist) {
                guard myGen == self.bpmLookupGeneration else { return }
                self.shazamBpmOverride = result.bpm
                self.shazamDanceabilityOverride = result.danceability
                self.shazamKeyOverride = result.key
                self.shazamAcousticnessOverride = result.acousticness
                self.shazamAggressivenessOverride = result.aggressiveness
                self.shazamHappinessOverride = result.happiness
                self.shazamVoiceVocalOverride = result.voiceVocal
                self.shazamTimbreBrightnessOverride = result.timbreBrightness
                self.shazamTimeSigOverride = result.timeSig
                self.shazamPartyOverride = result.party
                self.shazamRelaxedOverride = result.relaxed
                self.lastOverrideTitle = normalizeTitle("\(title) \(artist)")
                // Tier 2 attempt (no-op for local files since they
                // load at Tier 1 directly; kept for consistency with
                // the AM-play paths).
                self.tryTier2Upgrade(beatPositions: result.beatPositions)
            }
        }

        // 2. Stem cache lookup — macOS only (sidecar is macOS only).
        //    Tries the content-hash key first (matches what
        //    LibraryBatchCacher writes under), then falls through if
        //    not cached. We do NOT trigger a fresh Demucs compute
        //    here — the user explicitly batches that work via the
        //    library browser's Cache Features button.
        #if os(macOS)
        stemLookupGeneration += 1
        let stemGen = stemLookupGeneration
        stemFeatures = nil
        hasStemFeatures = false
        stemStatus = .idle
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let provider = await self.ensureStemFeatureProvider()
            let hashKey = await LibraryBatchCacher.cacheKeyForFile(fileURL)
            guard let key = hashKey else {
                stemLog("[HV-STEM-ALIGN] \(title) [library-local-cache] — could not hash file")
                return
            }
            let cached = try? await provider.cachedFeatures(forKey: key)
            if let cached {
                await MainActor.run {
                    guard stemGen == self.stemLookupGeneration else { return }
                    self.stemFeatures = cached
                    self.hasStemFeatures = true
                    self.stemStatus = .ready(fromCache: true)
                    Self.logStemAlignmentSanity(
                        label: "\(title) [library-local-cache]",
                        result: cached, frames: self.frames)
                }
            } else {
                let framesCount = await MainActor.run { self.frames.count }
                stemLog("[HV-STEM-ALIGN] \(title) [library-local-cache] — CACHE MISS for key=\(key.prefix(20))… frames=\(framesCount). Re-batch this song to cache stems.")
            }
        }
        #endif
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
        // MusicKit's `isPlaying` is polled at 30 Hz from
        // `player.state.playbackStatus`, so it lags ~33ms behind the
        // actual `player.play()` resolution. If the user picks an AM
        // song and immediately taps "Open Visualizer", the polled
        // value can still be `false` when we get here — the local
        // AVAudioPlayer would then steal the audio session and duck
        // AM. `nowPlaying` is set EAGERLY in MusicKitController.play
        // (before the await), so it catches this race. Whenever any
        // AM track is in the queue, MusicKit owns the audio path.
        if musicKit.nowPlaying != nil { return }
        #if os(iOS)
        // Same defense on iOS for system-music observer mode: when
        // we're following Apple Music's external playback, AM owns
        // the audio path even if our `isPlaying`/`nowPlaying` haven't
        // caught up yet.
        if useSystemMusic { return }
        #endif
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
            hasLocalPlaybackSource = true
        } catch {
            print("[HighVidelity] playback failed: \(error)")
        }
    }

    /// Stops playback and releases the player.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        hasLocalPlaybackSource = false
    }

    /// Whether the local AVAudioPlayer is currently producing sound.
    /// Used by transport HUDs to toggle their play/pause icon. Will
    /// be false during Music.app / Apple Music / mic / system-audio
    /// playback modes (none of which use audioPlayer).
    var isLocalPlaybackPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Observable mirror of `audioPlayer != nil`. We can't observe
    /// the audioPlayer property directly (it's @ObservationIgnored,
    /// originally to avoid spurious observer updates from AVAudioPlayer
    /// internals). A computed property reading it isn't observable
    /// either — SwiftUI doesn't know what to track, so views gated on
    /// `appModel.hasLocalPlaybackSource` evaluate once at build time
    /// and never re-render when the player gets created. This stored
    /// property is updated alongside every audioPlayer set/clear in
    /// `startPlayback` / `stopPlayback`, giving the LocalPlaybackHUD
    /// overlay a proper observable trigger.
    private(set) var hasLocalPlaybackSource: Bool = false

    /// Pause the local AVAudioPlayer without releasing it (unlike
    /// stopPlayback which destroys the player). No-op when no local
    /// player is active.
    func pauseLocalPlayback() {
        audioPlayer?.pause()
    }

    /// Resume the local AVAudioPlayer from where pause left it. If
    /// the player has been deallocated (after stopPlayback), this is
    /// a no-op — caller should kick off a new playback session via
    /// startPlayback() in that case.
    func resumeLocalPlayback() {
        audioPlayer?.play()
    }

    /// Seek the local AVAudioPlayer back to position 0 and continue
    /// playing if it was playing. No-op when no local player.
    func restartLocalPlayback() {
        guard let player = audioPlayer else { return }
        let wasPlaying = player.isPlaying
        player.currentTime = 0
        if wasPlaying { player.play() }
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

    // MARK: - Stem-separation kickoff

    /// Looks up the current Music.app track's local file path, then
    /// asks the StemFeatureProvider sidecar to separate it. On success,
    /// stores the per-stem features in `stemFeatures` (gated by
    /// generation counter for cancellation).
    ///
    /// NOT `@MainActor`-isolated — runs on a Task.detached executor so
    /// the synchronous AppleScript query doesn't block the main thread
    /// (which would starve the audio render thread + cause animation
    /// hitches). Hops back to main only for the final assignment.
    ///
    /// Currently only handles Music.app library tracks. Streaming-only
    /// tracks and non-Music.app audio sources (Spotify, browser) get a
    /// graceful no-op — visualizers fall back to band-split signals.
    /// The live-capture fallback for those sources is future work.
    ///
    /// The Shazam match's title/artist are used for cache row
    /// annotation (helps with debugging via `cache_stats`), but the
    /// CACHE KEY itself is the Music.app `persistentID` because it's
    /// stable per-track in the user's library independent of how
    /// Shazam happened to ID it. Cross-library sharing via Shazam ID
    /// is a future layer on top.
    nonisolated private func kickoffStemSeparation(
        title: String,
        artist: String,
        shazamID: String?,
        generation: Int
    ) async {
        // Tiny helper — push stemStatus to main thread. The kickoff is
        // nonisolated; every status mutation has to hop. Captures
        // `self` weakly so a deallocated AppModel doesn't get touched.
        @Sendable func setStatus(_ status: StemStatus) async {
            await MainActor.run { [weak self] in
                self?.stemStatus = status
            }
        }

        // 1. Find the local file path via Music.app. Synchronous
        // AppleScript — we're on a background task, so the ~10-50ms
        // block is harmless. Could not run from @MainActor.
        let nowPlaying: MusicAppTrack
        do {
            switch try MusicAppNowPlaying().query() {
            case .ready(let t):
                nowPlaying = t
                stemLog("[stem] kickoff: nowPlaying=.ready title=\(t.title) fileURL=\(t.fileURL?.path ?? "nil")")
            case .streamingOnly(let t):
                // Apple Music streaming, no local asset — wait for the
                // live-capture fallback (not yet implemented).
                stemLog("[stem] kickoff bail: .streamingOnly title=\(t.title)")
                await setStatus(.idle)
                return
            case .noTrack:
                stemLog("[stem] kickoff bail: .noTrack")
                await setStatus(.idle)
                return
            case .musicAppNotRunning:
                stemLog("[stem] kickoff bail: .musicAppNotRunning")
                await setStatus(.idle)
                return
            }
        } catch {
            // AppleScript permission denied or other failure — log and
            // move on. The visualizer continues with band-split signals.
            stemLog("[stem] kickoff bail: MusicAppNowPlaying query failed: \(error)")
            await setStatus(.idle)
            return
        }

        guard let fileURL = nowPlaying.fileURL else {
            stemLog("[stem] kickoff bail: fileURL nil for \(nowPlaying.title)")
            await setStatus(.idle)
            return
        }

        // We have a valid local file → kickoff is committed. Flip to
        // .computing so the UI shows "stems being computed" even
        // though it may resolve to a fast cache hit in 700ms — the
        // brief flash is informative for the user.
        await setStatus(.computing(fraction: nil))

        // 2. Lazy-start the provider on main (so the singleton lives
        // in a known scope), then call `separate` from this background
        // task — the StemFeatureProvider is an actor and runs on its
        // own executor regardless of caller.
        let provider = await self.ensureStemFeatureProvider()

        // 3. Submit separation. Cache key: musicapp-pid-{persistentID}
        //    — the Music.app library ID is stable per-track regardless
        //    of Shazam-match noise.
        //
        // Throttle: if Music.app is currently playing, the sidecar's
        // unthrottled MLX inference saturates Metal hard enough to
        // glitch audio playback + stall the visualizer animation.
        // Pass throttle_ms=500 so the sidecar chunks the work and
        // sleeps between segments — slower wall time but audio + UI
        // stay smooth. Idle (paused) playback → full-speed compute.
        // Cache hits ignore throttle since they don't run inference.
        let throttleMS = nowPlaying.isPlaying ? 500 : 0
        // Cross-library cache-key strategy: prefer `shazam-<id>` as the
        // primary key when Shazam has identified the song — it's stable
        // across libraries AND devices, which unlocks both alias-from-pid
        // (this device, previously cached under pid) and the CloudKit
        // public-DB cross-user shared cache layer. Fall back to
        // `musicapp-pid-<id>` when no Shazam ID is available yet.
        let pidKey = "musicapp-pid-\(nowPlaying.persistentID)"
        let shazamKey: String? = (shazamID?.isEmpty == false) ? "shazam-\(shazamID!)" : nil
        let primaryKey = shazamKey ?? pidKey
        let secondaryKey: String? = (shazamKey != nil) ? pidKey : nil

        // Opportunistic forward-alias: if Shazam ID arrived AFTER an
        // earlier pid-keyed kickoff for this same library track, copy
        // the existing pid row over to the shazam key so the upcoming
        // separate() finds it instead of recomputing. The alias action
        // gracefully no-ops when no pid row exists ("primary not found")
        // so this is safe to fire unconditionally.
        if let shazamKey {
            _ = try? await provider.alias(primaryKey: pidKey, aliasKey: shazamKey)
        }

        // Three-tier cache hierarchy:
        //   1. Local SQLite (read-only lookup) — sub-100ms hit on this device
        //   2. CloudKit public DB shared cache — only consulted on local miss
        //      AND when shazamID is known (the cross-user key)
        //   3. Fall through to Demucs separation (~30-60s)
        // Tiers 1 and 2 populate the local SQLite so future plays hit tier 1.

        // Tier 1: local read-only check.
        if let localHit = try? await provider.cachedFeatures(forKey: primaryKey) {
            await self.applyStemResult(
                localHit,
                nowPlaying: nowPlaying,
                generation: generation,
                originLabel: "local"
            )
            return
        }

        // Tier 2: CloudKit public DB — only when Shazam ID is known.
        if let shazamID, !shazamID.isEmpty,
           let cloudHit = await CloudCacheSync.shared.fetchStemFeatures(shazamID: shazamID) {
            // Persist into local SQLite so subsequent (potentially
            // offline) plays hit tier 1 instead of round-tripping
            // through CloudKit again. fromCloudPayload retains both
            // the raw binary blob AND the stems_meta JSON specifically
            // to make this populate cheap and faithful.
            if let blob = cloudHit.rawFeaturesBlob,
               let metaJSON = cloudHit.rawStemsMetaJSON {
                let metaArray = Self.decodeMetaArray(metaJSON)
                Task.detached(priority: .background) {
                    try? await provider.putCachedFeatures(
                        forKey: primaryKey,
                        featuresBlob: blob,
                        stemsMeta: metaArray,
                        durationSeconds: cloudHit.durationSeconds,
                        title: title.isEmpty ? nowPlaying.title : title,
                        artist: artist.isEmpty ? nowPlaying.artist : artist
                    )
                }
            }
            await self.applyStemResult(
                cloudHit,
                nowPlaying: nowPlaying,
                generation: generation,
                originLabel: "cloud"
            )
            return
        }

        // Tier 3: full Demucs separation.
        do {
            let result = try await provider.separate(
                filePath: fileURL.path,
                cacheKey: primaryKey,
                forceRefresh: false,
                title: title.isEmpty ? nowPlaying.title : title,
                artist: artist.isEmpty ? nowPlaying.artist : artist,
                throttleMS: throttleMS
            )

            // Backward-alias after a FRESH computation: the row now
            // lives under primaryKey; mirror it to secondaryKey so
            // future lookups by either pid or shazam-id hit the cache.
            // Skipped on cache hits (the alias was already done either
            // on a prior run or by the forward-alias above).
            if let secondaryKey, !result.fromCache {
                Task.detached(priority: .background) {
                    _ = try? await provider.alias(
                        primaryKey: primaryKey, aliasKey: secondaryKey)
                }
            }

            // CloudKit public-DB push: only on fresh computations and
            // when we know the Shazam ID (the cross-user key). Other
            // listeners' first plays of this song will get a cloud
            // cache hit and skip the ~30-60s Demucs run.
            if !result.fromCache, let shazamID, !shazamID.isEmpty {
                let resultForUpload = result  // capture explicitly
                let titleForUpload = title.isEmpty ? nowPlaying.title : title
                let artistForUpload = artist.isEmpty ? nowPlaying.artist : artist
                Task.detached(priority: .background) {
                    await CloudCacheSync.shared.saveStemFeatures(
                        shazamID: shazamID,
                        title: titleForUpload,
                        artist: artistForUpload,
                        result: resultForUpload
                    )
                }
            }

            await self.applyStemResult(
                result,
                nowPlaying: nowPlaying,
                generation: generation,
                originLabel: result.fromCache ? "local-fallback-cache" : "fresh"
            )
        } catch StemSidecarError.abandoned(let reason) {
            // Expected when a newer kickoff superseded us. The newer
            // task has already set its own status (.computing) so we
            // leave stemStatus alone. Log quietly.
            stemLog("[stem] separation abandoned for \(nowPlaying.title): \(reason)")
            // Queue this kickoff for later — when Music.app pauses
            // (user takes a break, song ends, etc.), the idle-drain
            // timer will pop it and finish the work in the background.
            // Doesn't waste the partial compute since the sidecar
            // doesn't persist mid-flight features, but at least we
            // don't FORCE the user to manually replay the track to
            // get its stems cached.
            let deferred = DeferredKickoff(
                cacheKey: primaryKey,
                fileURL: fileURL,
                title: nowPlaying.title,
                artist: nowPlaying.artist
            )
            await MainActor.run { [weak self] in
                self?.enqueueDeferredKickoff(deferred)
            }
        } catch {
            stemLog("[stem] separation failed for \(nowPlaying.title): \(error)")
            // Fall back to band-split. Only revert status if this
            // task is still the current one — a newer kickoff may
            // have already set .computing.
            await MainActor.run { [weak self] in
                guard let self else { return }
                if generation == self.stemLookupGeneration {
                    self.stemStatus = .idle
                }
            }
        }
    }

    /// iOS-only cache-lookup-only sibling of `kickoffStemSeparation`.
    /// Closes the gap left by that function bailing on iOS — Apple
    /// Music streaming has no `MusicAppNowPlaying` AppleScript path
    /// AND no Demucs sidecar available locally, so the only way an
    /// iOS user can light up `stemFeatures` for a streaming-AM track
    /// is the cross-user CloudKit public DB cache (populated by Mac
    /// listeners who fresh-computed the song).
    ///
    /// The chain:
    ///   1. Derive a `shazamID` from the iTunes preview's audio
    ///      signature (one-shot Shazam public-catalog match — no mic
    ///      involved, ~500–1500ms cost). See
    ///      [[ShazamPhase2.lookupShazamIDFromPreview]] for why this is
    ///      needed (the cache key namespace is shazamID-only today).
    ///   2. Query CloudKit public DB by shazamID.
    ///   3. On hit, hop to main + apply the stems via the same
    ///      `applyStemResult` path the Mac flow uses.
    ///   4. On miss, no-op — visualizers continue band-split fallback.
    ///      We don't compute fresh stems on iOS (no sidecar) and we
    ///      don't persist to local SQLite either (nothing reads it on
    ///      iOS; the in-memory `stemFeatures` reset per-song is fine).
    ///
    /// Generation counter shares `stemLookupGeneration` with the Mac
    /// path so a fast track-skip cancels a stale lookup. The cost
    /// (one Shazam round-trip) is small enough that we just fire it
    /// every track change — Shazam caches signatures internally, so
    /// re-matching the same preview is fast.
    @MainActor
    fileprivate func kickoffCloudOnlyStems(
        audioURL: URL,
        title: String,
        artist: String
    ) {
        #if os(iOS)
        stemFeatures = nil
        hasStemFeatures = false
        stemLookupGeneration += 1
        let stemGen = stemLookupGeneration
        let capturedTitle = title
        let capturedArtist = artist
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let shazamID = await ShazamController.lookupShazamIDFromPreview(audioURL: audioURL),
                  !shazamID.isEmpty
            else {
                stemLog("[stem] iOS cloud-only: no shazamID derived for \(capturedTitle)")
                return
            }
            guard let cloudHit = await CloudCacheSync.shared.fetchStemFeatures(shazamID: shazamID)
            else {
                stemLog("[stem] iOS cloud-only: no cloud cache for shazamID=\(shazamID) (\(capturedTitle))")
                return
            }
            // applyStemResult only reads .title for log lines — synthesize
            // a minimal MusicAppTrack rather than threading a separate
            // signature through it.
            let track = MusicAppTrack(
                fileURL: nil,
                title: capturedTitle,
                artist: capturedArtist,
                album: "",
                persistentID: shazamID,
                durationSeconds: 0,
                playerPositionSeconds: 0,
                isPlaying: true
            )
            await self.applyStemResult(
                cloudHit,
                nowPlaying: track,
                generation: stemGen,
                originLabel: "ios-cloud"
            )
        }
        #endif
    }

    /// Centralized handler for landing a `StemSeparationResult` —
    /// regardless of whether it came from local SQLite, CloudKit
    /// public DB, or a fresh Demucs run. Hops to main for state
    /// mutation + generation check.
    nonisolated private func applyStemResult(
        _ result: StemSeparationResult,
        nowPlaying: MusicAppTrack,
        generation: Int,
        originLabel: String
    ) async {
        await MainActor.run {
            guard generation == self.stemLookupGeneration else {
                stemLog("[stem] stale \(originLabel) result for gen=\(generation) (current=\(self.stemLookupGeneration)), discarding")
                return
            }
            self.stemFeatures = result
            self.hasStemFeatures = true
            self.stemStatus = .ready(fromCache: result.fromCache)
            Self.logStemAlignmentSanity(
                label: "\(nowPlaying.title) [\(originLabel)]",
                result: result, frames: self.frames)
            stemLog("[stem] stems landed (\(originLabel)): \(nowPlaying.title) " +
                  "from_cache=\(result.fromCache) sep=\(result.timing.separationSeconds)s " +
                  "feat=\(result.timing.featureSeconds)s " +
                  "offset=\(self.stemFrameOffset) (songPos=\(String(format: "%.1f", self.currentSongPosition))s, liveFrames=\(self.frames.count))")
        }
    }

    /// One-line diagnostic comparing stem-array length, frames-array
    /// length, and reported song duration. Confirms (or refutes) the
    /// "chunked librosa center-padding makes stem arrays slightly too
    /// long" hypothesis behind the early-firing drums symptom.
    /// Emitted on every successful stems-land so we can grep
    /// `HV-STEM-ALIGN` after playback to see the numbers per song.
    @MainActor
    static func logStemAlignmentSanity(
        label: String, result: StemSeparationResult, frames: [FeatureFrame]
    ) {
        let stemLen = result.stems.values.map { $0.nFrames }.max() ?? 0
        let stemSec = Double(stemLen) / 30.0
        let framesLen = frames.count
        let framesSec = Double(framesLen) / 30.0
        let songSec = result.durationSeconds ?? -1
        let delta = stemSec - framesSec
        stemLog(String(
            format: "[HV-STEM-ALIGN] %@ — stems=%d (%.2fs) frames=%d (%.2fs) song=%.2fs Δ(stem-frames)=%+.2fs",
            label, stemLen, stemSec, framesLen, framesSec, songSec, delta
        ))
    }

    /// Decode the wire `stems_meta` JSON ([{name, n_frames}, ...]) into
    /// the tuple-array shape `StemFeatureProvider.putCachedFeatures`
    /// expects. Returns an empty array on any decode failure (caller
    /// then no-ops the local-populate side effect — not fatal).
    nonisolated private static func decodeMetaArray(_ json: String) -> [(name: String, nFrames: Int)] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let nFrames = dict["n_frames"] as? Int else { return nil }
            return (name: name, nFrames: nFrames)
        }
    }

    /// Lazy provider construction. The sidecar's Python process stays
    /// alive for the rest of the session after the first request, so
    /// model load + numba JIT pay off across many songs.
    @MainActor
    func ensureStemFeatureProvider() async -> StemFeatureProvider {
        if let existing = stemFeatureProvider { return existing }
        let provider = StemFeatureProvider()
        do {
            try await provider.start()
            // Wire up progress callback — sidecar emits one envelope
            // per chunk during throttled compute. Hop to MainActor
            // and only update if we're still in a computing state
            // (avoid races where a stale progress update fires after
            // .ready or .idle has been set).
            await provider.setOnProgress { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .computing = self.stemStatus {
                        self.stemStatus = .computing(fraction: fraction)
                    }
                }
            }
        } catch {
            stemLog("[stem] sidecar start failed: \(error)")
        }
        stemFeatureProvider = provider
        return provider
    }

    // MARK: - Deferred-kickoff queue (idle-time requeue)

    /// Append an abandoned kickoff to the deferred queue. De-dupes
    /// against existing entries with the same cache_key (a quick-skip
    /// through the same song twice shouldn't queue it twice). Drops
    /// the oldest entry when the cap is hit. Idempotent re: the
    /// idle-drain timer — starts it if not running.
    @MainActor
    func enqueueDeferredKickoff(_ entry: DeferredKickoff) {
        // De-dupe: if this cache_key is already queued, move it to
        // the end (most recently abandoned wins, gets processed first
        // when timer fires next).
        deferredKickoffs.removeAll { $0.cacheKey == entry.cacheKey }
        deferredKickoffs.append(entry)
        // Bound the queue size — drop oldest.
        while deferredKickoffs.count > AppModel.maxDeferredKickoffs {
            deferredKickoffs.removeFirst()
        }
        deferredKickoffCount = deferredKickoffs.count
        stemLog("[stem] deferred kickoff queued: \(entry.title) (queue size: \(deferredKickoffs.count))")
        startIdleDrainTimerIfNeeded()
    }

    /// Start the periodic idle-drain timer if the queue is non-empty
    /// and the timer isn't already running. Auto-stops when the queue
    /// drains, so this only burns a tick every 30s WHILE work is
    /// pending — zero overhead at rest.
    @MainActor
    private func startIdleDrainTimerIfNeeded() {
        guard idleDrainTimer == nil, !deferredKickoffs.isEmpty else { return }
        // 30s cadence — coarse enough that the timer overhead is
        // negligible, fine enough that the user doesn't wait long
        // after pausing for queued separations to start.
        idleDrainTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            // Timer fires on the run loop's main thread, but it's
            // declared @MainActor-isolated implicitly through the
            // surrounding class. Hop explicitly to satisfy the
            // compiler.
            Task { @MainActor [weak self] in
                self?.tryDrainDeferredQueue()
            }
        }
        stemLog("[stem] idle-drain timer started (queue size: \(deferredKickoffs.count))")
    }

    /// One tick of idle-drain logic. Stops timer if queue empty;
    /// otherwise checks Music.app state and processes one entry if
    /// playback is paused.
    @MainActor
    private func tryDrainDeferredQueue() {
        // Already processing one — skip to avoid concurrent compute.
        if idleDrainBusy { return }

        // Queue empty → stop timer and bail.
        if deferredKickoffs.isEmpty {
            idleDrainTimer?.invalidate()
            idleDrainTimer = nil
            stemLog("[stem] idle-drain timer stopped (queue empty)")
            return
        }

        // Check Music.app — only drain when paused (or no track).
        // Don't compete with active playback for GPU. The synchronous
        // AppleScript query is short (~10-50ms) but still — defer to
        // a background task for cleanliness.
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let isPlayingNow: Bool
            do {
                switch try MusicAppNowPlaying().query() {
                case .ready(let t): isPlayingNow = t.isPlaying
                case .streamingOnly(let t): isPlayingNow = t.isPlaying
                case .noTrack, .musicAppNotRunning: isPlayingNow = false
                }
            } catch {
                isPlayingNow = false  // assume idle on query failure
            }
            if isPlayingNow {
                // Try again next tick.
                return
            }
            await self.processNextDeferredKickoff()
        }
    }

    /// Pop the most-recently-enqueued deferred entry and run its
    /// separation. No throttling (we're idle). No status updates
    /// (the deferred work is background catch-up, not the user's
    /// current track). Cache-aware: skips entries that were
    /// independently cached since enqueue (e.g., user replayed the
    /// song and a foreground kickoff already cached it).
    @MainActor
    private func processNextDeferredKickoff() async {
        guard !idleDrainBusy else { return }
        // Pop from the END (most recent abandon first — that's the
        // song the user most likely still cares about). Older entries
        // get processed on later ticks.
        guard let entry = deferredKickoffs.popLast() else { return }
        deferredKickoffCount = deferredKickoffs.count
        idleDrainBusy = true
        defer { idleDrainBusy = false }

        // File still exists? If user removed the track from their
        // library, just drop it.
        guard FileManager.default.fileExists(atPath: entry.fileURL.path) else {
            stemLog("[stem] deferred kickoff skipped (file gone): \(entry.title)")
            return
        }

        let provider = await ensureStemFeatureProvider()
        do {
            let result = try await provider.separate(
                filePath: entry.fileURL.path,
                cacheKey: entry.cacheKey,
                forceRefresh: false,  // honor cache — user may have triggered a foreground compute
                title: entry.title,
                artist: entry.artist,
                throttleMS: 0  // we're idle; full speed
            )
            stemLog("[stem] deferred kickoff completed: \(entry.title) " +
                  "(from_cache=\(result.fromCache), sep=\(result.timing.separationSeconds)s)")
        } catch StemSidecarError.abandoned(let reason) {
            // Someone foreground-kicked-off while we were processing.
            // Their kickoff wins. Drop this one — the foreground
            // process will handle it.
            stemLog("[stem] deferred kickoff preempted by foreground: \(entry.title) (\(reason))")
        } catch {
            stemLog("[stem] deferred kickoff failed for \(entry.title): \(error)")
        }
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
