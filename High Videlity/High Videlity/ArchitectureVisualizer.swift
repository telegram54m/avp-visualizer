//
//  ArchitectureVisualizer.swift
//  High Videlity
//
//  Architecture mode — the fourth HTML reference mode, ported to RealityKit
//  with a deliberate aesthetic lift: where HTML uses unlit `MeshBasicMaterial`
//  (flat colored shapes), we use `PhysicallyBasedMaterial` with metallic /
//  roughness + emissive HDR. The result reads as glowing colored sculpture
//  made of polished torus rings, lit by a couple of directional lights,
//  rather than HTML's flat 2D-painted feel.
//
//  This is the mode where RealityKit has the upper hand vs the HTML reference.
//
//  Each onset bakes one torus ring placed in 3D by its musical properties:
//    • pitch class (hue)          → azimuth around the central Y axis
//    • loudness                   → radial distance from the axis + ring
//                                   radius + tube thickness
//    • onset index over song      → height (Y position)
//    • harmonic complexity        → tilt off horizontal + segment count
//                                   (smoothness)
//    • pitch class                → lean direction (z-rotation)
//
//  The constellation rotates slowly around Y, speeding up with energy. Each
//  ring pops in over ~0.4s on its onset, then breathes / wobbles forever.
//  HTML's `architectureGroup.rotation.y` is mirrored on the root entity.
//
//  Implementation choices:
//   • Torus geometry built by hand via MeshDescriptor — RealityKit has no
//     built-in torus primitive. ~16 major × 8 minor segments per ring, with
//     a hc-driven major segment count (16→46 per HTML).
//   • PhysicallyBasedMaterial with HDR-boosted emissive: rings light up the
//     scene AND bloom interacts with them (HDR pixels drive CIBloom).
//   • Two directional lights (warm + cool) give the constellation cinematic
//     shape definition without making any single ring read as "shadowy."
//   • Opacity uses `OpacityComponent` per-ring (cheaper than rebuilding
//     materials each frame for the fade-in / energy pulse).
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

/// Per-ring animation state. Captured at make time, read every frame.
struct ArchRingComponent: Component {
    let onsetTime: Double
    let homeY: Float
    let wobbleFreq: Double
    let wobblePhase: Double
}

/// Cluster-level state for the architecture constellation.
struct ArchRootComponent: Component {
    /// Accumulated Y rotation (radians). Reset to 0 at make time, advances
    /// per frame at HTML's `0.08 + eLoud*0.35` rad/s rate.
    var groupRotation: Float = 0
    /// Lazy capture of the host-supplied base orientation so we don't
    /// stomp any tilt the host applied. NaN sentinel marks "not captured."
    var baseOrientation: simd_quatf = simd_quatf(ix: .nan, iy: 0, iz: 0, r: 1)
    /// Smoothed copy of incoming `energy`. The raw value (RealtimeOnset's
    /// EMA loudness × 2) reacts fast enough that loud transients spike it
    /// in a single frame — when that's multiplied by the per-ring sine
    /// wobble for vertical position (`wobble * energy * 1.1`) and scale
    /// (`1 + wobble*0.04 + energy*0.14`), the amplitude jumps mid-sine
    /// and the rings appear to jerk vertically. Lerping `energy` here
    /// at ~4 Hz keeps the energy reactivity but irons out the spikes.
    var smoothedEnergy: Float = 0
}

/// State carried on a live-mode Architecture root entity. Same pattern as
/// `CrystalVisualizerV2.CrystalLiveStateComponent` — lets the animate-tick
/// scan newly-arrived frames for onsets and spawn rings incrementally.
struct ArchLiveStateComponent: Component {
    /// Index into `appModel.frames` we've already scanned for onsets.
    var lastSeenFrameIndex: Int = 0
    /// Running count of rings spawned in live mode. Drives the
    /// golden-ratio height fraction sequence so any prefix is
    /// well-distributed across the heightSpan.
    var liveRingCount: Int = 0
    /// `appModel.liveModeResetCounter` value at the most-recent scan.
    /// When AppModel bumps it (Shazam track-change), `scanForNewOnsets`
    /// drops spawned rings + zeroes indices to start the constellation
    /// fresh for the new song.
    var lastSeenResetCounter: Int = 0
}

