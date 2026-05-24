//
//  AmbientVisualizer.swift
//  High Videlity
//
//  Ambient — calm-cosmic counter-programming. Lake-and-sky composition.
//
//  Scene composition:
//    • **Lake** — a flat ground plane at y = groundY filled with hex tiles
//      glowing like water highlights at night. The lake is divided into 12
//      radial wedges (30° azimuth pie-slices around the viewer), each
//      assigned to one pitch class. When that pitch class is active in
//      the chromagram, all tiles in its wedge brighten in that pitch's
//      circle-of-fifths hue. The user can SEE which note is playing by
//      where the glow appears in the surrounding lake.
//    • **Sky** — an upper-hemisphere starfield far overhead (radius 25 m).
//      Stars are static points; on every onset the whole field pulses
//      brighter uniformly, decaying exponentially.
//    • **Lake highlights** — ~100 pale "starlight" tiles scattered across
//      the lake plane, modulated by smoothed timbre + the star pulse.
//      These give the water surface ambient texture between active wedges,
//      and read as moonlight glints / star reflections without needing
//      actual reflection math.
//
//  Audio → visual mapping:
//    • Chromagram bin k → wedge k brightness + opacity. Smoothed ~3 Hz.
//    • Onset → bump the dominant pitch class's wedge AND pulse the
//      starfield + lake-highlight tiles. Decay ~0.35–0.5 s half-life.
//    • Overall loudness → ±5% breath scale on the wedge cluster. Subtle.
//    • Timbre brightness → starfield + starlight-tile brightness.
//    • Track change → reset smoothing + pulse state; re-seed from current frame.
//
//  Why this fits the suite as the calm mode:
//    • Crystal/Clouds/Rings/Architecture/Slipstream all use volumes /
//      orbital layouts / forward-flight — vertical-ish, intimate. Ambient
//      is horizontal: a horizon. Nothing else in the suite has one.
//    • The chromagram-12 mapping is the same as the original Ambient
//      pitch (12 streaks); we just laid them down and turned them into
//      wedges of water. The same musical idea, visually transposed.
//
//  Implementation notes:
//    • All meshes are shared: one hex mesh, one star quad. Lessons from
//      [[realitykit-meshresource-retention]] apply directly — uniqueness
//      lives in per-spawn `entity.scale` via LowLevelInstanceData
//      transforms, never in per-spawn MeshResource.
//    • Per-tick material updates are tiny allocations (no MeshResource
//      churn). 14 material updates per tick (12 wedges + 1 sky + 1
//      starlight) is comfortable.
//    • LowLevelInstanceData carries transforms only — that's why each
//      wedge gets its OWN entity + material rather than one big tile
//      grid with per-tile color. Same pattern Rings uses for its
//      per-ring color animation.
//

import RealityKit
import RealityKitContent
import AudioAnalysis
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-root state for Ambient. Holds smoothed chromagram + per-wedge onset
/// pulses + loudness/timbre smoothing + the uniform star/sky onset pulse.
struct AmbientRootComponent: Component {
    /// EMA-smoothed chromagram bin weights (per-frame max-normalized).
    var smoothedChromagram: [Float] = .init(repeating: 0, count: 12)
    /// Per-pitch-class onset pulse. Bumped when an onset fires whose
    /// dominant pitch class is this index. Decays exponentially. Adds
    /// brightness on top of the chromagram contribution.
    var wedgePulses: [Float] = .init(repeating: 0, count: 12)
    /// Smoothed loudness — drives the subtle vertical "breath" on the
    /// whole wedge cluster. ±5%. Calm.
    var smoothedLoudness: Float = 0
    /// Smoothed timbre — drives starfield + lake-highlight base brightness.
    var smoothedTimbre: Float = 0
    /// Long-window loudness EMA → "song intensity" / "section energy"
    /// proxy. Much slower than `smoothedLoudness` (≈20 s settle time)
    /// so it averages across whole verses/choruses rather than tracking
    /// individual hits. Used in `applyStarfieldState` to scale how many
    /// stars bloom per beat — quiet verses bloom ~15% of the sky, loud
    /// choruses bloom up to ~85%. Reset on track change so a new song
    /// doesn't inherit the previous song's "we were in a chorus" state.
    var slowLoudness: Float = 0
    /// Derived intensity in [0, 1]. Computed each tick from
    /// `slowLoudness × intensityScale`, clamped. Cached so the apply
    /// functions don't re-do the math per child.
    var songIntensity: Float = 0
    /// Even-slower trailing EMA of intensity (~30 s settle) used as
    /// reference for chorus-drop detection. When current `songIntensity`
    /// jumps above this trailing baseline by more than the burst
    /// threshold, fires an all-stars burst (Tier C).
    var trailingIntensity: Float = 0
    /// Wall-clock-style time of last chorus-drop burst, for the burst's
    /// refractory window. Stored as `elapsedTime` value at trigger so
    /// it's track-relative (resets to -inf on track change so the
    /// first build-and-drop of a new song always gets to fire).
    var lastBurstTime: Float = -1000
    /// Modulo-4 counter incremented on every `beatTrigger` — 0 marks
    /// the downbeat (every 4th beat gets emphasized blooms). 4/4 is
    /// far and away the most common time signature in popular music;
    /// 3/4 tracks will get an off-rotating "phantom downbeat" but
    /// that's an acceptable degradation vs. doing real meter detection.
    var beatCounter: Int = 0
    /// Smoothed harmonic complexity (raw signal is twitchy). Drives
    /// star saturation — simple monophonic passages → stars stay
    /// cool-white; dense harmonized passages → stars take on more
    /// of the song's chromatic tint.
    var smoothedComplexity: Float = 0
    /// Uniform onset pulse for the lake-highlight ("starlight") tiles only.
    /// The SKY starfield now uses per-instance pulses on a random subset
    /// of stars per onset (see AmbientStarfieldComponent.pulses) rather
    /// than a uniform brightness flash. Jesse's call: "random stars that
    /// bloom rather than uniform."
    var starlightPulse: Float = 0
    /// Edge-detection cursor for new-onset scanning.
    var lastFrameIndex: Int = -1
    /// First-tick sentinel — re-seed smoothing values from current frame
    /// on first call (and on track-change reset) instead of lerping in
    /// from zero.
    var firstAnimateTick: Bool = true
    /// `appModel.liveModeResetCounter` at last scan. Differs → track change.
    var lastSeenResetCounter: Int = 0
    /// Wall-clock-adjacent elapsed time accumulator. Drives the gentle
    /// per-tile drift sin/cos in applyWedgeState. Accumulates `deltaTime`
    /// each animate call. Reset to 0 on track-change so drift restarts
    /// cleanly with the new song (otherwise tiles would teleport to wherever
    /// the sin curve happens to be at the moment of reset).
    var elapsedTime: Float = 0
    /// Stage C — EMA-smoothed RGB sent to the water shader's `chromaColor`
    /// uniform. Without this, the dominant-pitch argmax flips between
    /// near-tied bins every chromagram update and the lake colour
    /// flickers discretely. Smoothing the *output* RGB (not just the
    /// chromagram) buys buttery crossfades that survive any upstream
    /// jitter. Reset on track-change so a new song doesn't start by
    /// lerping out of the previous song's tint.
    var smoothedWaterRGB: SIMD3<Float> = .init(0.2, 0.5, 0.8)
}

/// State for one of the 12 wedge tile entities. Carries:
///   • `pitchClassIndex` — which chromagram bin drives this wedge.
///   • `basePositions/baseSizes/baseRotations` — the baked layout used by
///     animate's per-tick transform rebuild. Same pattern the starfield
///     uses for its per-instance bloom.
///   • `phasesXZ/phasesY/freqs` — per-tile random parameters for the
///     gentle XZ-circular-drift + Y-bob motion that gives the lake its
///     "fluid surface" character. Each tile drifts independently so the
///     surface reads as autonomous flow rather than synchronized waves.
struct AmbientWedgeComponent: Component {
    let pitchClassIndex: Int
    let basePositions: [SIMD3<Float>]
    let baseSizes: [Float]
    let baseRotations: [simd_quatf]
    /// Per-tile XZ-drift phase (radians). One full revolution around the
    /// drift circle is `2π / freq` seconds.
    let phasesXZ: [Float]
    /// Per-tile Y-bob phase (radians). Independent of XZ phase so tiles
    /// don't all bob in lockstep with their drift.
    let phasesY: [Float]
    /// Per-tile drift frequency (Hz). Mixed values 0.10–0.30 Hz mean tiles
    /// complete a drift circle every 3–10 seconds — slow, calm.
    let freqs: [Float]
}

/// Tag for the dark-blue translucent water-surface disk that sits just
/// above the wedge tiles. Tiles glow up through it; the disk's tint
/// supplies the "this is water" visual cue that pure tile-on-void was
/// missing. No per-tick update needed — purely a static visual layer.
struct AmbientWaterSurfaceComponent: Component {}

/// Marker for the procedural nebula sky-sphere (RCP material at
/// `/Root/Nebula`). Inside-out sphere rendered BEHIND the starfield;
/// the per-tick apply pushes `time` + `chromaColor` + `chromaMix`
/// to its uniforms.
struct AmbientNebulaComponent: Component {}

/// State for the water-haze sprite layer — many small light cyan-white
/// translucent hex sprites scattered across the lake. v2 inverted the
/// tint from dark-blue (which read as invisible against dark water) to
/// LIGHT cyan-white so the patches read as "reflective surface
/// highlights" — the way real water has lighter shimmer patches
/// catching ambient light. Per-instance Y-bob via cached phases gives
/// the highlights gentle undulation in place (no XZ drift — highlights
/// reflect stationary light sources, so they don't slide laterally).
struct AmbientWaterHazeComponent: Component {
    let basePositions: [SIMD3<Float>]
    let baseSizes: [Float]
    let baseRotations: [simd_quatf]
    let bobPhases: [Float]
    let bobFreqs: [Float]
}

/// Tag for the horizon-line glow cylinder — a faint cyan-white
/// horizontal band at the far edge of the lake giving the impression
/// of atmospheric scattering / moonlight pooling along the horizon.
/// Reduces the "hard 3D edge" feel where the lake meets the black sky.
/// Static layer.
struct AmbientHorizonGlowComponent: Component {}

/// State for the caustics layer — the bright elongated drifting streaks
/// that sit above the water surface like moonlight reflections on water.
/// This is the single most "water-specific" visual element in the scene:
/// the lake tiles say "color is here", the water surface says "blue
/// medium", but caustics say "light is being bent and concentrated by a
/// moving fluid surface." Carries per-streak base layout + drift parameters
/// for per-tick transform rebuild.
/// Marker for the procedural caustic shimmer disk (RCP material at
/// `/Root/Caustics`). Single flat disk overlay above the water surface;
/// `applyCausticsState` pushes time/chromaColor/chromaMix/loudness
/// uniforms each tick. Replaces the earlier 60-sprite-instance approach.
struct AmbientCausticsComponent: Component {}

/// State for the upper-hemisphere starfield entity. Carries the baked
/// per-instance layout (positions + sizes + rotations) so the animate
/// loop can rebuild the instance transforms each tick with a fresh
/// `size = baseSize × (1 + pulse × 2)` derived from the per-instance
/// pulse state. The pulses array is bumped on onsets (a random subset
/// per onset, NOT uniformly across all stars — Jesse called this out
/// explicitly: "random stars that bloom rather than uniform").
///
/// Holding the base layout here instead of recomputing it from a seed
/// every frame would cost ~300 random draws per tick on the main actor.
/// 300 × 3 floats + 300 quats + 300 floats = ~16 KB of state — well
/// worth the per-tick saving.
struct AmbientStarfieldComponent: Component {
    let basePositions: [SIMD3<Float>]
    let baseSizes: [Float]
    let baseRotations: [simd_quatf]
    var pulses: [Float]

    init(
        basePositions: [SIMD3<Float>],
        baseSizes: [Float],
        baseRotations: [simd_quatf]
    ) {
        self.basePositions = basePositions
        self.baseSizes = baseSizes
        self.baseRotations = baseRotations
        self.pulses = Array(repeating: 0, count: basePositions.count)
    }
}

/// Tag for the lake-highlight starlight-tile entity. Sits on the lake
/// plane scattered across the whole surface; pulses with the same
/// signal as the starfield (timbre + onset pulse).
struct AmbientStarlightComponent: Component {}

enum AmbientVisualizer {

    // MARK: - Tuning constants

    /// Lake surface Y coordinate. -1.5 m below the windowed virtual camera
    /// puts the lake at "looking-over-a-railing" height for the viewer.
    /// visionOS users at eye height ~1.5 m experience this as roughly
    /// ground level (root.position adds 1.45 m so lake ends up at -0.05 m
    /// in world coords — just below their feet).
    static let groundY: Float = -1.5

