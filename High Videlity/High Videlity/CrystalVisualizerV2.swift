//
//  CrystalVisualizerV2.swift
//  High Videlity
//
//  Crystal v2 — HTML-faithful rebuild. Each onset becomes a "shardGroup"
//  entity with three SIBLING children:
//   • shardEnt: non-additive translucent cone — the spike itself, alpha-fades
//     from 0 to (0.72 + eLoud*0.28) per HTML.
//   • haloEnt: additive wide colored cylinder — the colored beam envelope.
//   • coreEnt: additive thin near-white-hot cylinder — the laser filament.
//
//  Sibling layout (rather than the v1 nesting shard→beams) lets each role
//  carry its own OpacityComponent so we can drive HTML's distinct opacity
//  curves per element. The shardGroup carries scale (pop + breathing) and
//  rotation (point along this onset's pitch-class direction); animation
//  reads ShardComponent off the group and updates per-child opacity via
//  the BeamRole tag.
//
//  History of dead-ends before this layout (do not retry — see crystal-v2
//  memory for the full record):
//   • v1: 4 stacked additive cylinders per beam ≈ 600 meshes — RealityKit's
//     transparency pipeline dropped beams selectively.
//   • Point-emitter particles with speed > 0 — read as streaks, not beams.
//   • Box-volume emitters with speed 0 — crashed the visionOS render server.
//   • 3-concentric atmospheric-glow cylinder — caused bullseye end-cap
//     stacking on shards aimed at camera. Atmospheric scatter belongs in a
//     post-process pass (BloomPostProcessEffect handles it on macOS now).
//
//  Shares ShardComponent + BeamRole and CrystalVisualizer.animate with v1.
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

enum CrystalVisualizerV2 {

