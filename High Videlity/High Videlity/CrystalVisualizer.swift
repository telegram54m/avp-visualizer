//
//  CrystalVisualizer.swift
//  High Videlity
//
//  Builds the Crystal visualization as RealityKit geometry.
//  Increment 1: a static field of shard cones radiating from a center point —
//  no audio, animation, or beams yet. Those layer in next.
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

/// Per-shard data the animation loop reads each frame.
struct ShardComponent: Component {
    var onsetTime: Double
    var direction: SIMD3<Float>
    var length: Float
    var wobbleFreq: Double
    var wobblePhase: Double
}

/// Tags each child of a v2 shardGroup so `animate` can pick the right HTML
/// opacity curve. v1's nested halo stacks don't carry this — v1 falls
/// through the opacity-update path harmlessly.
struct BeamRole: Component {
    enum Kind { case shard, halo, core }
    var kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

enum CrystalVisualizer {

    /// Shard count for the synthetic placeholder structure.
    private static let shardCount = 80

    /// Builds the crystal from a real analyzed song — one shard per onset.
    /// Direction comes from each onset's pitch-class hue (azimuth) and its
    /// index (an even spread over the sphere); length comes from loudness.
    static func makeCrystal(from frames: [FeatureFrame]) async -> Entity {
        let onsets = frames.filter { $0.onset }
        guard !onsets.isEmpty else { return makeCrystal() }   // fall back to synthetic

        // One shared additive-blend program: beams add their light to the dark
        // and stack toward white-hot where they overlap — the HTML's diffusion.
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        let additiveProgram = await UnlitMaterial.Program(descriptor: descriptor)

        let root = Entity()
        root.position = [0, 1.3, -1.5]
        let n = onsets.count

        for (i, frame) in onsets.enumerated() {
            // Pitch class drives azimuth — matches the HTML reference exactly.
            // Tonally consistent songs cluster into a fan; varied songs fill
            // the sphere. The fan IS the faithful behavior.
            let azimuth = frame.color.hue * 2 * .pi
            let elevation = asin(1 - 2 * (Double(i) / Double(n)))   // even, pole to pole
            let ce = cos(elevation)
            let dir = SIMD3<Float>(
                Float(ce * cos(azimuth)),
                Float(sin(elevation)),
                Float(ce * sin(azimuth))
            )

            let length = 0.14 + frame.loudness * 0.42              // loudness → length (m)
            let baseRadius = 0.01 + length * 0.05
            let mesh = MeshResource.generateCone(height: length, radius: baseRadius)

            let saturation = min(1.0, 0.5 + Double(frame.loudness) * 1.6)
            let brightness = min(1.0, 0.6 + frame.color.saturation * 1.2)
            // HDR-boosted so the additive shard cones read as glowing
            // wedges instead of flat dim slivers on the non-bloom-having
            // macOS / iOS / tvOS pathway. On visionOS the same boost just
            // pumps the OLED display past SDR for natural optical bloom.
            let color = PlatformColor.hdrColor(
                hue: CGFloat(frame.color.hue),
                saturation: CGFloat(saturation),
                brightness: CGFloat(brightness),
                hdrBoost: 1.8
            )
            // Additive, like the beams — the cone glows and merges into the
            // light instead of reading as a hard opaque spike.
            var material = UnlitMaterial(program: additiveProgram)
            material.color = .init(tint: color)
            let shard = ModelEntity(mesh: mesh, materials: [material])

            shard.orientation = simd_quatf(from: [0, 1, 0], to: dir)
            shard.position = dir * (length / 2)
            shard.scale = .zero                                    // hidden until its onset
            shard.components.set(ShardComponent(
                onsetTime: frame.time,
                direction: dir,
                length: length,
                wobbleFreq: 0.6 + Double(i % 13) * 0.11,            // each shard its own rate
                wobblePhase: Double(i) / Double(n) * 2 * .pi
            ))

            // Laser beam from the shard's tip: a bright thin white-hot core
            // inside graded additive halos. All beam layers live under one
            // beamGroup entity, so the loop can flare the whole beam with a
            // single OpacityComponent rather than touching every material.
            let beamLength = 0.6 + frame.loudness * 0.9
            let beamBase = length / 2                          // where the beam starts
            let beamY = beamBase + beamLength / 2              // core's center
            let hue = CGFloat(frame.color.hue)
            let beamGroup = Entity()

            let coreMesh = MeshResource.generateCylinder(
                height: beamLength,
                radius: 0.012 + frame.loudness * 0.010         // bright filament — visible white-hot core
            )
            var coreMaterial = UnlitMaterial(program: additiveProgram)
            // The brightest part of every beam — white-hot filament. Big
            // HDR boost so it dominates the additive stack and reads as a
            // pure-white line through the centre of each colored halo.
            coreMaterial.color = .init(tint: PlatformColor.hdrColor(
                hue: hue, saturation: 0.3, brightness: 1.0, hdrBoost: 3.5))
            let core = ModelEntity(mesh: coreMesh, materials: [coreMaterial])
            core.position = [0, beamY, 0]
            beamGroup.addChild(core)

            // Graded halo layers — concentric additive cylinders, each wider,
            // dimmer, and longer than the core. The stacked additive falloff
            // reads as soft diffusion both around the beam and past its tip.
            let haloGrades: [(base: Float, loud: Float, brightness: CGFloat, extend: Float)] = [
                (0.020, 0.015, 0.70, 0.07),
                (0.035, 0.020, 0.45, 0.18),
                (0.055, 0.025, 0.25, 0.38),
            ]
            for grade in haloGrades {
                let haloLen = beamLength + grade.extend        // extends past the tip
                let haloMesh = MeshResource.generateCylinder(
                    height: haloLen,
                    radius: grade.base + frame.loudness * grade.loud
                )
                var haloMaterial = UnlitMaterial(program: additiveProgram)
                // Coloured halo layers — moderate HDR boost so they glow
                // visibly around the core without overpowering it.
                haloMaterial.color = .init(tint: PlatformColor.hdrColor(
                    hue: hue, saturation: 1.0, brightness: grade.brightness, hdrBoost: 2.2))
                let halo = ModelEntity(mesh: haloMesh, materials: [haloMaterial])
                halo.position = [0, beamBase + haloLen / 2, 0] // base-aligned with the core
                beamGroup.addChild(halo)
            }

            shard.addChild(beamGroup)
            root.addChild(shard)
        }
        return root
    }

