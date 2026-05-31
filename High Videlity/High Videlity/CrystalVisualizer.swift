//
//  CrystalVisualizer.swift
//  High Videlity
//
//  Shared infrastructure for the Crystal visualization. The V1
//  builder (stacked cone shards) was retired with the Visualizers-
//  page rebuild — [[CrystalVisualizerV2]] is the only Crystal
//  implementation now. What's left here is the shared bits V2
//  depends on:
//
//    • `ShardComponent` — per-shard data the animate loop reads
//    • `BeamRole` — tags V2's shard / halo / core sub-entities so
//      `animate` picks the right opacity curve per layer
//    • `CrystalVisualizer.animate(...)` — per-frame transform +
//      pop-in + breathing + camera inverse, called by both the
//      windowed RealityView and the visionOS ImmersiveView paths
//
//  This file used to also host `makeCrystal(from:)` and
//  `makeCrystal()` (the V1 builders). Those are gone; V2 owns
//  scene construction now.
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
    /// Live-mode recycle pool: slots are pre-allocated at scene build and
    /// reused in place (no add/removeFromParent — see CrystalVisualizerV2
    /// `makeCrystalLive`). An unconfigured or track-change-deactivated slot
    /// carries `active = false`; `animate` skips it entirely so it neither
    /// renders nor pollutes camera targeting. Defaults to `true` so the
    /// preview path (`makeCrystal`, every shardGroup real) is unaffected.
    var active: Bool = true
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

            // Live-mode recycle pool: skip inactive slots (pre-allocated but
            // not yet configured, or deactivated on track change). Keep them
            // hidden and exclude them from camera-target tracking below so a
            // placeholder direction never captures the camera.
            if !info.active {
                shard.scale = .zero
                continue
            }

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

}
