//
//  CloudVisualizer.swift
//  High Videlity
//
//  Clouds — the ambient/passive visualizer mode. Soft glowing colour orbs
//  drifting in dark space; the HTML reference builds them from 5 main
//  sprites on slow lissajous orbits, 8 detail sprites that fade in with
//  harmonic complexity, and 1 central core. Each sprite is a camera-facing
//  quad with an alpha-blended radial-glow texture, tinted per audio
//  features.
//
//  Increment 4 (current): full audio reactivity. Drift, spring-back onset
//  perturbations, per-sprite HSB colour from a lagged FeatureFrame, size
//  modulation by loudness + onset, detail-cloud visibility gated by
//  harmonic complexity.
//

import RealityKit
import AudioAnalysis
import simd
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-sprite component — tier + spring-perturbation state.
struct CloudComponent: Component {
    /// Tiers, in conceptual depth order: haze fills negative space behind the
    /// active layer, then main is the foreground colour orbs, detail is
    /// background sparkle gated on harmonic complexity, core is the anchor.
    enum Tier { case haze, main, detail, core }
    var tier: Tier
    var indexInTier: Int
    /// Spring displacement (offset from the lissajous position), world-space.
    var perturb: SIMD3<Float> = .zero
    /// Spring velocity.
    var perturbVel: SIMD3<Float> = .zero
}

/// Per-scene state — tracks the global drift phase, last-visited audio frame
/// (for onset edge detection), and smoothed energies. Lives on the root.
struct CloudSceneComponent: Component {
    var driftPhase: Double = 0
    var lastIndex: Int = -1
    var lastMicOnsetCount: Int = 0
    var eLoud: Float = 0
    var eTimbre: Float = 0
    var eComplex: Float = 0
    var onsetKick: Float = 0
    /// `appModel.liveModeResetCounter` value at the most-recent animate
    /// tick. When AppModel bumps it (Shazam track-change reset),
    /// `animate` notices on the next tick, drops per-song state
    /// (lastIndex, onsetKick, sprite spring perturbations) and seeds
    /// lastIndex to current frames.count - 1 so we don't replay the
    /// pre-reset frames' onsets. Smoothed energies aren't reset —
    /// they re-converge to the new song's values in ~1s.
    var lastSeenResetCounter: Int = 0
}

enum CloudVisualizer {

