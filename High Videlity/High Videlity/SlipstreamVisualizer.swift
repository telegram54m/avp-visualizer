//
//  SlipstreamVisualizer.swift
//  High Videlity
//
//  Slipstream — forward-flight visualizer. The camera is fixed at world
//  origin (or eye-height on visionOS); the scene is a corridor that flows
//  TOWARD the camera over time. Each onset spawns a "gate" at the far end
//  of the corridor (-Z spawnDistance) and the gate slides forward at a
//  constant `forwardSpeed`. As gates pass the camera they're evicted.
//
//  This is the first mode where TIME has a spatial axis: the song's past
//  is literally behind you, the future is literally ahead. Over a few
//  minutes the corridor becomes a navigable color-history of the piece.
//
//  Each gate is a ring of camera-facing billboard quads (using the same
//  alpha-glow texture pattern as Rings + Clouds). Hue comes from the
//  onset's pitch-class color, radius and HDR boost from loudness, nested
//  inner-ring count from harmonic complexity. Per-instance positions are
//  driven by `MeshInstancesComponent` + `LowLevelInstanceData` — one
//  ModelEntity per ring, N billboards per ring, no per-instance color
//  needed (all particles in a ring share the gate's hue).
//
//  Key design choices:
//  • Gate position derived purely from `clock - spawnTime` * speed, no
//    persistent per-gate Z state. Means the animate tick is stateless
//    on the gates themselves; only the root carries the live-spawn
//    cursor. Simpler than tracking each gate's "current Z" through
//    perturbations.
//  • Eviction by Z threshold (past +5 m, well behind camera), not by
//    count cap — natural pruning that scales with onset density and
//    forwardSpeed.
//  • Live + preview paths mirror Crystal/Architecture exactly so the
//    track-change-reset + frame-seeding infrastructure works unchanged.
//
//  Cross-platform: same scene works in visionOS ImmersiveSpace (user is
//  inside the corridor, head-locked camera) and non-visionOS windowed
//  RealityView (virtual camera at origin looking down -Z). Per-platform
//  Y offset handled by the view layer.
//

import RealityKit
import AudioAnalysis
import CoreGraphics
import simd
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let slipLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "slipstream")

/// Per-gate state. Captured at spawn, read every animate tick to compute
/// the gate's current Z position. The odometer model (replacing the
/// older `(clock - spawnTime) × forwardSpeed` calc) is what lets the
/// corridor's speed vary smoothly without yo-yoing already-in-flight
/// gates: a speed change only affects how fast NEW distance accumulates
/// past `spawnedOdometer`, so each gate's Z monotonically advances.
struct SlipstreamGateComponent: Component {
    let spawnTime: Double
    /// `SlipstreamRootComponent.corridorOdometer` value at the moment
    /// this gate was spawned. Gate Z is computed each tick as
    /// `-spawnDistance + (currentOdometer - spawnedOdometer)`.
    let spawnedOdometer: Float
    let baseRadius: Float
    let hue: Float
    let loudness: Float
    let harmonicComplexity: Float
    /// Live recycle pool (render-crash fix, 2026-05-31): in live mode the
    /// gates are a FIXED pre-allocated pool (see `makeSlipstreamLive`).
    /// A slot that's flowed past the camera — or been freed on track change
    /// — carries `active = false` and `isEnabled = false`; `animate` skips
    /// it (no Z update, no eviction) and `configureGate` reactivates it on
    /// the next onset. So the scene graph is never structurally mutated in
    /// live mode. Defaults to `true` so the preview path (`makeSlipstream`,
    /// every gate real) is unaffected.
    var active: Bool = true
}

/// Per-root state — the live-spawn cursor + track-change watcher. Same
/// shape as `CrystalLiveStateComponent` / `ArchLiveStateComponent` so the
/// reset / replay-burst protection patterns transfer directly.
struct SlipstreamRootComponent: Component {
    /// Index into `appModel.frames` we've already scanned for onsets.
    var lastSeenFrameIndex: Int = 0
    /// Running count of gates spawned in live mode. Currently informational —
    /// could drive a per-spawn variation factor later if desired.
    var liveGateCount: Int = 0
    /// `appModel.liveModeResetCounter` value at the most-recent scan.
    /// When AppModel bumps it (Shazam track-change), `scanForNewOnsets`
    /// drops every spawned gate and reseeds the cursor to current frame
    /// count.
    var lastSeenResetCounter: Int = 0
    /// Smoothed copy of the current frame's chromagram hue, used to
    /// drive the fog backdrop. Circular-lerped at ~1.5 Hz so hue
    /// changes feel like an ambient drift rather than strobing. Wrapping
    /// at 1.0 handled by the lerp logic in `animate`.
    var fogHueSmoothed: Float = 0
    var fogHueInitialized: Bool = false
    /// Smoothed copy of loudness, drives fog brightness. Slow lerp so
    /// the fog "swells" with the section's energy without flickering on
    /// every kick drum.
    var fogLoudnessSmoothed: Float = 0
    /// Cumulative distance the corridor has flowed past the camera since
    /// scene-build. Each animate tick advances this by
    /// `effectiveSpeed × deltaTime`. Gates store their odometer-at-spawn;
    /// gate Z = -spawnDistance + (currentOdometer - spawnedOdometer).
    /// This lets `effectiveSpeed` vary per-tick without yo-yoing already-
    /// in-flight gates — a speed change only affects how fast NEW
    /// distance accumulates, not historical positions.
    var corridorOdometer: Float = 0
    /// First-tick sentinel — on the first animate call we initialize
    /// `corridorOdometer` to `clock × forwardSpeed` so preview-mode
    /// gates pre-positioned via their `frame.time` show up at the
    /// right Z immediately, even if the scene opens at a non-zero
    /// playback clock.
    var firstAnimateTick: Bool = true
    /// Smoothed loudness driving the speed multiplier. Lerps toward
    /// current frame's loudness at 1.5 Hz so speed changes feel like
    /// dynamic acceleration, not jerks. Distinct from fogLoudnessSmoothed
    /// because the fog wants a slower response than speed for visual
    /// taste — keeping them separate so they can be tuned independently.
    var smoothedSpeedActivity: Float = 0
    /// Onset pulse — bumped to ~1.0 on every new onset, decays
    /// exponentially. Applied as a scale-pop on every live gate so
    /// each new onset visibly reverberates through the entire corridor,
    /// not just spawns a single gate at the frontier. Decay constant
    /// 5/sec gives ~0.14s half-life: quick enough to feel like a
    /// percussion-driven shimmer, slow enough to be visible.
    var onsetPulse: Float = 0
    /// Beat-kick envelope. Bumped on every `FeatureFrame.beat.beatTrigger`,
    /// decayed at 4 Hz. Adds a transient acceleration to effectiveSpeed
    /// so the corridor visibly LURCHES forward on each beat. Scaled by
    /// aggressivenessOverride — aggressive tracks have punchier kicks.
    /// Distinct from `onsetPulse` (which is a visual scale-pop, not a
    /// motion change).
    var beatKickEnergy: Float = 0
    /// Index into `frames` we've already scanned for beat triggers.
    /// Avoids re-firing on already-seen frames every render tick.
    var lastScannedBeatIndex: Int = -1
    /// Smoothed vocals.loudness from stems. Drives the vocal-source
    /// glow's scale + brightness at the corridor horizon. EMA lerped
    /// at vocalGlowSmoothRate Hz so the glow swells with phrasing
    /// rather than reacting per-consonant. Stays at 0 when no vocals
    /// stem available (instrumental songs or pre-stem-load).
    var smoothedVocals: Float = 0
    /// Vocal attack envelope. Bumped to 1.0 on every vocals.onset
    /// (consonant attacks, phrase entries); decays at vocalAttackDecay
    /// Hz. Drives a brief scale POP + brightness flash on the orb so
    /// the start of each sung phrase is articulated discretely.
    var vocalAttackEnergy: Float = 0
    /// Last vocals.onset index scanned. Prevents re-firing on already-
    /// seen frames (render runs faster than playback).
    var lastScannedVocalIndex: Int = -1
    /// Smoothed pitch-derived Y offset for the orb. Derived from
    /// argmax(vocals.chromagram) → normalized 0..1 → mapped to ±vocalPitchYRange/2.
    /// EMA at vocalPitchSmoothRate so the orb moves with melodic phrasing
    /// (legato), not per-frame chromagram noise.
    var smoothedVocalPitchY: Float = 0
    /// Smoothed pitch-driven hue for the vocal-source glow, in
    /// [0, 1] hue space. Updated each tick from the chromagram
    /// argmax via circular lerp at vocalGlowPitchHueSmoothRate Hz.
    /// Singer's melodic line becomes the orb's color: high pitches
    /// → warm, low pitches → cool (or however the chromatic-to-hue
    /// mapping shakes out). NaN sentinel = uninitialized; first
    /// update snaps directly to target.
    var smoothedVocalPitchHue: Float = .nan
    /// Last-applied HDR boost on the orb's UnlitMaterial. The
    /// per-tick orb update skips the material rebuild when the next
    /// computed HDR would differ by less than `orbMaterialDelta` —
    /// avoids GPU material upload churn at 60Hz when the value isn't
    /// changing meaningfully. NaN sentinel forces first-update.
    /// Scale on the orb still updates every frame (transform-only,
    /// cheap) so visual continuity stays smooth.
    var lastAppliedOrbHDR: CGFloat = .nan
    /// Last-applied hue on the orb's material. Material rebuild
    /// triggers when either HDR delta OR hue delta exceeds threshold.
    var lastAppliedOrbHue: Float = .nan
    /// Same throttle pattern for the fog material's brightness term.
    /// Hue smoothing already runs in continuous space; only material
    /// rebuild needs gating.
    var lastAppliedFogBrightness: CGFloat = .nan
    var lastAppliedFogHue: Float = .nan
    /// True when this root is a LIVE recycle pool (`makeSlipstreamLive`).
    /// In that mode gate eviction + track-change reset DEACTIVATE slots in
    /// place (no removeFromParent) — the render-crash fix. Preview
    /// (`makeSlipstream`) leaves this false and keeps the original
    /// remove-on-evict behaviour (gates are transient, built at scene
    /// create, never recycled). NOTE: preview therefore still removes gates
    /// per-tick in `animate` — a latent version of the same race, but it's
    /// not the observed (live-mode) crash; tracked as a follow-up.
    var isLivePool: Bool = false
}

