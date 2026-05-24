//
//  RingsVisualizer.swift
//  High Videlity
//
//  Rings mode — concentric pulsating rings of glow-sprite particles.
//  Calmer and more meditative than Crystal's radiating beams; calmer in
//  ambient feel than Clouds' nebula sprites.
//
//  HTML reference's structure: 16 rings × 200 particles = 3200 glow points
//  on a roughly planar disc with a sin-wave Z displacement per particle.
//  Each ring rotates at a different rate (alternating direction). Onsets
//  trigger a "ripple" wave that expands radially outward at speed 12 over
//  1.6 seconds and gaussian-modulates each ring's radius as the wavefront
//  passes through. Harmonic complexity → how many rings are "alive";
//  loudness → saturation + rotation speed; timbre brightness → particle
//  brightness baseline.
//
//  Implementation strategy: we use `MeshInstancesComponent` (introduced
//  visionOS 26 / iOS 18 / macOS 15 — our deployment targets are 26+) so
//  each ring is a single `ModelEntity` with 200 instances of one quad
//  mesh. 16 entities total instead of 3200 — single material per ring,
//  one buffer write per ring per frame for transforms. We can't update
//  per-instance colors with the current API surface, but since HTML
//  computes one color per ring (all 200 of a ring's particles share it),
//  updating the ring's material color is sufficient.
//
//  Quad orientation: built manually in the XY plane facing +Z (rather
//  than `MeshResource.generatePlane` which gives an XZ plane). The ring
//  cluster sits at z = -2.5 from the windowed virtual camera (which is
//  at origin looking down -Z), so quads facing +Z appear face-on. The
//  ring plane is tilted slightly via root `orientation` so the rings
//  show depth instead of reading as a flat disc.
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

/// Per-ring animation state. Stored on each ring entity.
struct RingComponent: Component {
    let index: Int
    let baseR: Float
    var intensity: Float = 0
    var rotation: Float = 0
}

/// Cluster-level state. Stored on the root entity.
struct RingsRootComponent: Component {
    /// Onset-triggered ripples — clock times at which they were born. Pruned
    /// when older than 1.6s.
    var ripples: [Double] = []
    /// Last frame index we scanned for onsets, so we don't re-trigger ripples
    /// from frames we already processed.
    var lastFrameIndex: Int = -1
    /// Wall-clock-driven phase for the slow camera-pose oscillation. HTML's
    /// `autoRotate = true` orbits the CAMERA around the scene (rings always
    /// stay visible). Our previous attempt rotated the CLUSTER, which made
    /// the rings go edge-on (and invisible) at the 90° point. Instead we
    /// oscillate the cluster's orientation in a bounded range AND dolly it
    /// along Z, producing a "camera flies in toward the rings, drifts past
    /// them, pulls back" feel without ever losing visibility.
    var animPhase: Float = 0
    /// Base orientation captured lazily on the first animate() call —
    /// whatever the host (VisualizerView / ImmersiveView) set at scene-add
    /// time. Per-frame motion is layered on top. NaN sentinel marks "not
    /// captured yet."
    var baseOrientation: simd_quatf = simd_quatf(ix: .nan, iy: 0, iz: 0, r: 1)
    /// Base Z position captured lazily on first animate() call — dolly
    /// oscillation is layered on top.
    var baseZ: Float = .nan
    /// Smoothed copies of incoming `eLoud` / `eTimbre`. Raw per-frame
    /// loudness and timbre spike sharply on transients (kick drum, snare
    /// hit) — multiplying those spikes into the rotation rate, breath
    /// scale, and color params makes the whole cluster lurch on every
    /// loud beat. Lerping at ~4 Hz preserves the reactivity but smooths
    /// the discontinuities.
    var eLoudSmoothed: Float = 0
    var eTimbreSmoothed: Float = 0
    /// Smoothed copy of the frame's chromagram-derived hue. Raw `f.color.hue`
    /// can swing by 0.3+ between adjacent frames when a chord changes
    /// or a single melodic note dominates — the visualizer cycles through
    /// blue → purple → red → purple in <200ms, which reads as "color
    /// strobing." Smoothing via circular lerp keeps the hue moving
    /// continuously around the color wheel.
    var hueSmoothed: Float = 0
    var hueSmoothedInitialized: Bool = false
    /// `appModel.liveModeResetCounter` value at the most-recent animate
    /// tick. When AppModel bumps it (Shazam track-change reset),
    /// `animate` clears ripples + drops per-song frame-index state +
    /// re-initializes hue smoothing so the new song's first hue isn't
    /// blended with the old. Rings don't spawn entities, so the existing
    /// 16-ring pool stays put and just re-drives off new frames.
    var lastSeenResetCounter: Int = 0
}

