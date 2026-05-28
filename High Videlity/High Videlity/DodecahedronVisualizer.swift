//
//  DodecahedronVisualizer.swift
//  High Videlity
//
//  Dodecahedron — meditative, symmetric, mathematically clean mode. A
//  regular dodecahedron has exactly 12 pentagonal faces — perfect 1:1
//  mapping with the chromagram's 12 pitch classes. Each face is tinted
//  with that pitch class's circle-of-fifths hue and brightens with the
//  bin's energy weight in real time. The whole assembly rotates slowly
//  so faces tumble in and out of view.
//
//  Distinct from the other modes: this is the only one centered on a
//  SOLID OBJECT (rather than a scene of particles / glow elements).
//  The viewer's relationship is "watching an object react" — closer
//  to a sculpture than a landscape. Most static and contemplative of
//  the set.
//
//  Audio → visual mapping (Phase 1):
//  • Chromagram bin k → face[k] brightness + saturation
//  • Onset → strong pulse on dominant pitch's face (decay ~1 s)
//  • Loudness → overall HDR boost on all faces
//  • Timbre brightness → edge-glow accent
//  • Slow continuous rotation around Y axis + slow secondary X tumble
//
//  Deferred for a Phase 2 if Jesse likes it:
//  • Shatter-on-strong-onset (faces explode outward, then re-assemble)
//  • Songintensity / complexity → rotation speed
//  • Center-glow that brightens on loud peaks
//

import RealityKit
import AudioAnalysis
import CoreGraphics
import simd
import RealityKitContent
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-root state. Drives smoothing, per-face onset pulses, accumulated
/// rotation angle, the track-change reset cursor, AND the per-band
/// envelopes (shockwave for sub, sparkle for brilliance) introduced
/// by the multi-band routing.
struct DodecahedronRootComponent: Component {
    /// EMA-smoothed per-band chromagrams — length-12 arrays for the
    /// two harmonically-relevant bands. Drive per-face brightness
    /// (highMid → emissive, lowMid → outer-halo beam fan). The other
    /// two bands (sub / brilliance) are off the chroma scale and
    /// don't get a smoothed chromagram here.
    var smoothedHighMidChroma: [Float] = Array(repeating: 0, count: 12)
    var smoothedLowMidChroma: [Float] = Array(repeating: 0, count: 12)
    /// Per-face onset pulse — bumped when an onset's dominant pitch
    /// class matches this face, decays exponentially. Adds extra punch
    /// on top of the chromagram-driven baseline.
    var pulses: [Float] = Array(repeating: 0, count: 12)
    /// Smoothed full-spectrum loudness — drives global HDR boost
    /// (the whole solid gets brighter during loud sections).
    var smoothedLoudness: Float = 0
    /// Smoothed timbre — drives a subtle accent we'll add later.
    var smoothedTimbre: Float = 0
    /// Sparkle envelope (0…1). Bumped to 1.0 by brilliance-band
    /// onsets (hats / shakers / cymbals); decays exponentially.
    /// Drives the orbiting sparkle pool's brightness.
    var sparkleEnergy: Float = 0
    /// Smoothed brilliance-band loudness — provides a continuous
    /// "shimmer baseline" on the sparkle pool even between hat hits.
    var smoothedBrilliance: Float = 0
    /// Bass-pulse envelope — drives the whole-dodec "punch" on
    /// each bass onset. Set to a loudness-scaled amplitude on every
    /// bass-stem onset (or lowMid-band onset fallback), then decays
    /// exponentially with ~200ms half-life so the structure visibly
    /// snaps + relaxes with each bass hit. Replaces the earlier
    /// continuous-breath approach which read as sub-perceptible at
    /// any setting because raw stem RMS rarely exceeds ~0.3.
    var bassPulse: Float = 0
    /// Running peak of raw bass loudness for per-onset amplitude
    /// normalization. Raw stem RMS peaks at ~0.2-0.4 (varies by
    /// song), so we divide loudness-at-onset by this to get a 0-1
    /// punch amplitude that reliably fills the visible range no
    /// matter how the song was mastered. Jumps up instantly, decays
    /// with ~30s half-life. Floor at 0.05 prevents divide-by-tiny
    /// during silent intros.
    var bassLoudnessPeak: Float = 0.05
    /// EMA-smoothed bass chromagram (12 pitch-class energies). Drives
    /// the interior glow color so it tracks the dominant bass note.
    /// Lerped at ~12 Hz so the hue settles quickly after a new bass
    /// note enters without strobing on transients.
    var smoothedBassChroma: [Float] = Array(repeating: 0, count: 12)
    /// Smoothed "other" stem loudness — drives the per-tick final
    /// multiplier on face-beam opacities so beams dim during quiet
    /// passages and slam during loud ones. Source: stems["other"]?
    /// .loudness when available, falls back to `f.loudness` (full
    /// mix). Normalized via `otherLoudnessPeak` so the curve fills
    /// [0, 1] regardless of song mastering.
    var smoothedOtherLoudness: Float = 0
    /// Running peak of raw "other"-stem loudness for per-song
    /// normalization. Same pattern as `bassLoudnessPeak` — instant
    /// rise + 30s half-life decay + 0.05 floor.
    var otherLoudnessPeak: Float = 0.05
    /// Smoothed vocals loudness — drives the vocal-aura ring's
    /// opacity + emissive intensity. Source: stems["vocals"]?.loudness;
    /// when no vocals stem is loaded the aura stays dark (the design
    /// intent: aura is a stems-only feature, no band-fallback because
    /// no full-mix band cleanly isolates vocals).
    var smoothedVocalsLoudness: Float = 0
    /// Smoothed vocals chromagram — used to pick the dominant vocal
    /// pitch and tint the aura ring through the circle-of-fifths
    /// palette. Each entry EMA-lerped at the same rate as the other
    /// chromagrams so the color settles smoothly.
    var smoothedVocalsChroma: [Float] = Array(repeating: 0, count: 12)
    /// Per-face beam opacities — separate smoothing track from the
    /// chromagram smoothing above. Lerped each tick toward an
    /// unsmoothed target opacity (derived from the current frame's
    /// normalized chromagram) at a **tempo-driven** rate. Slow songs
    /// → low lerp rate → beams ease in/out; fast songs → high lerp
    /// rate → beams snap on/off. Keeping these separate from the face
    /// emissive smoothing means faces still glow with the steady
    /// `chromaLerpRate` reaction while beams react rhythmically.
    var smoothedCoreOpacity: [Float] = Array(repeating: 0, count: 12)
    var smoothedHaloOpacity: [Float] = Array(repeating: 0, count: 12)
    /// Last `happiness` value (0-100) we applied to the sparkle +
    /// shockwave materials. Materials only get rebuilt when this
    /// changes — happens once per track change (lookup completes
    /// with a new value, or song changes back to a value-less default).
    /// `nil` initially so the first non-nil happiness triggers a refresh.
    var lastAppliedHappiness: Float? = nil
    /// Smoothed `tempoT` (the [0, 1] position between slowBpm and
    /// fastBpm). The beat tracker bounces — confidence falls during
    /// instrumental sections, oscillates between adjacent locks
    /// (e.g. 109↔78 during a section with no clear kick). Smoothing
    /// at ~2 Hz means a brief BPM swing doesn't visually pop the
    /// intensity scale.
    var smoothedTempoT: Float = 0.5
    /// First-tick sentinel for the tempo-T snap (so first frame
    /// snaps to the song's current tempo instead of lerping from
    /// the default 0.5).
    var firstTempoTick: Bool = true
    /// Accumulated rotation angle (radians). Advances each tick by
    /// `rotationSpeed × 2π × deltaTime`. Continuous, never resets
    /// within a song — only on track change so the new song's first
    /// frame starts from the "canonical" facing.
    var rotationAngle: Float = 0
    /// Onset edge-detection cursor — index into `frames` we've already
    /// scanned. Each animate tick walks frames since this cursor.
    var lastFrameIndex: Int = -1
    /// First-tick sentinel — snap smoothing values to current frame
    /// instead of lerping in from zero.
    var firstAnimateTick: Bool = true
    /// `appModel.liveModeResetCounter` at last scan. Bump → track change
    /// → reset smoothing + rotation.
    var lastSeenResetCounter: Int = 0
    /// Disco-ball beat-pulse envelope (0…1). Bumped to 1.0 on each
    /// `frame.bandOnset[sub]` (kick onset); decays at
    /// `discoBallBeatPulseDecay`. Originally driven by `beat.beatTrigger`
    /// (BeatTracker metronome), but that felt "off" on songs with
    /// syncopation or half-time choruses where the tracker predicts
    /// beats the kick doesn't actually hit. Sub-band onsets fire on
    /// the actual kick attack, locking the flash to the percussion.
    var beatPulseEnergy: Float = 0
    /// Accumulated rotation angle for the disco-ball group (separate
    /// track from the dodec's `rotationAngle` so the ball drifts at its
    /// own slow rate independent of the dodec's tumble).
    var discoBallAngle: Float = 0
}

/// Per-face tag. `pitchClassIndex` identifies which of the 12 pitch
/// classes (and which chromagram bin) drives this face's brightness.
struct DodecahedronFaceComponent: Component {
    let pitchClassIndex: Int
    /// Base hue (circle-of-fifths position for this pitch class). Cached
    /// so the apply tick doesn't recompute it from the enum every frame.
    let baseHue: CGFloat
}

/// Distinguishes the two beam-layer groups under each face — the inner
/// "core" stack (thin bright filament) driven by the lead band, and
/// the outer "halo" stack (wide diffuse fan) driven by the bass band.
/// Splitting them this way lets a kick-and-bass groove brighten the
/// halo while a quiet lead leaves the core dim, or vice versa — the
/// listener can see which register is currently driving each pitch.
enum DodecahedronBeamKind {
    case core
    case halo
}

/// Tag for one of the two per-face beam-stack child entities. Animated
/// alpha driven by intensity in `applyState`, only visible at peak.
struct DodecahedronFaceBeamComponent: Component {
    let pitchClassIndex: Int
    let baseHue: CGFloat
    let kind: DodecahedronBeamKind
}

/// Tag for one sparkle in the orbiting brilliance-band particle pool.
/// `phase` is the particle's individual twinkle offset (radians); each
/// tick its opacity is `sparkleEnergy × (0.5 + 0.5 sin(t + phase))`.
struct DodecahedronSparkleComponent: Component {
    let phase: Float
}

/// Tag for the surrounding disco-ball entity (sibling of the rotator
/// under root). Slowly rotates around Y independent of the dodec's
/// own tumble. The disco ball is implemented as a single inverted
/// sphere with an RCP `ShaderGraphMaterial` — the shader handles the
/// per-cell checkerboard and pulse-driven emissive internally, so we
/// don't need per-tile entities anymore.
struct DodecahedronDiscoBallComponent: Component {}

/// Tag for the vocal-aura CONTAINER entity (child of `root`,
/// sibling of the rotator). Holds the per-particle sparkles that
/// form the volumetric "magic cloud" around the dodec. Container's
/// brightness scales with vocals.loudness; individual sparkles
/// twinkle at independent phases for the busy-shimmer effect.
struct DodecahedronVocalAuraComponent: Component {}

/// Tag for an individual vocal-cloud sparkle. Each one carries its
/// own twinkle phase + frequency offset so the cloud doesn't pulse
/// in lockstep. Animate-tick reads these to drive per-particle
/// opacity through a sin curve, multiplied by the global vocals
/// loudness envelope.
struct DodecahedronVocalSparkleComponent: Component {
    /// Random base phase in [0, 2π). Stops every sparkle being at
    /// the same point of its twinkle cycle on first frame.
    var phase: Float = 0
    /// Per-particle twinkle frequency in Hz. Range ~1-3 Hz so the
    /// cloud reads as alive without flicker.
    var frequency: Float = 1.5
    /// Base radial distance from the dodec center. Spread across the
    /// shell radius range so the cloud has depth.
    var radius: Float = 0.55
}

/// Tag for the sparkle CONTAINER entity (sibling of the rotator under
/// root). Holds the brilliance-band sparkle pool, positioned + scaled
/// to match the disco ball's coordinate system (same position offset,
/// same Y-flip) so sparkle local positions live in the same frame the
/// shader's cell UV math uses. Per-tick its Y rotation is synced to
/// the disco ball's `discoBallAngle` so sparkles ride along with the
/// lit-cell pattern they're aligned to.
struct DodecahedronSparkleContainerComponent: Component {}

/// Marker tag for the edge-skeleton container. Holds 30 thin additive
/// boxes laid along the dodec's 30 edges — they sit at the dodec's
/// nominal surface, so when face panels push outward on a bass pulse
/// the underlying glowing edge becomes visible "through the crack."
/// Per-tick the container's edges all get the same tint (driven by
/// dominant bass-stem pitch) and brightness (driven by bassPulse).
struct DodecahedronEdgeSkeletonComponent: Component {}

/// Per-layer tag for one of the three additive layers in the edge
/// stack — `0` = thin bright core, `1` = medium halo, `2` = wide
/// outer halo. The per-tick update reads this to pick the right
/// brightness + hdrBoost ramp for the layer's bassPulse response.
struct DodecahedronEdgeLayerComponent: Component {
    let layerIndex: Int
}

/// Layer parameters for the edge halo stack. Index 0 is the bright
/// thin core that visually IS the crack; indices 1 and 2 are wider
/// dimmer halos that bloom outward and read as "light spilling
/// past the seam." All three are additive, `writesDepth=false`.
struct DodecahedronEdgeLayer {
    let thickness: Float
    let baseBrightness: Float
    let peakBrightness: Float
    let baseHdrBoost: Float
    let peakHdrBoost: Float
}
let dodecahedronEdgeLayers: [DodecahedronEdgeLayer] = [
    .init(thickness: 0.010, baseBrightness: 0.05, peakBrightness: 1.00,
          baseHdrBoost: 0.50, peakHdrBoost: 6.00),
    .init(thickness: 0.030, baseBrightness: 0.03, peakBrightness: 0.70,
          baseHdrBoost: 0.30, peakHdrBoost: 4.00),
    .init(thickness: 0.075, baseBrightness: 0.01, peakBrightness: 0.40,
          baseHdrBoost: 0.20, peakHdrBoost: 2.50),
]

enum DodecahedronVisualizer {

    // MARK: - Tuning constants

    /// Y position of the dodecahedron's center. On visionOS, eye-height
    /// (~1.45 m). On windowed macOS the VisualizerView overrides the
    /// root entity's position to (0, 0, -1.5) so the solid floats in
    /// front of the world-origin camera.
    static let visionEyeHeight: Float = 1.45
    /// Distance forward from the viewer. Closer than typical immersive
    /// scenes — the dodecahedron is an OBJECT-scale subject (you look
    /// at it, not into it), so 0.8 m puts it close enough that the
    /// individual faces are clearly visible and the rotation is
    /// readable.
    static let forwardDistance: Float = -0.8
    /// Circumradius of the dodecahedron (distance from center to each
    /// vertex). 0.40 m gives a ~80 cm cross-section, comfortable at
    /// the 0.8 m forward distance. Inradius ≈ 0.795 × this ≈ 0.32 m,
    /// edge length ≈ 0.714 × inradius — proportions of a true
    /// regular dodecahedron.
    static let dodecahedronRadius: Float = 0.40
    /// Inradius — distance from center to face center. For a regular
    /// dodecahedron the ratio is ~0.795 × circumradius.
    static let dodecahedronInradius: Float = 0.40 * 0.795