enum ArchitectureVisualizer {

    // MARK: - Scale constants

    /// HTML uses world units in roughly 1–6 range. After the first build
    /// landed at obviously-too-small (visible constellation but rings tiny
    /// relative to viewport), bumped all dimensions ~2×. The constellation
    /// is now meant to feel like a room-scale sculpture, not a tabletop
    /// model — leaning into the immersive AVP feel.
    static let radialBase: Float  = 0.90
    static let radialGain: Float  = 1.80     // total radial range 0.90–2.70
    static let heightSpan: Float  = 3.50     // total Y range; centered at 0
    static let heightMin:  Float  = -1.50
    static let ringRadiusBase: Float = 0.28
    static let ringRadiusGain: Float = 0.65  // ring radius 0.28–0.93
    static let tubeBase:   Float  = 0.030
    static let tubeGain:   Float  = 0.045    // tube radius 0.030–0.075

    // MARK: - Build

    static func makeArchitecture(from frames: [FeatureFrame]) async -> Entity {
        let root = Entity()
        // Place the constellation centered in front of the viewer at eye
        // height. VisualizerView (windowed) overrides Y to 0; visionOS
        // immersive keeps this 1.3 height.
        root.position = [0, 1.3, -3.0]
        root.components.set(ArchRootComponent())

        // No directional lights — we use UnlitMaterial which ignores them.
        // If we revisit PBR later, addLights() is still defined below.

        let onsets = frames.filter { $0.onset }
        guard !onsets.isEmpty else { return root }
        let n = onsets.count

        for (i, fr) in onsets.enumerated() {
            let heightFraction = Float(i) / Float(max(n - 1, 1))
            let ring = makeRing(
                frame: fr,
                heightFraction: heightFraction,
                indexForWobble: i
            )
            root.addChild(ring)
        }

        return root
    }

    /// Build an empty Architecture root with `ArchLiveStateComponent` for
    /// live additive spawning. Animate-tick caller calls `scanForNewOnsets`
    /// to grow the constellation as onsets arrive.
    ///
    /// `startingFrameIndex` seeds `lastSeenFrameIndex` so the first scan
    /// only walks frames that arrive AFTER this call — same reason as
    /// `CrystalVisualizerV2.makeCrystalLive`: stops the first scan from
    /// catching up on every preview-and-pre-open onset in one tick.
    static func makeArchitectureLive(startingFrameIndex: Int, startingResetCounter: Int) -> Entity {
        let root = Entity()
        root.position = [0, 1.3, -3.0]
        root.components.set(ArchRootComponent())
        var state = ArchLiveStateComponent()
        state.lastSeenFrameIndex = startingFrameIndex
        state.lastSeenResetCounter = startingResetCounter
        root.components.set(state)
        return root
    }

    /// Walk new frames since the last call and spawn one ring per
    /// `onset == true` frame. Heights are placed using a golden-ratio
    /// fraction sequence so the constellation fills out evenly as new
    /// rings arrive — every new ring lands in the largest existing gap,
    /// independent of total ring count.
    @MainActor
    static func scanForNewOnsets(_ root: Entity, frames: [FeatureFrame], appResetCounter: Int) {
        guard var state = root.components[ArchLiveStateComponent.self] else { return }

        // Track-change reset (Shazam bumped `liveModeResetCounter` on
        // AppModel). Drop every spawned ring and start fresh.
        //
        // Critical: seed `lastSeenFrameIndex` to the CURRENT `frames.count`,
        // not 0. Between the reset firing and this tick running, the
        // polling task has typically drained ~30 frames with multiple
        // onsets. Setting to 0 would scan all of those AT ONCE and spawn
        // 3–5 entities in a single render frame — the "frontloaded at
        // start of song" feel the user reported. Setting to the current
        // count means we wait for genuinely-new frames after the reset,
        // giving a gradual buildup that matches the song's onset rate.
        if state.lastSeenResetCounter != appResetCounter {
            for child in root.children {
                child.removeFromParent()
            }
            state.lastSeenFrameIndex = frames.count
            state.liveRingCount = 0
            state.lastSeenResetCounter = appResetCounter
        }

        let upper = frames.count
        guard upper > state.lastSeenFrameIndex else {
            root.components.set(state)
            return
        }
        for k in state.lastSeenFrameIndex..<upper {
            if frames[k].onset {
                // Golden-ratio height fraction: any prefix of the running
                // ring count spreads evenly across the heightSpan without
                // re-positioning existing rings.
                let phiInverse: Double = 0.6180339887498949
                let frac = (Double(state.liveRingCount) * phiInverse)
                    .truncatingRemainder(dividingBy: 1.0)
                let ring = makeRing(
                    frame: frames[k],
                    heightFraction: Float(frac),
                    indexForWobble: state.liveRingCount
                )
                root.addChild(ring)
                state.liveRingCount += 1

                // Recycle oldest ring once we exceed the cap — same
                // motivation as Crystal's: keep render perf stable
                // across long sessions. Rings are torus meshes with
                // many triangles each (16-46 major × 8 minor segments
                // × 2 tris/quad), so per-ring cost is higher than a
                // Crystal shard — a tighter cap is warranted.
                while root.children.count > liveModeRingCap {
                    root.children.first?.removeFromParent()
                }
            }
        }
        state.lastSeenFrameIndex = upper
        root.components.set(state)
    }