/// Tag for the fog backdrop entity so `animate` can find and update it
/// each tick. Identical pattern to Crystal's BeamRole / Architecture's
/// ArchRingComponent for tagged-entity lookups.
struct SlipstreamFogComponent: Component {}

/// Tag for the vocal-source glow at the corridor horizon. The vocalist
/// is rendered conceptually as a point of light at the vanishing point —
/// gates appear to spawn FROM this source and flow toward the viewer.
/// Glow brightness + scale track `vocals.loudness` (from stems) when
/// available; falls back to a small steady baseline otherwise. Always
/// present so the corridor has a clear visual horizon.
struct SlipstreamVocalGlowComponent: Component {}

enum SlipstreamVisualizer {

    // MARK: - Tuning constants

    /// Distance from camera at which gates spawn (negative-Z, "ahead").
    /// 12 m gives the user a few seconds to see an incoming gate before
    /// it reaches their face. Tuned alongside forwardSpeed.
    static let spawnDistance: Float = 12.0

    /// Once a gate's Z exceeds this threshold (past camera, well behind),
    /// it's evicted. +3 m is past the camera at world origin by enough
    /// that the gate is fully out of the user's forward field of view
    /// before it disappears.
    static let evictionThreshold: Float = 3.0

    /// Forward speed of the corridor in meters per second. At 2 m/s with
    /// spawnDistance=12 + evictionThreshold=3, a gate lives 7.5 s from
    /// spawn to eviction. Typical pop music at ~1.5 onsets/sec means
    /// ~11 gates simultaneously visible — sparse enough to read
    /// individually, dense enough to read as a corridor.
    static let forwardSpeed: Float = 2.0

    /// Base ring radius at zero loudness. Real radius is base + loudness*gain.
    static let baseRadius: Float = 0.4
    /// Per-loudness gain for ring radius. Maxes at base + gain ≈ 1.5 m.
    static let radiusGain: Float = 1.1

    /// Number of perimeter particles at zero loudness. Real count is
    /// base + Int(loudness * gain). Higher count = "denser" ring.
    static let particleBase = 14
    static let particleGain = 14

    /// Size of each particle billboard quad. Each particle is a soft
    /// alpha-falloff dot — slightly larger than typical so the HDR
    /// pixels at center light up cleanly.
    static let particleSize: Float = 0.10

    /// Max gates allowed simultaneously. Safety cap in case
    /// forwardSpeed is reduced or onset density spikes; Z-based eviction
    /// usually keeps the count well below this naturally.
    /// Cap on simultaneous live gates. Was 200; tightened 2026-05-22 after
    /// observing FPS drift from ~60 to 30-40 within a single song. At 80
    /// gates × ~2 rings/gate × ~21 particles/ring ≈ 3,360 active
    /// billboards — visually full without overloading the additive
    /// pipeline. Z-based eviction in animate() still handles the typical
    /// case; this cap only triggers on pathologically dense onset
    /// streams (or when speed-reactivity slows the corridor enough that
    /// gates persist longer than usual). Inside the slow-corridor case
    /// the cap converts gradual FPS drift into a hard ceiling.
    static let liveModeGateCap = 80

    /// Max nested rings any gate can have. `nestedRingCount` =
    /// `1 + round(harmonicComplexity × 2)` ∈ [1, 3]. The live pool builds
    /// every gate with this many ring children up front and toggles the
    /// unused ones' `isEnabled` per onset — so a recycled slot can render
    /// any gate's ring structure without adding/removing children.
    static let maxNestedRings = 3

    /// Radius of the reactive fog backdrop sphere. Inside the global
    /// black backdrop (radius 50, added by VisualizerView) but outside
    /// the active gate range (-12 to +3) so gates always render in
    /// front of the fog. The colored fog occludes the global black
    /// sphere from view, becoming the user's ambient background.
    static let fogRadius: Float = 40

    /// Fog tuning — DYNAMIC-RANGE curve (retuned 2026-05-22 09:30).
    ///
    /// First attempt (base=0.12, gain=1.5, sat=0.60) gave a constant
    /// mid-brightness wash that muddled the in-between zones — the
    /// fog read as competing color rather than reactive color. The
    /// fix is to compress the floor and stretch the peak so the fog
    /// is a REACTION to the music, not a presence:
    ///  • baseBrightness 0.03 → near-invisible at quiet passages
    ///    (corridor reads as mostly black, gates pop clean)
    ///  • loudnessGain 5.0 → strong reactivity, the fog "ignites" with
    ///    the energy
    ///  • saturation 0.95 → when the fog IS visible, the color is
    ///    vivid, not muddy
    ///
    /// At typical loudness levels (streaming analyzer reports
    /// ~0.05-0.15): quiet ≈ brightness 0.18, loud ≈ 0.78. The
    /// difference is what reads as "the fog is reacting" instead of
    /// "the fog is there."
    static let fogBaseSaturation: CGFloat = 0.95
    static let fogBaseBrightness: CGFloat = 0.10
    static let fogLoudnessGain: CGFloat = 4.0

    /// Per-pixel opacity of the fog. Dropped 0.40 → 0.20 (2026-05-22
    /// 09:46) after even alpha-blended fog still dominated the viewport
    /// — full-screen color washes win the visual hierarchy too hard.
    /// At 0.20, fog provides a subtle tint at loud passages and is
    /// nearly imperceptible at quiet ones; gates dominate as the focal
    /// elements rather than competing with the backdrop.
    static let fogAlpha: CGFloat = 0.55

    // MARK: - Vocal-source glow constants

    /// Z position of the vocal-source glow, in cluster-local space.
    /// Placed BEYOND the gate spawn frontier (-12) so gates appear to
    /// spawn FROM the glow and travel toward the viewer. Visible as a
    /// distant point of light at the vanishing point of the corridor.
    static let vocalGlowZ: Float = -18.0
    /// Edge length of the billboarded glow quad. Small base size; the
    /// per-tick scale multiplier in animate grows it with vocals.
    static let vocalGlowBaseSize: Float = 1.4
    /// Scale multiplier at peak smoothed vocals.loudness. Glow grows
    /// from 1.0× base (silent / no vocals) to this on a wailing chorus.
    static let vocalGlowMaxScale: Float = 3.0
    /// HDR brightness floor — small steady glow always visible so the
    /// corridor has a clear horizon anchor.
    static let vocalGlowBaseHDR: CGFloat = 1.2
    /// HDR brightness at peak vocals. Adds to baseHDR — peak glow
    /// is bright enough to noticeably warm the deep end of the corridor.
    static let vocalGlowPeakHDR: CGFloat = 4.0
    /// Smoothing rate for vocals.loudness (Hz). Originally 2.5 Hz
    /// (400ms time constant) but that introduced visible lag —
    /// orb growth trailed audible vocals by ~third of a second.
    /// Bumped to 6 Hz (170ms) which is fast enough to feel responsive
    /// without strobing on consonant transients.
    static let vocalGlowSmoothRate: Float = 6.0
    /// Fallback hue for the glow when no vocal pitch is detected
    /// (vocals silent / instrumental section / pre-stem-load). When
    /// vocals are present, the chromagram-argmax pitch drives the
    /// hue instead (see vocalGlowPitchHueSmoothRate).
    static let vocalGlowHue: CGFloat = 0.10  // gold-amber
    /// Saturation for the orb tint. Modest so the orb still reads as
    /// "light source" rather than "neon pucker" even with strong
    /// pitch-driven hue.
    static let vocalGlowSaturation: CGFloat = 0.55
    /// Smoothing rate for the pitch-driven hue (Hz). 3 Hz tracks
    /// melodic phrasing without strobing on consonants / chromagram
    /// frame-to-frame jitter. Same rate as fog hue smoothing.
    static let vocalGlowPitchHueSmoothRate: Float = 3.0
    /// Threshold for triggering material rebuild on hue change (in
    /// normalized hue [0, 1] units, accounting for wrap-around).
    static let orbHueDelta: Float = 0.015