    // MARK: - World scale
    //
    // HTML composition: clouds cluster near origin; camera at z=18 looks at
    // the clump — so the WHOLE cluster fills the FOV and the clouds overlap
    // into a continuous wash. The earlier AVP layout put clouds on a sphere
    // AROUND the viewer, so looking one direction only revealed 1-3 isolated
    // orbs. Cluster the clouds in a small volume in FRONT of the viewer to
    // recover the HTML composition.
    private static let eyeHeight: Float = 1.45
    /// Centre of the cloud cluster, in front of and at eye-height with the viewer.
    private static let cloudCenter = SIMD3<Float>(0, eyeHeight, -1.5)
    // Orbits and counts match the HTML reference's composition:
    //   • 5 main + 8 detail clouds (HTML); plus our extra haze layer that
    //     stands in for HTML's THREE.Fog (RealityKit doesn't expose linear
    //     fog from a SwiftUI RealityView).
    //   • Orbits bumped 30% from initial values to spread the cluster
    //     further into the corners of the viewport — visually the cluster
    //     was still hugging the center with the original ratio because the
    //     implicit RealityViewCameraContent camera's FOV is narrower than
    //     HTML's 62°. Wider orbits effectively widen the apparent cluster.
    private static let mainOrbitR: Float   = 1.3
    private static let detailOrbitR: Float = 1.8
    private static let hazeOrbitR: Float   = 2.0
    private static let mainCount   = 5
    private static let detailCount = 8
    private static let hazeCount   = 6
    // Sprite sizes tuned to match the HTML reference's sprite/orbit ratio.
    // HTML main sprites scale 9-17 at orbit R=7.5 → 1.2-2.27× orbit. With
    // mainOrbitR=1.3, mainSize=1.5 puts us at ratio 1.15 baseline, ~1.8
    // at peak loudness (× scaleMul) — matching HTML. Previous mainSize=1.0
    // gave ratio 0.77, which made individual clouds look smaller than HTML
    // even though the cluster spread the same.
    private static let mainSize: Float    = 1.5
    private static let detailSize: Float  = 0.6
    private static let coreSize: Float    = 0.30
    private static let hazeSize: Float    = 1.30        // big, soft, diffuse
    private static let mainOpacity: Float = 0.72
    private static let coreOpacity: Float = 0.85
    private static let hazeOpacity: Float = 0.22        // very dim — only visible in overlap
    // Was 0.02 — a hard gate that made detail sprites pop in/out at quiet
    // sections. Now always-visible (threshold 0); the opacity formula
    // (1.6 × eComplex, capped at 0.7) already scales them down smoothly
    // at low complexity, so they fade rather than disappear.
    private static let detailComplexityThreshold: Float = 0
    /// HDR boost factor on the main cloud tint. RGB values above 1.0 in
    /// extended sRGB drive the AVP display past SDR white; on micro-OLED
    /// HDR pixels naturally bloom optically. Dialed down (was 1.6 / 1.9)
    /// now that BloomPostProcessEffect does real CIBloom — keeping the
    /// boost high too made the core overdrive into a single hot spot.
    /// visionOS keeps its native optical-bloom story (no CIBloom there);
    /// these values are shared with that path so on AVP the boost is gentler
    /// than before but the optical falloff still works. If visionOS needs
    /// more punch back, split this into per-platform constants.
    private static let mainHDRBoost: CGFloat = 1.2
    private static let coreHDRBoost: CGFloat = 1.2
    /// Per-onset velocity scale, picked so peak spring displacement is ~25%
    /// of the orbital radius on a hard hit (not the old radius-relative
    /// scaling, which became too gentle as we shrank the orbits).
    private static let perturbScale: Float = 0.12

    /// HTML's spring constants — preserved as-is. Dimensionless.
    private static let springK: Float = 22
    private static let springD: Float = 5.5

    // MARK: - Build

    /// Build the cloud sprite pool.
    ///
    /// `startingFrameIndex` and `startingResetCounter` configure live-mode
    /// state seeding. Defaults preserve preview-mode behavior:
    ///  • `startingFrameIndex: 0` → `lastIndex = -1`, animate walks every
    ///    frame from the start and fires every preview onset. Correct for
    ///    cached-preview playback.
    ///  • In macOS live system-audio mode, callers pass `appModel.frames.count`
    ///    so `lastIndex = frames.count - 1` and the first animate tick walks
    ///    only frames that arrive AFTER view-open — avoids a "replay the
    ///    last 60 seconds of onsets in a single render frame" burst that
    ///    would spring-kick every main sprite hundreds of times. Mirrors
    ///    the `makeCrystalLive(startingFrameIndex:)` pattern.
    static func makeClouds(
        from frames: [FeatureFrame],
        startingFrameIndex: Int = 0,
        startingResetCounter: Int = 0
    ) -> Entity {
        let root = Entity()
        var scene = CloudSceneComponent()
        // lastIndex = "last frame index already processed for onsets."
        // startingFrameIndex of 0 (preview) → lastIndex = -1 → walk 0...i.
        // startingFrameIndex of frames.count (live) → lastIndex = count-1 → skip.
        scene.lastIndex = startingFrameIndex - 1
        scene.lastSeenResetCounter = startingResetCounter
        root.components.set(scene)
        let texture = makeGlowTexture()

        // Haze layer — large, very-dim, low-saturation sprites that fill the
        // negative space between main clouds with a slow-drifting coloured
        // fog. The in-engine bloom approximation: individually they're too
        // dim to read, but their overlap with each other and the main clouds
        // suffuses the cluster's interior with diffuse light.
        for i in 0..<hazeCount {
            let sprite = makeSprite(
                texture: texture, size: hazeSize, opacity: hazeOpacity,
                hue: CGFloat(i) / CGFloat(hazeCount)
            )
            sprite.position = hazePosition(i: i, driftPhase: 0)
            sprite.components.set(CloudComponent(tier: .haze, indexInTier: i))
            root.addChild(sprite)
        }

        // Main clouds.
        for i in 0..<mainCount {
            let sprite = makeSprite(
                texture: texture, size: mainSize, opacity: mainOpacity,
                hue: CGFloat(i) / CGFloat(mainCount)
            )
            sprite.position = mainPosition(i: i, driftPhase: 0)
            sprite.components.set(CloudComponent(tier: .main, indexInTier: i))
            root.addChild(sprite)
        }
        // Detail clouds.
        for i in 0..<detailCount {
            let sprite = makeSprite(
                texture: texture, size: detailSize, opacity: 0.55,
                hue: CGFloat(i) / CGFloat(detailCount)
            )
            sprite.position = detailPosition(i: i, driftPhase: 0)
            sprite.components.set(CloudComponent(tier: .detail, indexInTier: i))
            root.addChild(sprite)
        }
        // Central core — at the heart of the cluster.
        let core = makeSprite(
            texture: texture, size: coreSize, opacity: coreOpacity,
            hue: 0.6
        )
        core.position = cloudCenter
        core.components.set(CloudComponent(tier: .core, indexInTier: 0))
        root.addChild(core)

        return root
    }