    /// Vocal-cloud sparkle count. 80 reads as "dense magic cloud"
    /// without hammering the GPU on per-tick material updates
    /// (existing brilliance pool runs ~60 sparkles fine on M1 Pro).
    static let vocalCloudSparkleCount: Int = 80
    /// Inner / outer radius bounds of the vocal-cloud spherical
    /// shell. Particles distributed across this range for visual
    /// depth — closer ones feel intimate, farther ones halo the
    /// silhouette. Inner radius set just outside the dodec
    /// circumradius (0.40) so sparkles never intersect face geometry,
    /// even at peak bass-breath scale (~+18%).
    static let vocalCloudInnerRadius: Float = 0.50
    static let vocalCloudOuterRadius: Float = 0.72
    /// Per-particle sphere radius. Small enough to read as a
    /// dust-mote sparkle, not a glowing orb. Halved from 0.010 →
    /// 0.005 after Jesse's reaction-pass — original size read as
    /// chunky dots rather than fine sparkles.
    static let vocalCloudSparkleSize: Float = 0.005
    /// Intensity threshold below which a face's beam stays invisible.
    /// Raised 0.55 → 0.75 so only genuinely dominant pitch bins fire
    /// beams. With max-normalized chromagram in [0, 1], a 0.75
    /// threshold typically allows 2–3 beams active at any moment
    /// instead of 7–8, giving a much cleaner read for which pitches
    /// are currently driving the song.
    static let beamIntensityThreshold: Float = 0.75

    /// Outward offset (along face normal) for the beam's near
    /// vertices. Without this, the beam near-end sits exactly on the
    /// face plate's plane, depth-test = LESS fails at equal depth,
    /// and the beam interior (especially the thin inner core) is
    /// occluded by the opaque face plate it's emerging from.
    /// Bumped 5mm → 20mm because the offset is along the FACE
    /// normal, which for partially-side-facing faces only has a
    /// fractional component along the camera-Z axis. A 5mm push
    /// reduced to a sub-millimeter Z-shift for those faces and got
    /// lost in depth-buffer precision. 20mm gives enough headroom
    /// even at oblique angles to win the depth comparison.
    static let beamSurfaceEpsilon: Float = 0.02

    /// Multi-layer beam config — modeled after Crystal's laser beams
    /// (`CrystalVisualizer.swift`). Each face emits a stack of
    /// pentagonal-prism layers using ADDITIVE blending: a thin
    /// near-white core inside progressively wider, dimmer, longer
    /// colored halos. The additive blend means overlapping beams
    /// brighten where they cross, and the multi-layer falloff reads
    /// as soft diffuse light rather than a hard solid stick.
    ///
    /// Per Jesse's design: each inner layer is 93% the length of the
    /// one immediately exterior to it. (Started at 85% but the
    /// 85³ = 61% ratio between core and outer halo felt too disparate;
    /// 93³ = 80% keeps them all roughly the same reach with the
    /// core just slightly shorter than the outermost diffusion.)
    fileprivate struct BeamLayerConfig {
        let widthScale: Float   // 1.0 = same pentagon as face; <1 inside, >1 outside
        let length: Float       // total beam length along face normal
        let brightness: CGFloat
        let saturation: CGFloat
        let hdrBoost: CGFloat
    }
    fileprivate static let beamLayers: [BeamLayerConfig] = [
        // White-hot core — thin pentagon down the middle, SHORTEST.
        //   1.6 × 0.93³ ≈ 1.287
        .init(widthScale: 0.20, length: 1.287,
              brightness: 1.0, saturation: 0.30, hdrBoost: 3.5),
        // Inner halo — bright, just outside the core.
        //   1.6 × 0.93² ≈ 1.384
        .init(widthScale: 0.45, length: 1.384,
              brightness: 0.70, saturation: 1.0, hdrBoost: 2.5),
        // Mid halo — wider, dimmer.
        //   1.6 × 0.93 ≈ 1.488
        .init(widthScale: 0.75, length: 1.488,
              brightness: 0.50, saturation: 1.0, hdrBoost: 2.2),
        // Outer halo — widest, dimmest, longest reach (base 1.6 m).
        // widthScale just barely past 1.0 so the halo slightly
        // overflows the face perimeter — reads as light bleeding
        // around the edge of the pentagon plate.
        .init(widthScale: 1.05, length: 1.600,
              brightness: 0.30, saturation: 1.0, hdrBoost: 2.0),
    ]

    /// Smoothing rates (Hz). Faster than Ambient's because the solid is
    /// the singular focus of attention here — slower smoothing on a
    /// dodecahedron reads as "broken" rather than "calm." 10 Hz means
    /// ~100 ms to fully catch up to a chord change, fast enough that
    /// chord-by-chord progression is visibly tracked.
    static let chromaLerpRate: Float = 10.0
    static let loudnessLerpRate: Float = 1.5
    static let timbreLerpRate: Float = 2.0
    /// Chromagram intensity threshold — bins below this contribute
    /// nothing to face brightness. Dropped 0.15 → 0.05 so more bins
    /// participate visibly; the previous 0.15 floor was suppressing
    /// genuine secondary harmonics that should show as dim faces.
    static let chromaIntensityFloor: Float = 0.05

    /// Per-face onset pulse — bump when onset's dominant pitch matches
    /// this face's index. Decays exponentially.
    static let pulseBump: Float = 0.8
    static let pulseDecay: Float = 1.5 // ~0.45 s half-life

    /// Slow continuous rotation, in revolutions per second around Y.
    /// 0.04 rev/s = one full revolution per 25 s, hypnotic without
    /// being motion-sick-inducing for a stationary viewer.
    static let rotationSpeed: Float = 0.04
    /// Secondary X-tilt rotation — different rate from Y so the solid
    /// doesn't repeat its orientation on a simple period. Creates a
    /// "tumbling" feel rather than "spinning."
    static let tumbleSpeed: Float = 0.018

    // MARK: - Per-band tuning

    /// EMA rate (Hz) for the brilliance + sub band envelopes that drive
    /// the sparkle baseline and shockwave color.
    static let bandLoudnessLerpRate: Float = 4.0

/// Brilliance-band onset bumps the sparkle envelope to 1.0; it
    /// decays at this rate (per second). 3.5 Hz = ~200 ms half-life,
    /// matched to the brief hat / shaker / cymbal hit feel.
    static let sparkleDecay: Float = 3.5
    /// Number of sparkles embedded in mirror cells on the disco ball's
    /// inner surface. Iterations: 32 (orbital shell) → 120 (volumetric
    /// dense) → 40 (volumetric sparse) → 80 (surface-aligned). The
    /// move to cell alignment changed the density math — 40 cells on a
    /// 14×28 grid (~294 mirror cells) left obvious gaps; 80 gives
    /// better coverage so most of the visible far-hemisphere cells
    /// host a sparkle, still well below the ~294 total mirror cells.
    static let sparkleCount: Int = 80
    /// Sparkles now embed in the disco ball's INNER SURFACE inside
    /// mirror (non-lit) cells. This inset multiplier places them just
    /// inside the surface (0.97 × discoBallRadius) so they sit in the
    /// cell rather than poking through. Smaller inset = deeper inside
    /// the sphere = sparkle more obviously "behind" the mirror cell.
    static let sparkleSurfaceInset: Float = 0.97
    /// Cell-grid dimensions for the disco ball. SINGLE SOURCE OF TRUTH —
    /// these values are pushed into the shader's `LatCells`/`LngCells`
    /// uniforms at build time via setParameter (see `buildDiscoBall`).
    /// The USDA carries matching defaults for RCP preview but they're
    /// always overwritten at runtime, so changing these here is the
    /// only edit needed to retune cell density.
    static let discoBallLatCells: Int = 14
    static let discoBallLngCells: Int = 28
    /// Size of each sparkle sprite (edge length, meters).
    static let sparkleSize: Float = 0.020
    /// Continuous shimmer floor — sparkle pool's minimum brightness
    /// at high brilliance loudness even between hat hits. Mixed with
    /// the onset-driven envelope so brilliance-heavy mixes (e.g. a
    /// shaker hi pattern) read as a continuously twinkling halo.
    static let sparkleShimmerStrength: Float = 0.35
    /// Tempo-driven sparkle size endpoints. INVERTED relationship vs
    /// the usual "faster = bigger" intuition: slow songs get LARGER
    /// sparkles (0.9×) that read as deliberate visible particles —
    /// they suit the slow ballad's "intimate floating points of light"
    /// feel — while fast songs get tinier ones (0.25×) that read as
    /// rapid micro-shimmer in the air, more like static buzz than
    /// discrete particles. Applied as `entity.scale` per-tick.
    static let sparkleSizeScaleSlow: Float = 0.9
    static let sparkleSizeScaleFast: Float = 0.25
    /// Extra brilliance-band tempo multiplier ON TOP of the existing
    /// tempoIntensityScale (which dims everything on slow songs). Pushes
    /// the sparkle pool's tempo dependence further so a high-BPM disco
    /// track has a noticeably more present shimmer than a low-BPM
    /// ballad, beyond what the global tempo dimming already gives.
    /// 0.25 slow → 1.0 fast — keeps the 4× slow/fast contrast but at
    /// half the absolute level (the earlier 0.5/2.0 range was too
    /// dominant in the overall mix once the disco ball started reflecting
    /// emissive elements).
    static let sparkleBrillianceTempoMultSlow: Float = 0.25
    static let sparkleBrillianceTempoMultFast: Float = 1.0

    // MARK: - Disco-ball tuning
    //
    // These constants drive the RCP `ShaderGraphMaterial` that wraps
    // the dodec. The shader handles the per-cell checkerboard and the
    // lit-cell emissive internally; we just set uniforms each tick.
    // The TILE-COUNT / GAP constants from the old per-entity build
    // path are gone — that geometry lives in the shader now.

    /// Radius of the surrounding disco-ball sphere, in meters. Camera /
    /// viewer sits at root origin; the dodec sits ~0 m (its center) with
    /// outer envelope ~0.9 m; the ball at 2.5 m surrounds both with
    /// comfortable margin and fills most of the visible FOV.
    /// Iteration: 2.5 → 3.25 m (30% larger). Pushes the surrounding
    /// disco-ball further from the viewer so the dodec feels less
    /// crowded and the cells subtend a smaller angle — the pattern
    /// reads as wrap-around environment rather than close-in walls.
    static let discoBallRadius: Float = 3.25
    /// Slow Y-rotation of the entire disco ball, rev/s. Now tempo-driven
    /// (lerped between Slow and Fast endpoints by tempoT each tick):
    /// a 60 BPM ballad gives ~0.008 rev/s (one rev per ~125 s, very
    /// slow drift); a 140 BPM disco track gives ~0.030 rev/s (one rev
    /// per ~33 s, noticeably more motion). Both are still slower than
    /// the dodec's tumble so the layers move at distinct rates.
    static let discoBallRotationRateSlow: Float = 0.008
    static let discoBallRotationRateFast: Float = 0.030
    /// Lit tile beat-pulse decay rate (per second). 7.0 Hz ≈ 99 ms
    /// half-life. Iteration history (in code path): 3.5 → 6.0 → 9.0 →
    /// 7.0. Sweet spot where flashes are clear but don't snap-vanish
    /// before the eye registers them.
    static let discoBallBeatPulseDecay: Float = 7.0
    /// Lit-cell emissive at rest (between beats). Driven into the
    /// shader's `Baseline` parameter. Near-zero so tiles read as
    /// genuinely dark between flashes.
    static let discoBallLitOpacityBaseline: Float = 0.02
    /// Lit-cell emissive at peak beat. Driven into the shader's
    /// `Peak` parameter. Doubled 1.0 → 2.0 when the lit-cell COUNT
    /// dropped from 50% to 25%: same net light pumped into the scene
    /// per flash, just from fewer/brighter cells instead of more/dimmer.
    /// 2.0 is HDR (above SDR white) so the remaining lit cells punch
    /// hard with bloom; tonemap clamps the visible peak to white.
    static let discoBallLitOpacityPeak: Float = 2.0
    /// Weight of the chromagram-derived hue in the per-tick LitColor
    /// blend. 0 = pure mood color (warm white / mood-tinted),
    /// 1 = pure pitch color. 0.6 = pitch dominates but mood is still
    /// audible, so the ball flashes the song's lead-band pitch hue
    /// with a residual mood undertone.
    static let discoBallChromaBlendWeight: CGFloat = 0.6
    /// Tempo-driven roughness endpoints for the LIT (metallic) cells.
    /// Faster songs → sharper reflections (0.04, near-perfect mirror)
    /// to match the intensity; slower songs → softer reflections (0.14,
    /// more diffuse). Pushed into the shader's `LitRoughness` parameter
    /// each tick. Mirror (non-lit) cells stay at roughness 1.0 always.
    static let discoBallLitRoughnessSlow: Float = 0.14
    static let discoBallLitRoughnessFast: Float = 0.04



    /// Tempo-driven beam-opacity lerp endpoints.
    ///
    /// Beam opacity is lerped each tick toward an unsmoothed target;
    /// the lerp rate is interpolated between these two endpoints based
    /// on `FeatureFrame.beat.bpm`. Slow songs → `beamLerpRateSlow`
    /// (≈ 670 ms to 63% — beams ease in/out softly). Fast songs →
    /// `beamLerpRateFast` (≈ 50 ms — beams snap on/off, matching the
    /// percussive rhythm). Linear interp between the two BPM anchors.
    ///
    /// Iterations on the BPM range, in order:
    /// - `60→140` (iter 1): 104 BPM at t=0.55 → barely any dimming.
    /// - `70→140` (iter 2): t=0.49 → still mid.
    /// - `90→130` (iter 3): t=0.35 → some dimming, still too disco-bright.
    /// - `100→125` (current): 104 BPM at t=0.16 → firmly slow zone,
    ///   100 BPM at t=0.00 → maximum dimming. 113 BPM (Bee Gees disco)
    ///   at t=0.52 → mid. 130+ BPM stays fully fast.
    ///
    /// `beamLerpRateSlow` lowered 1.5 → 1.0 Hz (≈ 1 sec to 63%) —
    /// at slow tempos beams now visibly EASE into existence rather
    /// than fade in over a quarter-second.
    ///
    /// Mid (~10 Hz) is the fallback when `beat.confidence < 0.3`.
    static let beamLerpRateSlow: Float = 1.0       // Hz, at slowBpm
    static let beamLerpRateFast: Float = 20.0      // Hz, at fastBpm
    /// Fallback when `beat.confidence < beatConfidenceFloor`. Lowered
    /// 10 → 5 Hz because "full intensity, fast snap" was a poor
    /// default for unlocked-tempo songs — most of the time the
    /// tracker WILL lock within a few seconds, and assuming
    /// "unknown = disco" up front made all live-tap songs feel
    /// intense for the first ~2 sec.
    static let beamLerpRateUnknown: Float = 5.0
    static let slowBpm: Float = 100.0
    static let fastBpm: Float = 125.0
    /// Beat-tracker confidence floor — below this, we don't trust the
    /// bpm estimate and fall back to `beamLerpRateUnknown`.
    static let beatConfidenceFloor: Float = 0.3