    /// Vocal-attack envelope decay (Hz). Each vocals.onset bumps the
    /// envelope to 1.0; this controls how quickly it fades. 8 Hz =
    /// ~125ms half-life, matches the percussive "tt" / "pp" feel of
    /// consonants and phrase entries. Faster than the loudness smoothing
    /// so attacks read as discrete events, not blurred into the sustain.
    static let vocalAttackDecay: Float = 8.0
    /// Scale boost on peak attack (added to baseline scale). 0.5 means
    /// orb pops to 1.5× current size on a fresh attack.
    static let vocalAttackScaleBoost: Float = 0.5
    /// HDR brightness boost added on peak attack. Stacks on top of the
    /// sustain HDR — phrase entry "flashes" the orb.
    static let vocalAttackHDRBoost: CGFloat = 2.0
    /// Range of Y motion driven by vocal pitch. Orb bobs ±vocalPitchYRange/2
    /// around the centerline. 1.6m total = a clearly visible melodic
    /// gesture without feeling cartoonish.
    static let vocalPitchYRange: Float = 1.6
    /// Smoothing rate for pitch-driven Y motion (Hz). Originally 3 Hz
    /// but melodic motion lagged the audible pitch by ~330ms.
    /// Bumped to 7 Hz (~145ms time constant) — still smooth enough
    /// that single-frame chromagram noise on consonant transients
    /// doesn't strobe, but the orb tracks vocal phrasing tightly.
    static let vocalPitchSmoothRate: Float = 7.0
    /// Idle "breath" rate when not singing (Hz). 0.4 Hz = a slow,
    /// human-like resting bob.
    static let vocalBreathRate: Float = 0.4
    /// Breath bob amplitude (meters). Tiny — implies the singer is
    /// "still there" without being a distinct visual gesture.
    static let vocalBreathAmplitude: Float = 0.10
    /// Loudness threshold above which the breath idle is suppressed
    /// (the orb is "singing" so it shouldn't also "breathe").
    static let vocalBreathSuppressThreshold: Float = 0.08

    /// Additional frame-count compensation applied on top of
    /// `appModel.stemFrameOffset` when indexing stem arrays. Pulls
    /// stem readouts FORWARD in song time to compensate for cumulative
    /// pipeline latency:
    ///   • Streaming analyzer's 8192-sample window (~170ms at 48kHz)
    ///   • Music.app's `player position` reporting lag (varies)
    ///   • Per-tick smoothing EMAs (165ms phase shift at 6 Hz)
    /// Empirically tuned.
    ///
    /// **Zeroed 2026-05-26 with the v3 sidecar refactor** — the old
    /// non-zero value (6 frames = 200ms) was compensating for the v2
    /// chunked-librosa padding drift that's now structurally fixed
    /// (concat-then-feature emits stems aligned to within ±0.03s of
    /// the mix timeline). Any residual lag now should be driven by
    /// live-pipeline latency only (irrelevant for local-file playback,
    /// already-corrected for streaming via stemFrameOffset). Tune up
    /// only if real-world testing exposes a new lag source.
    static let stemSyncCompensationFrames: Int = 0

    /// Threshold for skipping the per-tick orb material rebuild.
    /// HDR deltas smaller than this aren't visually perceptible but
    /// still trigger a GPU material upload — gating saves ~60 uploads
    /// per second on typical content where smoothedVocals only moves
    /// in small increments. Tune down if visible step changes appear.
    static let orbMaterialDelta: CGFloat = 0.08
    /// Same threshold for the fog material's brightness term.
    static let fogBrightnessDelta: CGFloat = 0.015
    /// Same for fog hue (in normalized [0, 1] units, accounting for
    /// wrap-around).
    static let fogHueDelta: Float = 0.015

    // MARK: - Cached resources

    /// Shared glow texture, built once. The same alpha-gradient texture
    /// Rings + Clouds use for their billboard sprites — radial alpha
    /// falloff so particles read as soft glow dots, not hard squares.
    /// `nonisolated(unsafe)` because we read it from the audio-driven
    /// `scanForNewOnsets` path; one-write-many-read after first build.
    @MainActor private static var cachedGlowTexture: TextureResource?

    @MainActor
    private static func sharedGlowTexture() -> TextureResource {
        if let cached = cachedGlowTexture { return cached }
        let texture = makeGlowTexture()
        cachedGlowTexture = texture
        return texture
    }