    /// Max rings visible at once in live mode. Past this point we recycle
    /// the oldest. Bumped 120 → 200 — at 120 the cap was hit too fast
    /// on dense songs and the user noticed rings appearing then evicting
    /// shortly after. 200 pushes the first eviction out to several
    /// minutes in for typical music. Each ring is a torus mesh with
    /// many triangles, so GPU cost scales faster than Crystal shards;
    /// keep the cap below Crystal's.
    static let liveModeRingCap: Int = 200

    /// Build one ring entity at its HTML-derived position and orientation.
    /// `heightFraction` is 0..1 — caller picks the distribution (i/n for
    /// preview, golden-ratio for live). `indexForWobble` is an arbitrary
    /// per-ring id for wobble freq/phase variation.
    private static func makeRing(frame fr: FeatureFrame, heightFraction: Float, indexForWobble i: Int) -> Entity {
        // Position: azimuth (hue) + radial (loudness) + height (caller-
        // supplied fraction — i/n in preview mode, golden-ratio in live).
        let azimuth = Float(fr.color.hue) * 2 * .pi
        let radial  = radialBase + Float(fr.loudness) * radialGain
        let homeX   = cos(azimuth) * radial
        let homeZ   = sin(azimuth) * radial
        let homeY   = heightMin + heightFraction * heightSpan

        // Ring dimensions.
        let majorRadius = ringRadiusBase + Float(fr.loudness) * ringRadiusGain
        let tubeRadius  = tubeBase + Float(fr.loudness) * tubeGain
        // Harmonic complexity → major segment count (HTML: 16–46).
        let majorSegs = 16 + Int((fr.harmonicComplexity * 30).rounded())
        let minorSegs = 8  // fixed — keeps tube cross-section round enough

        let mesh = torusMesh(
            majorRadius: majorRadius,
            tubeRadius: tubeRadius,
            majorSegments: majorSegs,
            minorSegments: minorSegs
        )

        // HDR-boosted unlit material — matches Crystal/Clouds/Rings pattern.
        // Tried PhysicallyBasedMaterial first (metallic+emissive sculptural
        // look) but the baseColor wasn't reading through reliably — even
        // with metallic=0, low-intensity lights, and rebalanced emissive,
        // the rings rendered as desaturated silver instead of the song's
        // hue palette. Reverted to the proven unlit pattern: simple, fast,
        // and bloom-friendly. We give up sculptural shading; we get
        // reliable colored glowing rings.
        let hue = CGFloat(fr.color.hue)
        let sat = CGFloat(min(1.0, 0.45 + Double(fr.loudness) * 1.7))
        let bri = CGFloat(min(1.0, 0.60 + Double(fr.color.saturation) * 1.3))
        let hdrBoost: CGFloat = 1.6
        let tint = PlatformColor.hdrColor(
            hue: hue, saturation: sat, brightness: bri, hdrBoost: hdrBoost
        )

        var mat = UnlitMaterial()
        mat.color = .init(tint: tint)
        // Material opacity stays at 1.0; OpacityComponent on each ring
        // multiplies this for the per-frame fade-in / energy pulse. Setting
        // blending opacity to 0 here would multiply OpacityComponent's value
        // by 0 and the ring would never render.
        mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        // No depth-write — the constellation's overlapping rings would
        // Z-fight with each other; same trick as Crystal's halos/cores.
        mat.writesDepth = false

        let ring = ModelEntity(mesh: mesh, materials: [mat])

        // Orientation: tilt off horizontal by hc, lean by pitch class.
        // HTML: rotation.x = π/2 - hc*1.1 then rotation.z = (h - 0.5) * π * 0.7
        let tiltX = .pi / 2 - Float(fr.harmonicComplexity) * 1.1
        let leanZ = (Float(fr.color.hue) - 0.5) * .pi * 0.7
        ring.orientation = simd_quatf(angle: leanZ, axis: [0, 0, 1])
            * simd_quatf(angle: tiltX, axis: [1, 0, 0])

        ring.position = [homeX, homeY, homeZ]
        ring.scale = .zero  // hidden until the onset clock arrives

        ring.components.set(ArchRingComponent(
            onsetTime: fr.time,
            homeY: homeY,
            wobbleFreq:  0.7 + Double(i % 11) * 0.13,
            // Wobble phase: any 0..1 value × 2π. Reuse heightFraction —
            // it's already 0..1 in both preview (i/n) and live
            // (golden-ratio) modes.
            wobblePhase: Double(heightFraction) * 2 * .pi
        ))
        ring.components.set(OpacityComponent(opacity: 0))

        return ring
    }