enum RingsVisualizer {

    // MARK: - Constants (HTML mirror, scaled for our world)

    static let ringCount = 16
    static let perRing   = 200

    /// HTML radii are 1.8 + k*0.95 (k = 0..15) → 1.8..16.05 in HTML units. Our
    /// world is ~1/4 the scale (cluster ~ a few meters in front of viewer),
    /// so use a corresponding smaller spread. Outermost ring ~3.6 units.
    static let baseRadiusStart: Float = 0.45
    static let baseRadiusStep: Float  = 0.21

    /// Glow sprite world size — small enough that 200/ring don't visually
    /// merge into a solid ring, large enough that bloom touches each.
    static let spriteSize: Float = 0.07

    // MARK: - Build

    /// Build the 16-ring constellation.
    ///
    /// `startingFrameIndex` and `startingResetCounter` configure live-mode
    /// seeding. Defaults preserve preview behavior:
    ///  • `startingFrameIndex: 0` → `lastFrameIndex = -1`, animate walks
    ///    from 0 forward and fires onset ripples normally.
    ///  • In macOS live system-audio mode, callers pass
    ///    `appModel.frames.count` so `lastFrameIndex = count - 1` and the
    ///    first animate tick skips backwards-replay of pre-open frames.
    ///    Avoids a "200 ripples spawn at once" burst when the user has had
    ///    system audio on for a minute before opening the visualizer.
    static func makeRings(
        from frames: [FeatureFrame],
        startingFrameIndex: Int = 0,
        startingResetCounter: Int = 0
    ) async -> Entity {
        let root = Entity()
        // Place the ring plane in front of the viewer at eye height. The
        // immersive (visionOS) path sees this at world position; the windowed
        // path sees it at cluster-local position (the implicit virtual camera
        // at origin looks down -Z, so a positive offset behind here is
        // correct).
        root.position = [0, 1.3, -2.5]
        // Tilt the ring plane ~12° downward so the rings present some depth
        // instead of reading as a flat disc. Matches HTML's camera at
        // (0, 1.5, 18) looking slightly down at a roughly-flat ring system.
        root.orientation = simd_quatf(angle: -0.20, axis: [1, 0, 0])

        let glow = makeGlowTexture()
        let quadMesh = makeQuadMesh(size: spriteSize)

        for k in 0..<ringCount {
            let baseR = baseRadiusStart + Float(k) * baseRadiusStep

            // Per-ring material — UnlitMaterial with the glow texture and a
            // white tint initially. Updated per frame in animate() with the
            // current HSB tint reflecting hue / saturation / brightness*intensity.
            var material = UnlitMaterial()
            material.color = .init(
                tint: PlatformColor(white: 1.0, alpha: 1.0),
                texture: .init(glow)
            )
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            // No depth-write — same trick CloudVisualizer uses on its
            // overlapping alpha sprites to avoid quad-edge occlusion. HTML's
            // `depthWrite: false` on the rings' PointsMaterial does the same.
            material.writesDepth = false

            let ringEnt = ModelEntity(mesh: quadMesh, materials: [material])
            ringEnt.components.set(RingComponent(index: k, baseR: baseR))

            // Set up the 200 instances for this ring's particles.
            var instancesComp = MeshInstancesComponent()
            do {
                let data = try LowLevelInstanceData(instanceCount: perRing)
                data.withMutableTransforms { transforms in
                    for p in 0..<perRing {
                        let a = Float(p) / Float(perRing) * 2 * .pi
                        var t = Transform()
                        t.translation = SIMD3<Float>(cos(a) * baseR, sin(a) * baseR, 0)
                        transforms[p] = t.matrix
                    }
                }
                instancesComp[partIndex: 0] = .init(data: data)
            } catch {
                // If instance-data allocation fails we end up with the bare
                // mesh entity, which renders as a single quad at the ring's
                // origin — visually degraded but won't crash. Log so it's
                // diagnosable.
                print("RingsVisualizer: LowLevelInstanceData init failed: \(error)")
            }
            ringEnt.components.set(instancesComp)

            root.addChild(ringEnt)
        }

        var rootState = RingsRootComponent()
        // lastFrameIndex = "last frame index already scanned for onsets."
        // Default startingFrameIndex=0 → lastFrameIndex=-1 → preview walks
        // all frames. Live caller passes frames.count → lastFrameIndex=count-1
        // → live first-tick only walks NEW frames.
        rootState.lastFrameIndex = startingFrameIndex - 1
        rootState.lastSeenResetCounter = startingResetCounter
        root.components.set(rootState)
        return root
    }