    /// Number of pitch-class wedges. 12 = one per pitch class.
    static let wedgeCount = 12

    /// Tile count per wedge. Each wedge spans 30° azimuth × the lake's
    /// radial extent. 80 tiles per wedge × 12 wedges = 960 chromagram
    /// tiles total. Bumped from 60 → 80 after the first lake-Ambient
    /// build read as "no color, just stars" — denser tiles read more
    /// like a continuous lake surface.
    static let tilesPerWedge = 80

    /// Radial extent of the lake (where tiles can be placed).
    /// Inner radius keeps tiles from clustering at the viewer's feet
    /// (which would dominate the viewport when looking down).
    static let lakeInnerRadius: Float = 1.0
    static let lakeOuterRadius: Float = 15.0

    /// Tile size range. Bumped successively: 0.20/0.50 → 0.30/0.80 →
    /// 0.45/1.30 to make wedges "brighter, wider, larger diffusion"
    /// per Jesse's brief once they became visible through the Stage C
    /// semi-transparent water surface. With the soft lake-glow texture
    /// (long alpha tail) and the per-tile alpha cap, many overlapping
    /// tiles ACCUMULATE into Clouds-style soft color washes rather
    /// than reading as a checkerboard of discrete hexagons.
    static let tileMinRadius: Float = 0.45
    static let tileMaxRadius: Float = 1.30

    /// Starlight tile count + size range. v1 used 100 — that read as
    /// "stars reflecting on water" but the dots were too bright and
    /// numerous, distracting from the lake. Dropped to 30 (with lower
    /// brightness/alpha in applyStarlightState) for subtle surface flecks.
    static let starlightTileCount = 30
    static let starlightTileRadius: Float = 0.06

    /// Water-haze sprite count + size range. Count reduced 200 → 120
    /// to claw back overdraw cost after FPS dropped to ~60 with the
    /// haze-over-water render order. Larger patches at slightly higher
    /// individual presence (lower count, similar visual density).
    static let waterHazeCount = 120
    /// Patch sizes 0.5–1.8m — broader floor regions, not specks.
    static let waterHazeMinRadius: Float = 0.50
    static let waterHazeMaxRadius: Float = 1.80
    /// Y offset relative to groundY. NEGATIVE (haze Y = -1.55) — middle
    /// of the stack. RealityKit's depth-sort orders by distance from
    /// camera, so haze ends up rendered AFTER water (which is at -1.6,
    /// farther) and BEFORE tiles (at -1.5, closer). That render order
    /// is what produces visible dark patches: haze overrides the bright
    /// water surface but is then overrode by glowing tiles where they're
    /// active.
    static let waterHazeYOffset: Float = -0.05
    /// Per-instance Y-bob amplitude for haze patches. Tiny (2 cm) so
    /// highlights gently undulate in place rather than visibly translate
    /// — matches the way real surface reflections shimmer without
    /// laterally sliding.
    static let waterHazeBobAmplitude: Float = 0.02
    static let waterHazeBobFreqMin: Float = 0.20
    static let waterHazeBobFreqMax: Float = 0.50

    /// Horizon glow cylinder dimensions. Sits just outside the lake's
    /// outer radius so it visually overlaps with the far tiles at the
    /// horizon line. Vertical gradient texture concentrates brightness
    /// at the horizon midline and fades up + down.
    static let horizonGlowRadius: Float = 16.0
    static let horizonGlowHeight: Float = 3.0

    /// Star dome. Upper hemisphere only (y > 0 in dome-local coords).
    /// Larger radius than v1's 12m so stars feel genuinely distant.
    static let starCount = 300
    static let starDomeRadius: Float = 25.0
    /// Star particle billboard size.
    static let starSize: Float = 0.05

    /// Nebula sky-sphere radius. LARGER than the starfield's 25m so
    /// star sprites composite in front of the procedural nebula
    /// without z-fighting. 30m gives ~5m clearance.
    static let nebulaSphereRadius: Float = 30.0
    /// Nebula chroma-mix cap. ZERO — Jesse's preference: the SKY
    /// should not tint with the song, only the STARS get a mild
    /// chroma. Keeping the uniform plumbing in place so we can dial
    /// it back up later if we change our minds, but the sky itself
    /// stays the static dim nebula colors authored in the shader.
    static let nebulaChromaMixStrength: Float = 0.0

    /// Smoothing rates (Hz). Deliberately slow — calm aesthetic.
    static let chromaLerpRate: Float = 3.0
    static let loudnessLerpRate: Float = 1.5
    static let timbreLerpRate: Float = 2.0
    /// SLOW loudness lerp — used to derive song-section intensity (verse
    /// vs chorus). 0.1 Hz means ~10-15 s settle time, so the value
    /// reflects "where are we in the song's energy arc" rather than
    /// "what just happened." Used by the starfield to scale beat
    /// bloom fraction.
    static let slowLoudnessLerpRate: Float = 0.1
    /// Normalization factor that maps the slow-loudness range into a
    /// 0…1 intensity. Smoothed loudness on real music sits at
    /// ~0.04 in quiet passages and ~0.18 on loud peaks. ×6 gives a
    /// 0.24…1.0+ working range, which clamps cleanly to [0, 1].
    /// Tune up/down if quiet sections never reach mid-intensity or
    /// loud sections never reach peak.
    static let intensityScale: Float = 6.0
    /// EXTRA-slow lerp for `trailingIntensity` — ~30 s settle. Used
    /// only as the reference baseline that current intensity is
    /// compared against to detect chorus drops.
    static let trailingIntensityLerpRate: Float = 0.04
    /// Smoothing rate for harmonic complexity. Raw signal is noisy on
    /// short timescales; a couple-second smoothing gives a stable
    /// "this section is harmonically dense vs sparse" reading.
    static let complexityLerpRate: Float = 0.5
    /// Threshold delta (intensity - trailingIntensity) above which we
    /// fire a chorus-drop burst. 0.25 in the [0,1] intensity space
    /// means we need a ~25% relative jump — clearly above noise but
    /// reliably triggers on real verse→chorus transitions.
    static let burstJumpThreshold: Float = 0.25
    /// Minimum seconds between chorus-drop bursts. Songs can have
    /// 2–3 chorus-equivalents (chorus 1, chorus 2, bridge-drop) so a
    /// 6 s refractory lets each fire while preventing per-beat
    /// retriggering at sustained high intensity.
    static let burstRefractory: Float = 6.0

    /// Wedge onset pulse — bump on dominant-pitch-class onset, decays.
    /// Adds brightness on top of the chromagram contribution.
    static let wedgePulseBump: Float = 0.6
    static let wedgePulseDecay: Float = 2.0 // ~0.35 s half-life

    /// Per-instance star bloom — on each onset, this many random star
    /// instances get their pulse bumped (NOT all stars uniformly).
    /// Scattered bloom rather than a global flash. 25 of 300 = ~8% of
    /// the sky lights up per onset, sparse enough to read as discrete
    /// twinkles rather than a wash.
    static let starsToBloomPerOnset = 25
    /// Per-instance star pulse — bump amplitude added to a chosen star's
    /// pulse value on bloom, and the decay rate. Decay 1.5/s gives a
    /// ~0.46 s half-life — slow enough that the bloom is visible
    /// developing-then-fading, fast enough that the sky settles back
    /// between beats.
    static let starPulseBump: Float = 1.0
    static let starPulseDecay: Float = 1.5

    /// Lake-highlight onset pulse — uniform across all starlight tiles,
    /// like a sheen-pulse across the water surface on each beat. Kept
    /// uniform here (NOT random per-instance) so the lake-highlight
    /// layer reads as "the water glistens" while the sky reads as
    /// "scattered stars sparkle." Different signal, different visual.
    static let starlightPulseBump: Float = 0.8
    static let starlightPulseDecay: Float = 2.5

    /// Breath amplitude on the wedge cluster (vertical scale modulation).
    /// Very small — the calm mode shouldn't pulse like the other modes.
    static let breathAmplitude: Float = 0.05

    /// Tile drift amplitudes — XZ-circular motion + vertical bob.
    /// 0.15 m XZ + 0.04 m Y is enough to feel like a "flowing surface"
    /// without tiles visibly teleporting or breaking out of their wedge.
    static let driftAmplitudeXZ: Float = 0.15
    static let driftAmplitudeY: Float = 0.04
    /// Drift frequency range. 0.10–0.30 Hz → 3.3–10 second drift cycles.
    /// Each tile picks a random freq in this range, so the surface flows
    /// at varied tempos rather than one synchronized wave.
    static let driftFreqMin: Float = 0.10
    static let driftFreqMax: Float = 0.30

    /// Water surface disk dimensions. Radius larger than the lake tile
    /// extent (lakeOuterRadius=15) so the disk fully covers the tile area
    /// with margin.
    static let waterSurfaceRadius: Float = 18.0
    /// Y offset from groundY. NEGATIVE (water Y = -1.6, farthest from
    /// camera) so RealityKit's transparent-entity depth-sort puts the
    /// water FIRST in render order. The intended pipeline order
    /// (water → haze → tiles) requires water be the farthest layer; we
    /// can't rely on add-order alone because the depth-sort overrides it.
    static let waterSurfaceYOffset: Float = -0.10

    /// Caustic streak parameters. 60 elongated horizontal sprites scattered
    /// across the lake just above the water surface. Drift perpendicular
    /// to their length axis with scale-pulsing length.
    static let causticCount = 60
    /// Streak base size in the local mesh — 1.0 × 0.06 quad. Per-instance
    /// scale provides length and width variation.
    static let causticBaseLengthMin: Float = 0.6
    static let causticBaseLengthMax: Float = 1.8
    static let causticBaseWidth: Float = 0.06
    /// Drift amplitude — how far a caustic oscillates perpendicular to
    /// its length. 0.4 m sweeps give a clear "wave moving across" feel
    /// without disrupting the spatial layout of the lake.
    static let causticDriftAmplitude: Float = 0.4
    /// Drift frequency range. Slower than tile drift (0.05–0.18 Hz =
    /// 5.5–20 s cycles) — caustics undulate at a longer wavelength.
    static let causticFreqMin: Float = 0.05
    static let causticFreqMax: Float = 0.18
    /// How much the streak's length pulses with the drift cycle. 0.4 =
    /// length oscillates ±40% around its base size, giving the apparent
    /// brightness modulation we can't get via per-instance alpha.
    static let causticLengthPulseAmplitude: Float = 0.4
    /// Y offset above the water surface where caustics sit. Tiny
    /// positive value so they render strictly ON TOP of the water plane.
    static let causticYOffset: Float = 0.03

    // MARK: - Cached resources

    /// Shared flat-hexagon mesh in the XZ plane (normal = +Y), unit radius.
    /// Per-tile size variation comes from instance transform scale.
    @MainActor private static var cachedHexMesh: MeshResource?
    /// Shared star sprite quad (XY plane facing +Z).
    @MainActor private static var cachedStarMesh: MeshResource?
    /// Soft radial-falloff glow texture for lake tiles + lake highlights.
    /// Long alpha tail so the hex's geometric edges dissolve completely
    /// and adjacent tiles blend into Clouds-style color washes.
    @MainActor private static var cachedLakeGlowTexture: TextureResource?
    /// Sharper radial-falloff glow texture for sky stars. Distinct from
    /// the lake glow because stars want a more concentrated bright core
    /// for the per-instance bloom to read as a discrete twinkle, while
    /// the lake wants softness for blobby color washes.
    @MainActor private static var cachedStarGlowTexture: TextureResource?
    /// ShaderGraphMaterial authored in Reality Composer Pro (lives in
    /// `Immersive.usda` at USD path `/Root/WaterSurface`). Stage A of the
    /// RCP experiment: just a constant magenta color, so we can verify
    /// the load + apply pipeline works before adding shader graph
    /// complexity. Loaded once at first request and cached for the app's
    /// lifetime (the material itself is immutable; per-frame parameters
    /// will be set on per-entity copies once we promote them in Stage B).
    @MainActor private static var cachedWaterSurfaceShader: ShaderGraphMaterial?
    /// ShaderGraphMaterial for the nebula sky background (USD path
    /// `/Root/Nebula` in `Immersive.usda`). Cached for the app's
    /// lifetime — per-frame uniforms are pushed to per-entity copies
    /// in `applyNebulaState`.
    @MainActor private static var cachedNebulaShader: ShaderGraphMaterial?
    /// ShaderGraphMaterial for the procedural caustic shimmer
    /// (USD path `/Root/Caustics`). Replaces the earlier
    /// MeshInstance-based sprite-streak approach.
    @MainActor private static var cachedCausticsShader: ShaderGraphMaterial?
    /// Horizontal stretched-quad mesh for caustic streaks (unit XZ
    /// rectangle facing +Y, 1 × 1). Per-instance scale stretches it to
    /// the desired streak length and width.
    @MainActor private static var cachedCausticMesh: MeshResource?