    // MARK: - Animate

    static func animate(
        _ root: Entity,
        clock: Double,
        energy: Float,
        deltaTime: Double
    ) {
        guard var rootState = root.components[ArchRootComponent.self] else { return }

        // Lazy capture of the base orientation so we don't stomp host tilts.
        if rootState.baseOrientation.imag.x.isNaN {
            rootState.baseOrientation = root.orientation
        }

        // Smooth incoming energy so the per-ring breath amplitude doesn't
        // step-change with loud transients. Time constant ~250 ms (lerp
        // factor 4 × dt). The accumulated rotation rate uses the smoothed
        // value too — keeps the rotation speed from twitching on every
        // beat.
        let smoothingRate: Float = 4
        rootState.smoothedEnergy += (energy - rootState.smoothedEnergy)
            * Float(min(1.0, deltaTime * Double(smoothingRate)))
        let eSmooth = rootState.smoothedEnergy

        // Slow Y rotation that speeds up with energy. HTML uses
        //   architectureGroup.rotation.y += dt * (0.08 + eLoud*0.35)
        rootState.groupRotation += Float(deltaTime) * (0.08 + eSmooth * 0.35)
        let yRot = simd_quatf(angle: rootState.groupRotation, axis: [0, 1, 0])
        root.orientation = rootState.baseOrientation * yRot

        // Per-ring animation: pop-in scale, breathing wobble, opacity pulse.
        for child in root.children {
            guard let rc = child.components[ArchRingComponent.self],
                  let ring = child as? ModelEntity
            else { continue }

            let age = clock - rc.onsetTime
            if age < 0 {
                ring.scale = .zero
                ring.components.set(OpacityComponent(opacity: 0))
                continue
            }

            // Pop-in: overshoot 1.25 over 0.25s, settle to 1.0 by 0.45s.
            let popScale: Float
            if age < 0.25 {
                popScale = Float(age / 0.25) * 1.25
            } else if age < 0.45 {
                popScale = 1.25 - Float((age - 0.25) / 0.20) * 0.25
            } else {
                popScale = 1.0
            }

            // Breathing: wobble drives both vertical position and scale
            // pulse. Use smoothed energy so the amplitude doesn't lurch
            // mid-sine on transients — the sine itself is continuous, but
            // multiplying by a fast-changing energy was making the rings
            // visibly jerk vertically on every loud beat.
            let wobble = Float(sin(clock * rc.wobbleFreq + rc.wobblePhase))
            let breathY = wobble * eSmooth * 1.1
            let breathScale = 1.0 + wobble * 0.04 + eSmooth * 0.14

            ring.position.y = rc.homeY + breathY
            let s = popScale * breathScale
            ring.scale = [s, s, s]

            // Opacity fades in then pulses with loudness. Pulse uses raw
            // `energy` (not smoothed) — opacity changes are imperceptible
            // as "jerky" since the eye reads brightness changes more
            // tolerantly than positional ones.
            let fadeIn = Float(min(1.0, age / 0.2))
            let opacity = fadeIn * (0.65 + energy * 0.35)
            ring.components.set(OpacityComponent(opacity: opacity))

        }

        root.components.set(rootState)
    }

