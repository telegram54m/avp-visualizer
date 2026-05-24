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
    /// Shockwave envelope (0…1). Bumped to 1.0 by sub-band onsets
    /// (kicks); decays exponentially. Drives the central shockwave
    /// entity's scale + opacity.
    var shockwaveEnergy: Float = 0
    /// Sparkle envelope (0…1). Bumped to 1.0 by brilliance-band
    /// onsets (hats / shakers / cymbals); decays exponentially.
    /// Drives the orbiting sparkle pool's brightness.
    var sparkleEnergy: Float = 0
    /// Smoothed brilliance-band loudness — provides a continuous
    /// "shimmer baseline" on the sparkle pool even between hat hits.
    var smoothedBrilliance: Float = 0
    /// Smoothed sub-band loudness — colors the shockwave so its tint
    /// follows whatever's in the sub band's pitch-class energy.
    var smoothedSub: Float = 0
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

/// Tag for the singular central shockwave entity. Lives under the
/// rotator subroot so it tumbles with the dodec. Driven by
/// `shockwaveEnergy` (bumped on sub-band onsets).
struct DodecahedronShockwaveComponent: Component {}

/// Tag for one sparkle in the orbiting brilliance-band particle pool.
/// `phase` is the particle's individual twinkle offset (radians); each
/// tick its opacity is `sparkleEnergy × (0.5 + 0.5 sin(t + phase))`.
struct DodecahedronSparkleComponent: Component {
    let phase: Float
}

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

    /// Sub-band onset bumps the shockwave envelope to 1.0; it decays
    /// at this rate (per second). 2.5 Hz ≈ 280 ms half-life — long
    /// enough to read as an expanding ring, short enough that
    /// successive kicks at 120 BPM (2 Hz) stack visibly instead of
    /// merging into a held glow.
    static let shockwaveDecay: Float = 2.5
    /// Maximum radial scale the shockwave reaches at peak energy,
    /// expressed as a multiple of `dodecahedronRadius`. 2.2 = the
    /// shockwave grows from 0 to ~2.2× the dodec's circumradius
    /// (≈ 0.88 m) before fading out — well clear of the dodec body.
    static let shockwaveMaxScaleMultiplier: Float = 2.2
    /// Minimum scale floor — keeps the shockwave entity from
    /// collapsing into a 0-scale singularity at rest. Invisible at
    /// rest via opacity, but RealityKit can warn on degenerate scales.
    static let shockwaveMinScale: Float = 0.05

    /// Brilliance-band onset bumps the sparkle envelope to 1.0; it
    /// decays at this rate (per second). 3.5 Hz = ~200 ms half-life,
    /// matched to the brief hat / shaker / cymbal hit feel.
    static let sparkleDecay: Float = 3.5
    /// Number of orbiting sparkle entities around the dodec.
    static let sparkleCount: Int = 32
    /// Radius of the sparkle pool around the dodec center, in meters.
    /// Sits between the dodec's circumradius (~0.4) and the
    /// shockwave's peak reach (~0.88), so sparkles read as ambient
    /// twinkle in the immediate space around the solid.
    static let sparkleOrbitRadius: Float = 0.65
    /// Size of each sparkle sprite (edge length, meters).
    static let sparkleSize: Float = 0.018
    /// Continuous shimmer floor — sparkle pool's minimum brightness
    /// at high brilliance loudness even between hat hits. Mixed with
    /// the onset-driven envelope so brilliance-heavy mixes (e.g. a
    /// shaker hi pattern) read as a continuously twinkling halo.
    static let sparkleShimmerStrength: Float = 0.35

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
            material.roughness = 0.30
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

        // ---- Central shockwave entity (sub-band onset → kick pulse) -
        // An additive sphere centered on the dodec. Stays at scale ≈ 0
        // and opacity 0 at rest; on each kick (`bandOnset[sub]`), the
        // root's shockwaveEnergy bumps to 1.0 and animate() scales the
        // sphere outward as opacity fades. Reads as a quick concentric
        // shock radiating outward through the dodec on every kick hit.
        //
        // Lives on the rotator subroot so it tumbles with the dodec
        // (matching the "the dodec is the universe" framing rather
        // than "the shockwave is in the room").
        // Base sphere radius = dodecahedronRadius (0.4 m) so when the
        // per-tick scale crosses 2.2× (shockwaveMaxScaleMultiplier),
        // the visible radius reaches ~0.88 m — comfortably beyond the
        // dodec's outer envelope, so the wave reads as "passing
        // through and out" instead of "barely poking out."
        let shockwave = ModelEntity(
            mesh: .generateSphere(radius: dodecahedronRadius),
            materials: [{
                var mat = UnlitMaterial(program: additiveProgram)
                // Bright neutral-warm white tint; the per-tick HDR
                // boost in animate() pushes the brightness above SDR.
                mat.color = .init(tint: PlatformColor.hdrColor(
                    hue: 0.06, saturation: 0.20,
                    brightness: 1.0, hdrBoost: 2.5
                ))
                mat.writesDepth = false
                return mat
            }()]
        )
        shockwave.components.set(DodecahedronShockwaveComponent())
        shockwave.components.set(OpacityComponent(opacity: 0.0))
        shockwave.scale = SIMD3<Float>(repeating: shockwaveMinScale)
        rotator.addChild(shockwave)

        // ---- Orbiting sparkle pool (brilliance band → hats / shakers)
        // 32 tiny additive sprites positioned on a Fibonacci-spiral
        // sphere around the dodec. Each sparkle has a per-particle
        // phase so they twinkle individually rather than all flashing
        // together. The pool's overall brightness is the sum of
        // (continuous brilliance shimmer) and (onset-driven sparkle
        // envelope) — a busy hat pattern reads as a constant twinkle,
        // a single cymbal hit reads as a quick all-sparkle flash.
        //
        // Fibonacci spiral spacing: each successive index advances by
        // the golden angle (~137.5°) around y, with z stepping
        // uniformly from -1 to +1. Produces an even, non-clumpy
        // distribution on the sphere — better than uniform random.
        let goldenAngle: Float = .pi * (3 - sqrt(5))
        for i in 0..<sparkleCount {
            let z: Float = 1 - 2 * Float(i) / Float(sparkleCount - 1)
            let radiusAtZ: Float = sqrt(max(0, 1 - z * z))
            let theta: Float = goldenAngle * Float(i)
            let position = SIMD3<Float>(
                cos(theta) * radiusAtZ,
                z,
                sin(theta) * radiusAtZ
            ) * sparkleOrbitRadius

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
            rotator.addChild(sparkle)
        }

        return root
    }

    // MARK: - Tempo helpers

    /// Canonical musical-BPM range. Anything outside this gets folded
    /// by halving/doubling until it lands inside. Spans roughly
    /// "slow ballad" through "very fast dance" — wider would let
    /// half/double-time interpretations slip through; narrower might
    /// fold legitimate genre tempos (e.g. 160 BPM punk → 80).
    static let canonicalBpmMin: Float = 70.0
    static let canonicalBpmMax: Float = 140.0

    /// Octave-fold a raw bpm into the canonical musical range. The
    /// `BeatTracker` regularly locks onto half-time or double-time
    /// interpretations of the perceived tempo (it's a known limit of
    /// IOI-based trackers — a song with strong hat eighths and a
    /// 110 BPM kick will often lock onto 220 BPM because the
    /// inter-onset intervals are equally regular). Folding restores
    /// the perceptual tempo so visual-treatment thresholds match what
    /// a listener feels.
    static func octaveFoldBpm(_ raw: Float) -> Float {
        guard raw > 0 else { return 0 }
        var bpm = raw
        // Cap iterations to avoid pathological loops on bogus inputs.
        for _ in 0..<8 {
            if bpm > canonicalBpmMax {
                bpm *= 0.5
            } else if bpm < canonicalBpmMin {
                bpm *= 2.0
            } else {
                return bpm
            }
        }
        return bpm
    }

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
        danceabilityOverride: Float? = nil
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
            state.shockwaveEnergy = 0
            state.sparkleEnergy = 0
            state.smoothedBrilliance = 0
            state.smoothedSub = 0
            state.smoothedCoreOpacity = .init(repeating: 0, count: 12)
            state.smoothedHaloOpacity = .init(repeating: 0, count: 12)
            state.smoothedTempoT = 0.5
            state.firstTempoTick = true
            state.rotationAngle = 0
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
        let highMidChroma = f.bandChromagram[highMidIdx]
        let lowMidChroma = f.bandChromagram[lowMidIdx]

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
            state.smoothedSub = f.bandLoudness[subIdx]
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
        state.smoothedSub +=
            (f.bandLoudness[subIdx] - state.smoothedSub) * bandLerp

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
                if frame.onset {
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
                if frame.bandOnset[subIdx] {
                    state.shockwaveEnergy = 1.0
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
        let shockDecayFactor = Float(exp(-Double(shockwaveDecay) * deltaTime))
        state.shockwaveEnergy *= shockDecayFactor
        let sparkleDecayFactor = Float(exp(-Double(sparkleDecay) * deltaTime))
        state.sparkleEnergy *= sparkleDecayFactor

        // Advance rotation. Two axes at different rates — Y (yaw) +
        // X (tumble) — gives a non-repeating tumble feel.
        state.rotationAngle += Float(deltaTime) * rotationSpeed * 2 * .pi

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
        // GetSongBPM), use it directly instead of the BeatTracker
        // estimate. Override skips octave folding (database values are
        // already in perceived-tempo) and skips confidence weighting
        // (Shazam ID + DB lookup is high-confidence by definition).
        //
        // When `danceabilityOverride` is ALSO set, blend it with the
        // BPM-derived tempoT — a slow-but-groovy song (Stayin' Alive
        // at 104 BPM, danceability 85) should read more energetic than
        // its tempo alone suggests, and a fast-but-restrained song
        // (a 130 BPM acoustic piece, danceability 30) should read less
        // disco than its tempo alone suggests. Weighted 40% tempo /
        // 60% danceability — danceability is the more direct "should
        // this feel energetic" signal.
        //
        // Falls through to the BeatTracker path when bpm override is nil.
        let blendedTempoT: Float
        let hasBeat: Bool
        if let override = bpmOverride, override > 30 {
            hasBeat = true
            let bpmT = min(1.0, max(0.0,
                (override - slowBpm) / (fastBpm - slowBpm)))
            if let dance = danceabilityOverride {
                let danceT = min(1.0, max(0.0, dance / 100.0))
                blendedTempoT = bpmT * 0.4 + danceT * 0.6
            } else {
                blendedTempoT = bpmT
            }
        } else {
            let foldedBpm = octaveFoldBpm(f.beat.bpm)
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
            // saturated metal. Baseline (0.15) and loudness
            // contribution (0.8) are NOT scaled — faces never go fully
            // dark, and a loud-but-slow ballad still glows from the
            // loudness term.
            let emissiveStrength: Float = 0.15
                + min(1.0, Float(highMidIntensity)) * 1.65 * tempoIntensityScale
                + Float(loud) * 0.8
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

            // Apply to the two beam group children. The OpacityComponent
            // value we set is the post-tempo-smoothing one; the per-band
            // intensity decomposition still routes core vs halo to
            // different bands, but the speed of fade is now uniform-per-
            // tempo across both groups.
            for beamChild in child.children {
                guard let beamTag = beamChild.components[DodecahedronFaceBeamComponent.self]
                else { continue }
                let opacity: Float
                switch beamTag.kind {
                case .core: opacity = state.smoothedCoreOpacity[k]
                case .halo: opacity = state.smoothedHaloOpacity[k]
                }
                beamChild.components.set(OpacityComponent(opacity: opacity))
            }
        }

        // ---- Shockwave update (sub band) -------------------------------
        // Find the shockwave entity (tagged) and update its scale +
        // opacity from shockwaveEnergy. Energy decays from 1.0 (just
        // kicked) to 0.0 (idle); during decay the sphere grows from
        // ~0 to shockwaveMaxScaleMultiplier × dodecRadius and fades
        // out — reads as an expanding concentric shock.
        for child in rotator.children {
            guard child.components.has(DodecahedronShockwaveComponent.self) else { continue }
            let e = state.shockwaveEnergy
            // Scale: at e=1 (just kicked), small; at e→0, full reach.
            // Map (1 → e) to (0 → 1) for a "starts tight, grows
            // outward" expansion. Multiplied by the max-scale param.
            let growth = (1 - e) * shockwaveMaxScaleMultiplier + shockwaveMinScale
            child.scale = SIMD3<Float>(repeating: max(shockwaveMinScale, growth))
            // Opacity: peak at e≈0.85 (just past trigger, briefly
            // bright), fades as it expands. Quadratic falloff so it
            // doesn't linger. Scaled by tempoIntensityScale so slow
            // songs get a subtler shockwave (kicks are less explosive
            // visually) than fast songs.
            let opacity = e * e * 0.65 * tempoIntensityScale
            child.components.set(OpacityComponent(opacity: opacity))
        }

        // ---- Sparkle pool update (brilliance band) ---------------------
        // Each sparkle has its own phase; per-tick opacity is the sum
        // of the onset envelope (sparkleEnergy) and the continuous
        // brilliance shimmer (smoothedBrilliance × phase wave).
        let sparkleTime = Float(clock) * 6.0
        // Shimmer baseline scales with tempoIntensityScale — slow
        // songs get a near-invisible continuous shimmer (still there,
        // but doesn't compete with the dimmed beams); fast songs get
        // the full shimmer floor.
        let shimmerBase = min(1.0, state.smoothedBrilliance * 6.0)
            * sparkleShimmerStrength * tempoIntensityScale
        // Onset-driven twinkle is also scaled (so a cymbal hit on a
        // ballad is felt but not loud-disco-explosive).
        let twinkleScale = tempoIntensityScale
        for child in rotator.children {
            guard let sp = child.components[DodecahedronSparkleComponent.self] else { continue }
            let phaseWave = 0.5 + 0.5 * sin(sparkleTime + sp.phase)
            let twinkle = state.sparkleEnergy * phaseWave * twinkleScale
            let shimmer = shimmerBase * phaseWave
            let opacity = min(1.0, twinkle + shimmer)
            child.components.set(OpacityComponent(opacity: opacity))
        }

        root.components.set(state)
    }
}