    @MainActor
    private static func sharedHexMesh() -> MeshResource {
        if let cached = cachedHexMesh { return cached }
        let mesh = makeHexMesh(radius: 1.0)
        cachedHexMesh = mesh
        return mesh
    }

    @MainActor
    private static func sharedStarMesh() -> MeshResource {
        if let cached = cachedStarMesh { return cached }
        let mesh = makeStarQuadMesh(size: starSize)
        cachedStarMesh = mesh
        return mesh
    }

    @MainActor
    private static func sharedLakeGlowTexture() -> TextureResource {
        if let cached = cachedLakeGlowTexture { return cached }
        let t = makeLakeGlowTexture()
        cachedLakeGlowTexture = t
        return t
    }

    @MainActor
    private static func sharedStarGlowTexture() -> TextureResource {
        if let cached = cachedStarGlowTexture { return cached }
        let t = makeStarGlowTexture()
        cachedStarGlowTexture = t
        return t
    }

    /// Load the WaterSurface ShaderGraphMaterial authored in Reality
    /// Composer Pro. The material lives at USD path `/Root/WaterSurface`
    /// inside `Immersive.usda` in the RealityKitContent package.
    /// First call awaits the load; subsequent calls return the cached
    /// material immediately. Returns nil if the load fails (so the
    /// caller can fall back to the previous UnlitMaterial gracefully).
    @MainActor
    private static func sharedWaterSurfaceShader() async -> ShaderGraphMaterial? {
        if let cached = cachedWaterSurfaceShader { return cached }
        do {
            let material = try await ShaderGraphMaterial(
                named: "/Root/WaterSurface",
                from: "Immersive",
                in: realityKitContentBundle
            )
            cachedWaterSurfaceShader = material
            print("AmbientVisualizer: loaded WaterSurface shader from RCP")
            return material
        } catch {
            print("AmbientVisualizer: ShaderGraphMaterial load failed: \(error)")
            return nil
        }
    }

    @MainActor
    private static func sharedCausticsShader() async -> ShaderGraphMaterial? {
        if let cached = cachedCausticsShader { return cached }
        do {
            let material = try await ShaderGraphMaterial(
                named: "/Root/Caustics",
                from: "Immersive",
                in: realityKitContentBundle
            )
            cachedCausticsShader = material
            print("AmbientVisualizer: loaded Caustics shader from RCP")
            return material
        } catch {
            print("AmbientVisualizer: Caustics shader load failed: \(error)")
            return nil
        }
    }

    @MainActor
    private static func sharedNebulaShader() async -> ShaderGraphMaterial? {
        if let cached = cachedNebulaShader { return cached }
        do {
            let material = try await ShaderGraphMaterial(
                named: "/Root/Nebula",
                from: "Immersive",
                in: realityKitContentBundle
            )
            cachedNebulaShader = material
            print("AmbientVisualizer: loaded Nebula shader from RCP")
            return material
        } catch {
            print("AmbientVisualizer: Nebula shader load failed: \(error)")
            return nil
        }
    }

    @MainActor
    private static func sharedCausticMesh() -> MeshResource {
        if let cached = cachedCausticMesh { return cached }
        let mesh = makeHorizontalQuadMesh(width: 1.0, depth: 1.0)
        cachedCausticMesh = mesh
        return mesh
    }

    // MARK: - Build

    @MainActor
    static func makeAmbient(from frames: [FeatureFrame]) async -> Entity {
        let root = Entity()
        // visionOS eye-height anchor; VisualizerView overrides for windowed.
        root.position = [0, 1.45, 0]

        // === Lake-stack render order ===
        // RealityKit depth-sorts transparent entities back-to-front by
        // distance-to-camera, which is UNSTABLE here: the water surface
        // (y=-1.60) and water haze (y=-1.55) are only 5 cm apart, and
        // the haze instances bob ±2 cm. As the bob brings individual
        // haze sprites' fragments close to the water-surface fragments
        // in Y, the entity-level sort key can briefly flip frame-to-
        // frame → haze renders BEFORE water for one frame → the
        // (bright) water surface draws OVER the (dark) haze patch →
        // you see a brief flash of bright water at the haze location.
        // The artifact reads as "lightning shimmer" on the dark blobs.
        //
        // Fix: assign every transparent lake-stack entity to a single
        // ModelSortGroup with an explicit `order` index. Entities in a
        // sort group render in `order` sequence regardless of camera
        // distance, killing the per-frame sort-flip behavior.
        // See [[realitykit-transparent-depth-sort]] for the broader
        // rule this codifies.
        let lakeSortGroup = ModelSortGroup(depthPass: nil)
        func assignSortOrder(_ entity: Entity, _ order: Int32) {
            entity.components.set(ModelSortGroupComponent(
                group: lakeSortGroup, order: order
            ))
        }

        // Nebula sky FIRST — opaque-ish inside-out sphere at radius
        // 30. The material's PreviewSurface uses opacity 0.95 (just
        // under 1.0) so RealityKit puts it in the TRANSPARENT pass.
        // That kicks in back-to-front depth sorting, so star sprites
        // at distance ~25-26 composite in front of the nebula at
        // distance ~28-31. An opaque sphere here (opacity 1.0) was
        // somehow occluding the stars despite depth test, possibly
        // a face-culling-after-scale-flip artifact — opacity 0.95
        // is a verified workaround.
        root.addChild(await buildNebula())

        // Starfield in the upper sky.
        root.addChild(buildStarfield())

        // Water surface — single disk with the Stage C global tint
        // (dominant pitch → EMA-smoothed RGB → chromaColor uniform).
        // The 12-sub-slice per-wedge tint experiment was reverted on
        // 2026-05-23 — the hard angular boundaries between slices
        // read as a "beach ball" pattern at any non-trivial
        // chromaMix, and softening required per-fragment math that
        // RealityKit's MaterialX doesn't expose.
        //
        // 2026-05-23 PM: also tried inverting the stack to a "look
        // INTO the lake" model (haze→wedges→starlight→water→caustics
        // with water opacity 0.30). Result read much less like water,
        // so reverted. Water-as-base, paint-on-top is the actual
        // "looks like water" arrangement for this design.
        let waterSurface = await buildWaterSurface()
        assignSortOrder(waterSurface, 0)
        root.addChild(waterSurface)

        // Water haze — DARK patches drawn OVER the water surface so they
        // override its bright blue with their near-black color in patches.
        // Semantically "the dark substrate under the water" but in the
        // alpha-blend pipeline it has to render after the water to be
        // visible. Tiles will still draw on top, so tile colors dominate
        // wherever they're bright; haze patches show through dormant
        // wedges and in the gaps between tile groups.
        let waterHaze = buildWaterHaze()
        assignSortOrder(waterHaze, 1)
        root.addChild(waterHaze)

        // 12 wedge tile entities — the chromagram-driven lake surface.
        // Glow on top of the water+haze base.
        for i in 0..<wedgeCount {
            let wedge = buildWedgeTiles(pitchClassIndex: i)
            assignSortOrder(wedge, 2)
            root.addChild(wedge)
        }

        // Lake highlights — scattered starlight tiles across the whole
        // lake plane. Pulse with starfield (timbre + starPulse).
        let starlight = buildStarlightTiles()
        assignSortOrder(starlight, 3)
        root.addChild(starlight)

        // Horizon glow — faint cyan-white band at the lake's far edge
        // suggesting atmospheric scattering / moonlight haze at the
        // horizon. Reduces the "hard 3D edge" where lake meets sky.
        // Not part of the lake sort group — it's at a different
        // distance and angle, doesn't overlap the lake layers.
        root.addChild(buildHorizonGlow())

        // Caustics — procedural shader-driven shimmer ON TOP of the
        // water surface. Single disk + multi-noise intersection
        // pattern in the shader. Replaces the earlier sprite-streak
        // approach. Per-tick uniforms (time, chromaColor, loudness)
        // drive the animated shimmer.
        let caustics = await buildCaustics()
        assignSortOrder(caustics, 4)
        root.addChild(caustics)

        var state = AmbientRootComponent()
        state.lastFrameIndex = -1
        root.components.set(state)
        return root
    }

    // MARK: - Wedge tile builder

    /// Build a single wedge entity: one ModelEntity with a MeshInstancesComponent
    /// carrying `tilesPerWedge` hex instances scattered randomly within this
    /// pitch class's 30° azimuth wedge on the lake plane.
    @MainActor
    private static func buildWedgeTiles(pitchClassIndex i: Int) -> ModelEntity {
        let pitchClass = PitchClass(rawValue: i) ?? .c

        // Wedge azimuth range — centered on this pitch class's position
        // around the viewer. Wedge 0 is centered at azimuth 0 (in front
        // along +X axis), wedge 1 at 30°, etc.
        let wedgeCenter = Float(i) / Float(wedgeCount) * 2 * .pi
        let halfWidth = Float.pi / Float(wedgeCount)  // = 15° = π/12
        let azimuthMin = wedgeCenter - halfWidth
        let azimuthMax = wedgeCenter + halfWidth

        var material = UnlitMaterial()
        let initialTint = PlatformColor.hdrColor(
            hue: CGFloat(pitchClass.circleOfFifthsHue),
            saturation: 0.85,
            brightness: 0.45,
            hdrBoost: 1.0
        )
        material.color = .init(tint: initialTint, texture: .init(sharedLakeGlowTexture()))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        // No depth write — lake tiles are translucent + we want adjacent
        // tiles in different wedges to overlap softly rather than Z-fight.
        material.writesDepth = false

        let entity = ModelEntity(mesh: sharedHexMesh(), materials: [material])
        // The hex mesh is unit-radius in XZ plane at y=0; placing the
        // entity at (0, groundY, 0) puts ALL its instance tiles on the
        // lake surface, since instance transforms translate from this
        // entity's local origin.
        entity.position = [0, groundY, 0]

        // Seed per-wedge so layouts are deterministic but varied between
        // wedges. Mixing in pitch class index keeps wedge 0 different
        // from wedge 1 even when the cluster is re-built.
        var rng = SimpleRNG(seed: 0xA0DE_C0DE_0000_0000 &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15)

        // Build the per-tile base layout + drift parameters.
        var basePositions: [SIMD3<Float>] = []
        var baseSizes: [Float] = []
        var baseRotations: [simd_quatf] = []
        var phasesXZ: [Float] = []
        var phasesY: [Float] = []
        var freqs: [Float] = []
        basePositions.reserveCapacity(tilesPerWedge)
        baseSizes.reserveCapacity(tilesPerWedge)
        baseRotations.reserveCapacity(tilesPerWedge)
        phasesXZ.reserveCapacity(tilesPerWedge)
        phasesY.reserveCapacity(tilesPerWedge)
        freqs.reserveCapacity(tilesPerWedge)

        for _ in 0..<tilesPerWedge {
            // Uniform-area radial distribution: r = inner + (outer - inner) * sqrt(u).
            // Linear-in-radius would over-cluster at the center;
            // sqrt(u) gives equal expected tile count per unit
            // area, which reads more like a uniformly-lit lake.
            let u = Float(rng.nextUnit())
            let r = lakeInnerRadius
                + (lakeOuterRadius - lakeInnerRadius) * sqrt(u)
            let theta = azimuthMin
                + Float(rng.nextUnit()) * (azimuthMax - azimuthMin)

            let pos = SIMD3<Float>(
                cos(theta) * r,
                0,
                sin(theta) * r
            )
            // Tile size varies — larger tiles are rarer (biased
            // small via pow). Strong distance attenuation: far-side
            // tiles shrink to ~15% of near-side tiles, faking atmospheric
            // perspective via geometry (we don't have depth-aware
            // fog without ShaderGraphMaterial). Lake naturally fades
            // toward the horizon as tiles become point-sized in the
            // distance, which adds significant realism.
            let sizeU = Float(rng.nextUnit())
            let proximityBoost = 1.0 - 0.85 * (r - lakeInnerRadius)
                                          / (lakeOuterRadius - lakeInnerRadius)
            let size = (tileMinRadius
                        + pow(sizeU, 2) * (tileMaxRadius - tileMinRadius))
                       * proximityBoost
            // Small random rotation around Y so tiles aren't all
            // axis-aligned hex grids; the lake reads more organic.
            let baseRot = simd_quatf(
                angle: Float(rng.nextUnit()) * 2 * .pi,
                axis: [0, 1, 0]
            )

            // Per-tile drift parameters — unique phase + frequency.
            // Independent XZ and Y phases so a tile's bob isn't locked
            // to its drift circle, giving more chaotic-looking motion.
            let phaseXZ = Float(rng.nextUnit()) * 2 * .pi
            let phaseY = Float(rng.nextUnit()) * 2 * .pi
            let freq = driftFreqMin
                + Float(rng.nextUnit()) * (driftFreqMax - driftFreqMin)

            basePositions.append(pos)
            baseSizes.append(size)
            baseRotations.append(baseRot)
            phasesXZ.append(phaseXZ)
            phasesY.append(phaseY)
            freqs.append(freq)
        }

        // Initial instance transforms — drift offset 0 at t=0.
        var instances = MeshInstancesComponent()
        do {
            let data = try LowLevelInstanceData(instanceCount: tilesPerWedge)
            data.withMutableTransforms { transforms in
                for k in 0..<tilesPerWedge {
                    var t = Transform()
                    t.translation = basePositions[k]
                    t.scale = SIMD3<Float>(repeating: baseSizes[k])
                    t.rotation = baseRotations[k]
                    transforms[k] = t.matrix
                }
            }
            instances[partIndex: 0] = .init(data: data)
        } catch {
            print("AmbientVisualizer: wedge \(i) LowLevelInstanceData init failed: \(error)")
        }
        entity.components.set(instances)
        entity.components.set(AmbientWedgeComponent(
            pitchClassIndex: i,
            basePositions: basePositions,
            baseSizes: baseSizes,
            baseRotations: baseRotations,
            phasesXZ: phasesXZ,
            phasesY: phasesY,
            freqs: freqs
        ))
        return entity
    }