    /// Tempo-driven INTENSITY scaling — a separate axis from lerp rate
    /// that controls the visual magnitude of beams/sparkles/emissive
    /// per tempo. Lerp rate alone wasn't enough to differentiate slow
    /// vs. fast songs; this scalar also dampens peak opacity and
    /// raises beam thresholds at slow tempos so fewer beams fire AND
    /// those that do fire are dimmer.
    ///
    /// At slow tempos (≤ slowBpm) the scale is `tempoIntensityScaleSlow`
    /// (0.15 = ~sixth of full intensity, genuinely soft); at fast
    /// tempos (≥ fastBpm) it's 1.0 (full intensity). Linear interp.
    ///
    /// `tempoIntensityScaleUnknown` (0.5) is the fallback when beat
    /// tracker hasn't locked yet — "mid intensity" rather than
    /// "full bright" so live-tap songs don't burst into peak intensity
    /// in their first few seconds before the tracker locks.
    ///
    /// Iteration history:
    /// - 0.35 (iter 1) — too bright at mid-tempo
    /// - 0.2 (iter 2) — still too bright once you factor in the per-face
    ///   pulse from onsets (which was NOT tempo-scaled)
    /// - 0.15 (iter 3) — better, but additive beams + HDR boost (up to
    ///   3.5×) mean a 15% opacity layer still contributes ~0.5 to
    ///   screen brightness — beam still looks bright
    /// - 0.06 (current) — opacity * HDR boost ≈ 0.2, genuinely dim
    static let tempoIntensityScaleSlow: Float = 0.06
    static let tempoIntensityScaleFast: Float = 1.0
    static let tempoIntensityScaleUnknown: Float = 0.5
    /// At slow tempos, ADD this much to each beam's threshold —
    /// raises the bar for which pitches fire. At 0.45 a halo's
    /// effective threshold becomes 1.0 (only the absolute max bin),
    /// and the core threshold becomes 1.2 (effectively only the
    /// dominant pitch combined with a recent strong onset pulse).
    /// Both clamped by the per-side `min(0.98, ...)` floor so we
    /// don't divide by zero, but the clamp still lets only the
    /// absolute dominant pitch fire at slow tempos.
    static let beamThresholdOffsetSlow: Float = 0.45

    // MARK: - Key-anchored face treatment

    /// Per-face baseline emissive intensity when a canonical song key
    /// is known. The 12 faces split into three tiers:
    /// - TONIC: the song's home pitch class — brightest baseline,
    ///   visibly "breathes" via a slow sin pulse so it's recognizable
    ///   regardless of what the chromagram is currently doing.
    /// - DIATONIC (other 6 scale degrees): noticeable baseline; reads
    ///   as the song's "color palette" lit up.
    /// - NON-DIATONIC (the 5 outside-the-scale pitches): near-dark
    ///   baseline; only lights up when its chromagram bin really
    ///   activates (i.e. when the song accidentally hits one of those
    ///   notes — chromatic passing tones, modulations, etc.).
    ///
    /// At rest (silence), the constellation of bright vs dim faces
    /// spells out the song's key visually. Songs in different keys
    /// look immediately distinct.
    ///
    /// When NO key is known (no Shazam ID, or DB miss), falls back to
    /// a uniform 0.15 baseline (matching the pre-key-override era).
    static let tonicBaseline: Float = 0.55
    static let diatonicBaseline: Float = 0.30
    static let nonDiatonicBaseline: Float = 0.10
    static let noKeyBaseline: Float = 0.15

    /// Tonic-face heartbeat — slow sin pulse so the home note is
    /// recognizable even at rest. 0.5 Hz = 2-second period; amplitude
    /// 0.15 (small) — enough to read as "alive" without being
    /// distracting.
    static let tonicHeartbeatRate: Float = 0.5
    static let tonicHeartbeatAmplitude: Float = 0.15

    /// Major-scale step set (semitones from tonic). Diatonic
    /// membership for any major key is `{ (tonic.raw + s) % 12 for s in this }`.
    static let majorScaleSteps: [Int] = [0, 2, 4, 5, 7, 9, 11]
    /// Natural minor scale step set. Note: this is the natural minor;
    /// harmonic and melodic minor have raised 7ths/6ths that GetSongBPM
    /// doesn't distinguish. Natural minor is the right default for
    /// "what notes belong in this song" visualization.
    static let minorScaleSteps: [Int] = [0, 2, 3, 5, 7, 8, 10]

    /// Per-face beam-fan threshold for the OUTER halo. The bass band's
    /// pitch-class energy at face k must cross this fraction of the
    /// band's max-bin to fire that face's halo. Lower than the
    /// `beamIntensityThreshold` for the inner core (0.75) because
    /// bass is usually less peaky — a few notes share most of the
    /// energy and we want them to fire reliably.
    static let haloIntensityThreshold: Float = 0.55

    // MARK: - Geometry

    /// 12 face-center unit vectors for a regular dodecahedron. These are
    /// the vertices of an icosahedron (the dual polyhedron). Derived
    /// from the canonical (0, ±1, ±φ), (±1, ±φ, 0), (±φ, 0, ±1)
    /// construction where φ = (1+√5)/2, normalized to unit length.
    /// Order is arbitrary; pitch class k just gets faceDirections[k].
    private static let faceDirections: [SIMD3<Float>] = {
        let phi: Float = (1 + sqrt(5)) / 2
        let raw: [SIMD3<Float>] = [
            SIMD3(0, 1, phi), SIMD3(0, -1, phi),
            SIMD3(0, 1, -phi), SIMD3(0, -1, -phi),
            SIMD3(1, phi, 0), SIMD3(-1, phi, 0),
            SIMD3(1, -phi, 0), SIMD3(-1, -phi, 0),
            SIMD3(phi, 0, 1), SIMD3(phi, 0, -1),
            SIMD3(-phi, 0, 1), SIMD3(-phi, 0, -1)
        ]
        return raw.map { normalize($0) }
    }()

    /// The 20 vertices of a regular dodecahedron, scaled to
    /// `dodecahedronRadius`. Wikipedia canonical construction (the
    /// one whose dual icosahedron is at canonical (0, ±1, ±φ)
    /// positions):
    ///   • 8 cube vertices (±1, ±1, ±1)
    ///   • (0, ±φ, ±1/φ)
    ///   • (±1/φ, 0, ±φ)
    ///   • (±φ, ±1/φ, 0)
    /// IMPORTANT: this specific cyclic permutation must match the
    /// `faceDirections` icosahedron positions above for the dual
    /// relationship to hold. With this vertex set + those face
    /// normals, the 5 vertices closest to any face normal ARE the
    /// 5 vertices that lie on that face plane (verified: all 5 share
    /// the same dot product = inradius). An earlier version used the
    /// other cyclic permutation by mistake which produced broken,
    /// non-planar "faces."
    private static let dodecahedronVertices: [SIMD3<Float>] = {
        let phi: Float = (1 + sqrt(5)) / 2
        let invPhi: Float = 1 / phi
        let raw: [SIMD3<Float>] = [
            // 8 cube vertices
            SIMD3( 1,  1,  1), SIMD3( 1,  1, -1),
            SIMD3( 1, -1,  1), SIMD3( 1, -1, -1),
            SIMD3(-1,  1,  1), SIMD3(-1,  1, -1),
            SIMD3(-1, -1,  1), SIMD3(-1, -1, -1),
            // (0, ±φ, ±1/φ)
            SIMD3(0,  phi,  invPhi), SIMD3(0,  phi, -invPhi),
            SIMD3(0, -phi,  invPhi), SIMD3(0, -phi, -invPhi),
            // (±1/φ, 0, ±φ)
            SIMD3( invPhi, 0,  phi), SIMD3( invPhi, 0, -phi),
            SIMD3(-invPhi, 0,  phi), SIMD3(-invPhi, 0, -phi),
            // (±φ, ±1/φ, 0)
            SIMD3( phi,  invPhi, 0), SIMD3( phi, -invPhi, 0),
            SIMD3(-phi,  invPhi, 0), SIMD3(-phi, -invPhi, 0)
        ]
        return raw.map { normalize($0) * dodecahedronRadius }
    }()

    /// Returns the 5 dodecahedron-vertex world-space positions that lie
    /// on the face with the given normal, sorted angularly around the
    /// face center (CCW viewed from outside). Used by both face-mesh
    /// and beam-mesh construction.
    private static func faceVertices(faceDirection: SIMD3<Float>) -> [SIMD3<Float>] {
        // Top 5 vertices by dot with face direction = the 5 on the
        // face plane.
        let scored = dodecahedronVertices.map {
            (vertex: $0, dot: dot(normalize($0), faceDirection))
        }
        let top5 = scored.sorted { $0.dot > $1.dot }.prefix(5).map { $0.vertex }
        let faceCenter = top5.reduce(SIMD3<Float>.zero, +) / 5

        // 2D basis in the face's plane.
        let upRef: SIMD3<Float> =
            abs(faceDirection.y) < 0.99
                ? SIMD3(0, 1, 0)
                : SIMD3(1, 0, 0)
        let axisX = normalize(cross(upRef, faceDirection))
        let axisY = cross(faceDirection, axisX)

        return top5.sorted { a, b in
            let oa = a - faceCenter
            let ob = b - faceCenter
            return atan2(dot(oa, axisY), dot(oa, axisX))
                 < atan2(dot(ob, axisY), dot(ob, axisX))
        }
    }

    /// Enumerate the 30 unique edges of a regular dodecahedron as
    /// (vertexA, vertexB) world-space pairs. Each face contributes 5
    /// edges, every edge is shared between 2 faces → 12·5/2 = 30. We
    /// dedupe by canonicalizing endpoints (sorted, rounded) into a
    /// string key so floating-point equality doesn't bite.
    private static func dodecahedronEdges() -> [(SIMD3<Float>, SIMD3<Float>)] {
        var seen = Set<String>()
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        func key(_ v: SIMD3<Float>) -> String {
            String(format: "%.4f,%.4f,%.4f", v.x, v.y, v.z)
        }
        for dir in faceDirections {
            let perimeter = faceVertices(faceDirection: dir)
            for j in 0..<5 {
                let a = perimeter[j]
                let b = perimeter[(j + 1) % 5]
                let ka = key(a), kb = key(b)
                let canonical = ka < kb ? "\(ka)|\(kb)" : "\(kb)|\(ka)"
                if seen.insert(canonical).inserted {
                    edges.append((a, b))
                }
            }
        }
        return edges
    }

    /// Build a mesh for ONE face of a regular dodecahedron. Triangle-
    /// fan from face center out to the 5 perimeter vertices. Vertices
    /// are in WORLD-space relative to the dodecahedron center — no
    /// per-face transform needed.
    private static func makeFaceMesh(faceDirection: SIMD3<Float>) -> MeshResource {
        let perimeter = faceVertices(faceDirection: faceDirection)
        let faceCenter = perimeter.reduce(SIMD3<Float>.zero, +) / 5

        var positions: [SIMD3<Float>] = [faceCenter]
        positions.append(contentsOf: perimeter)
        let normals = Array(repeating: faceDirection, count: 6)

        var triangles: [UInt32] = []
        for i in 0..<5 {
            let next = (i + 1) % 5
            triangles.append(0)
            triangles.append(UInt32(i + 1))
            triangles.append(UInt32(next + 1))
        }

        var descriptor = MeshDescriptor(name: "dodec-face")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(triangles)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? MeshResource.generateBox(size: 0.1)
    }

    /// Build a pentagonal-prism beam mesh extruded outward from one
    /// dodecahedron face along its normal.
    ///   - `widthScale` 1.0 → beam pentagon matches the face perimeter
    ///     exactly. <1 → narrower pentagon inside the face (cores).
    ///     >1 → wider pentagon outside the face (outer halos).
    ///   - `length` is the total extrusion distance along faceDirection.
    ///
    /// The beam's near vertices are pushed outward by
    /// `beamSurfaceEpsilon` along the face normal so the whole beam
    /// renders just in front of the opaque face plate — eliminates
    /// depth-fighting that would otherwise occlude the inner core
    /// on side-facing faces.
    ///
    /// Geometry: 5 side quads (10 triangles) forming the prism walls
    /// + 5 triangles for the far-end cap. Near end is open — the
    /// dodecahedron face / inner-beam layers cover that.
    /// Vertices are in WORLD-space relative to the dodecahedron
    /// center, so no per-beam entity transform is needed.
    private static func makeBeamMesh(
        faceDirection: SIMD3<Float>,
        widthScale: Float = 1.0,
        length: Float = 1.0
    ) -> MeshResource {
        let perimeter = faceVertices(faceDirection: faceDirection)
        let faceCenter = perimeter.reduce(SIMD3<Float>.zero, +) / 5
        // Scale perimeter vertices outward (or inward) from the face
        // center to set the beam's cross-section width.
        // Then push slightly outward along face normal so the beam
        // depth-passes against the opaque face plate.
        let nearVerts = perimeter.map {
            faceCenter
                + ($0 - faceCenter) * widthScale
                + faceDirection * beamSurfaceEpsilon
        }
        let farVerts = nearVerts.map { $0 + faceDirection * length }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var triangles: [UInt32] = []

        // 5 side quads — each contributes 4 vertices + 2 triangles.
        // Computed side normal points OUTWARD from the prism axis so
        // backface culling / lighting behaves correctly.
        for i in 0..<5 {
            let nextI = (i + 1) % 5
            let n0 = nearVerts[i]
            let n1 = nearVerts[nextI]
            let f0 = farVerts[i]
            let f1 = farVerts[nextI]

            let edge = n1 - n0
            let extrusion = f0 - n0
            let sideNormal = normalize(cross(extrusion, edge))

            let baseIdx = UInt32(positions.count)
            positions.append(contentsOf: [n0, n1, f1, f0])
            normals.append(contentsOf: Array(repeating: sideNormal, count: 4))

            triangles.append(contentsOf: [
                baseIdx, baseIdx + 1, baseIdx + 2,
                baseIdx, baseIdx + 2, baseIdx + 3
            ])
        }

        // Far-end cap — triangle fan from far-center to each far
        // vertex. Closes the beam so it doesn't read as a hollow
        // tube when viewed from a steep angle.
        let farCenter = farVerts.reduce(SIMD3<Float>.zero, +) / 5
        let centerIdx = UInt32(positions.count)
        positions.append(farCenter)
        normals.append(faceDirection)
        let firstFarIdx = UInt32(positions.count)
        for v in farVerts {
            positions.append(v)
            normals.append(faceDirection)
        }
        for i in 0..<5 {
            let nextI = UInt32((i + 1) % 5)
            triangles.append(centerIdx)
            triangles.append(firstFarIdx + UInt32(i))
            triangles.append(firstFarIdx + nextI)
        }

        var descriptor = MeshDescriptor(name: "dodec-beam")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(triangles)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? MeshResource.generateBox(size: 0.1)
    }

    // MARK: - Build