    // MARK: - Lights

    /// Adds a warm key light from upper-right and a cool fill from lower-left.
    /// Together they give each torus a clear curve highlight + soft fill
    /// without making any ring read as "shadowy" against the dark backdrop.
    private static func addLights(to root: Entity) {
        // Mid-intensity lights: enough diffuse shading to define ring shape
        // and add highlights, not so bright they wash out the baseColor.
        // First attempt at 4500/2000 was too bright (silver sculpture); 450/200
        // was too dim (no shading at all); 1200/500 hits the balance with
        // the rebalanced emissive (2.0 intensity, deep-sat hue).
        let keyLight = Entity()
        var key = DirectionalLightComponent()
        key.color = PlatformColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1.0)
        key.intensity = 1200
        keyLight.components.set(key)
        keyLight.orientation = simd_quatf(angle: -0.6, axis: [1, 0, 0])
            * simd_quatf(angle: 0.5, axis: [0, 1, 0])
        root.addChild(keyLight)

        let fillLight = Entity()
        var fill = DirectionalLightComponent()
        fill.color = PlatformColor(red: 0.78, green: 0.88, blue: 1.0, alpha: 1.0)
        fill.intensity = 500
        fillLight.components.set(fill)
        fillLight.orientation = simd_quatf(angle: 0.4, axis: [1, 0, 0])
            * simd_quatf(angle: -0.7, axis: [0, 1, 0])
        root.addChild(fillLight)
    }

    // MARK: - Torus mesh

    /// Build a torus mesh with the given major (ring) and tube (cross-section)
    /// radii. The torus lies in the XZ plane (axis = +Y), so a downstream
    /// `tiltX = π/2` puts it edge-on to the camera (matching HTML's default
    /// `THREE.TorusGeometry` orientation).
    private static func torusMesh(
        majorRadius R: Float,
        tubeRadius r: Float,
        majorSegments majorN: Int,
        minorSegments minorN: Int
    ) -> MeshResource {
        let majorN = max(3, majorN)
        let minorN = max(3, minorN)

        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var indices:   [UInt32] = []

        positions.reserveCapacity(majorN * minorN)
        normals.reserveCapacity(majorN * minorN)
        indices.reserveCapacity(majorN * minorN * 6)

        for i in 0..<majorN {
            let u = Float(i) / Float(majorN) * 2 * .pi
            let cu = cos(u), su = sin(u)
            for j in 0..<minorN {
                let v = Float(j) / Float(minorN) * 2 * .pi
                let cv = cos(v), sv = sin(v)

                // Position on the torus surface.
                let x = (R + r * cv) * cu
                let y = r * sv
                let z = (R + r * cv) * su
                positions.append(SIMD3<Float>(x, y, z))

                // Outward-facing normal (perpendicular to tube cross-section).
                let nx = cv * cu
                let ny = sv
                let nz = cv * su
                normals.append(SIMD3<Float>(nx, ny, nz))
            }
        }

        // Two triangles per quad in the (majorN × minorN) grid, wrapping in
        // both directions.
        for i in 0..<majorN {
            let iNext = (i + 1) % majorN
            for j in 0..<minorN {
                let jNext = (j + 1) % minorN
                let a = UInt32(i     * minorN + j)
                let b = UInt32(iNext * minorN + j)
                let c = UInt32(iNext * minorN + jNext)
                let d = UInt32(i     * minorN + jNext)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        var descriptor = MeshDescriptor()
        descriptor.positions  = MeshBuffer(positions)
        descriptor.normals    = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            // Fallback to a sphere if descriptor build fails — the ring will
            // render as a wrong shape but the scene won't crash.
            return .generateSphere(radius: R)
        }
    }

}