    /// Build the reactive fog backdrop entity. An inside-out sphere of
    /// `fogRadius`, opaque material tinted from chromagram hue, scaled
    /// `[-1, 1, 1]` so the inward face is what the user sees. Updated
    /// by `animate` each tick — material.color is rebuilt from the
    /// smoothed hue/loudness state on the root. Tagged with
    /// `SlipstreamFogComponent` so `animate` can find it cheaply via
    /// a single component query.
    @MainActor
    private static func makeFogSphere() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: fogRadius)
        // Start dark; first animate tick will color it from the current
        // chromagram once frames are available. Alpha matches `fogAlpha`
        // — without bake-in alpha here, the first frame before animate
        // runs would render fully opaque.
        let initialTint = PlatformColor(
            white: CGFloat(fogBaseBrightness),
            alpha: fogAlpha
        )
        var material = UnlitMaterial()
        material.color = .init(tint: initialTint)
        // Alpha-blend so the global black void (radius-50 backdrop sphere
        // in VisualizerView) shows through partially. Without this the
        // fog is a SOLID colored room that dominates every pixel — even
        // a dim tint reads as "we're inside a colored sphere" rather
        // than "the void has a soft color wash."
        material.blending = .transparent(opacity: .init(floatLiteral: Float(fogAlpha)))
        // Don't write depth — gates are at z=-12..+3 and need to render
        // additively on top of whatever fog pixels are at their
        // screen-space coordinate. The fog's geometry depth (radius 40)
        // would block additive contributions at gate Z positions if it
        // wrote depth.
        material.writesDepth = false
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.scale = [-1, 1, 1]  // inward face
        entity.components.set(SlipstreamFogComponent())
        return entity
    }

    /// Build the vocal-source glow entity. A billboarded glow quad
    /// using the same shared radial-gradient texture gates use, sized
    /// at vocalGlowBaseSize and positioned at vocalGlowZ (deep into
    /// the corridor, beyond the gate spawn frontier). animate() reads
    /// the per-tick smoothedVocals and updates this entity's scale +
    /// material HDR boost so the glow swells when the singer is
    /// present. Faces +Z (toward the viewer) — no per-tick billboard
    /// reorientation needed since the camera doesn't move.
    private static func makeVocalGlow() -> ModelEntity {
        let mesh = makeQuadMesh(size: vocalGlowBaseSize)
        let glow = sharedGlowTexture()
        var material = UnlitMaterial()
        let tint = PlatformColor.hdrColor(
            hue: vocalGlowHue,
            saturation: vocalGlowSaturation,
            brightness: 1.0,
            hdrBoost: vocalGlowBaseHDR
        )
        material.color = .init(tint: tint, texture: .init(glow))
        // Additive-ish blending: alpha cuts the quad to circular shape
        // via the radial-gradient texture's alpha falloff. writesDepth
        // off so gates render in front when they pass over the glow.
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        material.writesDepth = false
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = [0, 0, vocalGlowZ]
        entity.components.set(SlipstreamVocalGlowComponent())
        return entity
    }

    // MARK: - Build (preview path)

    /// Pre-build a corridor of gates from a fully-analyzed frame list.
    /// Each onset gets one gate whose Z position at scene-build is
    /// derived from `(0 - onset.time) * forwardSpeed` — so onsets at
    /// t=0 sit at the spawn frontier (-12 m), later onsets sit deeper
    /// in the void ahead, and they all slide forward together as
    /// playback advances. Mirrors how `makeCrystal` differs from
    /// `makeCrystalLive` (build-all vs incremental).
    @MainActor
    static func makeSlipstream(from frames: [FeatureFrame]) -> Entity {
        let root = Entity()
        root.position = [0, 1.45, 0]   // visionOS eye height; non-visionOS overrides
        var state = SlipstreamRootComponent()
        // Preview path doesn't use scanForNewOnsets (we've already
        // pre-spawned everything); seed lastSeenFrameIndex past the end
        // so any stray scan call is a no-op.
        state.lastSeenFrameIndex = frames.count
        root.components.set(state)

        // Reactive fog backdrop — animate() drives its color from the
        // current frame's chromagram. Lives at root local origin so it
        // moves with the cluster's host transform (root.position) on
        // both visionOS and windowed paths.
        root.addChild(makeFogSphere())
        // Vocal-source glow at the deep end of the corridor.
        root.addChild(makeVocalGlow())

        let glow = sharedGlowTexture()

        for frame in frames where frame.onset {
            // Preview path: assume corridor moves at constant `forwardSpeed`
            // (no per-tick reactivity baked into pre-spawn positions). A
            // gate at frame.time = T would have been spawned at corridor
            // odometer = T × forwardSpeed if the corridor had been
            // advancing since clock=0. So `spawnedOdometer = T × forwardSpeed`.
            // Animate then computes current Z from
            // `corridorOdometer - spawnedOdometer`, which equals
            // `(clock - T) × forwardSpeed` at constant speed — matching
            // the prior simple `clock - spawnTime` formula. The new model
            // also accommodates dynamic speed (corridorOdometer integrates
            // the actual effectiveSpeed each tick).
            let gate = spawnGate(
                frame: frame,
                glow: glow,
                spawnedOdometer: Float(frame.time) * forwardSpeed
            )
            let age = 0.0 - frame.time
            gate.position.z = -spawnDistance + Float(age) * forwardSpeed
            root.addChild(gate)
        }
        return root
    }

    /// Build an empty Slipstream root for live additive spawning. The
    /// `scanForNewOnsets` tick (driven by `SceneEvents.Update`) walks
    /// newly-arrived frames and spawns gates incrementally. Same pattern
    /// as `makeCrystalLive` / `makeArchitectureLive`.
    @MainActor
    static func makeSlipstreamLive(startingFrameIndex: Int, startingResetCounter: Int) -> Entity {
        // Warm the glow-texture cache so `scanForNewOnsets` (a
        // synchronous animate-tick caller) doesn't pay the texture-build
        // cost on its first invocation.
        _ = sharedGlowTexture()
        let root = Entity()
        root.position = [0, 1.45, 0]
        var state = SlipstreamRootComponent()
        state.lastSeenFrameIndex = startingFrameIndex
        state.lastSeenResetCounter = startingResetCounter
        state.isLivePool = true
        root.components.set(state)
        // Same fog backdrop as the preview path — animate() drives it
        // from `frames[playbackIndex]` each tick.
        root.addChild(makeFogSphere())
        root.addChild(makeVocalGlow())

        // RECYCLE POOL (render-crash fix, 2026-05-31). Mirrors the Crystal
        // fix: pre-allocate the full fixed pool of `liveModeGateCap` gates
        // here, once, all inactive (isEnabled=false, active=false). After
        // this no child is ever added or removed in live mode —
        // `scanForNewOnsets` reconfigures a free slot per onset and `animate`
        // deactivates slots that flow past the camera, all in place. So the
        // render thread can never race a `removeFromParent` against its draw
        // (the EXC_BAD_ACCESS in re::encodeDrawCalls). The fog sphere +
        // vocal glow added above carry no SlipstreamGateComponent, so the
        // gate-only scans skip them and they're preserved.
        let glow = sharedGlowTexture()
        for _ in 0..<liveModeGateCap {
            root.addChild(buildEmptyGate(glow: glow))
        }
        return root
    }

    // MARK: - Live spawning

    /// Walk new frames since the last call and spawn one gate per
    /// `onset == true` frame. Cheap when no new onsets — bounded by
    /// `frames.count - state.lastSeenFrameIndex` ≈ a few per call at
    /// 30 fps. Called from the animate-tick closure when in live mode.
    ///
    /// Track-change reset (Shazam-detected new song): when
    /// `appResetCounter` differs from the stored counter, drop every
    /// spawned gate and reseed the cursor to current `frames.count` so
    /// the next tick only walks genuinely-new frames. Mirrors
    /// `CrystalVisualizerV2.scanForNewOnsets`.
    @MainActor
    static func scanForNewOnsets(
        _ root: Entity,
        frames: [FeatureFrame],
        appResetCounter: Int,
        stemFeatures: StemSeparationResult? = nil,
        stemFrameOffset: Int = 0,
        playbackUpperBoundFrame: Int? = nil
    ) {
        // `playbackUpperBoundFrame` caps the spawn-loop's upper bound
        // for the LOCAL-FILE playback case. Without it, `frames.count`
        // is used (correct for live-streaming where frames grows over
        // time, wrong for local files where frames is pre-populated
        // with the full song's timeline — the first tick would spawn
        // ALL gates at once). When set, we walk only up to
        // `min(frames.count, playbackUpperBoundFrame)`. The caller
        // (VisualizerView) typically adds a small lookahead window
        // (~2 sec) so gates have time to flow from the spawn frontier
        // forward to the camera before the actual audio onset.
        guard var state = root.components[SlipstreamRootComponent.self] else { return }

        // Prefer drum-isolated onsets when stems are available — full-mix
        // `frame.onset` fires on any energy spike (guitar strums, sustained
        // loud passages) which produces a wall of gates with no rhythmic
        // grid. Drum-isolated onsets fire only on actual percussive events.
        // Same pattern dodec uses for its disco-ball flash trigger.
        // Falls back to frame.onset when stems aren't loaded yet (first
        // 30-60s of a never-heard song).
        let drumsOnset: [Bool]? = stemFeatures?.stems["drums"]?.onset

        if state.lastSeenResetCounter != appResetCounter {
            // Track change: DEACTIVATE every gate slot in place (no child
            // removal — keeps the scene graph stable so the render thread
            // can't race a removeFromParent). The fog sphere + vocal glow
            // carry no gate component, so they're untouched. Animate resets
            // the fog's smoothing state separately.
            for child in root.children
                where child.components[SlipstreamGateComponent.self] != nil
            {
                deactivateGate(child)
            }
            state.lastSeenFrameIndex = frames.count
            state.liveGateCount = 0
            state.lastSeenResetCounter = appResetCounter
        }

        let upper: Int
        if let bound = playbackUpperBoundFrame {
            upper = min(frames.count, max(0, bound))
        } else {
            upper = frames.count
        }
        guard upper > state.lastSeenFrameIndex else {
            root.components.set(state)
            return
        }

        // The fixed pool, gathered once. Slot for onset N is
        // `liveGateCount % cap` — round-robin, so the oldest-spawned slot is
        // the next reused (it has almost always already flowed past the
        // camera and deactivated). When onset density genuinely exceeds the
        // cap, the oldest in-flight gate is silently repurposed — the same
        // behaviour as the old count-cap eviction, with zero scene mutation.
        let gates = root.children.filter {
            $0.components[SlipstreamGateComponent.self] != nil
        }
        let cap = gates.count
        guard cap > 0 else {
            root.components.set(state)
            return
        }

        let glow = sharedGlowTexture()
        var spawnedThisTick = 0
        for k in state.lastSeenFrameIndex..<upper {
            // Drum-isolated onset preferred; fallback to full-mix when
            // stems aren't available or this frame is out of stem range.
            // STEM TIME ALIGNMENT: stem arrays are indexed by SONG TIME
            // (sidecar processed the full song file), but `k` is a LIVE
            // FRAME INDEX (frames captured since system audio turned on).
            // Add stemFrameOffset to translate. See appModel.stemFrameOffset
            // docs for the math.
            let stemIdx = k + stemFrameOffset + stemSyncCompensationFrames
            let triggered: Bool
            if let drumsOnset, stemIdx >= 0, stemIdx < drumsOnset.count {
                triggered = drumsOnset[stemIdx]
            } else {
                triggered = frames[k].onset
            }
            if triggered {
                // Reconfigure the pool slot at `liveGateCount % cap` in
                // place — record current corridor odometer so this gate's Z
                // starts at -spawnDistance regardless of how far the corridor
                // has already flowed. No addChild/removeFromParent; the cap
                // is now the fixed pool size, so the old count-based eviction
                // loop is gone.
                let slot = gates[state.liveGateCount % cap]
                configureGate(
                    slot,
                    frame: frames[k],
                    glow: glow,
                    spawnedOdometer: state.corridorOdometer
                )
                slot.position.z = -spawnDistance
                state.liveGateCount += 1
                spawnedThisTick += 1
                // Onset pulse — each new onset bumps the pulse value,
                // which decays over ~0.14s and is applied as a scale-pop
                // on every live gate in animate(). Cap at 1.2 so a burst
                // of back-to-back onsets doesn't accumulate into a giant
                // scale spike.
                state.onsetPulse = min(1.2, state.onsetPulse + 0.9)
            }
        }
        state.lastSeenFrameIndex = upper
        root.components.set(state)
        _ = spawnedThisTick  // retained for future diagnostic logging; see slipLog
    }

    /// Build one gate entity (a stack of 1-3 concentric rings of glow-
    /// particles) for a single onset frame.
    @MainActor
    private static func spawnGate(
        frame: FeatureFrame,
        glow: TextureResource,
        spawnedOdometer: Float
    ) -> Entity {
        let radius = baseRadius + Float(frame.loudness) * radiusGain
        // Harmonic complexity ∈ [0, 1] → 1..3 nested rings. Rich chords
        // make the gate read as a "flower" of stacked rings; simple notes
        // give a single clean perimeter.
        let nestedRingCount = 1 + Int((frame.harmonicComplexity * 2).rounded())

        let gate = Entity()
        gate.components.set(SlipstreamGateComponent(
            spawnTime: frame.time,
            spawnedOdometer: spawnedOdometer,
            baseRadius: radius,
            hue: Float(frame.color.hue),
            loudness: Float(frame.loudness),
            harmonicComplexity: Float(frame.harmonicComplexity)
        ))

        for ringIdx in 0..<nestedRingCount {
            // Inner rings step inward by 18% of the previous radius.
            // 3 nested rings give radii of 1.0R, 0.82R, 0.67R — visibly
            // distinct concentric circles, not blurred together.
            let ringR = radius * (1.0 - Float(ringIdx) * 0.18)
            let ringEnt = makeRingEntity(
                radius: ringR,
                hue: Float(frame.color.hue),
                loudness: Float(frame.loudness),
                glow: glow
            )
            gate.addChild(ringEnt)
        }

        return gate
    }

    /// Build a single ring entity: a circle of camera-facing billboard
    /// quads with the shared alpha-glow texture. One `ModelEntity` carrying
    /// a `MeshInstancesComponent` so the N particles render as instances
    /// of one quad mesh — same pattern Rings uses for its 16x200 grid.
    @MainActor
    private static func makeRingEntity(
        radius: Float,
        hue: Float,
        loudness: Float,
        glow: TextureResource
    ) -> ModelEntity {
        let ent = buildEmptyRing()
        configureRing(ent, radius: radius, hue: hue, loudness: loudness, glow: glow)
        return ent
    }

    /// Build the bare ring skeleton — quad mesh + BillboardComponent +
    /// placeholder material — with no per-onset appearance. `configureRing`
    /// fills in the material + instanced particle transforms.
    @MainActor
    private static func buildEmptyRing() -> ModelEntity {
        let mesh = makeQuadMesh(size: particleSize)
        let ent = ModelEntity(mesh: mesh, materials: [UnlitMaterial()])
        // BillboardComponent: each particle always faces the camera, so
        // the glow texture reads as a soft round dot from any angle —
        // critical because the camera moves along Z and we don't want
        // particles to disappear edge-on as they pass.
        ent.components.set(BillboardComponent())
        return ent
    }

    /// Apply one onset's appearance to an existing ring entity: material
    /// (hue + loudness-driven HDR) + a fresh ring of `particleCount`
    /// instanced billboard transforms at `radius`. Pure component updates —
    /// safe to call from the render tick (no scene-graph structural change).
    @MainActor
    private static func configureRing(
        _ ent: ModelEntity,
        radius: Float,
        hue: Float,
        loudness: Float,
        glow: TextureResource
    ) {
        // Particle count scales with loudness — loud onsets feel denser.
        let particleCount = particleBase + Int(loudness * Float(particleGain))

        // HDR boost: loud onsets push past SDR white more aggressively,
        // driving the micro-OLED's optical bloom on visionOS and pushing
        // past CIBloom's threshold on macOS. Quiet onsets stay near SDR
        // brightness so they read as soft glow rather than blinding rings.
        let hdrBoost: CGFloat = 1.4 + CGFloat(loudness) * 0.9
        let tint = PlatformColor.hdrColor(
            hue: CGFloat(hue),
            saturation: 0.88,
            brightness: 0.92,
            hdrBoost: hdrBoost
        )

        var material = UnlitMaterial()
        material.color = .init(tint: tint, texture: .init(glow))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        // No depth-write — overlapping rings (when gates stack densely)
        // would Z-fight against each other and produce visible flicker
        // on the inner-ring edges. Additive-style soft overlap is the
        // visual goal anyway.
        material.writesDepth = false
        ent.model?.materials = [material]

        var instances = MeshInstancesComponent()
        do {
            let data = try LowLevelInstanceData(instanceCount: particleCount)
            data.withMutableTransforms { transforms in
                for p in 0..<particleCount {
                    let a = Float(p) / Float(particleCount) * 2 * .pi
                    var t = Transform()
                    t.translation = SIMD3<Float>(cos(a) * radius, sin(a) * radius, 0)
                    transforms[p] = t.matrix
                }
            }
            instances[partIndex: 0] = .init(data: data)
        } catch {
            print("SlipstreamVisualizer: LowLevelInstanceData init failed: \(error)")
        }
        ent.components.set(instances)
    }

    // MARK: - Live recycle pool (gate build / configure / free)

    /// Build one inactive pool gate: a parent Entity with `maxNestedRings`
    /// ring children, all disabled, plus an inactive SlipstreamGateComponent.
    /// `configureGate` activates and dresses it per onset. Live mode only.
    @MainActor
    private static func buildEmptyGate(glow: TextureResource) -> Entity {
        let gate = Entity()
        var comp = SlipstreamGateComponent(
            spawnTime: 0,
            spawnedOdometer: 0,
            baseRadius: baseRadius,
            hue: 0,
            loudness: 0,
            harmonicComplexity: 0
        )
        comp.active = false
        gate.components.set(comp)
        gate.isEnabled = false
        for _ in 0..<maxNestedRings {
            let ring = buildEmptyRing()
            ring.isEnabled = false
            gate.addChild(ring)
        }
        return gate
    }

    /// Dress an existing pool gate for one onset frame, in place: set its
    /// SlipstreamGateComponent (active), enable it, reset any leftover pulse
    /// scale, and configure / enable exactly `nestedRingCount` ring children
    /// (disabling the rest). No add/removeFromParent. MUST fully overwrite
    /// every visual the prior occupant set.
    @MainActor
    private static func configureGate(
        _ gate: Entity,
        frame: FeatureFrame,
        glow: TextureResource,
        spawnedOdometer: Float
    ) {
        let radius = baseRadius + Float(frame.loudness) * radiusGain
        // Harmonic complexity ∈ [0, 1] → 1..3 nested rings.
        let nestedRingCount = 1 + Int((frame.harmonicComplexity * 2).rounded())

        var comp = SlipstreamGateComponent(
            spawnTime: frame.time,
            spawnedOdometer: spawnedOdometer,
            baseRadius: radius,
            hue: Float(frame.color.hue),
            loudness: Float(frame.loudness),
            harmonicComplexity: Float(frame.harmonicComplexity)
        )
        comp.active = true
        gate.components.set(comp)
        gate.isEnabled = true
        // Clear any pulse-scale left on the slot by its prior occupant;
        // animate sets the live pulse scale next tick.
        gate.scale = SIMD3<Float>(repeating: 1)

        let rings = gate.children
        for ringIdx in 0..<rings.count {
            guard let ring = rings[ringIdx] as? ModelEntity else { continue }
            if ringIdx < nestedRingCount {
                // Inner rings step inward by 18% of the previous radius.
                let ringR = radius * (1.0 - Float(ringIdx) * 0.18)
                configureRing(
                    ring,
                    radius: ringR,
                    hue: Float(frame.color.hue),
                    loudness: Float(frame.loudness),
                    glow: glow
                )
                ring.isEnabled = true
            } else {
                ring.isEnabled = false
            }
        }
    }

    /// Free a pool gate without removing it from the scene: mark its
    /// component inactive and disable it. `animate` then skips it and
    /// `configureGate` can reclaim it on a later onset. The core of the
    /// no-structural-mutation render-crash fix.
    @MainActor
    private static func deactivateGate(_ gate: Entity) {
        if var comp = gate.components[SlipstreamGateComponent.self] {
            comp.active = false
            gate.components.set(comp)
        }
        gate.isEnabled = false
    }

    // MARK: - Animate (per-frame)

    /// Advance the corridor: update each gate's Z based on its age, evict
    /// gates past the eviction threshold, drive the reactive fog from
    /// the current frame's chromagram, and pass through the track-
    /// change reset signal (so even preview-mode callers — which don't
    /// run `scanForNewOnsets` — still respond to live-mode resets).
    @MainActor
    static func animate(
        _ root: Entity,
        clock: Double,
        frames: [FeatureFrame],
        deltaTime: Double,
        appResetCounter: Int = -1,
        bpmOverride: Float? = nil,
        danceabilityOverride: Float? = nil,
        aggressivenessOverride: Float? = nil,
        happinessOverride: Float? = nil,
        timbreBrightnessOverride: Float? = nil,
        stemFeatures: StemSeparationResult? = nil,
        stemFrameOffset: Int = 0
    ) {
        guard var state = root.components[SlipstreamRootComponent.self] else { return }

        // Track-change reset (live mode only). Same shape as Cloud/Rings:
        // when appResetCounter >= 0 and differs from stored counter,
        // wipe all gates (but KEEP the fog sphere — it's still the
        // backdrop for the next song). In preview mode the caller passes
        // -1 (default) and this is skipped.
        if appResetCounter >= 0 && appResetCounter != state.lastSeenResetCounter {
            for child in root.children
                where child.components[SlipstreamGateComponent.self] != nil
            {
                // Live pool: free the slot in place (no scene mutation).
                // Preview: gates are transient, remove as before.
                if state.isLivePool {
                    deactivateGate(child)
                } else {
                    child.removeFromParent()
                }
            }
            state.lastSeenFrameIndex = frames.count
            state.liveGateCount = 0
            state.lastSeenResetCounter = appResetCounter
            // Reset fog smoothing so the new song's first hue lerps
            // from itself instead of from the prior song's last value
            // (would cause a visible slide through unrelated hues for
            // ~1s after every track change — same fix Rings has).
            state.fogHueInitialized = false
            state.fogLoudnessSmoothed = 0
            // Reset corridor odometer + speed activity so the new song
            // starts at zero flow — without this, the post-reset gates'
            // spawnedOdometer (set to the current corridorOdometer) would
            // be a huge number and their Z math would still work but the
            // numbers would drift unboundedly across many song changes.
            // Reset onsetPulse so a lingering pulse from the prior song
            // doesn't pop the (now empty) corridor on track change.
            state.corridorOdometer = 0
            state.smoothedSpeedActivity = 0
            state.onsetPulse = 0
            // Reset beat-kick state so a lingering kick from the prior
            // song's last beat doesn't lurch the (newly reset) corridor.
            state.beatKickEnergy = 0
            state.lastScannedBeatIndex = -1
            // Reset throttle anchors so new song's first frame
            // unconditionally rebuilds materials.
            state.lastAppliedOrbHDR = .nan
            state.lastAppliedOrbHue = .nan
            state.smoothedVocalPitchHue = .nan
            state.lastAppliedFogBrightness = .nan
            state.lastAppliedFogHue = .nan
            // Reset vocal-source glow smoothing so it doesn't carry the
            // previous song's vocal energy into the new song's silence.
            state.smoothedVocals = 0
            state.vocalAttackEnergy = 0
            state.lastScannedVocalIndex = -1
            state.smoothedVocalPitchY = 0
            // Force first-tick reinit on next call so the post-reset
            // odometer baseline aligns with the new clock.
            state.firstAnimateTick = true
            root.components.set(state)
            return
        }

        // First-tick initialization: align corridorOdometer with the
        // current clock × forwardSpeed so preview-mode gates (whose
        // spawnedOdometer = frame.time × forwardSpeed) show up at the
        // correct Z immediately, even if the scene was created at a
        // non-zero clock value. Without this, the first frame would
        // render all preview gates at their "clock=0" positions and
        // then snap forward by `clock × forwardSpeed` on the second
        // tick — visible as a one-frame teleport.
        if state.firstAnimateTick {
            state.corridorOdometer = Float(max(0, clock)) * forwardSpeed
            state.firstAnimateTick = false
        }

        // Per-song character overrides resolved once per tick.
        // Tempo: octave-folded BPM scales the base forward speed. 100 BPM
        // = neutral 1.0×; clamp to [0.6, 1.6] so slow songs don't stall
        // and fast songs don't blur. Same pattern dodec uses.
        let tempoMul: Float = {
            guard let raw = bpmOverride else { return 1.0 }
            let folded = BeatHelpers.octaveFoldBpm(raw)
            return max(0.6, min(1.6, folded / 100.0))
        }()
        // Danceability scales the onsetPulse target — high-dance tracks
        // make the corridor breathe harder on each onset.
        let danceMul: Float = {
            guard let d = danceabilityOverride else { return 1.0 }
            return 0.6 + (d / 100.0) * 0.8  // 0.6–1.4
        }()
        // Aggressiveness scales the beat-kick amplitude — aggressive
        // tracks have punchier on-beat acceleration.
        let aggroMul: Float = {
            guard let a = aggressivenessOverride else { return 1.0 }
            return 0.6 + (a / 100.0) * 1.2  // 0.6–1.8
        }()
        // Happiness biases fog hue toward warm (gold ~0.10) for happy
        // or cool (indigo ~0.72) for sad. Applied as a constant offset
        // pull on fogHueSmoothed below.
        let happyBias = clamp01(((happinessOverride ?? 50) - 50) / 50)  // -1..+1
        let warmHue: Float = 0.10
        let coolHue: Float = 0.72
        let moodTargetHue: Float = happyBias >= 0 ? warmHue : coolHue
        let moodHuePull: Float = abs(happyBias) * 0.25  // 0–0.25 strength
        // Timbre brightness boosts fog brightness gain.
        let timbreMul: Float = {
            guard let t = timbreBrightnessOverride else { return 1.0 }
            return 0.7 + (t / 100.0) * 0.6  // 0.7–1.3
        }()

        // Compute current frame's energy for the speed-reactivity loop
        // (also reused below for the fog). Reading frames[i] once.
        let currentLoudness: Float
        if !frames.isEmpty {
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            currentLoudness = Float(frames[i].loudness)
        } else {
            currentLoudness = 0
        }

        // Beat-trigger scan: walk new frames since lastScannedBeatIndex
        // and bump beatKickEnergy on any beat trigger. Single envelope
        // (most-recent beat wins). Decay at 4 Hz — slower than the
        // onsetPulse (5 Hz) so the kick lingers a touch into the next
        // beat for a more "pumping" feel.
        //
        // Amplitude: when stems are available, use drums.loudness at
        // the beat frame instead of a flat 1.0 — quiet drums (verse,
        // breakdown) give a subtle kick; loud drums (chorus, drop)
        // give a punchy lurch. Falls back to 1.0 when no stems. Same
        // clamp range (0.4-1.0) dodec uses so quiet kicks still
        // register visibly.
        let drumsLoudness: [Float]? = stemFeatures?.stems["drums"]?.loudness
        if !frames.isEmpty {
            let currentIdx = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let startIdx = max(0, min(currentIdx, state.lastScannedBeatIndex + 1))
            if currentIdx >= startIdx {
                for i in startIdx...currentIdx {
                    if frames[i].beat.beatTrigger {
                        let kickStrength: Float
                        // Stem-time offset: i is live-frame index, stems
                        // are song-time indexed. See appModel.stemFrameOffset.
                        let stemI = i + stemFrameOffset + stemSyncCompensationFrames
                        if let drumsLoudness, stemI >= 0, stemI < drumsLoudness.count {
                            kickStrength = min(1.0,
                                max(0.4, drumsLoudness[stemI] * 4.0))
                        } else {
                            kickStrength = 1.0
                        }
                        state.beatKickEnergy = max(state.beatKickEnergy, kickStrength)
                    }
                }
            }
            state.lastScannedBeatIndex = currentIdx
        }
        let beatDecayFactor = Float(exp(-Double(4.0) * deltaTime))
        state.beatKickEnergy *= beatDecayFactor

        // Vocal-source glow update. Read vocals.loudness at the current
        // playback frame, smooth at vocalGlowSmoothRate Hz (slow enough
        // that the glow swells with phrasing rather than strobing on
        // consonants), and push to the glow entity's scale + material
        // HDR boost. When no vocals stem available (instrumental song
        // or pre-stem-load), smoothedVocals stays at 0 and the glow
        // sits at its baseline size + HDR.
        let vocalsLoudness: [Float]? = stemFeatures?.stems["vocals"]?.loudness
        let vocalsTarget: Float = {
            guard let vocalsLoudness, !frames.isEmpty else { return 0 }
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let stemI = i + stemFrameOffset + stemSyncCompensationFrames
            guard stemI >= 0, stemI < vocalsLoudness.count else { return 0 }
            // Clamp to [0, 1] — vocals.loudness is RMS-like and rarely
            // exceeds 1.0 but the clamp is cheap insurance against the
            // bass-RMS-spike issue we hit on Slipstream's first stems pass.
            return min(1.0, max(0, vocalsLoudness[stemI] * 4.0))
        }()
        let vocalsLerp = Float(min(1.0, deltaTime * Double(vocalGlowSmoothRate)))
        state.smoothedVocals += (vocalsTarget - state.smoothedVocals) * vocalsLerp

        // Vocal-attack scan: walk new vocals.onset entries and bump the
        // attack envelope on each. Single envelope, most-recent wins.
        // Drives a brief scale POP + brightness flash on the orb so
        // phrase entries / consonant attacks ARTICULATE as discrete
        // events, distinct from the held smoothedVocals sustain.
        //
        // BLEED FILTER: demucs' vocal stem isn't perfectly clean —
        // drum hits (especially snare) often produce small spikes in
        // vocals.onset. Gate the onset by requiring vocals.loudness
        // at the same stem frame to exceed `vocalOnsetLoudnessFloor`
        // (i.e., the singer is actually present, not just a percussion
        // crackle bleeding through). Without this filter the orb pops
        // on every snare hit.
        let vocalsOnset: [Bool]? = stemFeatures?.stems["vocals"]?.onset
        let vocalOnsetLoudnessFloor: Float = 0.03
        if let vocalsOnset, !frames.isEmpty {
            let currentIdx = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let startIdx = max(0, min(currentIdx, state.lastScannedVocalIndex + 1))
            if currentIdx >= startIdx {
                for i in startIdx...currentIdx {
                    let stemI = i + stemFrameOffset + stemSyncCompensationFrames
                    guard stemI >= 0, stemI < vocalsOnset.count else { continue }
                    if vocalsOnset[stemI] {
                        // Bleed filter: only count if the vocal channel
                        // actually has energy at this frame.
                        let loudHere: Float = {
                            guard let vl = vocalsLoudness,
                                  stemI < vl.count else { return 0 }
                            return vl[stemI]
                        }()
                        if loudHere >= vocalOnsetLoudnessFloor {
                            state.vocalAttackEnergy = 1.0
                        }
                    }
                }
            }
            state.lastScannedVocalIndex = currentIdx
        }
        let vocalAttackDecayFactor = Float(exp(-Double(vocalAttackDecay) * deltaTime))
        state.vocalAttackEnergy *= vocalAttackDecayFactor

        // Pitch-driven Y motion. Use the vocals.chromagram argmax to find
        // the dominant vocal pitch class at the current frame, then map
        // it linearly to a Y offset around the orb's centerline. The orb
        // literally rises/falls with the singer's melody — a held high
        // note keeps the orb up; descending phrases pull it down. Smooth
        // at vocalPitchSmoothRate Hz so legato melodic motion reads as
        // continuous gesture, not strobing per-frame.
        let vocalsChroma: [[Float]]? = stemFeatures?.stems["vocals"]?.chromagram
        // Compute argmax once and reuse it for BOTH pitch-Y motion
        // and pitch-driven hue. -1 = no meaningful pitch present
        // (silent / instrumental). Saves a redundant chromagram read.
        let dominantPitch: Int = {
            guard let vocalsChroma, !frames.isEmpty else { return -1 }
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let stemI = i + stemFrameOffset + stemSyncCompensationFrames
            guard stemI >= 0, stemI < vocalsChroma.count,
                  vocalsChroma[stemI].count == 12 else { return -1 }
            let row = vocalsChroma[stemI]
            let sum = row.reduce(0, +)
            guard sum > 0.001 else { return -1 }
            var maxIdx = 0
            var maxVal = row[0]
            for k in 1..<12 where row[k] > maxVal {
                maxVal = row[k]
                maxIdx = k
            }
            return maxIdx
        }()

        // Pitch-Y target: pitch class 0..11 → -0.5..+0.5 → ±vocalPitchYRange/2.
        // The 12 pitch classes wrap (B → C jumps from +0.5 to -0.5),
        // but at melodic timescales sequential notes rarely jump a
        // full octave, so the wrap rarely fires visibly.
        let pitchYTarget: Float = dominantPitch >= 0
            ? (Float(dominantPitch) / 11.0 - 0.5) * vocalPitchYRange
            : state.smoothedVocalPitchY  // hold position when silent
        let pitchLerp = Float(min(1.0, deltaTime * Double(vocalPitchSmoothRate)))
        state.smoothedVocalPitchY += (pitchYTarget - state.smoothedVocalPitchY) * pitchLerp

        // Pitch-driven hue: pitch class 0..11 → hue 0..1 (chromatic
        // wheel). Circular lerp at vocalGlowPitchHueSmoothRate so the
        // color phrases smoothly with the melodic line without
        // strobing on consonant transients. When silent or no stems,
        // hue drifts toward the warm-amber fallback (vocalGlowHue)
        // so the orb still looks like a "light source" between
        // vocal sections.
        let pitchHueTarget: Float = dominantPitch >= 0
            ? Float(dominantPitch) / 12.0
            : Float(vocalGlowHue)
        if state.smoothedVocalPitchHue.isNaN {
            state.smoothedVocalPitchHue = pitchHueTarget
        } else {
            // Circular lerp — shortest-arc on the [0, 1] hue ring.
            var diff = pitchHueTarget - state.smoothedVocalPitchHue
            if diff > 0.5 { diff -= 1 }
            if diff < -0.5 { diff += 1 }
            let hueLerp = Float(min(1.0, deltaTime * Double(vocalGlowPitchHueSmoothRate)))
            var next = state.smoothedVocalPitchHue + diff * hueLerp
            if next < 0 { next += 1 }
            if next >= 1 { next -= 1 }
            state.smoothedVocalPitchHue = next
        }

        // Smoothed speed-activity lerps toward current loudness at 1.5 Hz.
        // Faster than fog (where 4 Hz is fine because it's a color drift)
        // would be — but slower than the fog brightness (3 Hz) — because
        // a flicker on SPEED reads as a stutter, while a flicker on color
        // reads as reactivity. 1.5 Hz feels like "the corridor accelerates
        // into the heavy section, eases out of it."
        let speedLerp = Float(min(1.0, deltaTime * 1.5))
        state.smoothedSpeedActivity +=
            (currentLoudness - state.smoothedSpeedActivity) * speedLerp

        // Effective speed = base × tempo × (floor + activity × gain +
        // beatKick × aggro). Three modulations on the base forwardSpeed:
        //   1. tempoMul — per-song scaling so fast songs flow faster
        //   2. smoothedSpeedActivity — current loudness drives steady-
        //      state acceleration (existing reactivity)
        //   3. beatKick × aggroMul — transient acceleration ON each
        //      beat trigger. Aggressive songs pump harder.
        //
        // speedFloor bumped 0.5 → 0.7 on 2026-05-22 to fix FPS drift —
        // at 0.5 floor, quiet passages slowed the corridor enough that
        // gates persisted ~15s each, accumulating to 30-45 simultaneously
        // and dragging FPS from 60 to 30-40. 0.7 floor caps gate lifetime
        // closer to the original 7.5s baseline at quiet sections.
        let speedFloor: Float = 0.7
        let speedGain: Float = 5.0
        let beatKickGain: Float = 0.6  // peak transient add at beatKick=1
        let bassSpeedGain: Float = 4.0  // bass.loudness multiplier on top of base

        // Bass-loudness as an ADDITIONAL forward-speed term. When stems
        // are available, the bass channel's loudness adds groove-driven
        // momentum on top of the full-mix smoothed activity. Bass-heavy
        // sections (verses with riding bass, dubby choruses) make the
        // corridor flow visibly faster even when the full-mix loudness
        // is moderate. Falls back to 0 contribution when no stems —
        // the existing smoothedSpeedActivity term carries baseline
        // reactivity in that case.
        let bassLoudness: [Float]? = stemFeatures?.stems["bass"]?.loudness
        let bassContribution: Float = {
            guard let bassLoudness, !frames.isEmpty else { return 0 }
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let stemI = i + stemFrameOffset + stemSyncCompensationFrames
            guard stemI >= 0, stemI < bassLoudness.count else { return 0 }
            // Clamp to avoid runaway speeds on bass-RMS spikes
            // (similar to the bandLoudness clamp lesson from Architecture).
            return min(1.0, max(0, bassLoudness[stemI] * bassSpeedGain))
        }()

        let effectiveSpeed = forwardSpeed * tempoMul
            * (speedFloor + state.smoothedSpeedActivity * speedGain
               + state.beatKickEnergy * beatKickGain * aggroMul
               + bassContribution)

        // Advance corridor odometer by the effective speed × dt.
        state.corridorOdometer += effectiveSpeed * Float(deltaTime)

        // Decay onset pulse exponentially. Decay rate 5/sec gives a
        // half-life of ~0.14s — a quick percussive shimmer, not a long
        // afterglow. The pulse is bumped to ~1.0 in scanForNewOnsets
        // when a new onset arrives.
        state.onsetPulse *= exp(-Float(deltaTime) * 5.0)
        // Apply pulse as a uniform scale-pop on every live gate so each
        // new onset reverberates through the entire corridor, not just
        // spawns one gate at the front. Max boost ~×1.18 at peak pulse
        // (neutral danceability) — visible as a brief "the corridor
        // breathes." Danceability scales the boost magnitude: high-dance
        // songs (D=100) push to ~×1.25 at peak; low-dance (D=0) settle
        // around ×1.11. Visible difference between Skinny Puppy
        // (industrial, modest dance) and a disco track.
        let pulseScale = 1.0 + state.onsetPulse * 0.18 * danceMul

        // Walk all gates: position update via odometer + eviction in one
        // pass. Skip the fog sphere and any other future non-gate child.
        var toEvict: [Entity] = []
        for child in root.children {
            guard let gc = child.components[SlipstreamGateComponent.self] else { continue }
            // Live pool: skip free slots (inactive — already flowed past the
            // camera or reset). Preview gates are always active.
            guard gc.active else { continue }
            let z = -spawnDistance + (state.corridorOdometer - gc.spawnedOdometer)
            if z > evictionThreshold {
                // Live pool: free the slot in place (no removeFromParent —
                // the render-crash fix). Preview: collect for removal.
                if state.isLivePool {
                    deactivateGate(child)
                } else {
                    toEvict.append(child)
                }
                continue
            }
            child.position.z = z
            // Apply onset pulse uniformly to every live gate. Scaling
            // the gate ENTITY (not its individual ring children) propagates
            // through the 1-3 nested rings inside cleanly.
            child.scale = SIMD3<Float>(repeating: pulseScale)
        }
        for ent in toEvict {
            ent.removeFromParent()
        }

        // --- Reactive fog ---------------------------------------------
        // Soft ambient color that drifts with the current chromagram —
        // fills the in-between moments when no onset is firing, so the
        // corridor never feels totally dark. Smoothing is slow (~1.5 Hz
        // on hue, ~3 Hz on loudness) so the fog feels like a held breath
        // rather than a strobe. Saturation low + brightness dim so the
        // fog is an ambient presence, not a competing focal point.
        if !frames.isEmpty {
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            let f = frames[i]
            // Fog hue source: prefer bass.chromagram when stems
            // available — the bass line carries the harmonic
            // foundation cleanly without drum-onset noise that muddies
            // the full-mix chromagram. Bass usually plays one note at
            // a time, so argmax is a robust pitch detector. Falls back
            // to full-mix `f.color.hue` (TonalColor's weighted hue
            // estimate) when no bass stem yet (instrumental song
            // sections without bass, or pre-stem-load).
            let bassChroma: [[Float]]? = stemFeatures?.stems["bass"]?.chromagram
            let targetHue: Float = {
                guard let bassChroma else { return Float(f.color.hue) }
                let stemI = i + stemFrameOffset + stemSyncCompensationFrames
                guard stemI >= 0, stemI < bassChroma.count,
                      bassChroma[stemI].count == 12 else {
                    return Float(f.color.hue)
                }
                let row = bassChroma[stemI]
                let sum = row.reduce(0, +)
                guard sum > 0.001 else { return Float(f.color.hue) }
                var maxIdx = 0
                var maxVal = row[0]
                for k in 1..<12 where row[k] > maxVal {
                    maxVal = row[k]
                    maxIdx = k
                }
                return Float(maxIdx) / 12.0
            }()
            let targetLoudness = Float(f.loudness)

            if !state.fogHueInitialized {
                state.fogHueSmoothed = targetHue
                state.fogHueInitialized = true
            } else {
                // Circular hue lerp — pick the shorter direction around
                // the color wheel. Identical to Rings' hue smoothing
                // logic so chord-driven hue jumps don't slide through
                // unrelated colors.
                //
                // Lerp rate bumped 1.5 → 4.0 Hz on 2026-05-22 after
                // observing the fog stayed mostly blue across songs
                // with wildly different chromagrams. Streaming-analyzer
                // log showed hue values bouncing across 0.24-0.93
                // every few frames; with 1.5Hz smoothing the EMA
                // gravitated toward the ~0.55 average (cyan/blue).
                // 4Hz tracks the chromagram visibly without strobing.
                var diff = targetHue - state.fogHueSmoothed
                if diff > 0.5 { diff -= 1.0 }
                else if diff < -0.5 { diff += 1.0 }
                let hueLerp = Float(min(1.0, deltaTime * 4.0))
                var next = state.fogHueSmoothed + diff * hueLerp
                if next < 0 { next += 1 }
                if next >= 1 { next -= 1 }
                state.fogHueSmoothed = next
            }

            let loudLerp = Float(min(1.0, deltaTime * 3.0))
            state.fogLoudnessSmoothed +=
                (targetLoudness - state.fogLoudnessSmoothed) * loudLerp

            // Update the fog material. Looking up by component is O(N)
            // in children but N is small (~30 gates + 1 fog sphere) and
            // this is one query per frame — cheap.
            //
            // Alpha-blending: setting `material.blending = .transparent(...)`
            // in makeFogSphere alone was visually a no-op — fog kept
            // rendering at full opacity (theory: the property doesn't
            // survive `modelComp.materials.first as? UnlitMaterial` →
            // `modelComp.materials[0] = mat` reassign on macOS). Fix:
            // bake alpha into the TINT color AND re-set the blending
            // mode every tick. Belt and suspenders — one of them takes.
            for child in root.children
                where child.components[SlipstreamFogComponent.self] != nil
            {
                guard let model = child as? ModelEntity,
                      var modelComp = model.components[ModelComponent.self],
                      var mat = modelComp.materials.first as? UnlitMaterial
                else { continue }
                // Mood hue bias: pull the smoothed chromagram-derived
                // hue toward warm (gold) for happy / cool (indigo) for
                // sad. moodHuePull is 0 at neutral happiness; up to
                // 0.25 at the extremes. Keeps the chromagram's tonal
                // motion visible while shifting the overall feel.
                var displayedHue = state.fogHueSmoothed
                if moodHuePull > 0 {
                    var diff = moodTargetHue - displayedHue
                    if diff > 0.5 { diff -= 1 }
                    if diff < -0.5 { diff += 1 }
                    displayedHue += diff * moodHuePull
                    if displayedHue < 0 { displayedHue += 1 }
                    if displayedHue >= 1 { displayedHue -= 1 }
                }
                // Timbre brightness scales the brightness gain — bright-
                // timbre songs (T=100) push fog brighter (1.3×); dark-
                // timbre songs (T=0) dim it (0.7×). Multiplies BOTH base
                // and gain components so the whole fog brightness curve
                // shifts.
                let brightness = (fogBaseBrightness
                    + fogLoudnessGain * CGFloat(state.fogLoudnessSmoothed))
                    * CGFloat(timbreMul)
                // Throttle material rebuild — skip the GPU upload
                // unless brightness or hue has meaningfully changed
                // since last applied. Saves ~60 material uploads/sec
                // on steady-state passages.
                let hueChanged = state.lastAppliedFogHue.isNaN
                    || min(abs(displayedHue - state.lastAppliedFogHue),
                           1 - abs(displayedHue - state.lastAppliedFogHue)) >= fogHueDelta
                let brightnessChanged = state.lastAppliedFogBrightness.isNaN
                    || abs(brightness - state.lastAppliedFogBrightness) >= fogBrightnessDelta
                if hueChanged || brightnessChanged {
                    let tint = PlatformColor(
                        hue: CGFloat(displayedHue),
                        saturation: fogBaseSaturation,
                        brightness: brightness,
                        alpha: fogAlpha
                    )
                    mat.color = .init(tint: tint)
                    mat.blending = .transparent(opacity: .init(floatLiteral: Float(fogAlpha)))
                    mat.writesDepth = false
                    modelComp.materials[0] = mat
                    model.components.set(modelComp)
                    state.lastAppliedFogBrightness = brightness
                    state.lastAppliedFogHue = displayedHue
                }
                break  // only one fog sphere
            }
        }

        // --- Vocal-source glow ---------------------------------------
        // Three behaviors combine here so the orb reads as a singer,
        // not just a light bulb:
        //   1. SUSTAIN — smoothedVocals drives steady scale + brightness
        //      across vowel bodies and held notes.
        //   2. ATTACK — vocalAttackEnergy adds a brief scale POP +
        //      brightness FLASH on each phrase entry / consonant onset.
        //      This is what makes it look like the orb is articulating
        //      syllables.
        //   3. PITCH MOTION — smoothedVocalPitchY shifts the orb's Y
        //      position with the melodic line. High notes = orb rises.
        //   4. BREATH — when not singing, slow Y bob so the orb feels
        //      "still there, breathing" rather than dead.
        for child in root.children
            where child.components[SlipstreamVocalGlowComponent.self] != nil
        {
            guard let model = child as? ModelEntity,
                  var modelComp = model.components[ModelComponent.self],
                  var mat = modelComp.materials.first as? UnlitMaterial
            else { continue }
            let v = state.smoothedVocals
            let a = state.vocalAttackEnergy
            // Scale: sustain (smoothedVocals) × attack pop.
            let sustainScale = 1.0 + v * (vocalGlowMaxScale - 1.0)
            let attackScale = 1.0 + a * vocalAttackScaleBoost
            let scale = sustainScale * attackScale
            // Position Y: pitch motion + breath idle.
            // Breath is suppressed when actively singing so the two
            // motions don't sum into a noisy wobble.
            let breathY: Float = v < vocalBreathSuppressThreshold
                ? Float(sin(clock * 2 * .pi * Double(vocalBreathRate))) * vocalBreathAmplitude
                : 0
            let posY = state.smoothedVocalPitchY + breathY
            child.position = [0, posY, vocalGlowZ]
            child.scale = SIMD3<Float>(repeating: scale)
            // HDR boost: baseline + sustain × peak + attack × flash.
            // Material rebuild + GPU upload is THROTTLED — only when
            // the HDR value shifts by more than `orbMaterialDelta`
            // since the last applied state. Previously this rebuilt
            // every animate tick (60Hz) and crushed FPS from 60 → 30
            // (with the fog doing the same pattern, ~120 GPU material
            // uploads per second). Scale + position above stay
            // per-frame because transform changes are cheap.
            let hdr = vocalGlowBaseHDR
                + CGFloat(v) * vocalGlowPeakHDR
                + CGFloat(a) * vocalAttackHDRBoost
            // Pitch-driven hue: the singer's melodic line colors the
            // orb. C → red, moving up the chromatic scale through the
            // color wheel. Saturation low-ish (vocalGlowSaturation)
            // so it still reads as "light source" rather than vivid
            // neon. Throttle rebuild on EITHER HDR delta OR hue delta
            // — both can change independently.
            let hue = state.smoothedVocalPitchHue
            let hdrChanged = state.lastAppliedOrbHDR.isNaN
                || abs(hdr - state.lastAppliedOrbHDR) >= orbMaterialDelta
            let hueChanged = state.lastAppliedOrbHue.isNaN
                || min(abs(hue - state.lastAppliedOrbHue),
                       1 - abs(hue - state.lastAppliedOrbHue)) >= orbHueDelta
            if hdrChanged || hueChanged {
                let tint = PlatformColor.hdrColor(
                    hue: CGFloat(hue),
                    saturation: vocalGlowSaturation,
                    brightness: 1.0,
                    hdrBoost: hdr
                )
                mat.color = .init(tint: tint, texture: .init(sharedGlowTexture()))
                mat.writesDepth = false
                modelComp.materials[0] = mat
                model.components.set(modelComp)
                state.lastAppliedOrbHDR = hdr
                state.lastAppliedOrbHue = hue
            }
            break  // only one vocal glow
        }

        root.components.set(state)
    }

    // MARK: - Quad mesh (XY plane facing +Z, billboarded at runtime)

    /// Build a unit-ish quad in the XY plane facing +Z. Same hand-rolled
    /// mesh Rings uses — `MeshResource.generatePlane` gives an XZ plane
    /// facing +Y, which is wrong orientation for our viewer-down-Z framing.
    private static func makeQuadMesh(size: Float) -> MeshResource {
        let h = size / 2
        let positions: [SIMD3<Float>] = [
            [-h, -h, 0], [ h, -h, 0], [ h,  h, 0], [-h,  h, 0]
        ]
        let normals: [SIMD3<Float>] = Array(repeating: [0, 0, 1], count: 4)
        // V-flipped UVs so the glow texture isn't upside-down — Core
        // Graphics draws Y-down, RealityKit samples Y-up.
        let texCoords: [SIMD2<Float>] = [
            [0, 1], [1, 1], [1, 0], [0, 0]
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]

        var descriptor = MeshDescriptor()
        descriptor.positions  = MeshBuffer(positions)
        descriptor.normals    = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generatePlane(width: size, height: size)
        }
    }

    // MARK: - Glow texture

    /// 128² alpha-gradient texture, white centre fading to transparent at
    /// the rim. Identical pattern to Rings + Clouds. Drawn once on first
    /// request, cached and shared across every ring's material.
    private static func makeGlowTexture() -> TextureResource {
        let size = 128
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let centre = CGPoint(x: size / 2, y: size / 2)
        let radius = CGFloat(size / 2)
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.45),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 0.35, 1.0]
        )!
        ctx.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: radius,
            options: []
        )

        return try! TextureResource(
            image: ctx.makeImage()!,
            withName: "slipstream-glow",
            options: .init(semantic: .color)
        )
    }

    /// Clamp a value to the [-1, 1] range. Used by mood-bias math
    /// in the per-song character overrides (happiness normalized
    /// around its neutral 50 → ±1).
    private static func clamp01(_ x: Float) -> Float {
        max(-1, min(1, x))
    }
}