    /// Build the dodecahedron scene. Returns an entity tree:
    ///   root (DodecahedronRootComponent, eye-height position)
    ///     └─ rotator (gets Y/X rotation each tick)
    ///          └─ 12 face ModelEntities (each with DodecahedronFaceComponent)
    @MainActor
    static func makeDodecahedron(from frames: [FeatureFrame]) async -> Entity {
        let root = Entity()
        root.position = SIMD3(0, visionEyeHeight, forwardDistance)
        root.components.set(DodecahedronRootComponent())

        // Shared additive-blend program for all beam layers. Same
        // recipe as Crystal: beams stack additively so overlapping
        // layers brighten toward white instead of compositing as
        // semi-transparent blobs. This is what gives Crystal's
        // beams their luminous "stacked light" feel.
        var blendDescriptor = UnlitMaterial.Program.Descriptor()
        blendDescriptor.blendMode = .add
        let additiveProgram = await UnlitMaterial.Program(descriptor: blendDescriptor)

        // Inner "rotator" subroot — receives the per-tick rotation
        // updates. Keeping it separate from `root` means the windowed
        // VisualizerView can move/scale the root without disturbing
        // the rotation math.
        let rotator = Entity()
        root.addChild(rotator)

        // Edge skeleton — 30 thin additive boxes laid along the dodec's
        // edges. Children of rotator (not of individual faces), so they
        // stay at the original surface when faces push outward on a
        // bass pulse. Closed panels overlap them visually; open panels
        // expose them as "cracks of light." Color (per-tick) tracks
        // dominant bass pitch, brightness scales with bassPulse — at
        // rest the skeleton is nearly invisible, on a hit the seams
        // blaze.
        let edgeSkeleton = Entity()
        edgeSkeleton.components.set(DodecahedronEdgeSkeletonComponent())
        rotator.addChild(edgeSkeleton)
        for (a, b) in dodecahedronEdges() {
            let center = (a + b) / 2
            let edgeVec = b - a
            let length = simd_length(edgeVec)
            let dirUnit = edgeVec / length
            let orientation = simd_quatf(
                from: SIMD3<Float>(1, 0, 0),
                to: dirUnit
            )
            // Build all 3 halo layers coaxially. Same length + same
            // center; varying thickness. Outer halos are wider so on
            // a bass hit the seam reads as a bright core surrounded
            // by a soft volumetric bloom rather than a hairline.
            for (layerIdx, layer) in dodecahedronEdgeLayers.enumerated() {
                var mat = UnlitMaterial(program: additiveProgram)
                mat.color = .init(tint: PlatformColor.white)
                // CRITICAL: writesDepth=false — same coaxial-additive
                // discipline as Crystal/face beams. Without it the
                // outer halo's depth write blocks the inner core at
                // the depth-LESS test.
                mat.writesDepth = false
                let mesh = MeshResource.generateBox(size: SIMD3<Float>(
                    length, layer.thickness, layer.thickness
                ))
                let entity = ModelEntity(mesh: mesh, materials: [mat])
                entity.position = center
                entity.orientation = orientation
                entity.components.set(
                    DodecahedronEdgeLayerComponent(layerIndex: layerIdx)
                )
                edgeSkeleton.addChild(entity)
            }
        }

        // Build 12 face entities. Each face has its OWN mesh built
        // from the 5 dodecahedron vertices that lie on that face,
        // expressed in world space relative to the dodecahedron center.
        // No per-face position or orientation needed — adjacent face
        // meshes share vertex positions exactly, so edges align.
        for k in 0..<12 {
            let dir = faceDirections[k]
            let pitchClass = PitchClass(rawValue: k) ?? .c
            let baseHue = CGFloat(pitchClass.circleOfFifthsHue)

            // Face material is TRANSPARENT (writesDepth = false). The
            // previous opaque + depth-writing version caused beams
            // from the SAME face to depth-fight against their own
            // face plate at the beam's near end — the inner core
            // was the most affected because its narrow pentagon
            // sits entirely within the face plate's screen
            // footprint. With transparent face plates and no depth
            // write, the beam's full multi-layer stack (core
            // included) renders cleanly at every angle.
            //
            // Back beams are instead hidden via SOFTWARE backface
            // culling in `applyState` — each face entity's
            // `isEnabled` flag is driven by the dot product of its
            // world-space normal with the camera direction, so
            // back-facing face entities (with both their face
            // plate AND their beam group) disappear entirely each
            // tick before they can bleed.
            // Metallic-shiny face plate, tinted with the pitch class
            // hue. baseColor + emissiveColor both carry the tint —
            // baseColor tints any specular reflections (metallic=1.0
            // means the surface reflects environment with the
            // baseColor as a tint multiplier), emissiveColor keeps
            // the face visibly tinted even without strong scene
            // lighting. Architecture's earlier PBR attempt rendered
            // as "desaturated silver" because they relied on lit
            // baseColor alone; we keep the tint legible by pushing
            // emissive HARD and using lit metallic as a sheen on top.
            //
            // blending=transparent(0.99) puts the face plate in the
            // transparent pass so it doesn't write depth (preserves
            // the depth-clearance we need for the inner beam core).
            // Visually still reads as fully opaque at 0.99 alpha.
            let tintColor = PlatformColor(
                hue: baseHue,
                saturation: 0.85,
                brightness: 0.55,
                alpha: 1.0
            )
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: tintColor)
            material.metallic = 1.0
            // Roughness dropped 0.30 → 0.10 for noticeably sharper
            // specular highlights — the dodec faces now read as
            // polished mirror-metal rather than brushed metal. The
            // disco ball lit cells use roughness 0.08, so the dodec is
            // similar (slightly less mirror) — gives the dodec and
            // the disco ball a unified reflective family of surfaces.
            material.roughness = 0.10
            material.emissiveColor = .init(color: tintColor)
            material.emissiveIntensity = 0.40
            material.blending = .transparent(opacity: .init(floatLiteral: 0.99))

            let faceMesh = makeFaceMesh(faceDirection: dir)
            let face = ModelEntity(mesh: faceMesh, materials: [material])
            // No per-face transform — face vertices already in world
            // (dodecahedron-center) space.

            face.components.set(DodecahedronFaceComponent(
                pitchClassIndex: k,
                baseHue: baseHue
            ))

            // Beam stack — same 4-layer additive pentagonal prism as
            // before, but split into TWO subgroups so each can be
            // faded independently by `applyState`:
            //   • coreGroup = layers 0..1 (thin white-hot core +
            //     bright inner halo). Driven by the HIGH-MID band
            //     chromagram → "the lead is currently playing this
            //     pitch."
            //   • haloGroup = layers 2..3 (wide mid + outer halo
            //     fan). Driven by the LOW-MID band chromagram →
            //     "the bass is currently holding this pitch."
            //
            // Per-band routing rationale: when a song's bass and
            // lead are on different pitches, the listener sees the
            // bass face firing a wide colored halo and a different
            // face firing a bright filament inside it. When they
            // line up on the same pitch, that face fires the full
            // stack. Visually decomposes the harmonic register the
            // way the multi-band split decomposes the signal.
            //
            // All four layers still share the same additive program
            // and writesDepth=false discipline as the original
            // single-group beam — only the parent OpacityComponent
            // grouping changes.
            let coreGroup = Entity()
            coreGroup.components.set(DodecahedronFaceBeamComponent(
                pitchClassIndex: k,
                baseHue: baseHue,
                kind: .core
            ))
            coreGroup.components.set(OpacityComponent(opacity: 0.0))

            let haloGroup = Entity()
            haloGroup.components.set(DodecahedronFaceBeamComponent(
                pitchClassIndex: k,
                baseHue: baseHue,
                kind: .halo
            ))
            haloGroup.components.set(OpacityComponent(opacity: 0.0))

            for (layerIdx, layer) in beamLayers.enumerated() {
                let layerMesh = makeBeamMesh(
                    faceDirection: dir,
                    widthScale: layer.widthScale,
                    length: layer.length
                )
                let layerTint = PlatformColor.hdrColor(
                    hue: baseHue,
                    saturation: layer.saturation,
                    brightness: layer.brightness,
                    hdrBoost: layer.hdrBoost
                )
                var layerMat = UnlitMaterial(program: additiveProgram)
                layerMat.color = .init(tint: layerTint)
                // CRITICAL: writesDepth = false on every additive
                // beam layer — without this, the four coaxial
                // pentagonal prisms (core + 3 halos) sharing the same
                // near-vertex plane write depth on each other and the
                // depth-LESS test fails for whichever layer renders
                // second. In dodec this manifests as the thin inner
                // CORE never rendering on side/angled faces (outer
                // halo wins the depth race because it's added first
                // and slightly wider, occluding everything inside).
                // Crystal documented this same issue in
                // [[crystal-v2]] §5 — the canonical fix for coaxial
                // additive geometry.
                layerMat.writesDepth = false
                let layerEntity = ModelEntity(
                    mesh: layerMesh,
                    materials: [layerMat]
                )
                // Layers 0,1 → core group; 2,3 → halo group.
                if layerIdx < 2 {
                    coreGroup.addChild(layerEntity)
                } else {
                    haloGroup.addChild(layerEntity)
                }
            }

            face.addChild(coreGroup)
            face.addChild(haloGroup)

            rotator.addChild(face)
        }

// ---- Cell-aligned sparkle pool (brilliance band → hats / shakers)
        // Sparkles snap to mirror (non-lit) cells on the disco ball's
        // INNER SURFACE so each one inhabits a dark cell. Visually this
        // ties the brilliance band into the disco ball's percussive
        // grid — when a sparkle pulses on a hi-hat, it pulses INSIDE
        // a specific dark cell, reinforcing the geometric layer
        // instead of floating randomly in the volume.
        //
        // Coordinate frame: sparkles live in a CONTAINER entity that
        // matches the disco ball's transform (same position offset,
        // same Y-flip from `scale = (1, -1, 1)`, same per-tick Y
        // rotation). That way each sparkle's local position can be
        // computed in the SAME frame as the shader's UV → 3D math, and
        // the sparkles ride along as the disco ball rotates.
        let sparkleContainer = Entity()
        sparkleContainer.position = SIMD3<Float>(0, 0, -forwardDistance)
        sparkleContainer.scale = SIMD3<Float>(1, -1, 1)
        sparkleContainer.components.set(DodecahedronSparkleContainerComponent())
        root.addChild(sparkleContainer)

        // Collect mirror-cell coordinates — same lit-mask formula the
        // shader uses. Mirror = NOT lit, where lit is the staggered
        // brick pattern (cellY%2==0 AND (cellX + cellY/2)%2 == 0).
        var mirrorCells: [(Int, Int)] = []
        for cellY in 0..<discoBallLatCells {
            for cellX in 0..<discoBallLngCells {
                let isLit = (cellY % 2 == 0) && ((cellX + cellY / 2) % 2 == 0)
                if !isLit { mirrorCells.append((cellX, cellY)) }
            }
        }
        // Score each mirror cell with a deterministic sin-based hash,
        // sort, pick top N. Gives a reproducible well-spread subset
        // (vs naive in-order which would cluster sparkles into the
        // first few latitude bands).
        let scored = mirrorCells.enumerated().map { (i, cell) -> ((Int, Int), Float) in
            let h = sin(Float(i) * 12.9898 + 78.233) * 43758.5453
            return (cell, h - floor(h))
        }
        let picked = scored.sorted { $0.1 < $1.1 }
            .prefix(min(sparkleCount, mirrorCells.count))
            .map { $0.0 }

        let surfaceR = discoBallRadius * sparkleSurfaceInset
        let latCellsF = Float(discoBallLatCells)
        let lngCellsF = Float(discoBallLngCells)
        for (i, cell) in picked.enumerated() {
            let cellX = cell.0
            let cellY = cell.1
            // UV center → spherical coords. Matches the shader's
            // texcoord → cell mapping exactly: u runs longitude
            // 0..1, v runs latitude 0..1 (south pole at v=0).
            let u = (Float(cellX) + 0.5) / lngCellsF
            let v = (Float(cellY) + 0.5) / latCellsF
            let longitude = u * 2 * .pi
            let latitude = -.pi / 2 + v * .pi
            let cosLat = cos(latitude)
            let position = SIMD3<Float>(
                surfaceR * cosLat * cos(longitude),
                surfaceR * sin(latitude),
                surfaceR * cosLat * sin(longitude)
            )

            var sparkleMat = UnlitMaterial(program: additiveProgram)
            sparkleMat.color = .init(tint: PlatformColor.hdrColor(
                hue: 0.58,                // cool icy blue
                saturation: 0.25,
                brightness: 1.0,
                hdrBoost: 2.0
            ))
            sparkleMat.writesDepth = false
            let sparkle = ModelEntity(
                mesh: .generateSphere(radius: sparkleSize),
                materials: [sparkleMat]
            )
            sparkle.position = position
            // Phase offset spread evenly around the cycle, plus a
            // small irrational perturbation so they don't form a
            // visible wave pattern.
            let phase = Float(i) * 0.61803398 * 2 * .pi
            sparkle.components.set(DodecahedronSparkleComponent(phase: phase))
            sparkle.components.set(OpacityComponent(opacity: 0.0))
            sparkleContainer.addChild(sparkle)
        }

        // ---- Surrounding disco-ball sphere -------------------------
        // Single inverted-normal sphere with a custom RCP shader graph
        // (Materials/DiscoBallMaterial.usda). The shader handles the
        // per-cell checkerboard + beat-driven emissive via UV math.
        // Build is async (material loads from the bundle).
        //
        // POSITIONING: root sits at the dodec position (forwardDistance
        // ahead of the camera). We offset the ball by -forwardDistance
        // in root's local space so its center lands at world origin =
        // camera position, wrapping the viewer symmetrically.
        if let discoBall = await buildDiscoBall() {
            discoBall.position = SIMD3<Float>(0, 0, -forwardDistance)
            root.addChild(discoBall)
        }

        // Vocal sparkle cloud (spherical shell of independently-
        // twinkling particles around the dodec). Sibling of `rotator`
        // under `root` so it doesn't tumble with the dodec — the
        // cloud halos the solid as a stable shimmer while the
        // structure spins inside it. Animate-tick scales each
        // sparkle's brightness from vocals.loudness × per-particle
        // sin twinkle.
        let aura = buildVocalAura(additiveProgram: additiveProgram)
        root.addChild(aura)