    // MARK: - Animate (per-frame)

    static func animate(
        _ rings: Entity,
        clock: Double,
        frames: [FeatureFrame],
        deltaTime: Double,
        appResetCounter: Int = -1
    ) {
        guard !frames.isEmpty,
              var rootState = rings.components[RingsRootComponent.self]
        else { return }

        // Track-change reset (live mode only). AppModel bumps the counter
        // when Shazam detects a new song; we clear per-song ripple +
        // frame-index state and re-init hue smoothing so the new song's
        // first hue lerps from itself instead of from the prior song's
        // last hue (would cause a visible color slide through unrelated
        // hues for ~1s after every track change).
        //
        // Smoothed loudness / timbre intentionally NOT reset — they
        // converge naturally and resetting to 0 makes the rings look
        // momentarily dim at the moment of track change.
        //
        // appResetCounter < 0 means "caller didn't pass it" (preview-only),
        // skip the check.
        if appResetCounter >= 0 && appResetCounter != rootState.lastSeenResetCounter {
            rootState.lastFrameIndex = max(-1, frames.count - 1)
            rootState.ripples.removeAll()
            rootState.hueSmoothedInitialized = false
            rootState.lastSeenResetCounter = appResetCounter
        }

        let t = max(0, clock)
        // 30 fps frame grid — same as CloudVisualizer.
        let i = max(0, min(frames.count - 1, Int((t * 30).rounded())))
        let f = frames[i]
        // Smooth loudness + timbre toward the raw values at ~4 Hz so
        // transients don't lurch the rotation/breath/color. (Raw f.loudness
        // is what makes the cluster jerk on every kick drum hit.) The
        // smoothed copies live on the root component so they persist
        // across animate ticks.
        let smoothRate: Float = 4
        let lerp = Float(min(1.0, deltaTime * Double(smoothRate)))
        rootState.eLoudSmoothed   += (Float(f.loudness)          - rootState.eLoudSmoothed)   * lerp
        rootState.eTimbreSmoothed += (Float(f.color.saturation)  - rootState.eTimbreSmoothed) * lerp

        // Hue smoothing — CIRCULAR lerp because hue wraps at 1.0. A burst
        // capture during testing showed the raw chromagram hue jumping
        // by 0.2–0.3 between adjacent frames (blue → purple → red → blue)
        // when chord-rich songs play; that reads as harsh color strobing.
        // We take the shorter way around the wheel: if the diff exceeds
        // 0.5, wrap it (going forward 0.7 means going backward 0.3 is
        // shorter, etc.) so the lerp travels the correct arc.
        let targetHue = Float(f.color.hue)
        if !rootState.hueSmoothedInitialized {
            rootState.hueSmoothed = targetHue
            rootState.hueSmoothedInitialized = true
        } else {
            var diff = targetHue - rootState.hueSmoothed
            if diff > 0.5 { diff -= 1.0 }
            else if diff < -0.5 { diff += 1.0 }
            // Slower lerp on hue than loudness — color changes feel
            // intrusive even at 4 Hz, where loudness reactivity at 4 Hz
            // feels appropriately responsive. 2 Hz keeps color drift
            // visible and music-driven without strobing.
            let hueLerp = Float(min(1.0, deltaTime * 2))
            var next = rootState.hueSmoothed + diff * hueLerp
            if next < 0 { next += 1 }
            if next >= 1 { next -= 1 }
            rootState.hueSmoothed = next
        }

        let eLoud    = Double(rootState.eLoudSmoothed)
        let eComplex = Double(f.harmonicComplexity)
        let eTimbre  = Double(rootState.eTimbreSmoothed)
        let hue      = CGFloat(rootState.hueSmoothed)

        // Detect new onsets since last scan. Each new onset pushes a ripple.
        if rootState.lastFrameIndex < i {
            let start = max(0, rootState.lastFrameIndex + 1)
            for k in start...i where frames[k].onset {
                rootState.ripples.append(t)
            }
        }
        rootState.lastFrameIndex = i
        // Prune ripples older than 1.6s (the HTML lifetime).
        rootState.ripples.removeAll { t - $0 >= 1.6 }

        // HTML-faithful audio-driven globals.
        let sat   = Float(min(1.0, 0.32 + eLoud * 2.2))
        let baseV = Float(min(1.0, 0.45 + eTimbre * 1.4))
        let activeRings = 4 + Int((eComplex * Double(ringCount - 4)).rounded())
        // Breath = energy-driven gentle scale modulation (HTML uses *0.04).
        let breath: Float = 1.0 + Float(eLoud) * 0.04
        rings.scale = SIMD3<Float>(repeating: breath)

        // Capture base transform lazily on first animate() call —
        // whatever the host set up (VisualizerView's tilt + Z, or
        // ImmersiveView's defaults). NaN sentinels mark "not captured yet."
        if rootState.baseOrientation.imag.x.isNaN {
            rootState.baseOrientation = rings.orientation
        }
        if rootState.baseZ.isNaN {
            rootState.baseZ = rings.position.z
        }

        // Camera-feel animation. HTML's OrbitControls
        // `autoRotate = true, autoRotateSpeed = 0.35` circles the CAMERA
        // around the scene; rotating our CLUSTER on its local Y caused
        // 90°-edge-on invisibility, so instead:
        //   • orientation drifts in a bounded oscillation (±0.70 rad yaw,
        //     ±0.20 rad pitch) → rings always stay visible
        //   • Z position dollies through a 2.4m range → camera appears to
        //     fly toward the rings, push through, pull back ("moves toward
        //     and through them" feel Jesse described in HTML)
        //
        // Phase rate + amplitudes tuned (2026-05-21) after a burst-frame
        // capture revealed the cluster swinging through ~40° of yaw in
        // ~2 seconds and the dolly Z pumping noticeably. Both contributed
        // to a "frenetic / jerky" feel. Reductions:
        //   • phase rate 0.55 → 0.30 rad/s (yaw period ~21s, dolly ~42s)
        //   • yaw amplitude 0.70 → 0.40 rad (~23°, was ~40°)
        //   • pitch amplitude 0.20 → 0.12 rad (~7°, was ~11°)
        //   • dolly amplitude 1.2 → 0.6 m
        // Net effect: smooth, contemplative camera drift instead of an
        // amusement-park swing. The HTML reference originally had no
        // explicit camera autorotate at all on this mode; the visible
        // motion came purely from the orbit controls being released.
        rootState.animPhase += Float(deltaTime) * 0.30
        let phase = rootState.animPhase
        let yaw    = sin(phase) * 0.40
        let pitch  = sin(phase * 0.7 + 1.3) * 0.12
        let dollyZ = sin(phase * 0.5) * 0.6
        let yawQ   = simd_quatf(angle: yaw,   axis: [0, 1, 0])
        let pitchQ = simd_quatf(angle: pitch, axis: [1, 0, 0])
        rings.orientation = rootState.baseOrientation * yawQ * pitchQ
        rings.position.z  = rootState.baseZ + dollyZ

        for child in rings.children {
            guard var rc = child.components[RingComponent.self],
                  let ringEnt = child as? ModelEntity,
                  // LowLevelInstanceData is a reference type — modifying via
                  // replaceMutableTransforms below mutates the buffer in
                  // place, so we don't need to reassign the component.
                  let instancesComp = ringEnt.components[MeshInstancesComponent.self]
            else { continue }

            let k = rc.index
            // Smooth intensity toward target (active or not). HTML uses dt*3.
            let target: Float = k < activeRings ? 1.0 : 0.0
            rc.intensity += (target - rc.intensity) * Float(min(1.0, deltaTime * 3))
            // Rotation: alternating direction; outer rings spin slightly faster.
            let dir: Float = (k % 2 == 0) ? 1 : -1
            rc.rotation += Float(deltaTime) * dir
                * Float(0.15 + eLoud * 1.4) * (0.5 + Float(k) * 0.05)

            // Material color — one update per ring per frame (16 total),
            // not 3200. Brightness baked into the tint via HSB; opacity stays
            // 1.0 because the texture's alpha provides the soft falloff and
            // ring intensity * baseV is folded into brightness here.
            let v = baseV * rc.intensity
            let color = PlatformColor(
                hue: hue,
                saturation: CGFloat(sat),
                brightness: CGFloat(max(0, min(1, v))),
                alpha: 1.0
            )
            if var modelComp = ringEnt.components[ModelComponent.self],
               var mat = modelComp.materials.first as? UnlitMaterial {
                mat.color = .init(tint: color, texture: mat.color.texture)
                modelComp.materials[0] = mat
                ringEnt.components.set(modelComp)
            }

            // Ripple contribution to the effective radius. HTML formula:
            //   d = (baseR - age*12) / 2.2
            //   ripple += 1.1 * exp(-d*d) * (1 - age/1.6)
            // The wavefront travels outward at speed 12 in the cluster's
            // units. We use Float math throughout for the per-instance loop.
            //
            // **Attack envelope (added 2026-05-21):** the HTML formula has
            // no fade-in — at age=0, the wavefront sits at radius 0, very
            // close to the inner rings' baseR. So d ≈ baseR/2.2 (small),
            // exp(-d²) ≈ 1, and the inner ring's ripple contribution
            // SNAPS to its full amplitude on the onset frame, then decays.
            // Visually the center ring jumps to a larger aperture instead
            // of growing/contracting. A 120ms linear attack on the envelope
            // ramps the ripple in smoothly for the center ring without
            // meaningfully delaying the outer rings (their wavefront-pass
            // happens at age = baseR/12, which is well past the attack
            // window for any ring whose baseR > ~1.5 units).
            var ripple: Float = 0
            let attack: Float = 0.12
            for born in rootState.ripples {
                let age = Float(t - born)
                let d = (rc.baseR - age * 12) / 2.2
                let attackEnv: Float = age < attack ? age / attack : 1.0
                let decayEnv: Float = max(0, 1 - age / 1.6)
                ripple += 1.1 * exp(-d * d) * attackEnv * decayEnv
            }
            let r = rc.baseR + ripple

            // Update the 200 particle transforms via the instance buffer.
            // replaceMutableTransforms (not withMutable) avoids CPU/GPU sync
            // stalls — the runtime rotates internal buffers per the API
            // contract documented in the Apple Developer forums thread on
            // LowLevelInstanceData animation.
            if let part = instancesComp[partIndex: 0] {
                part.data.replaceMutableTransforms { transforms in
                    for p in 0..<perRing {
                        let a = Float(p) / Float(perRing) * 2 * .pi + rc.rotation
                        let x = cos(a) * r
                        let y = sin(a) * r
                        // Z wobble: HTML uses sin(a*2 + rot)*0.7. The earlier
                        // 0.18 damping made the rings look flat — HTML's
                        // version reads as visibly warped/undulating
                        // saddle shapes that swim as the ring rotates.
                        // Restored to 0.5 — slightly less than HTML's 0.7
                        // because our camera is proportionally closer so
                        // the angular amplitude of the wobble is already
                        // larger per unit world Z.
                        let z = sin(a * 2 + rc.rotation) * 0.5
                        var tr = Transform()
                        tr.translation = SIMD3<Float>(x, y, z)
                        transforms[p] = tr.matrix
                    }
                }
            }

            ringEnt.components.set(rc)
        }

        rings.components.set(rootState)
    }