    // MARK: - Animate

    /// Advances drift, applies onset perturbations, and updates sprite
    /// positions. Reads the FeatureFrame timeline directly so it can detect
    /// onset edges between the previous and current playback indices.
    /// When `useMic` is true, `micOnsetCount` is consulted instead of the
    /// frame timeline for onset firing — each increment fires one spring
    /// kick. Liveness from real audio without re-synthesizing the timeline.
    static func animate(_ root: Entity,
                        clock: Double,
                        frames: [FeatureFrame],
                        deltaTime: Double,
                        liveLoudness: Float = -1,
                        micOnsetCount: Int = 0,
                        useMic: Bool = false,
                        appResetCounter: Int = -1) {
        guard !frames.isEmpty,
              var scene = root.components[CloudSceneComponent.self] else { return }

        // Track-change reset (live mode only): AppModel bumps
        // `liveModeResetCounter` when Shazam detects a new song. We drop
        // per-song state but keep the sprite pool — Clouds doesn't spawn
        // entities, so the existing sprites just need to forget that they
        // were mid-perturbation from the previous song's last onset.
        //
        // Seed lastIndex to `frames.count - 1` (not 0) for the same reason
        // CrystalVisualizerV2 does: between the reset firing and this tick
        // running, the polling task may have already drained 20-30 new
        // frames with onsets. Setting to 0 would replay them all in this
        // single tick — same "frontloaded onset burst" problem.
        // appResetCounter < 0 means "caller didn't pass it" → skip the check
        // (preview-only mode where the counter isn't meaningful).
        if appResetCounter >= 0 && appResetCounter != scene.lastSeenResetCounter {
            scene.lastIndex = max(-1, frames.count - 1)
            scene.onsetKick = 0
            scene.lastSeenResetCounter = appResetCounter
            // Reset main-cloud spring state — otherwise a sprite still
            // ringing from the prior song's final onset keeps swinging
            // into the new song.
            for sprite in root.children
                where sprite.components[CloudComponent.self]?.tier == .main
            {
                guard var cc = sprite.components[CloudComponent.self] else { continue }
                cc.perturb = .zero
                cc.perturbVel = .zero
                sprite.components.set(cc)
            }
        }

        let dt = Float(min(0.1, deltaTime))         // clamp to keep spring stable
        let FPS = 30.0
        let i = max(0, min(frames.count - 1, Int((clock * FPS).rounded())))
        let f = frames[i]

        // Smooth energies — mirror HTML rates (×5, ×4, ×3 per second). In
        // mic mode, `liveLoudness` overrides the frame's loudness so the
        // visualizer's "energy" tracks the room's audio. Timbre + complexity
        // still come from the timeline (mic alone can't derive them cheaply).
        let loudnessInput: Float = (useMic && liveLoudness >= 0) ? liveLoudness : f.loudness
        scene.eLoud    += (loudnessInput              - scene.eLoud)    * min(1, dt * 5)
        scene.eTimbre  += (f.timbreBrightness         - scene.eTimbre)  * min(1, dt * 4)
        scene.eComplex += (f.harmonicComplexity       - scene.eComplex) * min(1, dt * 3)

        // Advance the global drift accumulator. Speed scales with loudness so
        // quiet sections feel slower and drowsier than loud ones.
        scene.driftPhase += Double(dt) * (0.35 + Double(scene.eLoud) * 2.0)

        // HTML's per-onset energy expression — capped at 1, floored at 0.25.
        let energy: Float = 0.25 + min(1, scene.eLoud * 2.6)

        // Onsets — either from the analyzed timeline (when playing the
        // loaded song internally) or from the mic counter (when listening
        // to external audio). Each triggers the same spring-kick reaction
        // on the main clouds.
        let mainSprites = root.children.filter {
            $0.components[CloudComponent.self]?.tier == .main
        }
        func fireOnset() {
            scene.onsetKick = min(1.6, scene.onsetKick + 0.8 * energy)
            for sprite in mainSprites {
                guard var cc = sprite.components[CloudComponent.self] else { continue }
                let dir = randomUnitVector()
                let mag = (3 + Float.random(in: 0..<5)) * energy * perturbScale
                cc.perturbVel += dir * mag
                sprite.components.set(cc)
            }
        }
        if useMic {
            let newMicOnsets = max(0, micOnsetCount - scene.lastMicOnsetCount)
            // Cap per-frame onset bursts so a flurry of mic detections (which
            // can happen on a sudden loud transient) doesn't compound into a
            // visible "explosion" of the cluster.
            for _ in 0..<min(newMicOnsets, 3) { fireOnset() }
            scene.lastMicOnsetCount = micOnsetCount
        } else if i > scene.lastIndex {
            for k in (scene.lastIndex + 1)...i where frames[k].onset {
                fireOnset()
            }
        }
        scene.lastIndex = i

        // Onset-kick exponential decay.
        scene.onsetKick += -scene.onsetKick * min(1, dt * 4.5)

        // HTML's lag spacing: clouds chase the current frame's colour from
        // further behind when the song is loud (more vivid colour layering).
        let colorSpread: Float = 0.15 + energy * 0.5

        for sprite in root.children {
            guard var cc = sprite.components[CloudComponent.self],
                  var modelComp = sprite.components[ModelComponent.self],
                  var mat = modelComp.materials[0] as? UnlitMaterial else { continue }

            // --- Position (spring + drift) ---------------------------------
            switch cc.tier {
            case .main:
                cc.perturbVel += (-springK * cc.perturb - springD * cc.perturbVel) * dt
                cc.perturb    += cc.perturbVel * dt
                sprite.position = mainPosition(i: cc.indexInTier,
                                               driftPhase: scene.driftPhase) + cc.perturb
            case .detail:
                sprite.position = detailPosition(i: cc.indexInTier,
                                                 driftPhase: scene.driftPhase)
            case .haze:
                sprite.position = hazePosition(i: cc.indexInTier,
                                               driftPhase: scene.driftPhase)
            case .core:
                break
            }

            // --- Audio-driven colour + size + opacity ----------------------
            let cf: FeatureFrame
            let v: Float
            let sat: Float
            let scaleMul: Float
            let opacity: Float
            var visible = true

            // Saturation cap matches the HTML reference's "pastel through
            // fog" feel — HTML's THREE.Fog desaturates rendered pixels by
            // mixing them toward 0xd4d8de. We approximate that desaturation
            // both at the source (this cap) and in the post-process (fog
            // wash in BloomPostProcessEffect). Pulled down from 0.78 after
            // direct visual diff against the HTML showed our colours read
            // as "candy" while HTML's read as "haze".
            let satCap: Float = 0.55
            let vCap: Float   = 0.95

            switch cc.tier {
            case .main:
                let lag = Float(cc.indexInTier) * colorSpread
                cf = laggedFrame(frames, clock: clock, lag: lag)
                sat = min(satCap, 0.30 + cf.loudness * 2.2)
                v   = min(vCap, 0.34 + Float(cf.color.saturation) * 1.7
                            + Float(cf.color.brightness) * 0.18
                            + scene.eTimbre * 0.12
                            + scene.onsetKick * 0.05)
                scaleMul = (1 + min(1, scene.eLoud * 3.5) * 0.55)
                         * (1 + scene.onsetKick * 0.12)
                opacity = mainOpacity

            case .detail:
                visible = scene.eComplex > detailComplexityThreshold
                let lag = Float(cc.indexInTier) * 0.22
                cf = laggedFrame(frames, clock: clock, lag: lag)
                sat = min(satCap, 0.30 + cf.loudness * 2.2)
                v   = min(vCap, 0.45 + Float(cf.color.saturation) * 1.6)
                scaleMul = 1 + min(1, scene.eLoud * 3.0) * 0.53
                // HTML uses 0.62 * eComplex — boost factor compensates if
                // Swift's HarmonicComplexity tops out lower than JS's.
                opacity = min(0.7, 1.6 * scene.eComplex)

            case .core:
                cf = f
                sat = min(satCap, 0.30 + scene.eLoud * 2.2)
                v   = min(vCap, 0.6 + scene.eTimbre * 0.38)
                scaleMul = (1 + min(1, scene.eLoud * 3.5) * 1.5)
                         * (1 + scene.onsetKick * 0.10)
                opacity = coreOpacity

            case .haze:
                // Haze pulls colour from a LONG lag — each haze sprite carries
                // a colour from several seconds earlier, so the fog drifts
                // hue-wise behind the active foreground. Low saturation and
                // mid brightness keep it as a soft fog rather than a focal
                // point.
                let lag = 0.6 + Float(cc.indexInTier) * 0.35
                cf = laggedFrame(frames, clock: clock, lag: lag)
                sat = 0.35                                  // intentionally low — atmospheric
                v   = min(vCap, 0.55 + Float(cf.color.brightness) * 0.25)
                scaleMul = 1.0
                opacity = hazeOpacity
            }

            sprite.isEnabled = visible
            sprite.scale = SIMD3<Float>(repeating: scaleMul)
            // Main + core get HDR boost; haze and detail stay SDR (they're
            // supposed to be soft/subtle and would lose that with HDR push).
            let hdrBoost: CGFloat
            switch cc.tier {
            case .main:   hdrBoost = mainHDRBoost
            case .core:   hdrBoost = coreHDRBoost
            case .detail: hdrBoost = 1.0
            case .haze:   hdrBoost = 1.0
            }
            let tint = PlatformColor.hdrColor(
                hue: CGFloat(cf.color.hue),
                saturation: CGFloat(sat),
                brightness: CGFloat(v),
                hdrBoost: hdrBoost
            )
            mat.color = .init(tint: tint, texture: mat.color.texture)
            mat.blending = .transparent(opacity: .init(floatLiteral: opacity))
            modelComp.materials[0] = mat

            sprite.components.set(cc)
            sprite.components.set(modelComp)
        }

        root.components.set(scene)
    }