        return root
    }

    /// Build the vocal-cloud sparkle container. A spherical shell of
    /// many small additive-blend particles arranged around the dodec
    /// for the "magic dust cloud" effect: invisible at rest, dazzling
    /// at peak vocals. Each particle stores its own twinkle phase +
    /// frequency so the cloud doesn't pulse in lockstep — it reads
    /// as a busy living shimmer instead.
    ///
    /// Replaces the earlier torus-halo design, which was too tame to
    /// give vocals a wow moment.
    @MainActor
    private static func buildVocalAura(
        additiveProgram: UnlitMaterial.Program
    ) -> Entity {
        let container = Entity()
        container.position = SIMD3<Float>(0, 0, -forwardDistance)
        container.components.set(DodecahedronVocalAuraComponent())

        let mesh = MeshResource.generateSphere(radius: vocalCloudSparkleSize)
        // Fixed seed (deterministic positions across launches helps
        // visual continuity if a user is comparing songs side-by-side).
        var rng = SystemRandomNumberGenerator()
        for i in 0..<vocalCloudSparkleCount {
            // Uniform sample on a spherical shell: pick a random
            // unit direction, then scale by a random radius in the
            // shell range. Two random angles → direction; one random
            // for radial depth.
            let azimuth = Float.random(in: 0..<(2 * .pi), using: &rng)
            // Cosine-weighted polar (uniform on sphere surface).
            let cosPolar = Float.random(in: -1...1, using: &rng)
            let sinPolar = (1 - cosPolar * cosPolar).squareRoot()
            let direction = SIMD3<Float>(
                sinPolar * cos(azimuth),
                cosPolar,
                sinPolar * sin(azimuth)
            )
            let radius = Float.random(
                in: vocalCloudInnerRadius...vocalCloudOuterRadius, using: &rng
            )
            // Independent twinkle phase + frequency per particle —
            // the cloud's busy-shimmer comes from these being all
            // different per particle.
            let phase = Float.random(in: 0..<(2 * .pi), using: &rng)
            let frequency = Float.random(in: 1.2...2.8, using: &rng)

            var mat = UnlitMaterial(program: additiveProgram)
            mat.color = .init(tint: .black)  // animate sets the live color
            mat.writesDepth = false
            let sparkle = ModelEntity(mesh: mesh, materials: [mat])
            sparkle.position = direction * radius
            sparkle.components.set(DodecahedronVocalSparkleComponent(
                phase: phase, frequency: frequency, radius: radius
            ))
            _ = i  // silence unused-variable warning
            container.addChild(sparkle)
        }
        return container
    }

    /// Procedural torus mesh generator. RealityKit doesn't ship a
    /// torus primitive (only sphere / box / plane), so we build one
    /// via MeshDescriptor: parametric (θ, φ) → position over
    /// majorSegments × minorSegments quads, two triangles per quad.
    /// Normals are the outward-facing tube surface normal so the
    /// torus shades correctly under any lighting.
    nonisolated private static func generateTorusMesh(
        majorRadius R: Float, minorRadius r: Float,
        majorSegments majorN: Int, minorSegments minorN: Int
    ) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(majorN * minorN)
        normals.reserveCapacity(majorN * minorN)
        for i in 0..<majorN {
            let theta = Float(i) / Float(majorN) * 2 * .pi
            let cT = cos(theta), sT = sin(theta)
            for j in 0..<minorN {
                let phi = Float(j) / Float(minorN) * 2 * .pi
                let cP = cos(phi), sP = sin(phi)
                let x = (R + r * cP) * cT
                let y = r * sP
                let z = (R + r * cP) * sT
                positions.append(SIMD3(x, y, z))
                normals.append(SIMD3(cP * cT, sP, cP * sT))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(majorN * minorN * 6)
        for i in 0..<majorN {
            let iNext = (i + 1) % majorN
            for j in 0..<minorN {
                let jNext = (j + 1) % minorN
                let a = UInt32(i * minorN + j)
                let b = UInt32(iNext * minorN + j)
                let c = UInt32(iNext * minorN + jNext)
                let d = UInt32(i * minorN + jNext)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        var desc = MeshDescriptor()
        desc.positions = MeshBuffer(positions)
        desc.normals = MeshBuffer(normals)
        desc.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [desc])) ?? .generateSphere(radius: 0.01)
    }

    // MARK: - Disco ball (RCP ShaderGraphMaterial)

    /// Builds the surrounding disco-ball sphere. Single inverted-normal
    /// sphere mesh + one `ShaderGraphMaterial` (authored as USDA in
    /// `Materials/DiscoBallMaterial.usda`). The shader handles the
    /// per-cell checkerboard + beat-driven emissive via UV math; we
    /// just push uniforms per tick.
    ///
    /// `MeshResource.generateSphere` has outward normals (camera inside
    /// = back-face-culled = invisible). Mirroring the entity along Y
    /// flips triangle winding so the inside renders. UV.y also flips —
    /// the checker is symmetric so it doesn't matter visually.
    private static func buildDiscoBall() async -> Entity? {
        let mesh = MeshResource.generateSphere(radius: discoBallRadius)
        guard let material = try? await ShaderGraphMaterial(
            named: "/Root/DiscoBallMaterial",
            from: "Materials/DiscoBallMaterial",
            in: realityKitContentBundle
        ) else {
            return nil
        }
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        sphere.scale = SIMD3<Float>(1, -1, 1)  // flip winding → inside visible
        sphere.components.set(DodecahedronDiscoBallComponent())
        // Override shader defaults so ALL cells are pure black between
        // beats — only lit cells flash on the kick. Mirror cells stay
        // black always (no constant dim glow), lit baseline is 0 (no
        // dim warm rest state). Effect: every kick reveals a sparse
        // constellation of bright cells against the void.
        let black = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [0, 0, 0, 1]
        )!
        setDiscoBallFloat(sphere, name: "Baseline", value: 0.0)
        setDiscoBallFloat(sphere, name: "Peak", value: discoBallLitOpacityPeak)
        // Push the cell-grid dimensions from Swift so they're a single
        // source of truth. The USDA carries the same values as defaults
        // (for previewing the shader graph in RCP), but at runtime the
        // shader uses these values. Same constants that drive the
        // mirror-cell sparkle placement so they're guaranteed to match.
        setDiscoBallFloat(sphere, name: "LatCells", value: Float(discoBallLatCells))
        setDiscoBallFloat(sphere, name: "LngCells", value: Float(discoBallLngCells))
        if var model = sphere.components[ModelComponent.self],
           var mat = model.materials.first as? ShaderGraphMaterial {
            try? mat.setParameter(name: "MirrorColor", value: .color(black))
            model.materials[0] = mat
            sphere.components.set(model)
        }
        return sphere
    }

    /// Helper: set a float parameter on the disco-ball's shader-graph
    /// material. Material in RealityKit is a value-typed struct, so we
    /// mutate a copy and write it back into the entity's ModelComponent.
    private static func setDiscoBallFloat(
        _ entity: Entity,
        name: String,
        value: Float
    ) {
        guard var model = entity.components[ModelComponent.self],
              var mat = model.materials.first as? ShaderGraphMaterial
        else { return }
        try? mat.setParameter(name: name, value: .float(value))
        model.materials[0] = mat
        entity.components.set(model)
    }

    /// Push a Float input into the vocal-aura ShaderGraphMaterial.
    /// Mirrors `setDiscoBallFloat`; bails silently when the aura
    /// entity's material isn't a shader graph (fallback path).
    @MainActor
    private static func setVocalAuraFloat(
        _ entity: Entity, name: String, value: Float
    ) {
        guard var model = entity.components[ModelComponent.self],
              var mat = model.materials.first as? ShaderGraphMaterial
        else { return }
        try? mat.setParameter(name: name, value: .float(value))
        model.materials[0] = mat
        entity.components.set(model)
    }

    /// Push a color3 input. PlatformColor is platform-specific
    /// (NSColor on macOS, UIColor on iOS); we convert to CGColor for
    /// the .color() ParameterValue case.
    @MainActor
    private static func setVocalAuraColor(
        _ entity: Entity, name: String, value: PlatformColor
    ) {
        guard var model = entity.components[ModelComponent.self],
              var mat = model.materials.first as? ShaderGraphMaterial
        else { return }
        try? mat.setParameter(name: name, value: .color(value.cgColor))
        model.materials[0] = mat
        entity.components.set(model)
    }

    /// Helper: set a color3 parameter from a PlatformColor. `MaterialParameters.Value.color`
    /// takes a `CGColor` — we explicitly construct one in the device-RGB
    /// colorspace from the unpacked RGB components so there's no
    /// ambiguity with the multiple `init(red:green:blue:alpha:)` overloads.
    /// Blend two `PlatformColor`s in RGB space at `weight` (0 = pure a,
    /// 1 = pure b). Both inputs assumed to be in 0..1 range (non-HDR).
    /// Used for per-tick blending of the mood-tinted LitColor with the
    /// currently-dominant chromagram pitch's hue.
    private static func blendColors(
        _ a: PlatformColor,
        _ b: PlatformColor,
        weight: CGFloat
    ) -> PlatformColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let inv = 1 - weight
        return PlatformColor(
            red:   ar * inv + br * weight,
            green: ag * inv + bg * weight,
            blue:  ab * inv + bb * weight,
            alpha: 1
        )
    }

    private static func setDiscoBallColor(
        _ entity: Entity,
        name: String,
        color: PlatformColor
    ) {
        guard var model = entity.components[ModelComponent.self],
              var mat = model.materials.first as? ShaderGraphMaterial
        else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let cgColor = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [r, g, b, 1]
        )!
        try? mat.setParameter(name: name, value: .color(cgColor))
        model.materials[0] = mat
        entity.components.set(model)
    }

    // MARK: - Mood-driven palette

    /// Sparkle pool color, modulated by happiness 0..100. nil →
    /// the original icy-blue default. Below 50 shifts toward a deeper
    /// cool blue (sad); above 50 shifts toward warm pink (happy). The
    /// curve is piecewise so the neutral midpoint matches the
    /// hardcoded default — linear blending between extremes would
    /// land at a magenta in the middle, which would mean the
    /// happiness-nil case (most pop songs hitting GetSongBPM) looks
    /// different from happiness=50.
    static func sparkleColor(happiness: Float?) -> PlatformColor {
        let hue: CGFloat
        let saturation: CGFloat
        let hdrBoost: CGFloat
        if let h = happiness {
            let t = CGFloat(min(1.0, max(0.0, h / 100.0)))
            if t < 0.5 {
                let f = t * 2  // 0..1 across the sad half (0=very sad → 1=neutral)
                // Endpoint: hue 0.65 (deep indigo), sat 0.85, hdrBoost 2.3.
                // Neutral end of half preserves the icy default (0.58 / 0.25 / 2.0).
                hue        = 0.65 + (0.58 - 0.65) * f
                saturation = 0.85 + (0.25 - 0.85) * f
                hdrBoost   = 2.3  + (2.0  - 2.3 ) * f
            } else {
                let f = (t - 0.5) * 2  // 0..1 across the happy half (0=neutral → 1=very happy)
                // Endpoint: hue 0.93 (vivid magenta), sat 0.85, hdrBoost 2.3.
                hue        = 0.58 + (0.93 - 0.58) * f
                saturation = 0.25 + (0.85 - 0.25) * f
                hdrBoost   = 2.0  + (2.3  - 2.0 ) * f
            }
        } else {
            hue = 0.58
            saturation = 0.25
            hdrBoost = 2.0
        }
        return PlatformColor.hdrColor(
            hue: hue, saturation: saturation,
            brightness: 1.0, hdrBoost: hdrBoost
        )
    }