    /// Build a low-poly faceted cone (the crystalline shard shape). HTML's
    /// `CylinderGeometry(0.008, baseR, len, segs)` with `segs = 4 + hc*3`
    /// gives shards distinct prismatic faces that vary with harmonic
    /// complexity — the "elegant" half of the elegant-electric paradox.
    /// `MeshResource.generateCone(...)` produces a smooth ~32-segment mesh
    /// that reads as a blob instead of a crystal, so we build the geometry
    /// by hand here.
    ///
    /// Mesh: a near-cone with a small flat tip (matches HTML's 0.008 top
    /// radius), built as a triangle fan from the tip to the base ring, then
    /// a base cap so the shard is fully closed for proper alpha-blended
    /// silhouette. Centroid at y=0, base at -height/2, tip at +height/2.
    static func facetedShardMesh(height: Float, baseRadius: Float, sides: Int) -> MeshResource {
        let sides = max(3, sides)
        let topRadius = baseRadius * 0.04   // HTML's 0.008/0.18 ≈ 0.044 — near-zero but not point-zero
        let halfH = height / 2
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Top ring (small face at tip)
        let topStart = UInt32(positions.count)
        for i in 0..<sides {
            let a = Float(i) / Float(sides) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * topRadius, halfH, sin(a) * topRadius))
        }

        // Base ring
        let baseStart = UInt32(positions.count)
        for i in 0..<sides {
            let a = Float(i) / Float(sides) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * baseRadius, -halfH, sin(a) * baseRadius))
        }

        // Side faces — each is a quad split into two triangles.
        for i in 0..<sides {
            let next = (i + 1) % sides
            let t0 = topStart + UInt32(i)
            let t1 = topStart + UInt32(next)
            let b0 = baseStart + UInt32(i)
            let b1 = baseStart + UInt32(next)
            // outward winding (counter-clockwise from outside, +Y up)
            indices.append(contentsOf: [t0, b0, b1])
            indices.append(contentsOf: [t0, b1, t1])
        }

        // Top cap (small)
        let topCenter = UInt32(positions.count)
        positions.append(SIMD3<Float>(0, halfH, 0))
        for i in 0..<sides {
            let next = (i + 1) % sides
            indices.append(contentsOf: [topCenter, topStart + UInt32(next), topStart + UInt32(i)])
        }

        // Base cap (closes the shard so its silhouette reads as a solid spike)
        let baseCenter = UInt32(positions.count)
        positions.append(SIMD3<Float>(0, -halfH, 0))
        for i in 0..<sides {
            let next = (i + 1) % sides
            indices.append(contentsOf: [baseCenter, baseStart + UInt32(i), baseStart + UInt32(next)])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generateCone(height: height, radius: baseRadius)
        }
    }

    /// Build a low-poly tapered cylinder (the beam shape). HTML uses
    /// `CylinderGeometry(topR, bottomR, len, 6)` with topR < bottomR — beam
    /// is wider where it emerges from the shard and narrower at the far
    /// end. `MeshResource.generateCylinder` only takes a single radius, so
    /// like the shard mesh we build this by hand.
    static func taperedBeamMesh(height: Float, topRadius: Float, bottomRadius: Float, sides: Int = 6) -> MeshResource {
        let sides = max(3, sides)
        let halfH = height / 2
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let topStart = UInt32(positions.count)
        for i in 0..<sides {
            let a = Float(i) / Float(sides) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * topRadius, halfH, sin(a) * topRadius))
        }
        let baseStart = UInt32(positions.count)
        for i in 0..<sides {
            let a = Float(i) / Float(sides) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * bottomRadius, -halfH, sin(a) * bottomRadius))
        }
        for i in 0..<sides {
            let next = (i + 1) % sides
            let t0 = topStart + UInt32(i)
            let t1 = topStart + UInt32(next)
            let b0 = baseStart + UInt32(i)
            let b1 = baseStart + UInt32(next)
            indices.append(contentsOf: [t0, b0, b1])
            indices.append(contentsOf: [t0, b1, t1])
        }
        // No end caps — beams are additively blended so closed silhouette
        // isn't necessary, and skipping caps avoids depth artifacts on the
        // end disks when the beam points roughly at the camera.

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return .generateCylinder(height: height, radius: bottomRadius)
        }
    }

    /// State carried on a live-mode Crystal root entity. Lets the
    /// animate-tick caller scan newly-arrived frames for onsets and
    /// spawn new shardGroups incrementally (instead of building the full
    /// set at scene-build time, which doesn't work when `frames` grows
    /// continuously from the streaming analyzer).
    struct CrystalLiveStateComponent: Component {
        /// Index into `appModel.frames` we've already scanned for onsets.
        /// `scanForNewOnsets` walks `frames[lastSeenFrameIndex..<frames.count]`.
        var lastSeenFrameIndex: Int = 0
        /// Running count of shards spawned in live mode. Drives the
        /// golden-ratio elevation sequence that gives every new shard a
        /// well-distributed elevation without knowing total count.
        var liveShardCount: Int = 0
        /// `appModel.liveModeResetCounter` value at the most-recent scan.
        /// When AppModel bumps it (Shazam track-change reset),
        /// `scanForNewOnsets` notices on the next tick, drops all spawned
        /// children, and zeroes the indices to start the cluster fresh
        /// for the new song.
        var lastSeenResetCounter: Int = 0
    }

    /// Cached additive-blend material program. Built async once and reused
    /// for every shardGroup's halo + core. Stored statically so live-mode
    /// spawning (which happens inside a non-async animate-tick) can read it
    /// without rebuilding. Set by `makeCrystal` / `makeCrystalLive`.
    @MainActor private static var cachedAdditiveProgram: UnlitMaterial.Program?

    // MARK: - Shared mesh palette
    //
    // Crystal V2 originally generated a UNIQUE `MeshResource` per spawn —
    // shard length/baseRadius and beam length/radii all vary continuously
    // with frame.loudness, so every spawn called `facetedShardMesh` and
    // `taperedBeamMesh` to build fresh geometry. On 2026-05-22 the leak
    // instrumentation caught the consequence: ~26 MB of mesh data stuck
    // in memory after each Crystal-visit-then-mode-change, because
    // RealityKit retains MeshResource backing storage even after every
    // referencing entity has been removed from the scene tree. Over a
    // multi-mode-cycle session that accumulated to 250+ MB and a malloc
    // failure on the audio thread.
    //
    // Fix: a 5-mesh palette built once at scene-create time and reused
    // across every spawn for the app's lifetime:
    //   • 4 canonical shard meshes (one per side count ∈ {4,5,6,7} — the
    //     HTML range of `4 + round(harmonicComplexity × 3)`)
    //   • 1 canonical beam mesh (used for BOTH halo and core — their
    //     top:bottom taper ratios are 0.59 and 0.60 respectively, close
    //     enough to share a single canonical mesh)
    //
    // Per-spawn dimension variance comes from non-uniform `entity.scale`:
    // `(rx, ly, rx)` scales the radius and length axes independently while
    // preserving the canonical taper ratio (both top and bottom radii get
    // multiplied by the same `rx`). The existing `shardEnt.position =
    // [0, length/2, 0]` math is unchanged — `length` here is the desired
    // post-scale length, and the entity-position scales through the
    // shardGroup transform exactly as before.

    /// Canonical (pre-scale) shard length. Per-spawn `scale.y = length / 1.0`.
    /// Chosen as 1.0 so `scale.y` directly equals the desired world length.
    private static let canonicalShardLength: Float = 1.0
    /// Canonical shard base radius, derived from the established
    /// `baseRadius = length × 0.12` ratio at canonicalShardLength=1.0.
    private static let canonicalShardBaseRadius: Float = 0.12
    /// Canonical beam length. Same reasoning as the shard.
    private static let canonicalBeamLength: Float = 1.0
    /// Canonical beam bottom radius — chosen at the mid-loudness halo size
    /// (0.040 + 0.5 × 0.030 = 0.055, rounded to 0.05 for clean ratios).
    /// Top radius is 0.59× this to match the halo taper.
    private static let canonicalBeamBottomRadius: Float = 0.05

    /// One shard mesh per `sides ∈ {4, 5, 6, 7}`. Built lazily on first
    /// request; the four entries are cheap (~64 vertices each) so total
    /// palette size is < 5 KB.
    @MainActor private static var cachedShardMeshes: [Int: MeshResource] = [:]

    /// Single beam mesh — used for halo AND core via per-spawn radial scale.
    @MainActor private static var cachedBeamMesh: MeshResource?

    @MainActor
    private static func sharedShardMesh(sides: Int) -> MeshResource {
        let clamped = max(4, min(7, sides))
        if let cached = cachedShardMeshes[clamped] { return cached }
        let mesh = facetedShardMesh(
            height: canonicalShardLength,
            baseRadius: canonicalShardBaseRadius,
            sides: clamped
        )
        cachedShardMeshes[clamped] = mesh
        return mesh
    }

    @MainActor
    private static func sharedBeamMesh() -> MeshResource {
        if let cached = cachedBeamMesh { return cached }
        let mesh = taperedBeamMesh(
            height: canonicalBeamLength,
            topRadius: canonicalBeamBottomRadius * 0.59,
            bottomRadius: canonicalBeamBottomRadius
        )
        cachedBeamMesh = mesh
        return mesh
    }

    /// Warm the entire palette in one call. Called from `makeCrystal` and
    /// `makeCrystalLive` at scene-create time so the synchronous
    /// `scanForNewOnsets` path never pays mesh-build cost on its first call.
    @MainActor
    private static func warmMeshPalette() {
        for s in 4...7 { _ = sharedShardMesh(sides: s) }
        _ = sharedBeamMesh()
    }

    /// Build (or return cached) shared additive-blend program for shard beams.
    @MainActor
    private static func sharedAdditiveProgram() async -> UnlitMaterial.Program {
        if let cached = cachedAdditiveProgram { return cached }
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        let program = await UnlitMaterial.Program(descriptor: descriptor)
        cachedAdditiveProgram = program
        return program
    }

    /// DEBUG: density-saturation test multiplier. When > 1, makeCrystal
    /// builds `n * synthShardMultiplier` shards by cycling through the
    /// onsets array, distributing elevation via the golden ratio so any
    /// multiplier value gives a well-distributed sphere. Used to answer
    /// "at what shard count does the cluster visually saturate, and where
    /// does the renderer drop out?" — informs whether the live-mode cap
    /// (default 300) can be raised, or whether a MeshInstancesComponent
    /// refactor is needed. Reset to 1 before shipping.
    static var synthShardMultiplier: Int = 1

    /// Builds the crystal: one shardGroup per onset, each containing a
    /// translucent cone shard plus an additive halo+core beam radiating from
    /// its tip.
    static func makeCrystal(from frames: [FeatureFrame]) async -> Entity {
        let onsets = frames.filter { $0.onset }
        let root = Entity()
        root.position = [0, 1.3, -1.5]
        guard !onsets.isEmpty else { return root }

        // DEBUG saturation test: cycle through onsets `synthShardMultiplier`
        // times. Default 1 = no-op (one shardGroup per real onset, original
        // i/n elevation). Higher values clone each onset across additional
        // elevation slots — same color/loudness, different elevation — so
        // we can A/B "how does the cluster look at 300 vs 600 vs 900 shards?"
        // without needing a live audio source.
        let mult = max(1, synthShardMultiplier)
        let total = onsets.count * mult

        // One shared additive blend program for the beams. Shard uses the
        // default UnlitMaterial (alpha-blended translucent) — HTML's shard is
        // NOT additive, only its beams are.
        let additiveProgram = await sharedAdditiveProgram()
        // Pre-build the canonical mesh palette so spawnShardGroup never
        // allocates fresh MeshResources (the 2026-05-22 leak source).
        warmMeshPalette()

        for k in 0..<total {
            let frame = onsets[k % onsets.count]
            let elevationFraction = Double(k) / Double(total)
            let shardGroup = spawnShardGroup(
                frame: frame,
                elevationFraction: elevationFraction,
                indexForWobble: k,
                additiveProgram: additiveProgram
            )
            root.addChild(shardGroup)
        }
        return root
    }

    /// Build an empty Crystal root sized + positioned exactly like
    /// `makeCrystal`'s root, plus a `CrystalLiveStateComponent` for the
    /// animate-tick caller to drive live spawning. Returns immediately —
    /// the cluster grows entity-by-entity as `scanForNewOnsets` is called.
    ///
    /// `startingFrameIndex` seeds `lastSeenFrameIndex` so the first scan
    /// only walks frames that arrive AFTER this call. Callers pass
    /// `appModel.frames.count` when opening the visualizer, ensuring a
    /// fresh cluster that grows from "now" — without it, the first
    /// scanForNewOnsets call would catch up on every onset accumulated
    /// since the user toggled system audio on, spawning a flurry of
    /// entities in a single frame (rendering stall).
    static func makeCrystalLive(startingFrameIndex: Int, startingResetCounter: Int) async -> Entity {
        // Warm the shared additive program now so `scanForNewOnsets` (which
        // is synchronous) can read it from the cache without ever blocking
        // on async build.
        let additiveProgram = await sharedAdditiveProgram()
        // Pre-build the canonical mesh palette so the first live spawn
        // doesn't pay 5× MeshResource-build cost on the audio-driven scan.
        warmMeshPalette()
        let root = Entity()
        root.position = [0, 1.3, -1.5]

        // RECYCLE POOL (render-crash fix, 2026-05-31). Previously live mode
        // grew the cluster via addChild per onset and evicted the oldest via
        // removeFromParent — both STRUCTURAL mutations of the scene graph,
        // performed from inside the SceneEvents.Update closure while
        // RealityKit's render thread concurrently draws that same graph. The
        // per-tick remove raced the draw → use-after-free crash on the CoreRE
        // render thread (EXC_BAD_ACCESS in re::encodeDrawCalls).
        //
        // Fix mirrors Clouds (the one live mode never implicated): pre-build
        // the FULL fixed pool of `liveModeShardCap` shardGroups here, once,
        // all inactive (scale .zero, ShardComponent.active = false → animate
        // skips them, nothing renders). `scanForNewOnsets` then RECONFIGURES
        // an existing slot per onset instead of adding/removing. After this
        // call no structural mutation ever happens again, so the render
        // thread has nothing to race.
        for _ in 0..<liveModeShardCap {
            root.addChild(buildEmptyShardGroup(additiveProgram: additiveProgram))
        }

        var state = CrystalLiveStateComponent()
        state.lastSeenFrameIndex = startingFrameIndex
        state.lastSeenResetCounter = startingResetCounter
        root.components.set(state)
        return root
    }

    /// Walk new frames since the last call and spawn one shardGroup per
    /// `onset == true` frame. Cheap when no new onsets — bounded by
    /// `frames.count - state.lastSeenFrameIndex` ≈ a few per call at
    /// 30 fps. Call from the animate-tick closure when in live mode.
    ///
    /// Spawned shards use a golden-ratio elevation sequence so any prefix
    /// of the running shard count is well-distributed on the sphere,
    /// independent of total count (the preview path's `i/n` formula
    /// would require recomputing all existing shard elevations on each
    /// new arrival).
    @MainActor
    static func scanForNewOnsets(_ root: Entity, frames: [FeatureFrame], appResetCounter: Int) {
        guard var state = root.components[CrystalLiveStateComponent.self] else { return }
        guard let additiveProgram = cachedAdditiveProgram else { return }

        // The pool was pre-allocated in `makeCrystalLive`; its size is the
        // recycle capacity. (Guard against an empty root in case this is
        // ever called on a non-pool entity.)
        let pool = root.children
        let cap = pool.count
        guard cap > 0 else {
            root.components.set(state)
            return
        }

        // Track-change reset: AppModel bumped `liveModeResetCounter` (e.g.
        // Shazam detected a new song or user clicked next/restart). DEACTIVATE
        // every pool slot in place rather than removing children — no
        // structural mutation, so nothing for the render thread to race.
        // `active = false` + onsetTime → ∞ makes `animate` skip the slot
        // (hidden, excluded from camera targeting) until it's reconfigured.
        //
        // Seed `lastSeenFrameIndex` to the CURRENT `frames.count`, not 0.
        // Between the reset firing and this tick running, the polling task
        // has typically drained ~30 frames with multiple onsets. Setting to
        // 0 would replay all of those at once — visible as a "frontloaded"
        // burst of shards at song start. Seeding to current count means
        // we wait for genuinely-new frames, giving a gradual buildup that
        // matches the song's onset rate.
        if state.lastSeenResetCounter != appResetCounter {
            for slot in pool {
                if var info = slot.components[ShardComponent.self] {
                    info.active = false
                    info.onsetTime = .infinity
                    slot.components.set(info)
                }
                slot.scale = .zero
            }
            state.lastSeenFrameIndex = frames.count
            state.liveShardCount = 0
            state.lastSeenResetCounter = appResetCounter
        }

        let upper = frames.count
        guard upper > state.lastSeenFrameIndex else {
            root.components.set(state)
            return
        }
        // Walk only newly-arrived frames.
        for k in state.lastSeenFrameIndex..<upper {
            if frames[k].onset {
                // Golden-ratio elevation: `frac(liveShardCount / phi)` is a
                // low-discrepancy sequence over [0,1) — every new sample
                // lands maximally far from the previously-placed samples.
                let phiInverse = 0.6180339887498949
                let frac = (Double(state.liveShardCount) * phiInverse)
                    .truncatingRemainder(dividingBy: 1.0)

                // Reconfigure the slot at `liveShardCount % cap` in place.
                // When the count wraps past `cap`, the oldest occupant is
                // silently overwritten — the same eviction behaviour as the
                // old `removeFromParent` loop, but with zero scene-graph
                // mutation. `frame.time` is monotonic in live mode, so the
                // reused slot's onsetTime always moves FORWARD; `animate`
                // sees age ≈ 0 and pops it back in fresh.
                let slotIndex = state.liveShardCount % cap
                configure(
                    pool[slotIndex],
                    frame: frames[k],
                    elevationFraction: frac,
                    indexForWobble: state.liveShardCount,
                    additiveProgram: additiveProgram
                )
                state.liveShardCount += 1
            }
        }
        state.lastSeenFrameIndex = upper
        root.components.set(state)
    }

    /// Max shards visible at once in live mode. Past this point we recycle
    /// the oldest. Each shard = 3 child meshes (cone + halo + core), so
    /// at the cap the cluster is ~900 additive meshes. RealityKit's
    /// additive pipeline started showing dropout at ~700 in v1 but v2's
    /// per-program-pipeline blend is more robust. The eviction events
    /// become visible at high spawn rates — bumped 200 → 300 to push
    /// the first eviction out to several minutes in for typical music.
    static let liveModeShardCap: Int = 300

    /// Find a shardGroup's child by its BeamRole. Children are added in a
    /// fixed order (shard, halo, core) but we look up by role so `configure`
    /// stays robust to ordering.
    @MainActor
    private static func child(_ group: Entity, _ kind: BeamRole.Kind) -> ModelEntity? {
        for c in group.children {
            if let role = c.components[BeamRole.self], role.kind == kind {
                return c as? ModelEntity
            }
        }
        return nil
    }

    /// Build the entity SKELETON for one shardGroup — the three child
    /// ModelEntities (shard / halo / core) with shared canonical meshes,
    /// placeholder materials, BeamRole tags and zeroed opacity — but NO
    /// per-frame appearance. Starts inactive (scale .zero,
    /// `ShardComponent.active = false`) so `animate` skips it until
    /// `configure` activates it.
    ///
    /// Live mode pre-allocates `liveModeShardCap` of these once in
    /// `makeCrystalLive`, then recycles them via `configure` — so the scene
    /// graph is never structurally mutated after build (the render-crash fix).
    @MainActor
    private static func buildEmptyShardGroup(additiveProgram: UnlitMaterial.Program) -> Entity {
        let shardGroup = Entity()
        shardGroup.position = .zero
        shardGroup.scale = .zero
        var inactive = ShardComponent(
            onsetTime: .infinity,
            direction: SIMD3<Float>(0, 1, 0),
            length: 0.3,
            wobbleFreq: 1,
            wobblePhase: 0
        )
        inactive.active = false
        shardGroup.components.set(inactive)

        // Shard: non-additive translucent spike. Canonical mesh + placeholder
        // material; `configure` swaps in the real per-frame mesh + tint.
        let shardEnt = ModelEntity(mesh: Self.sharedShardMesh(sides: 4), materials: [UnlitMaterial()])
        shardEnt.components.set(BeamRole(.shard))
        shardEnt.components.set(OpacityComponent(opacity: 0))
        shardGroup.addChild(shardEnt)

        // Halo: additive colored envelope.
        var haloMaterial = UnlitMaterial(program: additiveProgram)
        haloMaterial.writesDepth = false
        let haloEnt = ModelEntity(mesh: Self.sharedBeamMesh(), materials: [haloMaterial])
        haloEnt.components.set(BeamRole(.halo))
        haloEnt.components.set(OpacityComponent(opacity: 0))
        shardGroup.addChild(haloEnt)

        // Core: additive white-hot filament.
        var coreMaterial = UnlitMaterial(program: additiveProgram)
        coreMaterial.writesDepth = false
        let coreEnt = ModelEntity(mesh: Self.sharedBeamMesh(), materials: [coreMaterial])
        coreEnt.components.set(BeamRole(.core))
        coreEnt.components.set(OpacityComponent(opacity: 0))
        shardGroup.addChild(coreEnt)

        return shardGroup
    }

    /// Build one shardGroup entity (cone shard + additive halo + core beam)
    /// for a single onset frame. Used by the preview-mode `makeCrystal` loop.
    /// (Live mode builds empty pool slots and `configure`s them in place.)
    ///
    /// `elevationFraction` is the fraction-of-sphere coordinate that
    /// determines the shard's polar angle (0 → south pole, 1 → north pole).
    /// Preview mode passes `i/n`; live mode passes a golden-ratio value.
    @MainActor
    private static func spawnShardGroup(
        frame: FeatureFrame,
        elevationFraction: Double,
        indexForWobble i: Int,
        additiveProgram: UnlitMaterial.Program
    ) -> Entity {
        let group = buildEmptyShardGroup(additiveProgram: additiveProgram)
        configure(
            group,
            frame: frame,
            elevationFraction: elevationFraction,
            indexForWobble: i,
            additiveProgram: additiveProgram
        )
        return group
    }

    /// Apply one onset frame's full appearance to an EXISTING shardGroup —
    /// direction / length / colors / scales / positions / ShardComponent —
    /// mutating its three child entities in place. This is the recycle
    /// primitive: live mode calls it on a pre-allocated pool slot per onset
    /// (no add/removeFromParent), and `spawnShardGroup` calls it once on a
    /// freshly-built skeleton for the preview path.
    ///
    /// MUST fully reset every visual the previous occupant could have set, or
    /// stale appearance bleeds across a recycle. Soak-test by wrapping the
    /// pool (>`liveModeShardCap` onsets in one session).
    @MainActor
    private static func configure(
        _ shardGroup: Entity,
        frame: FeatureFrame,
        elevationFraction: Double,
        indexForWobble i: Int,
        additiveProgram: UnlitMaterial.Program
    ) {
        // Pitch-class hue → azimuth. Elevation from caller — `i/n` for the
        // preview path (HTML's `buildCrystals` behavior), or a golden-ratio
        // sequence for live mode that gives any prefix a well-distributed
        // spherical layout without knowing total count.
        let azimuth = frame.color.hue * 2 * .pi
        let elevation = asin(1 - 2 * elevationFraction)
            let ce = cos(elevation)
            let dir = SIMD3<Float>(
                Float(ce * cos(azimuth)),
                Float(sin(elevation)),
                Float(ce * sin(azimuth))
            )

            // Shard dimensions.
            //
            // FLY-THROUGH SCALE-UP. Previous values (length 0.21 + l*0.63,
            // baseRadius ratio 0.20) gave a beautiful tight cluster but the
            // camera ended up permanently INSIDE the shard shell (camera
            // ~0.17 from origin vs shard tips at 0.84) — so when the next
            // shard target flipped to the opposite side, the camera arc
            // was tiny in world units and there was no perceptible
            // "fly-through." HTML works because its camera sits at ~15×
            // the shard-shell radius from origin (8.7 vs 0.56), so on
            // retarget the camera arcs along a real chord that passes
            // through the beam shell. To recreate that topology at our
            // wider RealityView FOV: scale shards and beams up ~2-3× AND
            // push the camera out enough that camera_dist > shard_radius.
            // baseRadius ratio dropped back closer to HTML's 0.047 — shards
            // are now big enough in absolute terms that the previous 0.20
            // compensation makes them comical.
            let length = 0.30 + frame.loudness * 0.90
            let baseRadius = length * 0.12

            // --- shardGroup carries the per-frame transform & ShardComponent ---
            //
            // Position at world origin (cluster center) rather than at the
            // shard centroid (dir * length/2). Combined with the shardEnt
            // local offset below, this places the shard's BASE at the
            // cluster center — so when `breath` scales the group along its
            // local Y, the base stays anchored at the cluster center and
            // the tip extends outward. This matches HTML's `cone.position
            // = base; cone.scale = stretchFromBase` semantics. Previously
            // the centroid sat at dir*length/2 and breathing stretched
            // symmetrically around it — both base AND tip moved (the base
            // even drifted into negative-dir territory at breath > 1).
            shardGroup.orientation = simd_quatf(from: [0, 1, 0], to: dir)
            shardGroup.position = .zero
            shardGroup.scale = .zero    // hidden until onset; animate flips it on
            var shardInfo = ShardComponent(
                onsetTime: frame.time,
                direction: dir,
                length: length,
                wobbleFreq: 0.6 + Double(i % 13) * 0.11,
                // Wobble phase: any 0..1 value times 2π gives per-shard
                // variation. Reuse `elevationFraction` (which is already
                // 0..1 — derived from i/n in preview mode, golden-ratio in
                // live mode) so phase distribution matches the spherical
                // distribution.
                wobblePhase: elevationFraction * 2 * .pi
            )
            shardInfo.active = true     // wake the slot — animate now drives it
            shardGroup.components.set(shardInfo)

            let hue = CGFloat(frame.color.hue)

            // --- Shard mesh: non-additive translucent spike ---------------
            // HTML uses MeshBasicMaterial with `transparent: true, opacity: 0`
            // and fades the opacity in. The shard has a defined silhouette;
            // it's not a glowing additive smear. We mirror that: regular
            // UnlitMaterial with the tint color, alpha driven each frame by
            // the OpacityComponent.
            // Brightness floor bumped 0.65 → 0.85: even low-saturation
            // shards now read as bright cone wedges, so the hub stays
            // luminous regardless of which frames are near the camera at
            // any given moment. Saturation floor unchanged — desaturated
            // shards (low-loudness moments) still give a pale pastel hub
            // closer to HTML's pale-pink reference.
            let shardSat = min(1.0, 0.5 + Double(frame.loudness) * 1.6)
            let shardBri = min(1.0, 0.85 + frame.color.saturation * 1.2)
            let shardColor = PlatformColor(
                hue: hue,
                saturation: CGFloat(shardSat),
                brightness: CGFloat(shardBri),
                alpha: 1.0
            )
            var shardMaterial = UnlitMaterial()
            shardMaterial.color = .init(tint: shardColor)
            // HTML uses 4 + round(hc*3) sides per shard — the crystalline
            // facet count varies with harmonic complexity, giving each
            // shard a slightly different prismatic shape.
            let shardSides = 4 + Int((frame.harmonicComplexity * 3).rounded())
            // Shared canonical mesh + non-uniform scale. The canonical mesh
            // has height=1.0 and baseRadius=0.12; scaling y by `length` and
            // x/z by `baseRadius/0.12` gives the desired per-spawn dimensions
            // without allocating a fresh MeshResource. Taper ratio is
            // preserved because both top and bottom radii are scaled by
            // the same x/z factor. See the "Shared mesh palette" comment
            // block above for the leak history this fixes.
            let shardMesh = Self.sharedShardMesh(sides: shardSides)
            // Mutate the pre-built child in place (no add/removeFromParent).
            guard let shardEnt = Self.child(shardGroup, .shard) else { return }
            shardEnt.model?.mesh = shardMesh
            shardEnt.model?.materials = [shardMaterial]
            let shardRadialScale = baseRadius / canonicalShardBaseRadius
            shardEnt.scale = SIMD3<Float>(
                shardRadialScale,
                length / canonicalShardLength,
                shardRadialScale
            )
            // Cone mesh is centroid-centered (vertices span y = -0.5..+0.5
            // in canonical coords). With shardEnt scaled by `length` along
            // Y, the scaled mesh spans -length/2..+length/2 in
            // shardGroup-local. Offsetting the entity by +length/2 places
            // the mesh's BASE at shardGroup-local y=0 (cluster center) and
            // the TIP at shardGroup-local y=length. When breath scales the
            // group along Y, this arrangement extends the tip outward
            // while the base stays anchored — the HTML stretch-from-base
            // behaviour. (Unchanged from the unique-mesh era; the
            // position-offset formula uses the desired post-scale length.)
            shardEnt.position = [0, length / 2, 0]
            shardEnt.components.set(OpacityComponent(opacity: 0))

            // --- Beam: halo (colored envelope) + core (white-hot filament) ---
            // Both additive. Scaled up alongside shards (~2.7×) so beams
            // reach well beyond the new pulled-back camera position
            // (~2.0-2.4 from origin) — gives HTML's "beams streaming
            // off-screen on all edges" while leaving the camera deep
            // inside the beam shell.
            let beamLength = 2.5 + frame.loudness * 4.0
            // With the base-anchored shardGroup layout, the shard tip sits
            // at shardGroup-local y = length. The beam attaches at the tip
            // and extends outward by `beamLength`, so its midpoint is at
            // y = length + beamLength/2.
            let beamCenterY = length + beamLength / 2

            // Halo: HTML radius 0.13–0.22 (top→bottom) vs core 0.03–0.05.
            // Tapered: wider at base (shard tip side), narrower at far end —
            // gives beams a directional ray-shape rather than uniform tube.
            // Scaled 1.5× along with the rest of the cluster. The halo
            // top:bottom ratio mirrors HTML's 0.13/0.22 ≈ 0.59.
            // Halo radius scaled up alongside beams (~1.6×). Doesn't need
            // to scale linearly with the beam-length 2.7× factor — angular
            // size from the new camera distance keeps halos reading as
            // soft translucent columns at this radius, and going wider
            // makes them blur into each other at the convergence.
            let haloBottom: Float = 0.040 + frame.loudness * 0.030
            let haloTop: Float = haloBottom * 0.59
            // shardGroup-local Y points outward along the shard direction —
            // the beam's "+Y end" (top) is the FAR end (away from origin).
            // We want narrower-far, wider-near, so topRadius < bottomRadius.
            // Shared canonical beam mesh — see palette comment block. The
            // canonical mesh has taper ratio 0.59 (= haloTop/haloBottom);
            // the core's 0.60 ratio is close enough that the same mesh
            // serves both, with per-spawn (rx, ly, rz) scale giving each
            // its actual dimensions. `_ = haloTop` keeps the legacy
            // top-radius derivation visible to readers comparing against
            // the HTML reference; not used at scale time.
            _ = haloTop
            let haloMesh = Self.sharedBeamMesh()
            // No HDR boost on the halo — matches HTML which renders halos at
            // SDR brightness 0.85 with additive blending. Previously 1.6
            // boost made halos compete with the cores' brightness; under
            // CIBloom the halo would smear into a wide colored haze that
            // obscured the thin white-hot core filament inside. With
            // SDR-bright halos the cores stay readable as distinct rods
            // running through each beam's colored envelope (HTML's look).
            let haloColor = PlatformColor.hdrColor(
                hue: hue, saturation: 0.95, brightness: 0.85, hdrBoost: 1.0
            )
            var haloMaterial = UnlitMaterial(program: additiveProgram)
            haloMaterial.color = .init(tint: haloColor)
            // No depth write — coaxial halo + core were Z-fighting at the
            // render framerate, causing visible per-frame flicker on the
            // white-hot rod (too fast for screenshot bursts at <16Hz to
            // catch). Matches HTML's `depthWrite: false` on both beam
            // materials. Additive blending also doesn't need depth write —
            // contributions sum regardless of order.
            haloMaterial.writesDepth = false
            guard let haloEnt = Self.child(shardGroup, .halo) else { return }
            haloEnt.model?.mesh = haloMesh
            haloEnt.model?.materials = [haloMaterial]
            let haloRadialScale = haloBottom / canonicalBeamBottomRadius
            haloEnt.scale = SIMD3<Float>(
                haloRadialScale,
                beamLength / canonicalBeamLength,
                haloRadialScale
            )
            haloEnt.position = [0, beamCenterY, 0]
            haloEnt.components.set(OpacityComponent(opacity: 0))

            // Core: thin near-white-hot filament inside the halo. HDR
            // boost 1.5 — enough to drive optical bloom on visionOS and
            // push above CIBloom's bright-pixel threshold on macOS so the
            // rod stays distinct from the halo, but quiet enough that the
            // pale-white look matches HTML's reference (which has no HDR
            // amplification at all). Lower values (1.0) made cores too
            // subtle; higher values (2.0+) overshot HTML's brightness.
            // Core also tapers — HTML's 0.03/0.05 = 0.6 top:bottom ratio.
            // Core radius scaled up ~1.7× alongside the rest.
            let coreBottom: Float = 0.008 + frame.loudness * 0.005
            // Core's natural top:bottom is 0.6; canonical beam mesh tapers
            // 0.59. Visually indistinguishable. `_ = coreTop` retained for
            // parity with the halo block above (legacy derivation marker).
            let coreTop: Float = coreBottom * 0.6
            _ = coreTop
            let coreMesh = Self.sharedBeamMesh()
            let coreColor = PlatformColor.hdrColor(
                hue: hue, saturation: 0.30, brightness: 1.0, hdrBoost: 1.5
            )
            var coreMaterial = UnlitMaterial(program: additiveProgram)
            coreMaterial.color = .init(tint: coreColor)
            coreMaterial.writesDepth = false
            guard let coreEnt = Self.child(shardGroup, .core) else { return }
            coreEnt.model?.mesh = coreMesh
            coreEnt.model?.materials = [coreMaterial]
            let coreRadialScale = coreBottom / canonicalBeamBottomRadius
            coreEnt.scale = SIMD3<Float>(
                coreRadialScale,
                beamLength / canonicalBeamLength,
                coreRadialScale
            )
            coreEnt.position = [0, beamCenterY, 0]
            coreEnt.components.set(OpacityComponent(opacity: 0))
    }
}