    /// Per-frame animation: each shard pops in when the clock passes its
    /// onset, then "breathes" — stretching along its length with the music.
    ///
    /// `useHeadLockedCamera` switches between the visionOS pathway (cluster
    /// carries an inverse-camera transform so a viewer at (0,1.5,0) sees the
    /// HTML camera's orbital frame) and the windowed pathway (cluster stays
    /// at the position its parent put it, real RealityKit camera looks at
    /// it). The shard pop-in / breathing math is identical either way.
    static func animate(_ crystal: Entity, clock: Double, energy: Float, deltaTime: Double,
                        camPos: inout SIMD3<Float>, camLook: inout SIMD3<Float>,
                        useHeadLockedCamera: Bool = true,
                        eye: SIMD3<Float> = SIMD3<Float>(0, 1.5, 0)) {
        var nextDir: SIMD3<Float>?
        var nextLen: Float = 0.3
        var nextOnset = Double.infinity

        // Live-mode fallback: track the most-recently-spawned shard. In
        // live mode every shard's `onsetTime` is <= `clock` at the moment
        // it spawns (entities appear AS frames arrive), so the
        // "anticipate the next future shard" logic never finds a target
        // and the camera freezes. Using the latest-spawned as a fallback
        // turns the camera into "swing to wherever the music just sent
        // us" — every new onset arcs the camera toward the new shard's
        // direction, giving live mode visible motion.
        //
        // In preview mode this also activates AFTER the last onset (when
        // playbackTime exceeds every shard's onsetTime), which is a small
        // improvement — camera no longer freezes on the final shard's
        // anticipated direction.
        var latestDir: SIMD3<Float>?
        var latestLen: Float = 0.3
        var latestOnset = -Double.infinity

        for shard in crystal.children {
            guard let info = shard.components[ShardComponent.self] else { continue }

            // Track the next shard still to appear — the camera anticipates it.
            if info.onsetTime > clock && info.onsetTime < nextOnset {
                nextOnset = info.onsetTime
                nextDir = info.direction
                nextLen = info.length
            }
            // Track the most-recently-spawned shard for the live-mode
            // fallback target.
            if info.onsetTime > latestOnset {
                latestOnset = info.onsetTime
                latestDir = info.direction
                latestLen = info.length
            }

            let age = clock - info.onsetTime
            if age < 0 {
                shard.scale = .zero
                continue
            }
            // Pop-in: quick overshoot, then settle.
            let pop: Float
            if age < 0.20 {
                pop = Float(age / 0.20) * 1.25
            } else if age < 0.40 {
                pop = 1.25 - Float((age - 0.20) / 0.20) * 0.25
            } else {
                pop = 1.0
            }
            // Breathing: a per-shard wobble plus the song's current energy,
            // applied along local Y — the shard's length axis.
            let wobble = Float(sin(clock * info.wobbleFreq + info.wobblePhase))
            let breath = 1.0 + wobble * 0.05 + energy * 0.20
            shard.scale = [pop, pop * breath, pop]

            // HTML opacity curves — applied per child via OpacityComponent so
            // each role gets its own α curve without sharing the parent's
            // multiplier. v1 shards have no BeamRole children, so this loop
            // is a harmless no-op for them.
            //
            // CORE OPACITY IS DELIBERATELY DECOUPLED FROM `flick`. HTML's
            // beam formula `(0.25 + l*0.75) * flick` applies the per-shard
            // sin-wobble to both core and halo. With each shard's
            // `wobblePhase` offset, cores fade independently — perceptually
            // fine in HTML where the alpha-to-pixel mapping is linear, but
            // under our HDR core (2.5× boost) + CIBloom the same low-flick
            // value puts the core below the bloom's bright-pixel threshold
            // and the rod momentarily disappears. The visible result was
            // "at any moment only a few beams show their white-hot rod,
            // and which ones changes frame to frame" — reads as strobing
            // rather than shimmer. Cores now use a flicker-free curve so
            // every beam has a persistent rod; halos keep the HTML flicker
            // so the colored envelope still pulses with the music.
            let fadeIn = Float(min(1.0, age / 0.15))
            // Shard alpha floor 0.72 → 0.85 (HTML-fidelity pass, session 10).
            // HTML's exact formula was `0.72 + energy*0.28` (range 0.72-1.0
            // modulated by fadeIn). After dropping halo alpha and bloom
            // intensity, the shard cones became readable as translucent
            // geometry in the midground — but during low-energy passages
            // they faded back near the 0.72 floor and the hub structure
            // lost some prominence. Bumping the floor to 0.85 (range
            // 0.85-1.0) keeps the cones consistently visible through the
            // whole song so HTML's "translucent prismatic mass with bright
            // cores" character holds during quiet moments too.
            let shardAlpha = fadeIn * (0.85 + energy * 0.15)
            // Restored to HTML's original `0.75 + 0.25*sin(...)` (range
            // 0.5-1.0, a 2× swing) from our previously dampened
            // `0.85 + 0.15*sin(...)` (range 0.7-1.0, a 1.4× swing). The
            // dampening was added back when we thought low-flick values
            // were causing the strobing — turned out to be Z-fighting,
            // fixed long ago with `writesDepth = false`. HTML's wider
            // swing gives the "starry pulsey shimmer" quality that the
            // narrower version lost. Each shard's per-shard `wobbleFreq`
            // and `wobblePhase` keep beams shimmering out of phase with
            // each other, like individual stars twinkling independently.
            let flick = Float(0.75 + 0.25 * sin(clock * info.wobbleFreq * 3 + info.wobblePhase))
            // Halo gets HTML's full opacity curve including flick — its
            // colored envelope pulses with the music. Multiplier dropped
            // 0.45 → 0.25 (HTML-fidelity pass, session 10) — side-by-side
            // at Clair de Lune showed HTML halos are whisper-thin (barely
            // visible colored envelopes around bright cores) while AVP
            // halos at 0.45 read as saturated colored tubes, drowning out
            // the translucent shard cones that give HTML its dimensional
            // character. At 0.25 halos retreat to a subtle colored haze
            // and the alpha-blended shards re-emerge as visible geometry.
            let haloAlpha = fadeIn * (0.25 + energy * 0.75) * flick * 0.25
            // Core flick restored (2026-05-20, later session). Previously
            // decoupled to fight strobing: at the original HDR boost 2.5×
            // and bloom radius 10, low `flick` values dropped cores below
            // CIBloom's bright-pixel threshold so the white-hot rods
            // popped in and out at the wobble frequency. Since then,
            // HDR boost is 1.5× and bloom radius 14, and the halo
            // brightness floor (0.85) provides visual continuity even
            // when a core dims a little. Restoring the full HTML formula
            // gives beams the "shimmer" / non-static laser quality that
            // was missing without it. If strobing reappears, narrow the
            // `flick` swing (e.g. 0.85 + 0.15*sin) instead of dropping
            // it entirely.
            let coreAlpha = fadeIn * (0.25 + energy * 0.75) * flick
            for child in shard.children {
                guard let role = child.components[BeamRole.self] else { continue }
                let opacity: Float
                switch role.kind {
                case .shard: opacity = shardAlpha
                case .halo:  opacity = haloAlpha
                case .core:  opacity = coreAlpha
                }
                child.components.set(OpacityComponent(opacity: opacity))
            }
        }

        // Reproduce the HTML camera frame-for-frame. The HTML orbits a moving
        // camera around a fixed structure. We always update the eased camera
        // state (camPos / camLook) here — both pathways read from the same
        // source of truth. Only the application differs:
        //   • visionOS / head-locked: the viewer can't move, so the crystal
        //     carries the INVERSE of the camera transform → a fixed observer
        //     at (0,1.5,0) sees what the HTML camera would.
        //   • windowed / non-head-locked: VisualizerView applies camPos /
        //     camLook to a real RealityKit PerspectiveCamera, leaving the
        //     cluster's parent-supplied transform alone — same camera
        //     dynamics, just driving a real camera around a static cluster.
        // Prefer the "next future shard" (preview-mode anticipation) when
        // available; fall back to the latest-spawned shard (live mode).
        let targetDir = nextDir ?? latestDir
        let targetLen = nextDir != nil ? nextLen : latestLen
        if let targetDir {
            let nextLen = targetLen     // keep the local name the body below uses
            let d = simd_normalize(targetDir)

            // HTML camera goal: look at the next shard's tip, sit just outside
            // the structure on the shard's side at a 3/4 angle.
            let camLookGoal = d * nextLen
            var side = SIMD3<Float>(-d.z, 0, d.x)              // shard × world-up
            let sl = simd_length(side)
            side = sl > 1e-4 ? side / sl : SIMD3<Float>(1, 0, 0)
            // FLY-THROUGH GEOMETRY. Previous values (0.12 + nextLen*0.06,
            // max ~0.17) put the camera permanently INSIDE the shard shell
            // — the lerp on retarget happened over a tiny world chord and
            // there was no perceptible transit through the cluster. This
            // value pushes the camera out to OUTSIDE the shard shell
            // (~1.8-2.4 from origin vs new shard tips at ~1.2 max) but
            // deep inside the beam shell (beam tips ~7.7 max). On
            // retarget, camera arcs across up to ~5 world units passing
            // near origin — beams sweep past the camera, producing HTML's
            // "fly-through" feel. Cluster scaled up to compensate for the
            // farther camera so it still fills viewport.
            //
            // HTML uses dist = 8.5 + len*0.4 in its world units; ratio
            // camera/shard_tip ≈ 1.3. We're now at a similar 1.5-2× ratio.
            let dist = 1.3 + nextLen * 0.35
            // Up-shift reduced 0.3 → 0.15. After the scale-up the previous
            // 0.3 was making the cluster sit too high in the viewport —
            // camera looked down at the convergence from a steep angle.
            // Halving keeps a hint of "looking-slightly-down at the
            // crystal" character without dragging the framing off-centre.
            let camDir = simd_normalize(d * 0.6 + side + SIMD3<Float>(0, 0.15, 0))
            let camPosGoal = camDir * dist

            let ease = min(1, Float(deltaTime) * 1.3)         // HTML's exact easing
            camPos  += (camPosGoal  - camPos)  * ease
            camLook += (camLookGoal - camLook) * ease
        }

        if useHeadLockedCamera {
            // Build the HTML camera's world transform, then invert it onto
            // the cluster so a viewer fixed at (0,1.5,0) gets the HTML view.
            let zc = simd_normalize(camPos - camLook)
            let xc = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), zc))
            let yc = simd_cross(zc, xc)
            let camMatrix = float4x4(
                SIMD4<Float>(xc, 0),
                SIMD4<Float>(yc, 0),
                SIMD4<Float>(zc, 0),
                SIMD4<Float>(camPos, 1)
            )
            var eyeMatrix = matrix_identity_float4x4
            eyeMatrix.columns.3 = SIMD4<Float>(eye.x, eye.y, eye.z, 1)
            crystal.transform = Transform(matrix: eyeMatrix * camMatrix.inverse)
        }
    }

    /// Builds the crystal root entity, positioned in front of the viewer.
    static func makeCrystal() -> Entity {
        let root = Entity()
        root.position = [0, 1.3, -1.5]   // ~1.3 m up, 1.5 m in front of the user

        for i in 0..<shardCount {
            // Fibonacci sphere — evenly distributed directions over the sphere.
            let t = Double(i) / Double(shardCount)
            let elevation = asin(2 * t - 1)            // -90°...+90°
            let azimuth = Double(i) * 2.399963229728   // golden angle
            let ce = cos(elevation)
            let dir = SIMD3<Float>(
                Float(ce * cos(azimuth)),
                Float(sin(elevation)),
                Float(ce * sin(azimuth))
            )

            // Shard size in meters — varied so it reads as a crystal, not a ball.
            let length = Float(0.18 + 0.30 * abs(sin(Double(i) * 1.7)))
            let baseRadius = 0.012 + length * 0.05

            let mesh = MeshResource.generateCone(height: length, radius: baseRadius)

            // Hue cycles around the structure — stand-in for pitch class.
            let hue = CGFloat((azimuth / (2 * .pi)).truncatingRemainder(dividingBy: 1))
            let color = PlatformColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
            let shard = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])

            // generateCone is centered on the origin with its axis along +Y.
            // Rotate +Y onto the shard's direction, then push it out so the
            // cone's base sits at the structure's center.
            shard.orientation = simd_quatf(from: [0, 1, 0], to: dir)
            shard.position = dir * (length / 2)

            root.addChild(shard)
        }
        return root
    }
}