/// Lit-tile color for the disco-ball pattern, modulated by
    /// happiness 0..100. Same piecewise-around-neutral shape as the
    /// sparkle/shockwave palette but with **subtler extremes** — the
    /// disco ball covers a much larger screen area than the sparkles
    /// or central shockwave, so a fully saturated indigo across 196
    /// lit tiles would overwhelm the dodec itself. The lit tiles stay
    /// "warm-white-ish" at all happiness values, just shifted slightly
    /// cool at sad / slightly warm-gold at happy.
    static func discoBallLitColor(happiness: Float?) -> PlatformColor {
        let hue: CGFloat
        let saturation: CGFloat
        let hdrBoost: CGFloat
        if let h = happiness {
            let t = CGFloat(min(1.0, max(0.0, h / 100.0)))
            if t < 0.5 {
                let f = t * 2  // 0=very sad → 1=neutral
                // Endpoint: cool indigo-white (subtler than sparkles' 0.65/0.85).
                hue        = 0.62 + (0.08 - 0.62) * f
                saturation = 0.40 + (0.10 - 0.40) * f
                hdrBoost   = 1.0  + (1.0  - 1.0 ) * f
            } else {
                let f = (t - 0.5) * 2  // 0=neutral → 1=very happy
                // Endpoint: warm gold (subtler than shockwave's 0.09/0.85).
                hue        = 0.08 + (0.10 - 0.08) * f
                saturation = 0.10 + (0.40 - 0.10) * f
                hdrBoost   = 1.0  + (1.2  - 1.0 ) * f
            }
        } else {
            hue = 0.08
            saturation = 0.10
            // hdrBoost dropped 2.0 → 1.0. The previous 2.0 meant peak
            // opacity = 1.0 contributed 2× to the additive layer, which
            // saturated to white well below opacity 1.0 — so the user's
            // perceived peak vs trough was tiny (both looked white).
            // At 1.0, opacity directly maps to screen brightness:
            // baseline 0.02 → 0.02 (black), peak 1.0 → 1.0 (white).
            // Clear 50:1 dynamic range that reads as a sharp flash.
            hdrBoost = 1.0
        }
        return PlatformColor.hdrColor(
            hue: hue, saturation: saturation,
            brightness: 1.0, hdrBoost: hdrBoost
        )
    }

    /// In-place update to an entity's first UnlitMaterial color tint.
    /// Used by the mood-palette refresh to recolor sparkle + shockwave
    /// materials without rebuilding their entities or meshes.
    /// `writesDepth = false` is preserved because that's a property of
    /// the existing material we're mutating, not something we re-set.
    private static func updateUnlitTint(_ entity: Entity, color: PlatformColor) {
        guard let model = entity as? ModelEntity,
              var modelComp = model.components[ModelComponent.self],
              var mat = modelComp.materials.first as? UnlitMaterial
        else { return }
        mat.color = .init(tint: color)
        modelComp.materials = [mat]
        model.components.set(modelComp)
    }

    // MARK: - Tempo helpers
    //
    // `octaveFoldBpm` + canonical BPM range constants hoisted to
    // [[BeatHelpers]] so other visualizers can share the tempo math
    // without depending on this enum. Callers now use
    // `BeatHelpers.octaveFoldBpm(raw)` directly.
    //
    // (placeholder retained so neighboring private helpers below keep
    // their MARK grouping)

    // MARK: - Animate

    /// Per-frame update — drives per-band envelopes, per-face material
    /// brightness, beam fades, rotation, shockwave + sparkle pool.
    /// Called from SceneEvents.Update subscription each frame.
    ///
    /// Per-band signal routing (the whole point of this viz mode):
    ///   • highMid bandChromagram → face emissive + inner-core beams
    ///     (the lead band paints the "this pitch is currently melodic")
    ///   • lowMid bandChromagram → outer-halo beams (the bass band
    ///     paints "this pitch is the chord/bass root")
    ///   • sub bandOnset → central shockwave bump (kick hits)
    ///   • brilliance bandOnset + bandLoudness → orbiting sparkle pool
    ///     (hat/cymbal patterns; loudness gives continuous shimmer)
    ///   • full-spectrum onset → per-face dominant-pitch pulse (kept
    ///     for the "any percussive event flashes its pitch's face"
    ///     reading — the bandOnset signals drive the new lanes, not
    ///     replace the existing per-pitch pulse).
    @MainActor
    static func animate(
        _ root: Entity,
        clock: Double,
        frames: [FeatureFrame],
        deltaTime: Double,
        appResetCounter: Int,
        bpmOverride: Float? = nil,
        danceabilityOverride: Float? = nil,
        acousticnessOverride: Float? = nil,
        aggressivenessOverride: Float? = nil,
        happinessOverride: Float? = nil,
        voiceVocalOverride: Float? = nil,
        timbreBrightnessOverride: Float? = nil,
        timeSigOverride: String? = nil,
        partyOverride: Float? = nil,
        relaxedOverride: Float? = nil,
        keyOverride: Key? = nil,
        /// Per-stem features from the demucs-mlx sidecar. When non-nil,
        /// the disco ball's beat-pulse trigger source switches from
        /// `bandOnset[sub]` (which includes kick + bass + room rumble
        /// because they all live in the sub frequency band) to the
        /// isolated `drums` stem's onsets — strictly drum-attack events,
        /// no bass-note bleed. nil → fall back to band-split path.
        stemFeatures: StemSeparationResult? = nil
    ) {
        guard var state = root.components[DodecahedronRootComponent.self] else { return }
        guard !frames.isEmpty else { return }

        // Track-change reset.
        if appResetCounter >= 0 && appResetCounter != state.lastSeenResetCounter {
            state.smoothedHighMidChroma = .init(repeating: 0, count: 12)
            state.smoothedLowMidChroma = .init(repeating: 0, count: 12)
            state.pulses = .init(repeating: 0, count: 12)
            state.smoothedLoudness = 0
            state.smoothedTimbre = 0
            state.sparkleEnergy = 0
            state.smoothedBrilliance = 0
            state.smoothedCoreOpacity = .init(repeating: 0, count: 12)
            state.smoothedHaloOpacity = .init(repeating: 0, count: 12)
            state.smoothedTempoT = 0.5
            state.firstTempoTick = true
            state.rotationAngle = 0
            state.beatPulseEnergy = 0
            state.discoBallAngle = 0
            state.lastFrameIndex = -1
            state.firstAnimateTick = true
            state.lastSeenResetCounter = appResetCounter
        }

        // Current frame (nearest index at 30 fps).
        let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
        let f = frames[i]

        let highMidIdx = FrequencyBand.highMid.rawValue
        let lowMidIdx = FrequencyBand.lowMid.rawValue
        let subIdx = FrequencyBand.sub.rawValue
        let brillianceIdx = FrequencyBand.brilliance.rawValue

        // Pull per-band chromagrams for this frame.
        //
        // Beam source selection:
        //   • Stems available → use the `other` stem's chromagram for
        //     BOTH the inner-core and outer-halo beams. `other` is
        //     Demucs's catch-all for the harmonic/melodic layer
        //     (guitar, piano, synths, horns). For a sustained
        //     monochromatic song like Whiskey River, the full-mix
        //     band-split chromagrams stay locked on one dominant
        //     pitch — only one beam ever lights up. The `other` stem
        //     isolates the actual chord movements so the beam
        //     selection changes as the song progresses.
        //   • Stems NOT available → fall back to the existing
        //     per-band (highMid / lowMid) split from the full mix.
        //     That's the pre-stems behavior the visualizer was built
        //     against and works well for material with clear band
        //     separation (drum-forward dance, etc.).
        let otherChromaForFrame: [Float]? = {
            guard let chroma = stemFeatures?.stems["other"]?.chromagram,
                  i < chroma.count, chroma[i].count == 12
            else { return nil }
            return chroma[i]
        }()
        let highMidChroma = otherChromaForFrame ?? f.bandChromagram[highMidIdx]
        let lowMidChroma = otherChromaForFrame ?? f.bandChromagram[lowMidIdx]

        // First-tick / post-reset: snap smoothed values to current
        // signal so the first visual doesn't lerp in from black.
        // Snap to NORMALIZED per-band chromagrams so they stay in [0, 1].
        if state.firstAnimateTick {
            let firstHighMidMax = max(0.001, highMidChroma.max() ?? 0.001)
            let firstLowMidMax = max(0.001, lowMidChroma.max() ?? 0.001)
            for k in 0..<12 {
                state.smoothedHighMidChroma[k] = highMidChroma[k] / firstHighMidMax
                state.smoothedLowMidChroma[k] = lowMidChroma[k] / firstLowMidMax
            }
            state.smoothedLoudness = f.loudness
            state.smoothedTimbre = f.timbreBrightness
            state.smoothedBrilliance = f.bandLoudness[brillianceIdx]
            state.firstAnimateTick = false
        }

        // Per-band max-bin normalization — same rationale as the
        // pre-multi-band code. Each band's chromagram gets normalized
        // by its OWN max bin, not a shared max — so even if the
        // highMid band is much louder than lowMid in absolute terms,
        // both bands' dominant pitches read as 1.0 visually. The
        // listener cares about WHICH pitch each band is on, not how
        // loud the bands are relative to each other.
        let highMidMax = max(0.001, highMidChroma.max() ?? 0.001)
        let lowMidMax = max(0.001, lowMidChroma.max() ?? 0.001)
        let chromaLerp = Float(min(1.0, deltaTime * Double(chromaLerpRate)))
        for k in 0..<12 {
            let hmNorm = highMidChroma[k] / highMidMax
            state.smoothedHighMidChroma[k] +=
                (hmNorm - state.smoothedHighMidChroma[k]) * chromaLerp
            let lmNorm = lowMidChroma[k] / lowMidMax
            state.smoothedLowMidChroma[k] +=
                (lmNorm - state.smoothedLowMidChroma[k]) * chromaLerp
        }
        // Smooth loudness + timbre + band loudnesses.
        let loudLerp = Float(min(1.0, deltaTime * Double(loudnessLerpRate)))
        state.smoothedLoudness +=
            (f.loudness - state.smoothedLoudness) * loudLerp
        let timbreLerp = Float(min(1.0, deltaTime * Double(timbreLerpRate)))
        state.smoothedTimbre +=
            (f.timbreBrightness - state.smoothedTimbre) * timbreLerp
        let bandLerp = Float(min(1.0, deltaTime * Double(bandLoudnessLerpRate)))
        state.smoothedBrilliance +=
            (f.bandLoudness[brillianceIdx] - state.smoothedBrilliance) * bandLerp

        // Bass-pulse envelope. On every bass onset (stems-isolated
        // when available, lowMid-band fallback otherwise), set the
        // pulse to a loudness-normalized amplitude in [0, 1]. Each
        // frame the envelope decays exponentially (~200ms half-life)
        // so the structure visibly snaps + relaxes per bass hit.
        let bassLoudnessSource: Float = {
            if let bassLoud = stemFeatures?.stems["bass"]?.loudness,
               i < bassLoud.count {
                return bassLoud[i]
            }
            return f.bandLoudness[lowMidIdx]
        }()
        let bassOnsetFired: Bool = {
            if let bassOnsets = stemFeatures?.stems["bass"]?.onset,
               i < bassOnsets.count {
                return bassOnsets[i]
            }
            return f.bandOnset[lowMidIdx]
        }()
        // Per-song loudness normalization (rises instantly, ~30s
        // half-life decay, floor at 0.05). Used to map raw RMS to
        // a punch amplitude that fills [0, 1] regardless of how the
        // song was mastered.
        let bassPeakDecay = pow(Float(0.5), Float(deltaTime) / 30.0)
        state.bassLoudnessPeak = max(
            0.05,
            max(state.bassLoudnessPeak * bassPeakDecay, bassLoudnessSource)
        )
        // Decay last frame's pulse before potentially retriggering.
        let bassPulseDecay = pow(Float(0.5), Float(deltaTime) / 0.20)
        state.bassPulse *= bassPulseDecay
        if bassOnsetFired {
            // Punch amplitude scaled by loudness at the onset frame.
            // Floor at 0.45 so even quiet onsets register visibly
            // (otherwise a soft verse-bass produces no movement).
            let rawAmplitude = bassLoudnessSource / state.bassLoudnessPeak
            let punchAmplitude = max(0.45, min(1.0, rawAmplitude))
            // Max-blend so a tail from a previous onset isn't
            // clobbered by a quieter new onset arriving before the
            // tail finishes decaying.
            state.bassPulse = max(state.bassPulse, punchAmplitude)
        }

        // "Other"-stem loudness pipeline (drives the final beam-opacity
        // multiplier so beams dim during quiet passages and slam during
        // loud ones). Falls back to full-mix loudness when stems aren't
        // loaded. Per-song peak normalization mirrors the bass pipeline.
        let otherLoudnessSource: Float = {
            if let otherLoud = stemFeatures?.stems["other"]?.loudness,
               i < otherLoud.count {
                return otherLoud[i]
            }
            return f.loudness
        }()
        let otherPeakDecay = pow(Float(0.5), Float(deltaTime) / 30.0)
        state.otherLoudnessPeak = max(
            0.05,
            max(state.otherLoudnessPeak * otherPeakDecay, otherLoudnessSource)
        )
        let otherNormalized = min(1.0, otherLoudnessSource / state.otherLoudnessPeak)
        // Lerp at ~6 Hz — slower than the bass-pulse envelope but
        // fast enough to register a chorus entry within ~200 ms.
        // EMA on the *normalized* value so the smoothed result also
        // lives in [0, 1].
        let otherLerp = Float(min(1.0, deltaTime * 6.0))
        state.smoothedOtherLoudness +=
            (otherNormalized - state.smoothedOtherLoudness) * otherLerp

        // Smooth the bass chromagram for the interior-glow color.
        // Lerp at ~12 Hz so the hue settles quickly after a new
        // bass note enters without strobing on per-frame chroma
        // jitter. No fallback when stems aren't loaded — glow stays
        // white in that case (still pulses with bassPulse).
        if let bassChroma = stemFeatures?.stems["bass"]?.chromagram,
           i < bassChroma.count {
            let frame = bassChroma[i]
            let chromaLerp = Float(min(1.0, deltaTime * 12.0))
            for k in 0..<12 {
                let target = k < frame.count ? frame[k] : 0
                state.smoothedBassChroma[k] +=
                    (target - state.smoothedBassChroma[k]) * chromaLerp
            }
        }

        // Vocals stem smoothing (loudness + chromagram). No
        // band-fallback: cloud stays dark when no vocals stem
        // loaded. Faster lerp (4 Hz vs original 2.5 Hz) so the
        // cloud snaps onto vocal entries / exits visibly rather
        // than sluggishly fading in.
        if let vocalsLoud = stemFeatures?.stems["vocals"]?.loudness,
           i < vocalsLoud.count {
            let vocLerp = Float(min(1.0, deltaTime * 4.0))
            state.smoothedVocalsLoudness +=
                (vocalsLoud[i] - state.smoothedVocalsLoudness) * vocLerp
        } else {
            // Decay quickly so cloud disappears within ~1s of
            // switching away from a song with stems.
            state.smoothedVocalsLoudness *= 0.85
        }
        if let vocalsChroma = stemFeatures?.stems["vocals"]?.chromagram,
           i < vocalsChroma.count, vocalsChroma[i].count == 12 {
            let chroma = vocalsChroma[i]
            let chromaMax = max(0.001, chroma.max() ?? 0.001)
            for k in 0..<12 {
                state.smoothedVocalsChroma[k] +=
                    (chroma[k] / chromaMax - state.smoothedVocalsChroma[k]) * chromaLerp
            }
        }

        // Stem-features availability check — once per animate tick,
        // not once per frame. When `drumsOnset` is non-nil, the
        // pulse-trigger source switches from sub-band onsets to the
        // isolated drums stem (no bass / room-rumble bleed in the
        // sub band).
        let drumsOnset = stemFeatures?.stems["drums"]?.onset
        let drumsLoudness = stemFeatures?.stems["drums"]?.loudness
        // `other` is Demucs's catch-all stem for content that isn't
        // drums/bass/vocals — most of the harmonic/melodic layer
        // (guitar, piano, synths, horns). Drives the per-face "light
        // rays" pulse so the rays respond to the melody, not the
        // drum hits (drum hits are the disco-ball's job). Falls back
        // to full-mix `frame.onset` when no stem available — that's
        // the pre-stem behavior. Caught by Whiskey River where the
        // gentle full mix barely registers any onsets but the
        // isolated acoustic guitar strums (in `other`) are clean.
        let otherOnset = stemFeatures?.stems["other"]?.onset

        // Scan new onsets since last tick. Two passes:
        //   1. full-spectrum f.onset → per-pitch face pulse (existing)
        //   2. f.bandOnset → sub/brilliance envelope bumps (new)
        if state.lastFrameIndex < 0 {
            // First scan after reset — start at current frame so we
            // don't replay the song's history of onsets.
            state.lastFrameIndex = i
        } else if state.lastFrameIndex < i {
            for j in (state.lastFrameIndex + 1)...i {
                let frame = frames[j]
                // Face-pulse trigger: prefer the `other` stem's
                // onsets (melodic/harmonic content — guitar, piano,
                // horns), fall back to full-mix `frame.onset` when
                // no stems available. The disco-ball uses `drums`,
                // so the two visual layers respond to different
                // musical sources. Caught by Whiskey River: gentle
                // full-mix flux missed the acoustic guitar attacks
                // but the isolated `other` stem catches them cleanly.
                let faceTrigger: Bool
                if let otherOnset, j < otherOnset.count {
                    faceTrigger = otherOnset[j]
                } else {
                    faceTrigger = frame.onset
                }
                if faceTrigger {
                    // Find dominant pitch class for this onset (use
                    // the full chromagram so the pulse routing
                    // matches whichever pitch is loudest right now,
                    // regardless of band).
                    var dom = 0
                    var domW: Float = 0
                    for k in 0..<12 where frame.chromagram[k] > domW {
                        domW = frame.chromagram[k]
                        dom = k
                    }
                    state.pulses[dom] = min(2.0, state.pulses[dom] + pulseBump)
                }

                // ---- Disco-ball pulse trigger ----------------------------
                // Two sources, chosen at apply-time:
                //   • PREFERRED: drums stem onset from demucs-mlx
                //     (isolated kick/snare attacks, no bass bleed).
                //     Magnitude scales with drums.loudness[j].
                //   • FALLBACK: bandOnset[sub] (sub frequency band,
                //     includes kick + bass + room rumble — the kick
                //     lane is approximated by frequency, not source).
                // The fallback is what shipped pre-Phase 1.4; the
                // stem path activates as soon as the sidecar's separation
                // for the current song lands (cache hit = sub-second,
                // fresh compute = ~60s during which we use fallback).
                let useStemPulse: Bool
                if let drumsOnset, j < drumsOnset.count {
                    useStemPulse = drumsOnset[j]
                } else if let drumsOnset {
                    // Frame index past end of stem features — fall through.
                    useStemPulse = frame.bandOnset[subIdx]
                } else {
                    useStemPulse = frame.bandOnset[subIdx]
                }
                if useStemPulse {
                    // Magnitude: prefer drums.loudness[j] when available
                    // (drum-only RMS, much cleaner kick-strength signal
                    // than the sub-band which is dominated by sustained
                    // bass notes). Multiplier tuned for the librosa
                    // RMS scale where typical drum frames peak ≈ 0.1-0.3.
                    let kickStrength: Float
                    if let drumsLoudness, j < drumsLoudness.count {
                        kickStrength = min(1.0,
                            max(0.4, drumsLoudness[j] * 4.0))
                    } else {
                        // Same fallback formula as pre-Phase 1.4
                        kickStrength = min(1.0,
                            max(0.4, frame.bandLoudness[subIdx] * 6.0))
                    }
                    state.beatPulseEnergy = max(state.beatPulseEnergy, kickStrength)
                }

                if frame.bandOnset[brillianceIdx] {
                    state.sparkleEnergy = 1.0
                }
            }
            state.lastFrameIndex = i
        }

        // Decay envelopes.
        let pulseDecayFactor = Float(exp(-Double(pulseDecay) * deltaTime))
        for k in 0..<12 { state.pulses[k] *= pulseDecayFactor }
        let sparkleDecayFactor = Float(exp(-Double(sparkleDecay) * deltaTime))
        state.sparkleEnergy *= sparkleDecayFactor
        let beatDecayFactor = Float(exp(-Double(discoBallBeatPulseDecay) * deltaTime))
        state.beatPulseEnergy *= beatDecayFactor
        // Disco-ball Y rotation advance — tempo-driven. Uses last tick's
        // `state.smoothedTempoT` (this frame's tempoT is computed later
        // in animate, after this point). One-tick lag is invisible on
        // a rotation that's seconds-per-revolution.
        let discoBallRotationRate = discoBallRotationRateSlow
            + (discoBallRotationRateFast - discoBallRotationRateSlow)
            * state.smoothedTempoT
        state.discoBallAngle += Float(deltaTime) * discoBallRotationRate * 2 * .pi

        // Advance rotation. Two axes at different rates — Y (yaw) +
        // X (tumble) — gives a non-repeating tumble feel.
        //
        // Time signature biases rotation speed:
        //   - 3/4 (waltz): 0.75x — emphasizes the 3-beat cycle
        //   - 6/8 (compound duple): 0.85x — slightly slower for the
        //     compound feel
        //   - 5/4, 7/8 (odd meters): 0.90x — slightly off-balance
        //   - everything else (4/4, 2/4, etc.): 1.0x default
        // Without override, falls back to 1.0x.
        let rotationRateScale: Float = {
            guard let ts = timeSigOverride else { return 1.0 }
            switch ts {
            case "3/4":           return 0.75
            case "6/8":           return 0.85
            case "5/4", "7/8":    return 0.90
            default:              return 1.0
            }
        }()
        state.rotationAngle += Float(deltaTime) * rotationSpeed * rotationRateScale * 2 * .pi
        // Bass pulse expresses itself only as the per-face panel
        // separation in `applyState` — separate scale + rotation kicks
        // were tried (peak +25% scale, 2.5× rotation) but stacked with
        // separation they read as too intense. Keeping the pulse to
        // one clear physical metaphor (panels detach + rejoin).

        // Apply rotation to the rotator subroot. Y first then X so the
        // tumble axis stays world-locked rather than rotating with the
        // yaw — reads as "the solid is being turned by an unseen hand"
        // rather than "the solid is precessing on its own axis."
        let yawAngle = state.rotationAngle
        let tumbleAngle = state.rotationAngle * (tumbleSpeed / rotationSpeed)
        let yawQ = simd_quatf(angle: yawAngle, axis: SIMD3(0, 1, 0))
        let tumbleQ = simd_quatf(angle: tumbleAngle, axis: SIMD3(1, 0, 0))
        guard let rotator = root.children.first else {
            root.components.set(state)
            return
        }
        rotator.orientation = tumbleQ * yawQ
        let rotatorRotation = rotator.orientation
        let loud = state.smoothedLoudness

        // Key-anchored per-face baseline. When the song's canonical
        // key is known, every face gets a baseline emissive intensity
        // that reflects its membership in the song's scale: tonic
        // (1 face) > diatonic (6 other scale degrees) > non-diatonic
        // (5 outside-the-scale pitches). The TONIC face additionally
        // pulses via a slow sin "heartbeat" so it's recognizable
        // independent of the chromagram. When no key is known, all
        // faces get the legacy uniform baseline.
        let faceBaselines: [Float] = {
            guard let key = keyOverride else {
                return Array(repeating: noKeyBaseline, count: 12)
            }
            let tonicIndex = key.tonic.rawValue
            let stepsFromTonic = key.mode == .major
                ? majorScaleSteps : minorScaleSteps
            let diatonicSet = Set(stepsFromTonic.map { (tonicIndex + $0) % 12 })
            var out = [Float](repeating: 0, count: 12)
            for k in 0..<12 {
                if k == tonicIndex {
                    out[k] = tonicBaseline
                } else if diatonicSet.contains(k) {
                    out[k] = diatonicBaseline
                } else {
                    out[k] = nonDiatonicBaseline
                }
            }
            return out
        }()
        let tonicIndex: Int? = keyOverride.map { $0.tonic.rawValue }
        // Slow continuous heartbeat for the tonic — independent of
        // beat tracker (which can be wobbly) so it's a steady "this
        // is home" signal. Centered on 1.0 so it modulates the
        // baseline ±amplitude. Amplitude scales with vocal-vs-
        // instrumental: vocal songs have a clear melodic lead, so
        // the tonic pulses more obviously (~1.5× default); instrumental
        // tracks distribute melody across instruments, so the tonic's
        // identity is subtler (~0.5× default).
        let heartbeatAmpScale: Float = {
            guard let v = voiceVocalOverride else { return 1.0 }
            // v=0 → 0.5x, v=50 → 1.0x, v=100 → 1.5x
            return 0.5 + (v / 100.0) * 1.0
        }()
        let effectiveHeartbeatAmp = tonicHeartbeatAmplitude * heartbeatAmpScale
        let tonicPulse: Float = 1.0
            + sin(Float(clock) * tonicHeartbeatRate * 2 * .pi)
            * effectiveHeartbeatAmp

        // Tempo-driven beam lerp rate. The beam opacity per face is
        // lerped toward an unsmoothed target each tick; the rate of
        // that lerp varies with the song's tempo so slow songs read
        // as "beams ease in/out" and fast songs as "beams snap
        // on/off, matching the rhythm." `chromaLerpRate` is left
        // untouched — face emissive still uses the steady ~10 Hz
        // chromagram smoothing so the metallic plate glow doesn't
        // start strobing on fast tracks.
        //
        // `tempoT` is the normalized [0, 1] position between slow and
        // fast tempos. Used both for the lerp rate and for the
        // intensity scaling below.
        //
        // The raw `f.beat.bpm` is octave-folded into a canonical musical
        // range before use (beat trackers commonly lock onto half/double
        // time — verified empirically with "A Fifth of Beethoven"
        // (~110 BPM perceived, 195 BPM reported), folded back to ~97).
        //
        // Then we blend the locked-tempo `tempoT` with the unknown-tempo
        // fallback (0.5) by CONFIDENCE — at conf=1.0 we fully trust the
        // tracker; at conf=0.3 we're 50/50 with the fallback. This
        // damps the visual pop when the tracker briefly bounces to a
        // very different bpm during a low-confidence transition.
        //
        // Finally, the resulting `tempoT` is itself EMA-smoothed in
        // `state.smoothedTempoT` at ~2 Hz so even sustained tracker
        // wobble (which happens on instrumental sections with weak
        // percussion) reads as gradual intensity change, not strobing.
        // When `bpmOverride` is set (Shazam-verified canonical BPM from
        // GetSongBPM / MusicBrainz), use it directly instead of the
        // BeatTracker estimate. Override skips octave folding (database
        // values are already in perceived-tempo) and skips confidence
        // weighting (Shazam ID + DB lookup is high-confidence).
        //
        // When ANY additional character signals are set, blend them
        // into a **6-axis** "intensity character" tempoT:
        //   - bpmT          (0-1) — tempo position in slow→fast range
        //   - danceT        (0-1) — danceability (groove)
        //   - aggressiveT   (0-1) — punching / driving feel
        //   - electronicT   (0-1) — inverse of acousticness; high
        //                          for electronic, low for acoustic
        //   - partyT        (0-1) — celebration-energy vibe
        //   - inverseRelaxedT (0-1) — INVERSE of mood_relaxed; high
        //                          for tense, low for calm
        //
        // Missing signals default to 0.5 (neutral) — keeps the math
        // stable when only BPM is known. Weights chosen so tempo +
        // dance still dominate (most reliable signals), and the four
        // character axes refine without diluting:
        //   bpm 0.25 + dance 0.25 + aggressive 0.15 + electronic 0.10
        //   + party 0.15 + (1-relaxed) 0.10 = 1.00
        //
        // Concrete cases:
        //   - 90 BPM aggressive metal: medium-high (not slow-ballad)
        //   - 130 BPM acoustic singer-songwriter: medium (not disco)
        //   - 100 BPM relaxed jazz: even softer than 100 BPM alone
        //     would imply, because relaxed dampens
        //   - 110 BPM party-pop: medium-high even at modest tempo,
        //     because party + dance compound
        //
        // Falls through to the BeatTracker path when bpm override is nil.
        let blendedTempoT: Float
        let hasBeat: Bool
        if let override = bpmOverride, override > 30 {
            hasBeat = true
            let bpmT = min(1.0, max(0.0,
                (override - slowBpm) / (fastBpm - slowBpm)))
            let danceT: Float = danceabilityOverride.map {
                min(1.0, max(0.0, $0 / 100.0))
            } ?? 0.5
            let aggressiveT: Float = aggressivenessOverride.map {
                min(1.0, max(0.0, $0 / 100.0))
            } ?? 0.5
            // Acousticness is INVERTED — high acoustic should DAMPEN
            // intensity; high electronic should BOOST it.
            let electronicT: Float = acousticnessOverride.map {
                1.0 - min(1.0, max(0.0, $0 / 100.0))
            } ?? 0.5
            let partyT: Float = partyOverride.map {
                min(1.0, max(0.0, $0 / 100.0))
            } ?? 0.5
            // Relaxed is INVERTED in the intensity blend — high
            // relaxed should DAMPEN intensity.
            let inverseRelaxedT: Float = relaxedOverride.map {
                1.0 - min(1.0, max(0.0, $0 / 100.0))
            } ?? 0.5
            blendedTempoT =
                bpmT             * 0.25 +
                danceT           * 0.25 +
                aggressiveT      * 0.15 +
                electronicT      * 0.10 +
                partyT           * 0.15 +
                inverseRelaxedT  * 0.10
        } else {
            let foldedBpm = BeatHelpers.octaveFoldBpm(f.beat.bpm)
            hasBeat = f.beat.confidence >= beatConfidenceFloor && foldedBpm > 0
            let rawTempoT: Float = hasBeat
                ? min(1.0, max(0.0, (foldedBpm - slowBpm) / (fastBpm - slowBpm)))
                : 0.5  // unknown tempo fallback
            // Confidence weighting: smoothstep from 0.3 → 1.0 maps to a
            // 0 → 1 trust weight. Below the floor, trust=0 → use fallback.
            let trustWeight: Float = {
                let c = (f.beat.confidence - beatConfidenceFloor) / (1.0 - beatConfidenceFloor)
                let clamped = min(1.0, max(0.0, c))
                return clamped * clamped * (3 - 2 * clamped)
            }()
            blendedTempoT = 0.5 + (rawTempoT - 0.5) * trustWeight
        }

        // Smooth tempoT in state at ~2 Hz so brief tracker wobble
        // doesn't pop intensity. Snap on first tick / post-reset.
        if state.firstTempoTick {
            state.smoothedTempoT = blendedTempoT
            state.firstTempoTick = false
        } else {
            let tempoTLerp = Float(min(1.0, deltaTime * 2.0))
            state.smoothedTempoT += (blendedTempoT - state.smoothedTempoT) * tempoTLerp
        }
        let tempoT = state.smoothedTempoT

        let beamLerpRate: Float = hasBeat
            ? beamLerpRateSlow + (beamLerpRateFast - beamLerpRateSlow) * tempoT
            : beamLerpRateUnknown
        let beamLerp = Float(min(1.0, deltaTime * Double(beamLerpRate)))

        // Tempo-driven intensity scale. Slow songs cap beam opacity at
        // `tempoIntensityScaleSlow` (0.06); fast songs cap at 1.0.
        // Falls back to `tempoIntensityScaleUnknown` (0.5) when beat
        // tracker is fully unlocked (conf < floor) — but in practice
        // we're now mostly in the trustWeight-blended path above.
        let tempoIntensityScale: Float = tempoIntensityScaleSlow
            + (tempoIntensityScaleFast - tempoIntensityScaleSlow) * tempoT
        // Beam threshold offset — at slow tempos this raises the bar
        // so fewer pitches fire beams. Goes 0 at fastBpm → max at
        // slowBpm.
        let beamThresholdOffset: Float = beamThresholdOffsetSlow * (1 - tempoT)

        // Per-face material updates — emissive from highMid chromagram
        // + pulse + loudness; core beams from highMid intensity, halo
        // beams from lowMid intensity. Each band's chromagram is
        // already smoothed + normalized to [0,1] above.
        for child in rotator.children {
            // Skip non-face children (shockwave, sparkles, etc.) —
            // their per-tick update happens in the dedicated passes
            // below.
            guard let fc = child.components[DodecahedronFaceComponent.self] else { continue }

            // SOFTWARE BACKFACE CULL: hide the entire face entity
            // (face plate + beam groups) when its world-space normal
            // points well away from the camera. Threshold loosened
            // from -0.05 to -0.3 so side faces stay visible longer —
            // the metallic look REQUIRES side faces to catch and
            // sweep specular highlights as the dodec rotates.
            let localNormal = faceDirections[fc.pitchClassIndex]

            // Bass-pulse panel separation: push each face radially
            // outward along its own normal on every bass onset, then
            // let it spring back as `state.bassPulse` decays. Peak
            // displacement at full pulse (~1.0) = 0.05 m (12.5% of
            // dodec radius) — panels visibly detach from the body
            // and rejoin in ~200 ms. Tried 0.20 m (50%) initially;
            // panel separation that wide reads as a disintegrating
            // shape rather than a breathing one. Child beams (core
            // + halo) ride along since they're parented to `face`.
            // Applied to ALL faces (including back-facing ones)
            // before the backface-cull `continue` below so a face
            // crossing into view never snaps from a stale position.
            child.position = localNormal * (state.bassPulse * 0.05)

            let worldNormal = rotatorRotation.act(localNormal)
            let facingCamera = worldNormal.z > -0.3
            child.isEnabled = facingCamera
            if !facingCamera { continue }

            guard let model = child as? ModelEntity,
                  var modelComp = model.components[ModelComponent.self],
                  var mat = modelComp.materials.first as? PhysicallyBasedMaterial
            else { continue }

            let k = fc.pitchClassIndex
            // smoothedHighMidChroma drives ONLY the face emissive
            // here. The beam path now reads from `highMidChroma`
            // (unsmoothed, normalized below) so that the only
            // smoothing applied to beams is the tempo-driven lerp.
            // smoothedLowMidChroma is intentionally unread in the
            // beam path for the same reason.
            let highMid = state.smoothedHighMidChroma[k]
            let pulse = state.pulses[k]

            // Lead-band intensity for FACE EMISSIVE (uses smoothed
            // chroma so the plate glow is stable / tracks the song's
            // chord changes over ~100 ms instead of strobing). Pulse
            // contribution is also tempo-scaled — without this, the
            // per-face onset pulse provided an un-dimmed brightness
            // boost on slow songs, defeating the rest of the dimming.
            let gatedHighMid = max(0,
                (highMid - chromaIntensityFloor) / (1 - chromaIntensityFloor))
            let highMidIntensity = min(1.5, gatedHighMid + pulse * 0.7 * tempoIntensityScale)

            // Face emissive: driven by the LEAD band, since that's
            // where the song's melodic identity lives. The chroma
            // contribution scales with `tempoIntensityScale` so slow
            // songs read as softer glows rather than constantly
            // saturated metal. Baseline is now KEY-AWARE:
            // tonic / diatonic / non-diatonic faces get different
            // baselines so the song's scale "spells itself out"
            // even at rest. Tonic also pulses via tonicPulse.
            // Loudness contribution (0.8) is NOT key-scaled — a loud
            // chord on a non-diatonic note still lights up its face.
            //
            // FINAL multiplier: timbre brightness. Bright timbre →
            // punchier highlights (multiplier up to 1.15×); dark
            // timbre → more muted (down to 0.85×). Applied as a
            // global modulator on the active-chroma + loudness
            // contribution; baseline is unchanged so faces don't
            // lose their key-anchor identity in dark timbre.
            let timbreFactor: Float = {
                guard let t = timbreBrightnessOverride else { return 1.0 }
                // t=0 (dark) → 0.85, t=50 (neutral) → 1.0, t=100 (bright) → 1.15
                return 0.85 + (t / 100.0) * 0.30
            }()

            var baseline = faceBaselines[k]
            if tonicIndex == k {
                baseline *= tonicPulse
            }
            let activeContribution = (min(1.0, Float(highMidIntensity)) * 1.65 * tempoIntensityScale
                                      + Float(loud) * 0.8)
                * timbreFactor
            let emissiveStrength: Float = baseline + activeContribution
            mat.emissiveIntensity = emissiveStrength
            modelComp.materials[0] = mat
            model.components.set(modelComp)

            // Beam target opacities — computed from the CURRENT frame's
            // normalized chromagram (not the chromagram-smoothed value
            // above) so the only smoothing applied to the beam path is
            // the tempo-driven `beamLerp` below. This is what makes
            // beams snap on fast songs and ease on slow songs without
            // affecting the plate emissive's steady response.
            let coreRawIntensity: Float = {
                // Pulse contribution tempo-scaled (same rationale as
                // the face-emissive path) so the per-face onset pulse
                // doesn't dump an un-dimmed brightness boost into beam
                // targets on slow songs.
                let raw = highMidChroma[k] / highMidMax + pulse * 0.7 * tempoIntensityScale
                let gated = max(0, (raw - chromaIntensityFloor) / (1 - chromaIntensityFloor))
                return min(1.5, gated)
            }()
            let haloRawIntensity: Float = {
                let raw = lowMidChroma[k] / lowMidMax
                let gated = max(0, (raw - chromaIntensityFloor) / (1 - chromaIntensityFloor))
                return min(1.5, gated)
            }()

            // Threshold + falloff to get target opacities. Thresholds
            // are tempo-shifted upward at slow tempos
            // (`beamThresholdOffset` > 0 at low BPM) so fewer pitches
            // cross the bar on slow songs. The final opacity is then
            // capped at `tempoIntensityScale` — slow songs cap at
            // ~0.35, fast at 1.0 — so even active beams render dimmer
            // on a ballad than on a disco track.
            let coreThreshold = min(0.98, beamIntensityThreshold + beamThresholdOffset)
            let coreOver = max(0, coreRawIntensity - coreThreshold)
                / max(0.001, 1.0 - coreThreshold)
            let coreTarget = min(tempoIntensityScale,
                                 coreOver * coreOver * coreOver * 2.0)
            let haloThreshold = min(0.98, haloIntensityThreshold + beamThresholdOffset)
            let haloOver = max(0, haloRawIntensity - haloThreshold)
                / max(0.001, 1.0 - haloThreshold)
            let haloTarget = min(tempoIntensityScale,
                                 haloOver * haloOver * 1.6)

            // EMA-lerp the persisted opacity toward target at the
            // tempo-driven rate. This is the per-tempo smoothing — at
            // fast tempos `beamLerp` ≈ 1 (snap to target), at slow
            // tempos `beamLerp` ≈ 0.05 (smooth ease over many ticks).
            state.smoothedCoreOpacity[k] +=
                (coreTarget - state.smoothedCoreOpacity[k]) * beamLerp
            state.smoothedHaloOpacity[k] +=
                (haloTarget - state.smoothedHaloOpacity[k]) * beamLerp

            // Final multiplier: smoothed normalized "other"-stem loudness
            // (full-mix loudness fallback). Floor at 0.25 so a quiet but
            // pitch-clear passage still produces visible beams. Picked
            // post-cap (vs pre-cap on the shaped target) after A/B test
            // 2026-05-27 — linear loudness response read more naturally
            // than the plateau-at-cap behavior of pre-cap multiplication.
            let loudnessMultiplier = 0.25 + 0.75 * state.smoothedOtherLoudness
            for beamChild in child.children {
                guard let beamTag = beamChild.components[DodecahedronFaceBeamComponent.self]
                else { continue }
                let opacity: Float
                switch beamTag.kind {
                case .core: opacity = state.smoothedCoreOpacity[k]
                case .halo: opacity = state.smoothedHaloOpacity[k]
                }
                beamChild.components.set(OpacityComponent(opacity: opacity * loudnessMultiplier))
            }
        }

// ---- Sparkle pool update (brilliance band) ---------------------
        // Each sparkle has its own phase; per-tick opacity is the sum
        // of the onset envelope (sparkleEnergy) and the continuous
        // brilliance shimmer (smoothedBrilliance × phase wave).
        //
        // Tempo-driven SIZE + INTENSITY: slow songs get small dim
        // sparkles ("intimate atmosphere"); fast songs get larger
        // brighter ones ("the air is buzzing"). The base
        // `tempoIntensityScale` already dims everything on slow songs;
        // the brilliance-specific multiplier here pushes the contrast
        // further so the sparkle pool's tempo response is more
        // pronounced than the dodec's other elements.
        let sparkleTime = Float(clock) * 6.0
        let brillianceTempoMult = sparkleBrillianceTempoMultSlow
            + (sparkleBrillianceTempoMultFast - sparkleBrillianceTempoMultSlow) * tempoT
        let sparkleScale = sparkleSizeScaleSlow
            + (sparkleSizeScaleFast - sparkleSizeScaleSlow) * tempoT
        let shimmerBase = min(1.0, state.smoothedBrilliance * 6.0)
            * sparkleShimmerStrength * tempoIntensityScale * brillianceTempoMult
        let twinkleScale = tempoIntensityScale * brillianceTempoMult
        // Edge-skeleton update: tint all 90 edge-layer entities to
        // the dominant bass-stem pitch hue. Each layer (core / mid /
        // wide) interpolates its own brightness + hdrBoost ramp
        // between its base (rest) and peak values according to
        // `state.bassPulse`. The wide outer halo is what reads as
        // "light bleeding past the seam."
        if let skeleton = rotator.children.first(where: {
            $0.components.has(DodecahedronEdgeSkeletonComponent.self)
        }) {
            var dominantIdx = 0
            var dominantVal: Float = 0
            for k in 0..<12 {
                if state.smoothedBassChroma[k] > dominantVal {
                    dominantVal = state.smoothedBassChroma[k]
                    dominantIdx = k
                }
            }
            let hue = CGFloat(
                (PitchClass(rawValue: dominantIdx) ?? .c).circleOfFifthsHue
            )
            let pulse = state.bassPulse
            let saturation: CGFloat = CGFloat(0.90 - pulse * 0.30)
            // Precompute one tint per layer (3 total) — far cheaper
            // than computing per-edge in the inner loop.
            var layerTints: [PlatformColor] = []
            for layer in dodecahedronEdgeLayers {
                let brightness = CGFloat(
                    layer.baseBrightness
                    + (layer.peakBrightness - layer.baseBrightness) * pulse
                )
                let hdrBoost = CGFloat(
                    layer.baseHdrBoost
                    + (layer.peakHdrBoost - layer.baseHdrBoost) * pulse
                )
                layerTints.append(PlatformColor.hdrColor(
                    hue: hue,
                    saturation: saturation,
                    brightness: brightness,
                    hdrBoost: hdrBoost
                ))
            }
            for edge in skeleton.children {
                guard let layerComp = edge.components[DodecahedronEdgeLayerComponent.self],
                      let model = edge as? ModelEntity,
                      var modelComp = model.components[ModelComponent.self],
                      var mat = modelComp.materials.first as? UnlitMaterial
                else { continue }
                let layerIdx = layerComp.layerIndex
                guard layerIdx < layerTints.count else { continue }
                mat.color = .init(tint: layerTints[layerIdx])
                modelComp.materials[0] = mat
                model.components.set(modelComp)
            }
        }

        // Sync the sparkle container's Y rotation with the disco ball
        // so sparkles ride along with the lit-cell grid they're
        // aligned to. Both share `state.discoBallAngle`.
        let sparkleContainer = root.children.first(where: {
            $0.components.has(DodecahedronSparkleContainerComponent.self)
        })
        if let sparkleContainer {
            sparkleContainer.orientation = simd_quatf(
                angle: state.discoBallAngle,
                axis: SIMD3<Float>(0, 1, 0)
            )
            for child in sparkleContainer.children {
                guard let sp = child.components[DodecahedronSparkleComponent.self] else { continue }
                let phaseWave = 0.5 + 0.5 * sin(sparkleTime + sp.phase)
                let twinkle = state.sparkleEnergy * phaseWave * twinkleScale
                let shimmer = shimmerBase * phaseWave
                let opacity = min(1.0, twinkle + shimmer)
                child.components.set(OpacityComponent(opacity: opacity))
                child.scale = SIMD3<Float>(repeating: sparkleScale)
            }
        }

        // ---- Disco-ball update (RCP shader graph → BeatPulse uniform) ---
        // Single setParameter per tick fades all lit cells together via
        // the shader's emissive math. Cost: one entity lookup, one
        // material struct mutation, one component set.
        //
        // No confidence gate: the trigger source is `bandOnset[sub]`
        // (kick onsets) which is direct energy-detection — it either
        // fires or it doesn't, no "tracker uncertainty" concept like
        // beatTrigger had. Pulses always reach the shader; if there's
        // no kick, the envelope decays and the cells go dark naturally.
        let effectivePulse = state.beatPulseEnergy
        let discoBall = root.children.first(where: {
            $0.components.has(DodecahedronDiscoBallComponent.self)
        })
        if let discoBall {
            // Slow Y rotation, accumulated in state.discoBallAngle. Note
            // the entity also has scale.y = -1 (winding flip), so a
            // pure-Y rotation here composes fine — Y-axis rotation
            // commutes with Y-axis scale.
            discoBall.orientation = simd_quatf(
                angle: state.discoBallAngle,
                axis: SIMD3<Float>(0, 1, 0)
            )
            setDiscoBallFloat(discoBall, name: "BeatPulse", value: effectivePulse)

            // Per-tick LitColor: blend mood-tinted base with the
            // currently-dominant pitch hue. The disco ball flashes the
            // color of whichever pitch class is leading the mix, with
            // the mood undertone preserved. Dominant pitch comes from
            // the smoothed high-mid chromagram (lead band, normalized).
            var dom = 0
            var domW: Float = 0
            for k in 0..<12 where state.smoothedHighMidChroma[k] > domW {
                domW = state.smoothedHighMidChroma[k]
                dom = k
            }
            let pitchHue = CGFloat(PitchClass(rawValue: dom)?.circleOfFifthsHue ?? 0.5)
            let pitchColor = PlatformColor.hdrColor(
                hue: pitchHue, saturation: 0.5,
                brightness: 1.0, hdrBoost: 1.0
            )
            let moodColor = discoBallLitColor(happiness: happinessOverride)
            let blended = blendColors(
                moodColor, pitchColor,
                weight: discoBallChromaBlendWeight
            )
            setDiscoBallColor(discoBall, name: "LitColor", color: blended)

            // Energy-driven LIT roughness — sharper reflections when
            // the song is intense, softer when it's quiet. Combined
            // energy = 0.6 × tempoT + 0.4 × normalized loudness, so
            // the BASE roughness tracks the song's BPM character and
            // dynamic peaks (loud chorus) push it sharper still on
            // top. `smoothedLoudness × 4` is a rough normalization —
            // peak music loudness ≈ 0.25 → 1.0 after the multiplier.
            // Mirror cells are unaffected (shader fallback = 1.0).
            let loudnessEnergy = min(1.0, state.smoothedLoudness * 4.0)
            let combinedEnergy = 0.6 * tempoT + 0.4 * loudnessEnergy
            let litRoughness = discoBallLitRoughnessSlow
                + (discoBallLitRoughnessFast - discoBallLitRoughnessSlow) * combinedEnergy
            setDiscoBallFloat(discoBall, name: "LitRoughness", value: litRoughness)
        }

        // ---- Mood-driven palette refresh ----
        // Sparkle pool color tracks `happinessOverride`. Updated only
        // when the value CHANGES (per Shazam lookup that returns a
        // happiness, or per track change to nil) rather than every
        // tick — material replacement triggers a render-pipeline
        // update each time, and there's no reason to pay that cost
        // every frame for a value that only changes on song boundaries.
        if state.lastAppliedHappiness != happinessOverride {
            let sparkleTint = sparkleColor(happiness: happinessOverride)
            // Sparkles live in `sparkleContainer` (cell-aligned on the
            // disco ball's inner surface), not under the rotator.
            if let sparkleContainer {
                for child in sparkleContainer.children
                    where child.components.has(DodecahedronSparkleComponent.self) {
                    updateUnlitTint(child, color: sparkleTint)
                }
            }
            // Disco-ball LitColor is now blended with the chromagram
            // pitch hue per-tick (see the disco-ball apply block above),
            // so no per-song-boundary push is needed — happinessOverride
            // is folded in via discoBallLitColor() inside the per-tick
            // blend each frame.
            state.lastAppliedHappiness = happinessOverride
        }

        // Vocal sparkle cloud update: walk each particle, set its
        // material tint to (vocals-hue × global-intensity ×
        // per-particle twinkle). Additive blend means black tint =
        // invisible, brighter tint = brighter. Heavy gain (×8) so
        // the cloud goes from black to dazzling within a song — the
        // previous halo's ×4.5 was too subtle for the design intent.
        if let auraContainer = root.children.first(
            where: { $0.components[DodecahedronVocalAuraComponent.self] != nil }
        ) {
            // Dominant vocal pitch → hue.
            var domIdx = 0
            var domVal = state.smoothedVocalsChroma[0]
            for k in 1..<12 where state.smoothedVocalsChroma[k] > domVal {
                domVal = state.smoothedVocalsChroma[k]
                domIdx = k
            }
            let pitchHue = PitchClass(rawValue: domIdx)?.circleOfFifthsHue ?? 0
            // Global intensity (vocals loudness curve, more aggressive
            // than before).
            let globalIntensity = min(1.0, Float(state.smoothedVocalsLoudness * 8.0))
            if globalIntensity > 0.005 {
                // Drive each particle's twinkle. Use `clock` (song
                // playback time, monotonic) as the phase advance so
                // sparkles animate at consistent speed regardless
                // of frame rate.
                let songTime = Float(clock)
                for sparkle in auraContainer.children {
                    guard
                        let cfg = sparkle.components[DodecahedronVocalSparkleComponent.self],
                        let model = (sparkle as? ModelEntity)?.model,
                        var mat = model.materials.first as? UnlitMaterial
                    else { continue }
                    // sin(phase + t × frequency × 2π) lives in [-1, 1];
                    // halve+offset to [0, 1]; multiply by global. Per-
                    // particle frequencies differ so they sparkle out
                    // of phase, reading as a busy shimmer.
                    let twinkle = (sin(cfg.phase + songTime * cfg.frequency * 2 * .pi) * 0.5) + 0.5
                    let particleIntensity = globalIntensity * twinkle
                    let tint = PlatformColor.hdrColor(
                        hue: CGFloat(pitchHue),
                        saturation: 0.7,
                        brightness: 1.0,
                        hdrBoost: CGFloat(3.0 * particleIntensity)
                    )
                    mat.color = .init(tint: tint)
                    (sparkle as? ModelEntity)?.model?.materials = [mat]
                }
            } else {
                // Cloud invisible — zero out any lingering particles.
                for sparkle in auraContainer.children {
                    guard
                        let model = (sparkle as? ModelEntity)?.model,
                        var mat = model.materials.first as? UnlitMaterial,
                        mat.color.tint != .black
                    else { continue }
                    mat.color = .init(tint: .black)
                    (sparkle as? ModelEntity)?.model?.materials = [mat]
                }
            }
        }

        root.components.set(state)
    }
}