    // MARK: - Water surface

    /// Build the water-surface disk. Large flat circular disk at
    /// `groundY + waterSurfaceYOffset`, tinted deep cool blue, alpha
    /// ~0.5. Renders ABOVE the tiles in alpha-blend order (added last
    /// to the root tree) so colored tile contributions are composited
    /// THROUGH the water tint — what the user perceives as "glowing
    /// lights under water." Static — no per-tick updates.
    @MainActor
    private static func buildWaterSurface() async -> ModelEntity {
        let mesh = makeDiskMesh(radius: waterSurfaceRadius, segments: 48)

        // RCP Stage A: try the ShaderGraphMaterial first. If it loads,
        // use it (will appear as the constant magenta we set in the
        // graph — obvious visual confirmation that the bridge works).
        // If load fails, fall back to the previous tinted UnlitMaterial
        // so the app remains usable while we debug.
        let materials: [any Material]
        if let shader = await sharedWaterSurfaceShader() {
            materials = [shader]
        } else {
            var fallback = UnlitMaterial()
            let tint = PlatformColor(
                hue: 0.62,
                saturation: 0.72,
                brightness: 0.45,
                alpha: 0.55
            )
            fallback.color = .init(tint: tint)
            fallback.blending = .transparent(opacity: .init(floatLiteral: 0.55))
            fallback.writesDepth = false
            materials = [fallback]
        }

        let entity = ModelEntity(mesh: mesh, materials: materials)
        // Position just above the tile plane. groundY is the tile y;
        // surface sits at groundY + waterSurfaceYOffset so tiles are
        // strictly below the surface in world Z-order.
        entity.position = [0, groundY + waterSurfaceYOffset, 0]
        entity.components.set(AmbientWaterSurfaceComponent())
        return entity
    }

    // MARK: - Water haze layer

