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
}

/// Tag for the fog backdrop entity so `animate` can find and update it
/// each tick. Identical pattern to Crystal's BeamRole / Architecture's
/// ArchRingComponent for tagged-entity lookups.
struct SlipstreamFogComponent: Component {}

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
        root.components.set(state)
        // Same fog backdrop as the preview path — animate() drives it
        // from `frames[playbackIndex]` each tick.
        root.addChild(makeFogSphere())
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
    static func scanForNewOnsets(_ root: Entity, frames: [FeatureFrame], appResetCounter: Int) {
        guard var state = root.components[SlipstreamRootComponent.self] else { return }

        if state.lastSeenResetCounter != appResetCounter {
            // Only wipe gates — keep the fog sphere so the backdrop
            // doesn't blink out at track change. Animate will reset
            // the fog's smoothing state separately.
            for child in root.children
                where child.components[SlipstreamGateComponent.self] != nil
            {
                child.removeFromParent()
            }
            state.lastSeenFrameIndex = frames.count
            state.liveGateCount = 0
            state.lastSeenResetCounter = appResetCounter
        }

        let upper = frames.count
        guard upper > state.lastSeenFrameIndex else {
            root.components.set(state)
            return
        }

        let glow = sharedGlowTexture()
        var spawnedThisTick = 0
        for k in state.lastSeenFrameIndex..<upper {
            if frames[k].onset {
                // Live spawn — record current corridor odometer so this
                // gate's Z starts at -spawnDistance regardless of how
                // far the corridor has already flowed.
                let gate = spawnGate(
                    frame: frames[k],
                    glow: glow,
                    spawnedOdometer: state.corridorOdometer
                )
                gate.position.z = -spawnDistance
                root.addChild(gate)
                state.liveGateCount += 1
                spawnedThisTick += 1
                // Onset pulse — each new onset bumps the pulse value,
                // which decays over ~0.14s and is applied as a scale-pop
                // on every live gate in animate(). Cap at 1.2 so a burst
                // of back-to-back onsets doesn't accumulate into a giant
                // scale spike.
                state.onsetPulse = min(1.2, state.onsetPulse + 0.9)

                // Safety cap. Z-based eviction in animate() handles
                // pruning naturally most of the time; this guards
                // against pathologically-dense onset streams AND
                // the speed-reactivity case where the corridor flows
                // slowly during quiet passages (gates live longer).
                //
                // CRITICAL: only evict GATE children. The fog sphere is
                // also a child of root and was added FIRST, so
                // `root.children.first` would always remove it before
                // any gate — destroying the backdrop after one cap-hit
                // session. Iterate looking for the first gate-tagged
                // child and remove that one.
                while root.children.count > liveModeGateCap {
                    var didEvict = false
                    for child in root.children
                        where child.components[SlipstreamGateComponent.self] != nil
                    {
                        child.removeFromParent()
                        didEvict = true
                        break
                    }
                    // No gates left to evict (only fog + non-gate children
                    // remain) — bail to avoid an infinite loop.
                    if !didEvict { break }
                }
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

        let mesh = makeQuadMesh(size: particleSize)
        let ent = ModelEntity(mesh: mesh, materials: [material])
        // BillboardComponent: each particle always faces the camera, so
        // the glow texture reads as a soft round dot from any angle —
        // critical because the camera moves along Z and we don't want
        // particles to disappear edge-on as they pass.
        ent.components.set(BillboardComponent())

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

        return ent
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
        appResetCounter: Int = -1
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
                child.removeFromParent()
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

        // Compute current frame's energy for the speed-reactivity loop
        // (also reused below for the fog). Reading frames[i] once.
        let currentLoudness: Float
        if !frames.isEmpty {
            let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
            currentLoudness = Float(frames[i].loudness)
        } else {
            currentLoudness = 0
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

        // Effective speed = base × (floor + activity × gain). At quiet
        // (activity ~0.03): forwardSpeed × (0.7 + 0.15) = 0.85× base.
        // At loud (activity ~0.15): forwardSpeed × (0.7 + 0.75) = 1.45×.
        // speedFloor bumped 0.5 → 0.7 on 2026-05-22 to fix FPS drift —
        // at 0.5 floor, quiet passages slowed the corridor enough that
        // gates persisted ~15s each, accumulating to 30-45 simultaneously
        // and dragging FPS from 60 to 30-40. 0.7 floor caps gate lifetime
        // closer to the original 7.5s baseline at quiet sections.
        let speedFloor: Float = 0.7
        let speedGain: Float = 5.0
        let effectiveSpeed = forwardSpeed
            * (speedFloor + state.smoothedSpeedActivity * speedGain)

        // Advance corridor odometer by the effective speed × dt.
        state.corridorOdometer += effectiveSpeed * Float(deltaTime)

        // Decay onset pulse exponentially. Decay rate 5/sec gives a
        // half-life of ~0.14s — a quick percussive shimmer, not a long
        // afterglow. The pulse is bumped to ~1.0 in scanForNewOnsets
        // when a new onset arrives.
        state.onsetPulse *= exp(-Float(deltaTime) * 5.0)
        // Apply pulse as a uniform scale-pop on every live gate so each
        // new onset reverberates through the entire corridor, not just
        // spawns one gate at the front. Max boost ~×1.18 at peak pulse —
        // visible as a brief "the corridor breathes" without disrupting
        // gate identity.
        let pulseScale = 1.0 + state.onsetPulse * 0.18

        // Walk all gates: position update via odometer + eviction in one
        // pass. Skip the fog sphere and any other future non-gate child.
        var toEvict: [Entity] = []
        for child in root.children {
            guard let gc = child.components[SlipstreamGateComponent.self] else { continue }
            let z = -spawnDistance + (state.corridorOdometer - gc.spawnedOdometer)
            if z > evictionThreshold {
                toEvict.append(child)
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
            let targetHue = Float(f.color.hue)
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
                let brightness = fogBaseBrightness
                    + fogLoudnessGain * CGFloat(state.fogLoudnessSmoothed)
                let tint = PlatformColor(
                    hue: CGFloat(state.fogHueSmoothed),
                    saturation: fogBaseSaturation,
                    brightness: brightness,
                    alpha: fogAlpha
                )
                mat.color = .init(tint: tint)
                mat.blending = .transparent(opacity: .init(floatLiteral: Float(fogAlpha)))
                mat.writesDepth = false
                modelComp.materials[0] = mat
                model.components.set(modelComp)
                break  // only one fog sphere
            }
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
}