    /// Reads the FeatureFrame at `clock - lag` (clamped to the clip range).
    private static func laggedFrame(_ frames: [FeatureFrame],
                                    clock: Double, lag: Float) -> FeatureFrame {
        let t = max(0, clock - Double(lag))
        let i = max(0, min(frames.count - 1, Int((t * 30).rounded())))
        return frames[i]
    }

    // MARK: - Positions

    static func mainPosition(i: Int, driftPhase: Double) -> SIMD3<Float> {
        let m = Double(i)
        let r = Double(mainOrbitR)
        let x = r       * sin(driftPhase * (0.12 + 0.03 * m) + m * 1.7)
        let y = r * 0.7 * sin(driftPhase * (0.10 + 0.035 * m) + m * 2.3)
        let z = r       * sin(driftPhase * (0.09 + 0.025 * m) + m * 0.9)
        return cloudCenter + SIMD3<Float>(Float(x), Float(y), Float(z))
    }

    static func detailPosition(i: Int, driftPhase: Double) -> SIMD3<Float> {
        let d = Double(i)
        let r = Double(detailOrbitR)
        let x = r       * sin(driftPhase * (0.30 + 0.07 * d) + d * 2.1)
        let y = r * 0.8 * sin(driftPhase * (0.26 + 0.06 * d) + d * 1.3)
        let z = r       * cos(driftPhase * (0.28 + 0.05 * d) + d * 0.7)
        return cloudCenter + SIMD3<Float>(Float(x), Float(y), Float(z))
    }