    /// Build the water-haze sprite layer — ~200 small dark-blue
    /// translucent hex sprites scattered across the lake area on top of
    /// the flat water disk. Each sprite contributes a small patch of
    /// extra blue tint at its location; the cumulative effect across
    /// the lake is texture variation that breaks up the otherwise
    /// uniform flat-disk feel. Static layer, no per-tick update.
    @MainActor
    private static func buildWaterHaze() -> ModelEntity {
        var material = UnlitMaterial()
        // DARK near-black blue. Alpha 0.65 (was 0.80) for less overdraw
        // cost — the FPS dropped to ~60 with 0.80 alpha across 200
        // patches. At 0.65 the override is still strong enough to read
        // as clearly-darker patches against the bright water surface.
        let tint = PlatformColor(
            hue: 0.65,
            saturation: 0.80,
            brightness: 0.03,
            alpha: 0.65
        )
        material.color = .init(tint: tint, texture: .init(sharedLakeGlowTexture()))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.65))
        material.writesDepth = false

        let entity = ModelEntity(mesh: sharedHexMesh(), materials: [material])
        // Position BELOW the tile plane (waterHazeYOffset is negative).
        // The Y-bob in applyWaterHazeState gently raises and lowers each
        // patch, so some moments they peek closer to the tile plane.
        entity.position = [0, groundY + waterHazeYOffset, 0]

        var rng = SimpleRNG(seed: 0x0A7E_4DA7_0000_0000)  // "WATER" hex-ish

        var basePositions: [SIMD3<Float>] = []
        var baseSizes: [Float] = []
        var baseRotations: [simd_quatf] = []
        var bobPhases: [Float] = []
        var bobFreqs: [Float] = []
        basePositions.reserveCapacity(waterHazeCount)
        baseSizes.reserveCapacity(waterHazeCount)
        baseRotations.reserveCapacity(waterHazeCount)
        bobPhases.reserveCapacity(waterHazeCount)
        bobFreqs.reserveCapacity(waterHazeCount)

        for _ in 0..<waterHazeCount {
            // Uniform-area scatter across the full lake annulus.
            let u = Float(rng.nextUnit())
            let r = lakeInnerRadius
                + (lakeOuterRadius - lakeInnerRadius) * sqrt(u)
            let theta = Float(rng.nextUnit()) * 2 * .pi
            let pos = SIMD3<Float>(cos(theta) * r, 0, sin(theta) * r)
            // Bias toward small (pow > 1) — small bright highlights
            // are common, larger ones rarer. Mimics natural reflection
            // size distribution on water.
            let sizeU = Float(rng.nextUnit())
            let size = waterHazeMinRadius
                + pow(sizeU, 1.8)
                * (waterHazeMaxRadius - waterHazeMinRadius)
            let rot = simd_quatf(
                angle: Float(rng.nextUnit()) * 2 * .pi,
                axis: [0, 1, 0]
            )
            let phase = Float(rng.nextUnit()) * 2 * .pi
            let freq = waterHazeBobFreqMin
                + Float(rng.nextUnit())
                * (waterHazeBobFreqMax - waterHazeBobFreqMin)

            basePositions.append(pos)
            baseSizes.append(size)
            baseRotations.append(rot)
            bobPhases.append(phase)
            bobFreqs.append(freq)
        }

        var instances = MeshInstancesComponent()
        do {
            let data = try LowLevelInstanceData(instanceCount: waterHazeCount)
            data.withMutableTransforms { transforms in
                for k in 0..<waterHazeCount {
                    var t = Transform()
                    t.translation = basePositions[k]
                    t.scale = SIMD3<Float>(repeating: baseSizes[k])
                    t.rotation = baseRotations[k]
                    transforms[k] = t.matrix
                }
            }
            instances[partIndex: 0] = .init(data: data)
        } catch {
            print("AmbientVisualizer: water haze LowLevelInstanceData init failed: \(error)")
        }
        entity.components.set(instances)
        entity.components.set(AmbientWaterHazeComponent(
            basePositions: basePositions,
            baseSizes: baseSizes,
            baseRotations: baseRotations,
            bobPhases: bobPhases,
            bobFreqs: bobFreqs
        ))
        return entity
    }

    /// Per-tick Y-bob update for the water haze. Each patch oscillates
    /// vertically by `waterHazeBobAmplitude` at its own random frequency
    /// and phase. No XZ drift — highlights reflect stationary light
    /// sources, so they should shimmer in place rather than slide
    /// laterally. Also pulses size subtly so highlights "breathe" as
    /// they bob, reinforcing the surface-reflection feel.
    @MainActor
    private static func applyWaterHazeState(
        _ entity: Entity,
        state: AmbientRootComponent
    ) {
        guard let model = entity as? ModelEntity,
              var instances = model.components[MeshInstancesComponent.self],
              let hc = model.components[AmbientWaterHazeComponent.self]
        else { return }

        let t = state.elapsedTime
        if let part = instances[partIndex: 0] {
            part.data.replaceMutableTransforms { transforms in
                for k in 0..<hc.basePositions.count {
                    let angle = 2 * .pi * hc.bobFreqs[k] * t + hc.bobPhases[k]
                    let dy = sin(angle) * waterHazeBobAmplitude
                    // Subtle size breathe — ±15% of base size — for
                    // shimmer effect (since we can't do per-instance alpha
                    // via LowLevelInstanceData).
                    let sizeBreathe = 1 + sin(angle * 1.3 + 0.5) * 0.15
                    var trans = Transform()
                    trans.translation = hc.basePositions[k]
                        + SIMD3<Float>(0, dy, 0)
                    trans.scale = SIMD3<Float>(
                        repeating: hc.baseSizes[k] * sizeBreathe
                    )
                    trans.rotation = hc.baseRotations[k]
                    transforms[k] = trans.matrix
                }
            }
        }
    }

    // MARK: - Horizon glow

    /// Build the horizon-glow cylinder. A vertical inside-out cylindrical
    /// wall at radius `horizonGlowRadius` (just outside lake outer radius)
    /// with a vertical-gradient texture: peak brightness at the horizon
    /// midline, fading to 0 at top and bottom. Acts as a faint
    /// atmospheric ring at the lake's edge, dissolving the hard
    /// "lake meets black sky" horizon transition.
    @MainActor
    private static func buildHorizonGlow() -> ModelEntity {
        let mesh = makeCylinderWallMesh(
            radius: horizonGlowRadius,
            height: horizonGlowHeight,
            segments: 48
        )
        var material = UnlitMaterial()
        // Subtle cool tint — should suggest moonlight haze, not steal
        // attention from the lake. Low brightness + low alpha.
        let tint = PlatformColor(
            hue: 0.58,
            saturation: 0.30,
            brightness: 0.40,
            alpha: 0.35
        )
        material.color = .init(
            tint: tint,
            texture: .init(sharedHorizonGradientTexture())
        )
        material.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        material.writesDepth = false

        let entity = ModelEntity(mesh: mesh, materials: [material])
        // Y position: centered at groundY + 1.0 (around eye-level for the
        // lake). The gradient texture concentrates brightness at the
        // band's vertical midline, so the visible glow appears around
        // the horizon line.
        entity.position = [0, groundY + 1.0, 0]
        entity.components.set(AmbientHorizonGlowComponent())
        return entity
    }

    /// Inside-out cylinder wall mesh. The inward face is the visible one
    /// (user is inside the cylinder), so we wind the triangles so the
    /// +X-axis face points toward the cylinder center (-X direction)
    /// when viewed from inside.
    private static func makeCylinderWallMesh(
        radius: Float,
        height: Float,
        segments: Int
    ) -> MeshResource {
        let halfH = height / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texCoords: [SIMD2<Float>] = []
        for i in 0..<(segments + 1) {
            let a = Float(i) / Float(segments) * 2 * .pi
            let x = cos(a) * radius
            let z = sin(a) * radius
            let inwardNormal = SIMD3<Float>(-cos(a), 0, -sin(a))
            // Bottom + top rings.
            positions.append(SIMD3<Float>(x, -halfH, z))
            positions.append(SIMD3<Float>(x,  halfH, z))
            normals.append(inwardNormal)
            normals.append(inwardNormal)
            let u = Float(i) / Float(segments)
            texCoords.append(SIMD2<Float>(u, 0))  // bottom: V=0
            texCoords.append(SIMD2<Float>(u, 1))  // top: V=1
        }
        var indices: [UInt32] = []
        for i in 0..<segments {
            let bL = UInt32(i * 2)       // bottom-left
            let tL = UInt32(i * 2 + 1)   // top-left
            let bR = UInt32(i * 2 + 2)   // bottom-right
            let tR = UInt32(i * 2 + 3)   // top-right
            // Inside-facing winding — when viewed from inside the
            // cylinder, going around the wall CCW.
            indices.append(contentsOf: [bL, tL, tR])
            indices.append(contentsOf: [bL, tR, bR])
        }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generatePlane(width: radius * 2, height: height)
        }
    }

    /// Horizontal-band gradient texture: alpha peaks at V=0.5 (horizon
    /// midline) and fades to 0 at V=0 (bottom) and V=1 (top). Cached.
    @MainActor private static var cachedHorizonGradientTexture: TextureResource?

    @MainActor
    private static func sharedHorizonGradientTexture() -> TextureResource {
        if let cached = cachedHorizonGradientTexture { return cached }
        let t = makeHorizonGradientTexture()
        cachedHorizonGradientTexture = t
        return t
    }

    private static func makeHorizonGradientTexture() -> TextureResource {
        let width = 32
        let height = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Vertical gradient — alpha 0 at top/bottom, peak ~0.7 at middle.
        // Soft falloff so the band has a gentle haze quality.
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.7),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 0.30, 0.50, 0.70, 1.0]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: CGFloat(height)),
            options: []
        )
        return try! TextureResource(
            image: ctx.makeImage()!,
            withName: "ambient-horizon-gradient",
            options: .init(semantic: .color)
        )
    }

    // MARK: - Caustics layer

    /// Build the caustics entity — ~60 elongated bright streak sprites
    /// scattered across the lake surface, each drifting perpendicular
    /// to its length axis with scale-pulsing length. Renders ON TOP of
    /// the water surface (added last in `makeAmbient`) so they look like
    /// light caustics ON the water rather than under it.
    /// Build the procedural caustic shimmer disk. Single flat disk
    /// covering the lake area; the `/Root/Caustics` shader produces
    /// the moving caustic pattern via multi-noise intersection math.
    /// Replaces the earlier 60-sprite-instance approach.
    @MainActor
    private static func buildCaustics() async -> ModelEntity {
        let mesh = makeDiskMesh(radius: lakeOuterRadius, segments: 48)
        let materials: [any Material]
        if let shader = await sharedCausticsShader() {
            materials = [shader]
        } else {
            // Fallback: subtle cyan UnlitMaterial so the lake still
            // has SOME shimmer if the shader load breaks.
            var fallback = UnlitMaterial()
            let tint = PlatformColor(
                hue: 0.55,
                saturation: 0.15,
                brightness: 0.30,
                alpha: 0.15
            )
            fallback.color = .init(tint: tint)
            fallback.blending = .transparent(opacity: .init(floatLiteral: 0.15))
            fallback.writesDepth = false
            materials = [fallback]
        }

        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.position = [0, groundY + waterSurfaceYOffset + causticYOffset, 0]
        entity.components.set(AmbientCausticsComponent())
        return entity
    }

    /// Push per-tick uniforms to the caustic shader. The shader
    /// itself produces the moving caustic pattern via multi-noise
    /// math; here we just feed time, chromaColor (for subtle
    /// song-tinted shimmer), chromaMix, and loudness (which pumps
    /// caustic intensity on loud passages).
    @MainActor
    private static func applyCausticsState(
        _ entity: Entity,
        state: AmbientRootComponent
    ) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var shader = modelComp.materials.first as? ShaderGraphMaterial
        else { return }

        // Reuse the water's EMA-smoothed RGB so caustics drift with
        // the same color the water tints toward — visually cohesive.
        let rgb = state.smoothedWaterRGB
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let chromaCG = CGColor(
            colorSpace: cs,
            components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1]
        )

        // Dominant pitch weight gates the chroma bleed. Capped low
        // so caustics stay readable as cool surface shimmer.
        var domWeight: Float = 0
        for k in 0..<state.smoothedChromagram.count
        where state.smoothedChromagram[k] > domWeight {
            domWeight = state.smoothedChromagram[k]
        }
        let chromaMix = Double(min(1.0, domWeight)) * 0.30

        try? shader.setParameter(name: "time", value: .float(state.elapsedTime))
        if let chromaCG {
            try? shader.setParameter(name: "chromaColor", value: .color(chromaCG))
        }
        try? shader.setParameter(name: "chromaMix", value: .float(Float(chromaMix)))
        try? shader.setParameter(name: "loudness", value: .float(state.smoothedLoudness))
        modelComp.materials[0] = shader
        model.components.set(modelComp)
    }

    /// Flat XZ-plane quad (normal = +Y), used as the base shape for
    /// caustic streaks. Per-instance scale stretches it to the desired
    /// streak length × width. Same winding convention as the hex / disk
    /// meshes: CCW from above so the +Y face is the front.
    private static func makeHorizontalQuadMesh(width: Float, depth: Float) -> MeshResource {
        let hw = width / 2
        let hd = depth / 2
        let positions: [SIMD3<Float>] = [
            [-hw, 0, -hd], [ hw, 0, -hd], [ hw, 0,  hd], [-hw, 0,  hd]
        ]
        let normals: [SIMD3<Float>] = Array(repeating: [0, 1, 0], count: 4)
        // UVs: stretch the radial glow texture across the full quad so
        // the streak's center is brightest and the ends fade out.
        let texCoords: [SIMD2<Float>] = [
            [0, 0], [1, 0], [1, 1], [0, 1]
        ]
        // CCW from above (matches makeHexMesh winding fix).
        let indices: [UInt32] = [0, 2, 1, 0, 3, 2]

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generatePlane(width: width, height: depth)
        }
    }

    /// N-sided flat disk in the XZ plane (normal = +Y). Center vertex
    /// at origin, N outer vertices at `radius`, N triangles fanned.
    /// Same winding convention as `makeHexMesh` — CCW from above so the
    /// +Y face is the front (visible from the camera looking down).
    private static func makeDiskMesh(radius: Float, segments: Int) -> MeshResource {
        var positions: [SIMD3<Float>] = [[0, 0, 0]]
        var normals: [SIMD3<Float>] = [[0, 1, 0]]
        var texCoords: [SIMD2<Float>] = [[0.5, 0.5]]

        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * radius, 0, sin(a) * radius))
            normals.append([0, 1, 0])
            texCoords.append(SIMD2<Float>(
                0.5 + cos(a) * 0.5,
                0.5 + sin(a) * 0.5
            ))
        }

        var indices: [UInt32] = []
        for i in 0..<segments {
            let curr = UInt32(i + 1)
            let next = UInt32(((i + 1) % segments) + 1)
            // CCW from above (matches makeHexMesh winding fix).
            indices.append(contentsOf: [0, next, curr])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generatePlane(width: radius * 2, height: radius * 2)
        }
    }

    // MARK: - Nebula sky background

    /// Build the procedural nebula sky-sphere. Inside-out sphere of
    /// `nebulaSphereRadius` (larger than starfield) with a
    /// ShaderGraphMaterial authored at USD path `/Root/Nebula`. The
    /// `[-1, 1, 1]` scale flips face winding so the inside is what
    /// the user sees from world origin. If the shader load fails
    /// (e.g., a graph compile error) we fall back to a tinted
    /// UnlitMaterial so the scene still has SOMETHING in the sky.
    @MainActor
    private static func buildNebula() async -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: nebulaSphereRadius)
        let materials: [any Material]
        if let shader = await sharedNebulaShader() {
            materials = [shader]
        } else {
            // Fallback: dim purple wash so the user at least gets
            // SOME sky coloring if the shader load breaks.
            var fallback = UnlitMaterial()
            let tint = PlatformColor(
                hue: 0.78, saturation: 0.55,
                brightness: 0.08, alpha: 1
            )
            fallback.color = .init(tint: tint)
            materials = [fallback]
        }
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.scale = [-1, 1, 1]  // inside-out
        entity.components.set(AmbientNebulaComponent())
        return entity
    }

    // MARK: - Starfield builder

    @MainActor
    private static func buildStarfield() -> ModelEntity {
        var material = UnlitMaterial()
        // HDR boost lifted 1.3 → 2.4 and opacity 0.7 → 0.95 so stars
        // punch through the new nebula sky tint. Even at peak nebula
        // brightness (~0.04 r/g/b from the dim color3 values + chroma
        // tint), stars at this HDR push to ~2.3 in extended sRGB,
        // which clips bright-white on the display — visible against
        // any non-pure-black backdrop.
        let starTint = PlatformColor.hdrColor(
            hue: 0.6,
            saturation: 0.15,
            brightness: 1.0,
            hdrBoost: 2.4
        )
        material.color = .init(tint: starTint, texture: .init(sharedStarGlowTexture()))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.95))
        material.writesDepth = false

        let entity = ModelEntity(mesh: sharedStarMesh(), materials: [material])
        // NO BillboardComponent — on a 25 m-radius dome it was rotating
        // the entire starfield entity to face the camera each frame,
        // effectively gluing the dome to the user's viewport so drag
        // appeared to do nothing AND the stars covered the entire view
        // (hiding the lake behind them). Per-instance orientation below
        // achieves the same "star always faces camera" effect without
        // moving the dome relative to the world.

        var rng = SimpleRNG(seed: 0xA0DE_C0DE_5741_5253)  // "WARS" hex-ish

        // Compute base layout once. Per-instance orientation is baked in
        // so that each star sprite's local +Z points TOWARD the dome
        // center (the camera position). Combined with the camera being
        // fixed at world origin and the entire ambient root rotating as
        // the user drags, this keeps every star correctly oriented to
        // camera throughout free-look.
        var basePositions: [SIMD3<Float>] = []
        var baseSizes: [Float] = []
        var baseRotations: [simd_quatf] = []
        basePositions.reserveCapacity(starCount)
        baseSizes.reserveCapacity(starCount)
        baseRotations.reserveCapacity(starCount)

        for _ in 0..<starCount {
            // Upper-hemisphere distribution. cos(θ) uniform in (0, 1]
            // → θ in (0, π/2], i.e. zenith to horizon.
            let cosTheta = Float(rng.nextUnit())
            let sinTheta = sqrt(max(0, 1 - cosTheta * cosTheta))
            let phi = Float(rng.nextUnit()) * 2 * .pi
            let pos = SIMD3<Float>(
                sinTheta * cos(phi),
                cosTheta,
                sinTheta * sin(phi)
            ) * starDomeRadius
            // Scale variation — small bright stars common, large
            // ones rare (pow(u, 3) biases toward small).
            let u = Float(rng.nextUnit())
            let scale: Float = 0.4 + pow(u, 3) * 1.4
            // Per-instance rotation: star's local +Z should point at the
            // origin. Direction from star to origin is -normalize(pos).
            // simd_quatf(from: source, to: target) gives the rotation
            // that maps source onto target.
            let inward = -simd_normalize(pos)
            let rotation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: inward)

            basePositions.append(pos)
            baseSizes.append(scale)
            baseRotations.append(rotation)
        }

        var instances = MeshInstancesComponent()
        do {
            let data = try LowLevelInstanceData(instanceCount: starCount)
            data.withMutableTransforms { transforms in
                for k in 0..<starCount {
                    var t = Transform()
                    t.translation = basePositions[k]
                    t.scale = SIMD3<Float>(repeating: baseSizes[k])
                    t.rotation = baseRotations[k]
                    transforms[k] = t.matrix
                }
            }
            instances[partIndex: 0] = .init(data: data)
        } catch {
            print("AmbientVisualizer: starfield LowLevelInstanceData init failed: \(error)")
        }
        entity.components.set(instances)
        entity.components.set(AmbientStarfieldComponent(
            basePositions: basePositions,
            baseSizes: baseSizes,
            baseRotations: baseRotations
        ))
        return entity
    }

    // MARK: - Lake-highlight starlight tiles builder

    /// Scattered pale-cyan hex tiles across the lake plane. No wedge
    /// structure — uniform random across the full ring. Pulses with
    /// timbre + starPulse (same signal as starfield). Reads as
    /// moonlight glints on water, giving the lake surface texture
    /// even between active chromagram wedges.
    @MainActor
    private static func buildStarlightTiles() -> ModelEntity {
        var material = UnlitMaterial()
        let starlightTint = PlatformColor.hdrColor(
            hue: 0.58,
            saturation: 0.12,
            brightness: 0.7,
            hdrBoost: 1.1
        )
        material.color = .init(tint: starlightTint, texture: .init(sharedLakeGlowTexture()))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        material.writesDepth = false

        let entity = ModelEntity(mesh: sharedHexMesh(), materials: [material])
        // Slightly above the wedge tiles (groundY + 0.005) to avoid
        // Z-fighting with the chromagram tiles below. Doesn't shift visible
        // position — 5 mm is sub-perceptible.
        entity.position = [0, groundY + 0.005, 0]

        var rng = SimpleRNG(seed: 0xA0DE_C0DE_4D4F_4F4E)  // "MOON" hex-ish

        var instances = MeshInstancesComponent()
        do {
            let data = try LowLevelInstanceData(instanceCount: starlightTileCount)
            data.withMutableTransforms { transforms in
                for k in 0..<starlightTileCount {
                    // Distributed across the full lake — uniform area
                    // sampling on the annulus [innerRadius, outerRadius].
                    let u = Float(rng.nextUnit())
                    let r = lakeInnerRadius
                        + (lakeOuterRadius - lakeInnerRadius) * sqrt(u)
                    let theta = Float(rng.nextUnit()) * 2 * .pi
                    let pos = SIMD3<Float>(
                        cos(theta) * r,
                        0,
                        sin(theta) * r
                    )
                    // Smaller than chromagram tiles. Small variation.
                    let sizeU = Float(rng.nextUnit())
                    let size = starlightTileRadius * (0.6 + sizeU * 0.8)
                    let rot = Float(rng.nextUnit()) * 2 * .pi
                    var t = Transform()
                    t.translation = pos
                    t.scale = SIMD3<Float>(repeating: size)
                    t.rotation = simd_quatf(angle: rot, axis: [0, 1, 0])
                    transforms[k] = t.matrix
                }
            }
            instances[partIndex: 0] = .init(data: data)
        } catch {
            print("AmbientVisualizer: starlight LowLevelInstanceData init failed: \(error)")
        }
        entity.components.set(instances)
        entity.components.set(AmbientStarlightComponent())
        return entity
    }

    // MARK: - Animate

    @MainActor
    static func animate(
        _ root: Entity,
        clock: Double,
        frames: [FeatureFrame],
        deltaTime: Double,
        appResetCounter: Int = -1
    ) {
        guard var state = root.components[AmbientRootComponent.self] else { return }
        guard !frames.isEmpty else { return }

        // Track-change reset — re-seed smoothing from current frame so
        // we don't visibly lerp through the prior song's last state.
        // Per-instance starfield pulses get reset inside applyStarfieldState
        // since they live on the starfield's own component.
        if appResetCounter >= 0 && appResetCounter != state.lastSeenResetCounter {
            state.wedgePulses = .init(repeating: 0, count: 12)
            state.starlightPulse = 0
            state.lastFrameIndex = -1
            state.firstAnimateTick = true
            state.lastSeenResetCounter = appResetCounter
            // Tier A/B/C state — reset so the new song doesn't inherit
            // the prior song's energy arc or beat phase.
            state.slowLoudness = 0
            state.songIntensity = 0
            state.trailingIntensity = 0
            state.smoothedComplexity = 0
            state.beatCounter = 0
            state.lastBurstTime = -1000
            // Reset drift clock too — tiles would otherwise teleport to
            // wherever the sin curve happens to be at reset time. Restart
            // at 0 so drift begins from base positions on the new song.
            state.elapsedTime = 0
        }

        // Accumulate elapsed time for the per-tile drift sin/cos in
        // applyWedgeState. Float is fine for the drift math — even after
        // hours of playback we're nowhere near precision-loss territory
        // for sin/cos arguments.
        state.elapsedTime += Float(deltaTime)

        // Current frame index from playback clock.
        let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
        let f = frames[i]

        // First-tick init / post-reset re-seed — snap smoothed values to
        // current frame's signal.
        if state.firstAnimateTick {
            for k in 0..<12 {
                state.smoothedChromagram[k] = f.chromagram[k]
            }
            state.smoothedLoudness = f.loudness
            state.smoothedTimbre = f.timbreBrightness
            state.slowLoudness = f.loudness
            state.songIntensity = max(0, min(1,
                state.slowLoudness * intensityScale))
            state.trailingIntensity = state.songIntensity
            state.smoothedComplexity = f.harmonicComplexity
            state.beatCounter = 0
            state.lastBurstTime = -1000
            state.firstAnimateTick = false
        }

        // Onset detection — walk newly arrived frames since last tick.
        // Each onset:
        //   • bumps the dominant-pitch-class WEDGE pulse (positional —
        //     only that wedge brightens)
        //   • bumps the LAKE-HIGHLIGHT pulse uniformly (water-glisten
        //     sheen on every beat)
        //   • adds to `newOnsetCount` which is handed to the starfield
        //     handler so it can pick a random subset of stars to bloom
        //     (NON-uniform — scattered sky sparkle, not a global flash).
        //
        // Loudness gate: the onset detector fires false positives on
        // silent input (background mic noise, quiet system-audio
        // bleed). Without a gate, starlight tiles would flash like
        // brief white "lightning" over the lake even with no music
        // playing — eye picks them up most clearly where they sit on
        // the dark water-haze patches. Skipping onset effects below
        // `onsetLoudnessGate` keeps silence visually quiet while
        // letting any real audio through (peak music loudness ≈ 0.25,
        // so gate at 0.02 catches everything intended).
        let onsetLoudnessGate: Float = 0.02
        var newOnsetCount = 0
        // Beat-tracker output, harvested across the same frame range as
        // the onset scan. Used to drive the starfield bloom in a
        // rhythmically-locked way: when the beat tracker is confident
        // ([[beat-tracker]]), `beatTrigger` fires on the predicted beat
        // grid (even during sustained passages with no real onsets),
        // and the starfield blooms ~50% of stars per beat. When
        // confidence is low we fall back to onset-driven bloom.
        var newBeatTriggerCount = 0
        var latestBeatConfidence: Float = 0
        if state.lastFrameIndex < i {
            let start = max(0, state.lastFrameIndex + 1)
            for k in start...i {
                if frames[k].onset && frames[k].loudness > onsetLoudnessGate {
                    let chroma = frames[k].chromagram
                    var dominant = 0
                    var best: Float = -1
                    for j in 0..<12 where chroma[j] > best {
                        best = chroma[j]
                        dominant = j
                    }
                    state.wedgePulses[dominant] = min(1.2,
                        state.wedgePulses[dominant] + wedgePulseBump)
                    state.starlightPulse = min(1.4,
                        state.starlightPulse + starlightPulseBump)
                    newOnsetCount += 1
                }
                if frames[k].beat.beatTrigger {
                    newBeatTriggerCount += 1
                }
            }
            latestBeatConfidence = frames[i].beat.confidence
        }
        state.lastFrameIndex = i

        // Decay wedge + starlight pulses. Per-instance star pulses
        // decay inside applyStarfieldState (they live on the starfield
        // component, not root).
        let wedgeDecay = Float(exp(-Double(wedgePulseDecay) * deltaTime))
        for j in 0..<12 { state.wedgePulses[j] *= wedgeDecay }
        let starlightDecay = Float(exp(-Double(starlightPulseDecay) * deltaTime))
        state.starlightPulse *= starlightDecay

        // Smooth chromagram bin weights toward the current frame's
        // per-bin-max-normalized values. Normalizing makes streak/wedge
        // intensities feel consistent regardless of how loud the song is.
        let chromaMax = f.chromagram.max() ?? 1
        let chromaNorm = chromaMax > 0.0001 ? chromaMax : 1
        let chromaLerp = Float(min(1.0, deltaTime * Double(chromaLerpRate)))
        for k in 0..<12 {
            let normalized = f.chromagram[k] / chromaNorm
            state.smoothedChromagram[k] +=
                (normalized - state.smoothedChromagram[k]) * chromaLerp
        }

        // Smooth loudness + timbre.
        let loudLerp = Float(min(1.0, deltaTime * Double(loudnessLerpRate)))
        state.smoothedLoudness +=
            (f.loudness - state.smoothedLoudness) * loudLerp
        let timbreLerp = Float(min(1.0, deltaTime * Double(timbreLerpRate)))
        state.smoothedTimbre +=
            (f.timbreBrightness - state.smoothedTimbre) * timbreLerp

        // Song-section intensity — much slower EMA of loudness (~10 s
        // settle time) so it reads as the song's energy arc rather
        // than instantaneous level. Drives starfield bloom fraction so
        // the sky comes alive during choruses and settles during
        // verses. See [[ambient]] for tuning notes.
        let slowLerp = Float(min(1.0, deltaTime * Double(slowLoudnessLerpRate)))
        state.slowLoudness +=
            (f.loudness - state.slowLoudness) * slowLerp
        state.songIntensity = max(0, min(1, state.slowLoudness * intensityScale))

        // Even-slower trailing intensity — used as reference baseline
        // for detecting verse→chorus jumps. When current `songIntensity`
        // pulls noticeably above this trailing value, that's a "drop"
        // moment and we fire an all-stars burst (see Tier C in
        // [[ambient]]).
        let trailingLerp = Float(min(1.0,
            deltaTime * Double(trailingIntensityLerpRate)))
        state.trailingIntensity +=
            (state.songIntensity - state.trailingIntensity) * trailingLerp

        // Smooth harmonic complexity for the star saturation tint
        // (Tier C). Raw signal is twitchy at 30 fps; this lerp gives
        // a ~2 s settle so saturation changes feel like "this section
        // is dense" rather than per-frame jitter.
        let complexityLerp = Float(min(1.0,
            deltaTime * Double(complexityLerpRate)))
        state.smoothedComplexity +=
            (f.harmonicComplexity - state.smoothedComplexity) * complexityLerp

        // Apply to scene children.
        let breath = 1.0 + state.smoothedLoudness * breathAmplitude
        for child in root.children {
            if let wc = child.components[AmbientWedgeComponent.self] {
                applyWedgeState(child, wedge: wc, state: state, breath: breath)
            } else if child.components[AmbientStarfieldComponent.self] != nil {
                applyStarfieldState(child, state: &state,
                                    newOnsetCount: newOnsetCount,
                                    newBeatTriggerCount: newBeatTriggerCount,
                                    beatConfidence: latestBeatConfidence,
                                    deltaTime: deltaTime)
            } else if child.components[AmbientStarlightComponent.self] != nil {
                applyStarlightState(child, state: state)
            } else if child.components[AmbientCausticsComponent.self] != nil {
                applyCausticsState(child, state: state)
            } else if child.components[AmbientWaterHazeComponent.self] != nil {
                applyWaterHazeState(child, state: state)
            } else if child.components[AmbientWaterSurfaceComponent.self] != nil {
                applyWaterSurfaceState(child, state: &state)
            } else if child.components[AmbientNebulaComponent.self] != nil {
                applyNebulaState(child, state: state)
            } else if child.components[AmbientHorizonGlowComponent.self] != nil {
                applyHorizonGlowState(child, state: state)
            }
        }

        root.components.set(state)
    }

    /// Drive a single wedge's material from its smoothed chromagram weight
    /// + onset pulse AND apply per-tile drift to the instance transforms.
    /// Intensity shapes opacity / HDR / brightness for the "this wedge's
    /// pitch is active" cue; drift gives the lake its "this surface is
    /// flowing" cue (tiles bobbing and swirling in slow autonomous motion).
    @MainActor
    private static func applyWedgeState(
        _ entity: Entity,
        wedge wc: AmbientWedgeComponent,
        state: AmbientRootComponent,
        breath: Float
    ) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var mat = modelComp.materials.first as? UnlitMaterial,
              var instances = model.components[MeshInstancesComponent.self]
        else { return }
        let k = wc.pitchClassIndex

        let chromaWeight = state.smoothedChromagram[k]
        let pulse = state.wedgePulses[k]
        let intensity = min(1.5, chromaWeight + pulse * 0.6)

        // SQUARED-intensity alpha curve preserves dynamic range between
        // dormant and active wedges. Cap raised 0.55 → 0.85 so active
        // wedges punch through the now-tinted water surface more
        // forcefully. Dormant wedges still nearly vanish (intensity 0
        // → alpha 0.02 → effective center alpha ~0.015 against the
        // 0.75 glow peak).
        let alpha = min(0.85, 0.02 + intensity * intensity * 0.85)
        // HDR boost bumped 0.7 → 1.1 so the peak wedge HDR-pops on a
        // capable display rather than just maxing out at SDR white.
        let hdrBoost: CGFloat = 1.0 + CGFloat(intensity) * 1.1

        let pitchClass = PitchClass(rawValue: k) ?? .c
        // Brightness floor lifted 0.40 → 0.55, peak unchanged at 0.95.
        // The floor matters more than the peak for diffusion read —
        // even quiet wedges contribute visibly to the lake's colored
        // blur rather than disappearing entirely.
        let tint = PlatformColor.hdrColor(
            hue: CGFloat(pitchClass.circleOfFifthsHue),
            saturation: 0.65,
            brightness: CGFloat(0.55 + intensity * 0.40),
            hdrBoost: hdrBoost
        )

        mat.color = .init(tint: tint, texture: mat.color.texture)
        mat.blending = .transparent(opacity: .init(floatLiteral: alpha))
        mat.writesDepth = false
        modelComp.materials[0] = mat
        model.components.set(modelComp)

        // Breath — the whole wedge expands/contracts vertically by ≤5%.
        // Applied as Y-scale on the wedge entity (the tile instances live
        // at y=0 in the entity's local frame, so Y-scale moves them
        // slightly off the lake surface during the swell — subtle but
        // adds life to the still scene). The X/Z scales also drift
        // slightly so tiles "breathe" radially with the music.
        entity.scale = SIMD3<Float>(1, breath, 1)

        // Per-tile drift — rebuild the LowLevelInstanceData transforms
        // each tick. Each tile traces a small circle in XZ around its
        // base position (radius = driftAmplitudeXZ) at its own random
        // frequency + phase, and bobs in Y with an independent phase.
        // Together this reads as gentle fluid flow on the lake surface.
        //
        // Cost: ~80 tiles × 12 wedges = 960 transforms per frame across
        // all wedges. Each transform = a few sin/cos + matrix construction.
        // Comfortably within budget on modern CPUs at 60 fps.
        let t = state.elapsedTime
        if let part = instances[partIndex: 0] {
            part.data.replaceMutableTransforms { transforms in
                for j in 0..<wc.basePositions.count {
                    let freq = wc.freqs[j]
                    let phaseXZ = wc.phasesXZ[j]
                    let phaseY = wc.phasesY[j]
                    let angle = 2 * .pi * freq * t + phaseXZ
                    let dx = cos(angle) * driftAmplitudeXZ
                    let dz = sin(angle) * driftAmplitudeXZ
                    let dy = sin(2 * .pi * freq * t + phaseY) * driftAmplitudeY
                    var trans = Transform()
                    trans.translation = wc.basePositions[j]
                        + SIMD3<Float>(dx, dy, dz)
                    trans.scale = SIMD3<Float>(repeating: wc.baseSizes[j])
                    trans.rotation = wc.baseRotations[j]
                    transforms[j] = trans.matrix
                }
            }
        }
    }

    /// Drive the starfield material brightness from smoothed timbre, AND
    /// drive per-instance bloom by picking a random subset of stars per
    /// onset and bumping their per-instance pulses (which then scale the
    /// instance transform so those stars visibly grow + brighten).
    ///
    /// Per-tick steps:
    ///   1. Bump `starsToBloomPerOnset` random instance pulses for each
    ///      newly-arrived onset this tick.
    ///   2. Decay all per-instance pulses exponentially.
    ///   3. Update the material tint from smoothed timbre (continuous
    ///      base brightness; no global pulse — the bloom is per-instance).
    ///   4. Rebuild the instance transforms: each instance's translation
    ///      and rotation use the baked base values; its scale is
    ///      `baseSize × (1 + pulse × 2)` so peak-pulse stars are 3× their
    ///      base size and quiet stars are at base size.
    @MainActor
    private static func applyStarfieldState(
        _ entity: Entity,
        state: inout AmbientRootComponent,
        newOnsetCount: Int,
        newBeatTriggerCount: Int,
        beatConfidence: Float,
        deltaTime: Double
    ) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var mat = modelComp.materials.first as? UnlitMaterial,
              var sf = model.components[AmbientStarfieldComponent.self],
              var instances = model.components[MeshInstancesComponent.self]
        else { return }

        // 1. Bloom random instances. Three layered behaviors:
        //
        // (a) BEAT path (primary, when beat tracker confident):
        //     - Bloom fraction driven by `songIntensity` (Tier A) —
        //       quiet verses ~15% of sky, peak choruses ~85%.
        //     - Per-star bump ALSO scales with intensity (Tier B.1) —
        //       quiet pulses are soft (~0.5×base), loud peaks sharp
        //       (~1.8×base). Compose with the bloom-fraction scaling
        //       so quiet sections feel gentle in BOTH "how many" and
        //       "how bright," and choruses feel correspondingly punchy.
        //     - Downbeats (every 4th beat, Tier B.2) get an
        //       emphasized bloom — fraction goes to 1.0 (all stars)
        //       and bump gets a 1.5× multiplier. The off-beats (1, 2,
        //       3 in 4/4) use the intensity-driven fraction. Most
        //       popular music is in 4/4 so this lands; on 3/4 tracks
        //       the "downbeat" rotates which is degraded but not
        //       broken. No real meter detection.
        // (b) BURST path (Tier C.2, fires once per chorus-drop):
        //     - When `songIntensity` jumps above `trailingIntensity`
        //       by more than `burstJumpThreshold`, AND we're past the
        //       refractory window, fire a one-off all-stars bloom at
        //       2× the normal bump. Reads as "the song just dropped."
        // (c) ONSET fallback (beat tracker not confident yet):
        //     - Small random subset per real onset. Same as the
        //       pre-beat-tracking behavior.
        let songEnergy = state.songIntensity
        // Bump scale: ramp from 0.5× (songEnergy=0) to 1.8× (songEnergy=1).
        let bumpScale: Float = 0.5 + songEnergy * 1.3

        // Chorus-drop burst detection (Tier C.2). The trailing
        // intensity is the ~30 s baseline; if current intensity
        // pulled meaningfully above that AND we're past the
        // refractory window, this is a "drop" moment.
        let intensityJump = state.songIntensity - state.trailingIntensity
        let sinceLastBurst = state.elapsedTime - state.lastBurstTime
        if intensityJump > burstJumpThreshold
           && sinceLastBurst > burstRefractory {
            // Burst — bloom ALL stars with 2× bump. Strong visual cue
            // for the moment a song transitions into its loud section.
            let burstBump = starPulseBump * 2.0
            for idx in 0..<sf.pulses.count {
                sf.pulses[idx] = min(2.5, sf.pulses[idx] + burstBump)
            }
            state.lastBurstTime = state.elapsedTime
        }

        let beatLocked = beatConfidence > 0.3
        if beatLocked && newBeatTriggerCount > 0 {
            for _ in 0..<newBeatTriggerCount {
                // Advance beat counter (mod 4) per trigger.
                state.beatCounter = (state.beatCounter + 1) % 4
                let isDownbeat = state.beatCounter == 0

                // Downbeat: full sky + 1.5× bump multiplier.
                // Off-beat: intensity-driven fraction at scaled bump.
                let bloomFraction: Float
                let perStarBump: Float
                if isDownbeat {
                    bloomFraction = 1.0
                    perStarBump = starPulseBump * bumpScale * 1.5
                } else {
                    bloomFraction = 0.15 + songEnergy * 0.70
                    perStarBump = starPulseBump * bumpScale
                }
                for idx in 0..<sf.pulses.count {
                    if Float.random(in: 0..<1) < bloomFraction {
                        sf.pulses[idx] = min(2.0, sf.pulses[idx] + perStarBump)
                    }
                }
            }
        } else if newOnsetCount > 0 {
            let fallbackStarsPerOnset = 10
            for _ in 0..<newOnsetCount {
                for _ in 0..<fallbackStarsPerOnset {
                    let idx = Int.random(in: 0..<sf.pulses.count)
                    sf.pulses[idx] = min(2.0, sf.pulses[idx] + starPulseBump)
                }
            }
        }

        // 2. Decay all per-instance pulses.
        let decay = Float(exp(-Double(starPulseDecay) * deltaTime))
        for j in 0..<sf.pulses.count { sf.pulses[j] *= decay }

        // 3. Material brightness — pure smoothed-timbre, no global pulse.
        // Floor raised + HDR boost lifted so stars stay punchy against
        // the dim nebula. Star HUE shifts mildly toward the song's
        // dominant pitch (saturation stays low, ~0.20, so they read
        // as "barely-tinted starlight" rather than colored points).
        // The sky itself stays static — Jesse's call: only the stars
        // carry the song color.
        let timbre = state.smoothedTimbre
        let intensity = min(1.0, 0.85 + timbre * 0.15)
        let hdrBoost: CGFloat = 2.0 + CGFloat(intensity) * 0.8

        // Sample dominant pitch's hue for star tint. argmax of the
        // smoothed chromagram — same source as the water surface.
        var domIdx = 0
        var domWeight: Float = 0
        for k in 0..<state.smoothedChromagram.count
        where state.smoothedChromagram[k] > domWeight {
            domWeight = state.smoothedChromagram[k]
            domIdx = k
        }
        let pitchClass = PitchClass(rawValue: domIdx) ?? .c
        // Lerp from neutral cool-white (hue 0.6, classic starlight)
        // toward pitch hue, weighted by dominant weight × 0.6 cap.
        // At dom weight 1.0: 60% toward pitch hue. Saturation stays
        // capped at 0.20 even at full tint — these are STARS, not
        // colored gems.
        let neutralHue: CGFloat = 0.6
        let pitchHue = CGFloat(pitchClass.circleOfFifthsHue)
        let tintFactor = CGFloat(min(1.0, domWeight)) * 0.6
        // Shortest-path hue lerp (treat hue as circular). Compute
        // difference, wrap to [-0.5, 0.5], then lerp.
        var hueDelta = pitchHue - neutralHue
        if hueDelta > 0.5 { hueDelta -= 1.0 }
        if hueDelta < -0.5 { hueDelta += 1.0 }
        var hue = neutralHue + hueDelta * tintFactor
        if hue < 0 { hue += 1 }
        if hue >= 1 { hue -= 1 }
        // Tier C.1 — harmonic complexity modulates how much chromatic
        // tint actually paints the stars. At low complexity (sparse,
        // monophonic passages) saturation stays low — stars read as
        // near-pure starlight. At high complexity (dense harmonized
        // textures) saturation gets a meaningful boost so the
        // song's chromatic feel propagates into the sky. Smoothed
        // complexity has been observed to sit in ~0.1–0.6 range on
        // real music, so a ×1.5 scale gives a reasonable 0.15–0.9
        // modulation factor.
        let complexityBoost = CGFloat(
            min(1.0, state.smoothedComplexity * 1.5)
        )
        let saturation: CGFloat =
            0.05 + 0.15 * tintFactor * (0.4 + 0.6 * complexityBoost)

        let tint = PlatformColor.hdrColor(
            hue: hue,
            saturation: saturation,
            brightness: CGFloat(intensity),
            hdrBoost: hdrBoost
        )
        mat.color = .init(tint: tint, texture: mat.color.texture)
        modelComp.materials[0] = mat
        model.components.set(modelComp)

        // 4. Rebuild instance transforms with per-instance pulsed scale.
        if let part = instances[partIndex: 0] {
            part.data.replaceMutableTransforms { transforms in
                for k in 0..<sf.basePositions.count {
                    let pulsedScale = sf.baseSizes[k] * (1 + sf.pulses[k] * 2)
                    var t = Transform()
                    t.translation = sf.basePositions[k]
                    t.scale = SIMD3<Float>(repeating: pulsedScale)
                    t.rotation = sf.baseRotations[k]
                    transforms[k] = t.matrix
                }
            }
        }
        model.components.set(sf)
    }

    /// Drive the ShaderGraphMaterial's `time` parameter from the root
    /// component's elapsed time. Stage B of the RCP experiment: the
    /// material's shader graph (authored in `Immersive.usda`) reads
    /// `time` to scroll the noise UVs, producing animated water flow.
    /// If the material isn't a ShaderGraphMaterial (Stage A fallback to
    /// UnlitMaterial), this is a silent no-op.
    @MainActor
    private static func applyWaterSurfaceState(_ entity: Entity, state: inout AmbientRootComponent) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var shader = modelComp.materials.first as? ShaderGraphMaterial
        else { return }

        // Stage C — derive chromaColor + chromaMix from the smoothed
        // chromagram. Earlier attempt used TonalColor's vector-sum
        // hue, but on real music the saturation field rides at
        // 0.05–0.15 because energy spreads across many pitches; that
        // collapsed the chroma tint to near-white. Instead, pick the
        // dominant pitch class and use ITS circle-of-fifths hue at
        // full HSB saturation, then gate the mix by the dominant
        // pitch's weight (typically 0.3–1.0 on tonal content).
        let chroma = state.smoothedChromagram
        var domIdx = 0
        var domWeight: Float = 0
        for k in 0..<chroma.count where chroma[k] > domWeight {
            domWeight = chroma[k]
            domIdx = k
        }
        let pitchClass = PitchClass(rawValue: domIdx) ?? .c
        let targetColor = PlatformColor(
            hue: CGFloat(pitchClass.circleOfFifthsHue),
            saturation: 0.85,
            brightness: 1.0,
            alpha: 1
        )
        let (tr, tg, tb, _) = targetColor.rgbaComponents()
        let target = SIMD3<Float>(Float(tr), Float(tg), Float(tb))

        // EMA-smooth the chromaColor RGB toward the dominant pitch's
        // hue. Without this, argmax flips between near-tied bins every
        // chromagram update and the lake colour flickers discretely.
        // Smoothing the *output* RGB (not just the chromagram bins)
        // gives buttery crossfades that survive upstream jitter. Lerp
        // ~0.04 per frame @ ~110 fps → 90% convergence in ~0.5s.
        let lerp: Float = 0.04
        state.smoothedWaterRGB += (target - state.smoothedWaterRGB) * lerp

        let smoothedRGB = state.smoothedWaterRGB
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let chromaCG = CGColor(
            colorSpace: cs,
            components: [CGFloat(smoothedRGB.x), CGFloat(smoothedRGB.y), CGFloat(smoothedRGB.z), 1]
        ) ?? targetColor.cgColor

        // Mix-strength constant — caps the BASE chroma bleed. Stepped
        // 0.55 → 0.40 → 0.27 (cut another 33% per Jesse's brief once
        // the new procedural caustics made the lake read clearly as
        // water; the chroma tint was the last "competing" element).
        // Loudness still gradually pumps the tint via the boost factor.
        let chromaMixStrength: Float = 0.27
        let loud = state.smoothedLoudness
        let loudnessBoost = 1.0 + Double(loud) * 1.2
        // Final cap also dropped 33% (0.55 → 0.37) so even peak loud
        // chord on a strongly-tonal song stays subtle.
        let chromaMix = min(0.37,
            Double(min(1.0, domWeight)) * Double(chromaMixStrength) * loudnessBoost
        )

        // Sparkle density driven by loudness — Stage C's audio
        // reactivity, finally landed. Baseline 0.5 (visible glints at
        // rest), scaled by loudness ×5 so typical loudness of 0.1 →
        // 1.0 (full sparkle), peaks at 0.25+ push to ~1.75 (very
        // bright pumping glints). The shader's mix clamps internally
        // so values >1 don't blow out.
        let sparkleAmount: Float = 0.5 + loud * 5.0

        try? shader.setParameter(name: "time", value: .float(state.elapsedTime))
        try? shader.setParameter(name: "chromaColor", value: .color(chromaCG))
        try? shader.setParameter(name: "chromaMix", value: .float(Float(chromaMix)))
        try? shader.setParameter(name: "loudness", value: .float(loud))
        try? shader.setParameter(name: "sparkleAmount", value: .float(sparkleAmount))
        modelComp.materials[0] = shader
        model.components.set(modelComp)
    }

    /// Drive the horizon glow's tint from the chromagram dominant
    /// pitch + loudness, so the band at the lake's far edge reads as
    /// a "chromagram band" — visibly shifting color with the song's
    /// tonal center. The vertical gradient itself stays texture-
    /// driven (the cylinder mesh + horizon gradient texture handle
    /// the procedural-looking falloff at top/bottom without needing
    /// shader-side UV.y separation, which RealityKit's MaterialX
    /// doesn't expose).
    @MainActor
    private static func applyHorizonGlowState(_ entity: Entity, state: AmbientRootComponent) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var mat = modelComp.materials.first as? UnlitMaterial
        else { return }

        // Find dominant pitch (same source as water).
        var domIdx = 0
        var domWeight: Float = 0
        for k in 0..<12 where state.smoothedChromagram[k] > domWeight {
            domWeight = state.smoothedChromagram[k]
            domIdx = k
        }
        let pitchClass = PitchClass(rawValue: domIdx) ?? .c

        // Lerp hue from neutral moonlight cool (0.58) toward the
        // dominant pitch's hue. Shortest-path circular hue lerp.
        let baseHue: CGFloat = 0.58
        let pitchHue = CGFloat(pitchClass.circleOfFifthsHue)
        let chromaInfluence = CGFloat(min(1.0, domWeight)) * 0.45  // 0..0.45
        var hueDelta = pitchHue - baseHue
        if hueDelta > 0.5 { hueDelta -= 1.0 }
        if hueDelta < -0.5 { hueDelta += 1.0 }
        var hue = baseHue + hueDelta * chromaInfluence
        if hue < 0 { hue += 1 }
        if hue >= 1 { hue -= 1 }

        // Saturation lifts slightly when a pitch is strongly active —
        // band reads as "deeper colored" on chord moments.
        let saturation: CGFloat = 0.30 + 0.25 * chromaInfluence
        // Brightness pumps mildly with loudness so loud passages
        // brighten the horizon — visible chromagram band effect.
        let loud = CGFloat(state.smoothedLoudness)
        let brightness: CGFloat = 0.40 + 0.20 * min(1.0, loud * 2.0)

        let tint = PlatformColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 0.35
        )
        mat.color = .init(tint: tint, texture: mat.color.texture)
        modelComp.materials[0] = mat
        model.components.set(modelComp)
    }

    /// Push per-tick uniforms to the nebula sky shader. Reuses
    /// `smoothedWaterRGB` so the sky and water tint cohesively — the
    /// whole scene shifts color together as the song's tonal center
    /// moves. Capped at `nebulaChromaMixStrength` since the nebula
    /// covers the entire sky and a strong tint would overwhelm.
    @MainActor
    private static func applyNebulaState(_ entity: Entity, state: AmbientRootComponent) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var shader = modelComp.materials.first as? ShaderGraphMaterial
        else { return }

        // Dominant pitch weight gates the chroma bleed (same source as
        // water's chromaMix). Find it by argmax of the smoothed
        // chromagram — cheap, ~12 floats.
        var domWeight: Float = 0
        for k in 0..<state.smoothedChromagram.count
        where state.smoothedChromagram[k] > domWeight {
            domWeight = state.smoothedChromagram[k]
        }
        let chromaMix = Double(min(1.0, domWeight)) * Double(nebulaChromaMixStrength)

        let rgb = state.smoothedWaterRGB
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let chromaCG = CGColor(
            colorSpace: cs,
            components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1]
        )

        try? shader.setParameter(name: "time", value: .float(state.elapsedTime))
        if let chromaCG {
            try? shader.setParameter(name: "chromaColor", value: .color(chromaCG))
        }
        try? shader.setParameter(name: "chromaMix", value: .float(Float(chromaMix)))
        modelComp.materials[0] = shader
        model.components.set(modelComp)
    }

    /// Drive the lake-highlight starlight tiles. Different signal than
    /// the sky starfield: a UNIFORM `starlightPulse` modulates the whole
    /// layer, reading as "the water glistens" on each beat. Distinct
    /// from the sky's per-instance random bloom — two different visual
    /// languages for the same musical events.
    @MainActor
    private static func applyStarlightState(_ entity: Entity, state: AmbientRootComponent) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var mat = modelComp.materials.first as? UnlitMaterial
        else { return }

        let timbre = state.smoothedTimbre
        let pulse = state.starlightPulse
        // Substantially dialed back from v1 (was 0.5 + 0.3 timbre + 0.5
        // pulse with HDR boost 0.7 and alpha cap 0.6). The bright white
        // dots read as "lo-fi reflections of stars" — discrete pixels
        // on the water — rather than subtle surface flecks. New formula
        // keeps the timbre-responsive shimmer but at a fraction of the
        // brightness.
        let intensity = 0.2 + timbre * 0.2 + pulse * 0.3
        let hdrBoost: CGFloat = 1.0 + CGFloat(min(1.5, intensity)) * 0.3
        let alpha = min(0.30, 0.10 + intensity * 0.25)
        let tint = PlatformColor.hdrColor(
            hue: 0.58,
            saturation: 0.15,
            brightness: CGFloat(min(0.85, intensity)),
            hdrBoost: hdrBoost
        )
        mat.color = .init(tint: tint, texture: mat.color.texture)
        mat.blending = .transparent(opacity: .init(floatLiteral: alpha))
        modelComp.materials[0] = mat
        model.components.set(modelComp)
    }

    // MARK: - Mesh + texture builders

    /// Flat hexagon in the XZ plane (normal = +Y). Center at origin, 6
    /// outer vertices at the given radius, fanned via 6 triangles. UVs
    /// map center to (0.5, 0.5) and outer ring to a unit-circle inscribed
    /// in (0, 0)–(1, 1), so the radial glow texture renders cleanly.
    ///
    /// Winding: CCW when viewed from +Y (looking down at the lake), so
    /// default back-face culling shows the upper face to a camera above.
    private static func makeHexMesh(radius: Float) -> MeshResource {
        var positions: [SIMD3<Float>] = [[0, 0, 0]]
        var normals: [SIMD3<Float>] = [[0, 1, 0]]
        var texCoords: [SIMD2<Float>] = [[0.5, 0.5]]

        for i in 0..<6 {
            let a = Float(i) / 6 * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * radius, 0, sin(a) * radius))
            normals.append([0, 1, 0])
            // UVs: center at (0.5, 0.5), ring vertices on the unit circle
            // inscribed in the texture's (0, 1)² bounds. The +Z direction
            // (sin(a)) maps to UV +V so the glow texture isn't sheared.
            texCoords.append(SIMD2<Float>(
                0.5 + cos(a) * 0.5,
                0.5 + sin(a) * 0.5
            ))
        }

        var indices: [UInt32] = []
        for i in 0..<6 {
            let curr = UInt32(i + 1)
            let next = UInt32(((i + 1) % 6) + 1)
            // Winding fix (2026-05-22): vertex `curr` is at angle
            // `i × 60°` in XZ plane (cos in X, sin in Z). [0, curr, next]
            // is CCW when viewed from -Y (below the lake) — geometric
            // normal points in -Y, so the visible face is the lake's
            // UNDERSIDE. From the camera above, we see only the
            // back-face-culled bottom and the lake is invisible.
            // [0, next, curr] flips the winding so the +Y face is the
            // front and the lake is visible from above. (This was the
            // root cause of the "no color, just stars" symptom even
            // after fixing the billboarding-hijack and bumping tile
            // visibility.)
            indices.append(contentsOf: [0, next, curr])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            // Fallback — should never happen for this trivial mesh.
            return .generatePlane(width: radius * 2, height: radius * 2)
        }
    }

    /// Star sprite — small XY-plane quad facing +Z. Billboarded at runtime.
    private static func makeStarQuadMesh(size: Float) -> MeshResource {
        let h = size / 2
        let positions: [SIMD3<Float>] = [
            [-h, -h, 0], [ h, -h, 0], [ h,  h, 0], [-h,  h, 0]
        ]
        let normals: [SIMD3<Float>] = Array(repeating: [0, 0, 1], count: 4)
        let texCoords: [SIMD2<Float>] = [
            [0, 1], [1, 1], [1, 0], [0, 0]
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generatePlane(width: size, height: size)
        }
    }

    /// Soft long-tail radial glow texture for LAKE tiles (wedges +
    /// starlight). Low peak alpha (~0.55) and gradual fade so:
    ///   • Individual hex shapes dissolve completely — the geometry's
    ///     6-vertex silhouette is invisible because the gradient is
    ///     at near-zero alpha by the time it reaches the outer edge.
    ///   • Overlapping tiles ACCUMULATE into Clouds-style color washes.
    ///     With per-tile material alpha capped low and texture alpha
    ///     low, no single tile is visually loud — but a wedge full of
    ///     overlapping tiles builds into a continuous soft glow.
    ///
    /// Four-stop gradient — the extra mid stop gives the alpha curve
    /// a longer plateau before the soft fade.
    private static func makeLakeGlowTexture() -> TextureResource {
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
        // Heavily feathered bell-curve falloff with extra stops for
        // smooth interpolation. Alpha is essentially zero by radius
        // 0.85 so the hex MESH's perimeter (which cuts off the
        // texture sample at the polygon edge) falls inside the
        // transparent region — eliminates the "I can see hex-shaped
        // edges" artifact. Peak slightly raised (0.75 → 0.80) to
        // compensate for the inward-pulled falloff. Eight stops
        // (vs four) gives CGGradient finer slope segments to draw,
        // killing the linear-interpolation banding.
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.80),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.72),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.58),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.40),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.01),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.00)
            ] as CFArray,
            locations: [0.0, 0.15, 0.30, 0.45, 0.60, 0.75, 0.88, 1.0]
        )!
        ctx.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: radius,
            options: []
        )

        return try! TextureResource(
            image: ctx.makeImage()!,
            withName: "ambient-lake-glow",
            options: .init(semantic: .color)
        )
    }

    /// Sharper radial glow texture for SKY stars. Higher peak alpha
    /// and steeper falloff so each per-instance-bloomed star reads as
    /// a discrete sparkle rather than a soft blob. (Same shape as the
    /// Rings + Slipstream glow textures.)
    private static func makeStarGlowTexture() -> TextureResource {
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
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.50),
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
            withName: "ambient-star-glow",
            options: .init(semantic: .color)
        )
    }
}

/// Tiny seeded PRNG — local to Ambient. Linear-congruential, fine for
/// non-cryptographic visual seeding. Same shape as the prior version.
private struct SimpleRNG {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