    // MARK: - Sprite quad mesh (XY plane, facing +Z)

    /// Build a unit-ish quad in the XY plane facing +Z. `MeshResource.generatePlane`
    /// would give us a plane in the XZ plane facing +Y — wrong orientation for
    /// our viewer-down-Z framing. Hand-rolling a quad is 4 verts + 2 tris.
    private static func makeQuadMesh(size: Float) -> MeshResource {
        let h = size / 2
        let positions: [SIMD3<Float>] = [
            [-h, -h, 0], [ h, -h, 0], [ h,  h, 0], [-h,  h, 0]
        ]
        let normals: [SIMD3<Float>] = Array(repeating: [0, 0, 1], count: 4)
        // V-flipped texture coordinates so the glow texture isn't upside-down
        // — Core Graphics writes images with the Y axis pointing down, while
        // RealityKit samples textures with Y pointing up.
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
            // Fallback to RealityKit's built-in plane if descriptor build fails
            // for some reason. Orientation will be off (XZ plane) but at
            // least something renders.
            return .generatePlane(width: size, height: size)
        }
    }

    // MARK: - Glow texture (radial alpha gradient)

    /// 128² alpha-gradient texture, white centre fading to transparent at the
    /// rim. Same pattern Clouds uses for its sprites. Drawn once, shared
    /// across all 16 rings' materials.
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
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.50),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 0.40, 1.0]
        )!
        ctx.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: radius,
            options: []
        )

        return try! TextureResource(
            image: ctx.makeImage()!,
            withName: "rings-glow",
            options: .init(semantic: .color)
        )
    }
}