    /// Haze drifts SLOWLY — its motion shouldn't compete with the main
    /// clouds. Larger orbital radius so the haze can extend outside the main
    /// cluster's bounds, suffusing colour into the space around it.
    static func hazePosition(i: Int, driftPhase: Double) -> SIMD3<Float> {
        let h = Double(i)
        let r = Double(hazeOrbitR)
        let x = r       * sin(driftPhase * 0.08 + h * 1.7)
        let y = r * 0.6 * sin(driftPhase * 0.06 + h * 2.3)
        let z = r       * sin(driftPhase * 0.07 + h * 0.9)
        return cloudCenter + SIMD3<Float>(Float(x), Float(y), Float(z))
    }

    // MARK: - Helpers

    /// Uniformly-distributed point on the unit sphere (HTML's
    /// `Math.acos(2*Math.random()-1)` trick).
    private static func randomUnitVector() -> SIMD3<Float> {
        let th = Float.random(in: 0..<(2 * .pi))
        let cosPh = Float.random(in: -1..<1)
        let sinPh = sqrt(max(0, 1 - cosPh * cosPh))
        return SIMD3<Float>(sinPh * cos(th), sinPh * sin(th), cosPh)
    }

    private static func makeSprite(
        texture: TextureResource, size: Float, opacity: Float, hue: CGFloat
    ) -> ModelEntity {
        var material = UnlitMaterial()
        let tint = PlatformColor(hue: hue, saturation: 0.75, brightness: 1.0, alpha: 1.0)
        material.color = .init(tint: tint, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        #if !os(visionOS)
        // Suppress quad-edge occlusion between overlapping transparent
        // sprites (the HTML's `depthWrite: false` trick). Without this,
        // each sprite's full quad writes depth even where the alpha is
        // zero, so a smaller sprite passing through a bigger one shows a
        // hard rectangular edge where the smaller quad's depth wins.
        // Now that iterations 1-3 enlarged sprites and made them overlap
        // heavily, this artifact is much more visible than it was.
        //
        // Skipped on visionOS — earlier testing inside an immersive space
        // alongside a SwiftUI window made clouds outside the window's
        // screen-space bounds disappear. The non-visionOS windowed view
        // doesn't have that constraint.
        material.writesDepth = false
        #endif

        let mesh = MeshResource.generatePlane(width: size, height: size)
        let sprite = ModelEntity(mesh: mesh, materials: [material])
        sprite.components.set(BillboardComponent())
        return sprite
    }

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
        // Gentler falloff than 0.88/0.40/0 — the steeper version produced a
        // visible "hot spot" boundary where the HDR-boosted centre crossed
        // back into in-gamut alpha. Smooth the curve so the brightness
        // gradient is continuous instead of stepping at the SDR ceiling.
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.88),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
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
            withName: "cloud-glow",
            options: .init(semantic: .color)
        )
    }
}
