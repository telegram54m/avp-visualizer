//
//  FractalVisualizer.swift
//  High Videlity
//
//  Real-time Julia-set fractal rendered via a Metal compute kernel
//  into a LowLevelTexture, then sampled by a RealityKit UnlitMaterial
//  on a plane in front of the viewer. Audio-reactive uniforms walk
//  the Julia c parameter around an interesting point, drive zoom +
//  iteration depth from loudness, and palette hue from chromagram.
//
//  Why Metal compute (not MaterialX): MaterialX shader graphs are a
//  static DAG — no loops, no per-pixel iteration. Fractals
//  fundamentally need a `for k in 0..<N { z = z² + c; ... }` loop
//  with escape detection, so we can't express them as a shader
//  graph. The Metal compute kernel approach renders the fractal
//  off the RealityKit render path, writes to a LowLevelTexture,
//  and RealityKit samples that texture each frame from a regular
//  UnlitMaterial.
//
//  Architecture:
//    • root entity (FractalRootComponent — Metal state + uniforms)
//      └─ display plane (ModelEntity holding the LLT-backed material)
//
//  Per-frame flow in `animate`:
//    1. Sample current FeatureFrame + stems to compute uniforms
//    2. Encode kernel dispatch into a command buffer
//    3. LLT.replace(using: cmd) returns the writable MTLTexture
//    4. Commit (no wait — overlap with next CPU tick)
//    5. RealityKit picks up the new texture content automatically
//
//  Performance: 1024×1024 RGBA at ~80 iters per pixel comfortable on
//  modern Apple GPUs (M-series + A15+). If the LLT updates aren't
//  keeping pace we drop the kernel rate (see `kernelUpdateInterval`)
//  or shrink the texture resolution.
//

import Foundation
import Metal
import RealityKit
import RealityKitContent
import AudioAnalysis
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-pixel constant struct passed to the Metal kernel as a buffer.
/// MUST match `FractalUniforms` in the kernel source string below.
private struct FractalUniforms {
    var cParam: SIMD2<Float>        // Julia c (set walks around this)
    var viewCenter: SIMD2<Float>    // pan offset in fractal space
    var zoom: Float                 // scale factor (higher = closer)
    var iterationCount: Float       // max iterations (16-256)
    var paletteHue: Float           // 0..1, hue offset for color palette
    var paletteShift: Float         // 0..1, additional hue rotation
    var aspect: Float               // width/height of texture
    var time: Float                 // seconds, for any time-based modulation
    var vocalsHue: Float            // secondary hue from vocals chromagram
    var vocalsMix: Float            // 0..1 how much vocals hue blends in
    var drumPulse: Float            // 0..1 envelope; brightness + zoom kick
    var rotation: Float             // UV rotation in radians (continuous drift)
    var paletteCycle: Float         // additive offset on per-pixel palette index — escape bands flow
    var domainWarp: Float           // amplitude of noise-based UV displacement (drum-pulse driven)
    var bassBreath: Float           // subtle UV-zoom modulation on bass beats
}

/// Holds Metal pipeline state + LowLevelTexture handle. Class-typed
/// because MTL objects + LowLevelTexture are reference-counted; we
/// want all parts of the visualizer to share the same instances.
@MainActor
final class FractalMetalState {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource
    let textureWidth: Int
    let textureHeight: Int

    /// Smoothed audio state for the kernel uniforms. Lives here rather
    /// than on RealityKit's @Observable AppModel so per-tick uniform
    /// updates don't churn SwiftUI invalidation [[feedback_observable-frames-fps-leak]].
    var smoothedBassLoudness: Float = 0
    var smoothedOtherLoudness: Float = 0
    var smoothedSongIntensity: Float = 0
    var smoothedHueIndex: Float = 0
    var smoothedVocalsLoudness: Float = 0
    var smoothedVocalsHue: Float = 0
    /// Drum-onset envelope. Bumped on each drum onset, exponential
    /// decay between hits. Drives the zoom-pulse + brightness kick
    /// in the kernel.
    var drumPulse: Float = 0
    /// Continuously-advancing phase for the c-parameter drift —
    /// makes the fractal morph even on quiet sustained passages.
    var cPhase: Float = 0
    /// Accumulated yaw + tumble angles for the cube rotation.
    /// Stored across frames so `animate` can compose them into a
    /// fresh quaternion each tick (rather than incrementally
    /// composing, which would drift due to quaternion error
    /// accumulation).
    var cubeYaw: Float = 0
    var cubeTumble: Float = 0
    var lastFrameIndex: Int = -1
    var elapsedTime: Float = 0
    var firstTick: Bool = true

    init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        lowLevelTexture: LowLevelTexture,
        textureResource: TextureResource,
        textureWidth: Int,
        textureHeight: Int
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.lowLevelTexture = lowLevelTexture
        self.textureResource = textureResource
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
    }
}

/// Marker component on the fractal root; carries the Metal state.
/// Component requires Sendable conformance through RealityKit's ECS —
/// the @MainActor confinement on FractalMetalState makes this safe.
struct FractalRootComponent: Component {
    /// Reference to the Metal state. Stored as a reference so multiple
    /// component reads share the same MTL pipeline + texture.
    let state: FractalMetalState
}

/// Marker for the rotating cube child of the fractal root. Located
/// each tick via `root.children.first(where:)` so `animate` can
/// apply the accumulated yaw + tumble rotation.
struct FractalCubeComponent: Component {}

@MainActor
enum FractalVisualizer {

    // MARK: - Tuning constants

    /// Compute kernel output texture resolution. 1024² gives a clean
    /// detailed fractal on a 4K display without being wasteful. Drop
    /// to 512² if perf becomes an issue.
    static let textureWidth: Int = 1024
    static let textureHeight: Int = 1024

    /// Cube edge length + distance in world units. Cube spins
    /// around Y axis + a slower X tumble so different faces face
    /// the camera over time, each showing the same LLT texture.
    /// Distance 2.6m so the cube subtends a comfortable portion
    /// of the frame without clipping at the corners when rotating.
    static let cubeEdge: Float = 1.8
    static let cubeDistance: Float = 2.6
    static let cubeYOffset: Float = 0.0
    /// Cube rotation rates (radians/sec). Y is the primary axis;
    /// X tumble is slower so the visual reads as "a cube turning"
    /// rather than chaotic tumble.
    static let cubeYawRate: Float = 0.35
    static let cubeTumbleRate: Float = 0.13
    /// Bass-loudness boost applied to both rotation rates. Picked
    /// modest so bass moments accelerate the spin noticeably
    /// without going wild.
    static let cubeBassRotationBoost: Float = 1.2

    /// `c` is now walked along the Mandelbrot main cardioid boundary
    /// (see the c computation in `animate`) — every point on that
    /// boundary produces a dendritic Julia set. We don't have a
    /// "baseCparam + radial walk" anymore because that approach kept
    /// crossing INTO the cardioid where Julia sets are connected
    /// "filled" blobs. The boundary curve guarantees dendritic
    /// patterns at every t. Kept as a constant only for the default
    /// uniforms (initial frame before the first animate tick).
    static let baseCparam = SIMD2<Float>(-0.75, 0.0)

    /// EMA lerp rates for the smoothed state variables. All in Hz.
    static let bassLoudnessLerpRate: Float = 3.0
    static let otherLoudnessLerpRate: Float = 4.0
    static let songIntensityLerpRate: Float = 0.2  // very slow — chorus arc
    static let hueIndexLerpRate: Float = 1.5
    static let vocalsLoudnessLerpRate: Float = 4.0
    static let vocalsHueLerpRate: Float = 2.0

    /// Drum-pulse envelope: bumped this much on each drum onset
    /// (clamped to 1.0), decays with the half-life below. Drives
    /// zoom-pulse + brightness kick.
    static let drumPulseBump: Float = 0.6
    static let drumPulseHalfLife: Float = 0.30  // seconds

    /// Cardioid-traversal phase rate (radians/sec) — how fast c walks
    /// along the Mandelbrot main cardioid boundary. 0.06 rad/s gives
    /// a full traversal in ~105 seconds (longer than a typical song
    /// section, so each chord change happens against a slow morphing
    /// fractal backdrop). Bass loudness adds on top so bass-heavy
    /// passages morph faster.
    static let cDriftRate: Float = 0.06
    /// Drum-onset off-boundary kick. On a drum hit, c is briefly
    /// pushed perpendicular to the boundary tangent by this amount,
    /// which moves it just OUTSIDE the cardioid into "dust"/disconnected
    /// Julia territory — a visible momentary change of fractal
    /// character that decays as the drum pulse decays.
    static let cDrumKickAmplitude: Float = 0.045

    /// UV rotation drift rate (radians/sec). Adds a slow continuous
    /// camera-style turn so the fractal never reads as static even
    /// at song-stoppage.
    static let uvRotationRate: Float = 0.025

    // MARK: - Metal source (kernel as a Swift string)
    //
    // Kept inline so we don't have to add a .metal file to the
    // project (which would require updating the .pbxproj). The
    // library is compiled at app launch via
    // `device.makeLibrary(source:options:)` — that's a few hundred
    // ms one-shot cost, but only on the first build of the
    // visualizer per session.

    private static let kernelSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct FractalUniforms {
        float2 cParam;
        float2 viewCenter;
        float zoom;
        float iterationCount;
        float paletteHue;
        float paletteShift;
        float aspect;
        float time;
        float vocalsHue;
        float vocalsMix;
        float drumPulse;
        float rotation;
        float paletteCycle;
        float domainWarp;
        float bassBreath;
    };

    // Small hash-based 2D noise. Cheap, good enough for organic UV
    // distortion. Smoothstepped between integer-grid samples.
    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    static float noise2D(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    // HSV → RGB. Standard reference implementation.
    static float3 hsv2rgb(float h, float s, float v) {
        h = fract(h);
        float c = v * s;
        float x = c * (1.0 - fabs(fmod(h * 6.0, 2.0) - 1.0));
        float m = v - c;
        float3 rgb;
        if      (h < 1.0/6.0) rgb = float3(c, x, 0);
        else if (h < 2.0/6.0) rgb = float3(x, c, 0);
        else if (h < 3.0/6.0) rgb = float3(0, c, x);
        else if (h < 4.0/6.0) rgb = float3(0, x, c);
        else if (h < 5.0/6.0) rgb = float3(x, 0, c);
        else                  rgb = float3(c, 0, x);
        return rgb + float3(m);
    }

    // Shortest-path circular hue lerp — handles the 0/1 wrap.
    static float lerpHue(float a, float b, float t) {
        float d = b - a;
        if (d > 0.5) d -= 1.0;
        if (d < -0.5) d += 1.0;
        float r = a + d * t;
        return fract(r + 1.0);
    }

    kernel void juliaKernel(
        texture2d<float, access::write> output [[texture(0)]],
        constant FractalUniforms& u            [[buffer(0)]],
        uint2 gid                              [[thread_position_in_grid]]
    ) {
        uint w = output.get_width();
        uint h = output.get_height();
        if (gid.x >= w || gid.y >= h) return;

        // Map pixel coords to fractal space. UV in [-1, 1] with
        // aspect correction so the fractal doesn't squish on
        // non-square textures.
        float2 uv = float2(gid) / float2(w - 1, h - 1);
        uv = uv * 2.0 - 1.0;
        uv.x *= u.aspect;

        // UV rotation (continuous slow drift). Rotates the entire
        // fractal sample plane so the visual reads as a camera
        // slowly turning over the pattern.
        float cs = cos(u.rotation);
        float sn = sin(u.rotation);
        uv = float2(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);

        // Domain warp — sample two scrolling noise fields and use
        // them as a small UV displacement. Drum onsets pump the
        // warp amplitude, so kicks visibly ripple the fractal.
        // Independent X/Y noise samples avoid axis-aligned
        // artifacts; scrolling at different rates breaks symmetry.
        float warpAmp = u.domainWarp;
        if (warpAmp > 0.0001) {
            float nx = noise2D(uv * 2.5 + float2(u.time * 0.13, 0.0)) - 0.5;
            float ny = noise2D(uv * 2.5 + float2(0.0, u.time * 0.17) + 7.0) - 0.5;
            uv += float2(nx, ny) * warpAmp;
        }

        // Drum pulse adds a brief zoom-in punch on each drum onset.
        // Combined with bass breath (slow zoom modulation on
        // smoothed bass loudness) for a continuous "alive" feel.
        float effectiveZoom = max(0.0001,
            u.zoom * (1.0 + u.drumPulse * 0.20 + u.bassBreath * 0.06));

        // Apply zoom + pan in fractal space.
        float2 z = uv / effectiveZoom + u.viewCenter;
        float2 c = u.cParam;

        int iterMax = int(clamp(u.iterationCount, 16.0, 256.0));
        int iter = 0;
        float zMagSq = 0.0;
        // Orbit-trap accumulators. Across all iterations of the
        // Julia orbit, track the MINIMUM distance to two reference
        // shapes:
        //   • the unit circle |z| = 1
        //   • the real axis (z.y = 0)
        // After iteration, these give every pixel — including
        // "interior" ones — a smooth distance value we can use for
        // rich coloring. The classic orbit-trap technique: turns
        // the fractal's flat interior into a textured landscape of
        // filaments tracing where orbits pass closest to the traps.
        float trapCircle = 1e10;
        float trapAxis = 1e10;
        for (int i = 0; i < iterMax; i++) {
            // z = z² + c   (complex multiply: (a+bi)² = a²-b² + 2abi)
            float2 zNew = float2(
                z.x * z.x - z.y * z.y + c.x,
                2.0 * z.x * z.y         + c.y
            );
            z = zNew;
            zMagSq = z.x * z.x + z.y * z.y;
            // Update orbit traps on every iteration. Tracking
            // continues past the escape threshold so even escaping
            // pixels retain trap information from their early
            // bouncing-around phase.
            trapCircle = min(trapCircle, fabs(sqrt(zMagSq) - 1.0));
            trapAxis = min(trapAxis, fabs(z.y));
            if (zMagSq > 4.0) { iter = i; break; }
            iter = i + 1;
        }

        // Interior pixels (didn't escape) — color by the orbit
        // traps so the interior has rich smooth texture instead of
        // a flat slab. Pixels whose orbit got close to the unit
        // circle become bright filaments; pixels whose orbit stayed
        // close to the real axis get a different tint. Combined,
        // the interior fills with a "veined" pattern that reveals
        // hidden structure of the iteration dynamics.
        if (iter >= iterMax) {
            // Convert min distances to brightness curves. Small
            // distance = bright (orbit got close to the trap).
            float circleGlow = exp(-trapCircle * 6.0);
            float axisGlow = exp(-trapAxis * 8.0);
            // Hue: blend between two trap-driven hues. Circle trap
            // = paletteHue + 0.35 (warm); axis trap = paletteHue
            // + 0.65 (cool). Drum pulse hue-shifts both.
            float trapHue = u.paletteHue + 0.35 + axisGlow * 0.30
                          + u.drumPulse * 0.20 + u.paletteCycle * 0.5;
            float trapBrightness = 0.05 + circleGlow * 0.55 + axisGlow * 0.35;
            float trapSat = 0.55 + circleGlow * 0.35;
            float3 interior = hsv2rgb(trapHue, trapSat, trapBrightness)
                              * (1.0 + u.drumPulse * 0.6);
            output.write(float4(interior, 1.0), gid);
            return;
        }

        // Smooth (continuous) iteration count — kills the visible
        // banding the integer iter count produces. Standard
        // escape-time fractional iteration formula.
        float log_zn = log(zMagSq) * 0.5;
        float nu = log(log_zn / log(2.0)) / log(2.0);
        float smoothIter = float(iter) + 1.0 - nu;
        float t = smoothIter / float(iterMax);

        // Map to palette. Cycle through circle-of-fifths hue space
        // 1.5× across the iteration domain so the bands are clear.
        // `paletteCycle` adds a time-based offset to t before the
        // hue computation — escape-iteration BANDS visibly flow
        // outward as the offset increases, giving the impression
        // of waves rippling through the fractal even when c is
        // stationary. Standard escape-time visualizer trick;
        // cheap and effective.
        float tCycled = t + u.paletteCycle;
        float baseHue = u.paletteHue + tCycled * 1.5 + u.paletteShift;
        // Mix in vocals hue when present — secondary tint that
        // crossfades over the bass-driven base palette.
        float hue = lerpHue(fract(baseHue),
                            fract(u.vocalsHue + tCycled * 0.7),
                            clamp(u.vocalsMix, 0.0, 0.6));
        float sat = 0.85;
        // Brightness ramps with t so the escape boundary glows
        // brightest. Drum pulse adds a flash.
        float val = (0.3 + 0.7 * sqrt(t)) * (1.0 + u.drumPulse * 0.40);

        // Orbit-trap filament boost — escape pixels whose orbits
        // passed close to the unit circle or real axis get a
        // brightness + saturation kick. Visually this creates
        // bright glowing "veins" running through the dendritic
        // detail, threading the interior structure into the
        // boundary structure as one continuous fabric.
        float circleFilament = exp(-trapCircle * 8.0);
        float axisFilament = exp(-trapAxis * 10.0);
        float filament = circleFilament + axisFilament * 0.6;
        val += filament * 0.35;
        val = min(val, 1.0);

        float3 rgb = hsv2rgb(hue, sat, val);
        // Slight extra glow tint on filaments (additive to the
        // already-mixed boundary color). Tied to the inverse-
        // complement of `hue` so it reads as a contrasting accent.
        rgb += hsv2rgb(fract(hue + 0.5), 0.4, 1.0) * filament * 0.18;
        output.write(float4(rgb, 1.0), gid);
    }
    """

    // MARK: - Build

    /// Compile the Metal library + pipeline + allocate the LLT, then
    /// build the entity tree. Async because library compilation is a
    /// non-trivial wait (~hundreds of ms first time).
    @MainActor
    static func makeFractal(from frames: [FeatureFrame]) async -> Entity {
        let root = Entity()

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("FractalVisualizer: Metal device not available")
            return root
        }
        guard let commandQueue = device.makeCommandQueue() else {
            print("FractalVisualizer: failed to create command queue")
            return root
        }
        let library: MTLLibrary
        do {
            library = try await device.makeLibrary(source: kernelSource, options: nil)
        } catch {
            print("FractalVisualizer: Metal library compile failed: \(error)")
            return root
        }
        guard let kernelFn = library.makeFunction(name: "juliaKernel") else {
            print("FractalVisualizer: juliaKernel function not found")
            return root
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try await device.makeComputePipelineState(function: kernelFn)
        } catch {
            print("FractalVisualizer: compute pipeline state failed: \(error)")
            return root
        }

        // LowLevelTexture for GPU-direct read/write — avoids the
        // CPU round-trip that `TextureResource.replace(withImage:)`
        // would force. Pixel format BGRA8 (matches default
        // RealityKit material color sampling).
        let lltDescriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm,
            width: textureWidth,
            height: textureHeight,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite]
        )
        let lowLevelTexture: LowLevelTexture
        do {
            lowLevelTexture = try LowLevelTexture(descriptor: lltDescriptor)
        } catch {
            print("FractalVisualizer: LowLevelTexture init failed: \(error)")
            return root
        }
        let textureResource: TextureResource
        do {
            textureResource = try await TextureResource(from: lowLevelTexture)
        } catch {
            print("FractalVisualizer: TextureResource(from: LLT) failed: \(error)")
            return root
        }

        // Build the cube. UnlitMaterial because the fractal is
        // self-illuminating (computed pixel colors carry their own
        // brightness). RealityKit's generateBox produces a cube with
        // standard per-face UV mapping — each of 6 faces samples
        // the same LowLevelTexture as a full unit square. The
        // fractal therefore appears on every face the camera sees.
        var mat = UnlitMaterial()
        mat.color = .init(tint: PlatformColor.white, texture: .init(textureResource))
        let cube = ModelEntity(
            mesh: .generateBox(size: cubeEdge),
            materials: [mat]
        )
        cube.components.set(FractalCubeComponent())

        // Position the root so the cube sits `cubeDistance` in front
        // of the camera. On windowed platforms the camera is at
        // world origin looking -Z; on visionOS the eye-height
        // offset is applied by the system's camera. v1 hard-codes
        // windowed positioning — visionOS revisit later.
        root.position = SIMD3<Float>(0, cubeYOffset, -cubeDistance)
        root.addChild(cube)

        let state = FractalMetalState(
            device: device,
            commandQueue: commandQueue,
            pipeline: pipeline,
            lowLevelTexture: lowLevelTexture,
            textureResource: textureResource,
            textureWidth: textureWidth,
            textureHeight: textureHeight
        )
        root.components.set(FractalRootComponent(state: state))

        // Run one initial render so the plane shows fractal content
        // immediately rather than blank black for the first frame.
        renderOnce(state: state, uniforms: defaultUniforms(state: state))

        return root
    }

    // MARK: - Animate

    /// Per-frame entry point — called from VisualizerView /
    /// ImmersiveView's SceneEvents.Update subscription. Reads audio
    /// features, computes uniforms, dispatches the kernel.
    @MainActor
    static func animate(
        _ root: Entity,
        clock: Double,
        frames: [FeatureFrame],
        deltaTime: Double,
        appResetCounter: Int = -1,
        stemFeatures: StemSeparationResult? = nil
    ) {
        guard let comp = root.components[FractalRootComponent.self] else { return }
        let metal = comp.state
        guard !frames.isEmpty else { return }

        // Frame index from playback clock.
        let i = max(0, min(frames.count - 1, Int((clock * 30).rounded())))
        let f = frames[i]

        // Stem-aware loudness sources (with full-mix fallback).
        let bassLoudnessSrc: Float = {
            if let l = stemFeatures?.stems["bass"]?.loudness, i < l.count {
                return l[i]
            }
            return f.bandLoudness[FrequencyBand.sub.rawValue]
        }()
        let otherLoudnessSrc: Float = {
            if let l = stemFeatures?.stems["other"]?.loudness, i < l.count {
                return l[i]
            }
            return f.loudness
        }()

        // Smoothing — first tick snaps to current values; subsequent
        // ticks lerp at the per-axis rate.
        if metal.firstTick {
            metal.smoothedBassLoudness = bassLoudnessSrc
            metal.smoothedOtherLoudness = otherLoudnessSrc
            metal.smoothedSongIntensity = otherLoudnessSrc
            metal.lastFrameIndex = i - 1
            metal.firstTick = false
        } else {
            let bassLerp = Float(min(1.0, deltaTime * Double(bassLoudnessLerpRate)))
            metal.smoothedBassLoudness +=
                (bassLoudnessSrc - metal.smoothedBassLoudness) * bassLerp
            let otherLerp = Float(min(1.0, deltaTime * Double(otherLoudnessLerpRate)))
            metal.smoothedOtherLoudness +=
                (otherLoudnessSrc - metal.smoothedOtherLoudness) * otherLerp
            let intensityLerp = Float(min(1.0, deltaTime * Double(songIntensityLerpRate)))
            metal.smoothedSongIntensity +=
                (otherLoudnessSrc - metal.smoothedSongIntensity) * intensityLerp
        }

        // Drum onset scan across newly-arrived frames. Each onset
        // bumps drumPulse (clamped to 1.0). Exponential decay then
        // applies once per tick. Pulls from stems["drums"].onset if
        // available, else bandOnset[sub] (kick band) fallback.
        let drumOnsetTimeline = stemFeatures?.stems["drums"]?.onset
        if metal.lastFrameIndex < i {
            let start = max(0, metal.lastFrameIndex + 1)
            for k in start...i {
                let fired: Bool = {
                    if let do_ = drumOnsetTimeline, k < do_.count {
                        return do_[k]
                    }
                    return frames[k].bandOnset[FrequencyBand.sub.rawValue]
                }()
                if fired {
                    metal.drumPulse = min(1.0, metal.drumPulse + drumPulseBump)
                }
            }
        }
        metal.lastFrameIndex = i
        // Exponential decay with the configured half-life. log(2)
        // ≈ 0.6931 — using the literal avoids the Float16 ambiguity
        // that `Double.ln2` would (Float16 has `ln2` but Double
        // doesn't expose it on this SDK).
        let drumDecay = Float(exp(
            -0.6931471805599453 * deltaTime / Double(drumPulseHalfLife)
        ))
        metal.drumPulse *= drumDecay

        // Vocals stem smoothing — loudness for the mix amount,
        // chromagram dominant pitch for the secondary hue.
        if let vocalsLoud = stemFeatures?.stems["vocals"]?.loudness,
           i < vocalsLoud.count {
            let vocLerp = Float(min(1.0, deltaTime * Double(vocalsLoudnessLerpRate)))
            metal.smoothedVocalsLoudness +=
                (vocalsLoud[i] - metal.smoothedVocalsLoudness) * vocLerp
        } else {
            metal.smoothedVocalsLoudness *= 0.85
        }
        if let vocalsChroma = stemFeatures?.stems["vocals"]?.chromagram,
           i < vocalsChroma.count, vocalsChroma[i].count == 12 {
            var vDom = 0
            var vBest: Float = -1
            for k in 0..<12 where vocalsChroma[i][k] > vBest {
                vBest = vocalsChroma[i][k]
                vDom = k
            }
            let vPitch = PitchClass(rawValue: vDom) ?? .c
            let vHueRaw = Float(vPitch.circleOfFifthsHue)
            // Shortest-path hue lerp so we don't sweep the long way
            // around the wheel.
            var hueDelta = vHueRaw - metal.smoothedVocalsHue
            if hueDelta > 0.5 { hueDelta -= 1 }
            if hueDelta < -0.5 { hueDelta += 1 }
            let hLerp = Float(min(1.0, deltaTime * Double(vocalsHueLerpRate)))
            metal.smoothedVocalsHue += hueDelta * hLerp
            if metal.smoothedVocalsHue < 0 { metal.smoothedVocalsHue += 1 }
            if metal.smoothedVocalsHue >= 1 { metal.smoothedVocalsHue -= 1 }
        }

        // Dominant pitch from bass chromagram (preferred) or
        // full-mix chromagram fallback. Smoothed across frames so
        // the hue doesn't strobe between near-tied bins.
        let chroma: [Float] = {
            if let bc = stemFeatures?.stems["bass"]?.chromagram,
               i < bc.count, bc[i].count == 12 {
                return bc[i]
            }
            return f.chromagram
        }()
        var domBin = 0
        var domVal: Float = -1
        for k in 0..<12 where chroma[k] > domVal {
            domVal = chroma[k]
            domBin = k
        }
        let pitch = PitchClass(rawValue: domBin) ?? .c
        let pitchHueRaw = Float(pitch.circleOfFifthsHue)
        let hueLerp = Float(min(1.0, deltaTime * Double(hueIndexLerpRate)))
        metal.smoothedHueIndex += (pitchHueRaw - metal.smoothedHueIndex) * hueLerp

        metal.elapsedTime += Float(deltaTime)

        // Walk c along the Mandelbrot main cardioid boundary:
        //     c(t) = e^(it)/2 - e^(2it)/4
        // Every point on this curve produces a dendritic Julia.
        //
        // KEY CHANGE (2026-05-27): pitch contribution removed from
        // the c phase. Earlier we added `domBin / 12 * 2π` so each
        // bass-note change jumped c around the cardioid — but on
        // bass-rich music with notes changing every ~200ms, c was
        // teleporting across the cardioid faster than the eye
        // could read, giving the "blob then flash then blob" cadence.
        // Now c traverses the cardioid SMOOTHLY at a single slow
        // rate (bass loudness boosts that rate but doesn't jump
        // position). The bass pitch identity is preserved on the
        // palette hue + drum-pulse offset instead.
        let bassBoost = min(1.0, metal.smoothedBassLoudness * 6.0)
        metal.cPhase += Float(deltaTime) * (cDriftRate + bassBoost * 0.15)
        let t = metal.cPhase
        let cBoundary = SIMD2<Float>(
            cos(t) * 0.5 - cos(2.0 * t) * 0.25,
            sin(t) * 0.5 - sin(2.0 * t) * 0.25
        )
        // Perpendicular tangent direction at cardioid(t). Tangent is
        // dc/dt = i·e^(it)/2 - i·e^(2it)/2 → normal = i × tangent.
        // For visible effect we just pick a direction roughly normal
        // outward and modulate by drum pulse.
        let tangent = SIMD2<Float>(
            -sin(t) * 0.5 + sin(2.0 * t) * 0.5,
             cos(t) * 0.5 - cos(2.0 * t) * 0.5
        )
        // Perp = (-tan.y, tan.x), normalized
        let tangentLen = max(0.0001, simd_length(tangent))
        let perp = SIMD2<Float>(-tangent.y, tangent.x) / tangentLen
        let cParam = cBoundary + perp * (metal.drumPulse * cDrumKickAmplitude)

        // Zoom — pulled out so the view always captures the full
        // Julia set + boundary, regardless of where on the cardioid
        // c currently sits. At zoom=1.0, larger Julia sets (e.g. for
        // c near (-0.75, 0)) extend outside the [-1, 1] z view and
        // we end up looking at their interior (the "blob" frames).
        // 0.55 baseline = view extends to z ~ ±1.8 which captures
        // the dendritic boundary at all t. Song intensity adds a
        // gentle zoom-in (0.55 → 0.85) during chorus moments.
        let zoomTarget = 0.55 + min(1.0, metal.smoothedSongIntensity * 8.0) * 0.30
        // Iteration count — `other.loudness` raises detail in loud
        // passages so the fractal looks more intricate during
        // climaxes. Reverted from 90-200 (which made the interior
        // dominant — at high iter counts more pixels never escape,
        // pushing the fractal toward "dim blob") back to a tighter
        // 56-140 range that keeps most pixels on the colorful
        // escape side of the divide.
        let iterCount = 56.0 + min(1.0, metal.smoothedOtherLoudness * 8.0) * 84.0

        // Vocals mix amount — cap at 0.55 so the bass-driven base
        // palette stays the dominant identity even during heavy
        // vocal sections. Vocals act as a secondary tint, not a
        // takeover.
        let vocalsMix = min(0.55, metal.smoothedVocalsLoudness * 8.0)

        // Palette cycle — continuous offset (per second) that flows
        // the escape-iteration bands outward. Slow base + faster
        // during loud sections so quiet passages have gentle drift
        // and choruses have visible "waves."
        let paletteCycle = metal.elapsedTime
            * (0.06 + min(1.0, metal.smoothedOtherLoudness * 8.0) * 0.18)

        // Domain warp — drum pulse only, no baseline. Earlier the
        // 1% baseline warp was smearing the fine dendritic detail
        // at all times, making the fractal feel softer/less crisp.
        // Now warp ONLY fires on drum kicks (transient ripple
        // through the fractal on each hit) and the boundary stays
        // crisp the rest of the time.
        let domainWarp = metal.drumPulse * 0.10

        // Bass breath — slow EMA of bass loudness modulates a
        // micro-zoom. Range scaled in kernel; here we just pass
        // smoothed bass loudness as a 0..1-ish signal.
        let bassBreath = min(1.0, metal.smoothedBassLoudness * 6.0)

        let uniforms = FractalUniforms(
            cParam: cParam,
            viewCenter: SIMD2<Float>(0, 0),
            zoom: zoomTarget,
            iterationCount: iterCount,
            paletteHue: metal.smoothedHueIndex,
            paletteShift: metal.elapsedTime * 0.02,  // slow palette drift
            aspect: Float(metal.textureWidth) / Float(metal.textureHeight),
            time: metal.elapsedTime,
            vocalsHue: metal.smoothedVocalsHue,
            vocalsMix: vocalsMix,
            drumPulse: metal.drumPulse,
            rotation: metal.elapsedTime * uvRotationRate,
            paletteCycle: paletteCycle,
            domainWarp: domainWarp,
            bassBreath: bassBreath
        )

        renderOnce(state: metal, uniforms: uniforms)

        // Apply rotation to the cube child. Yaw and tumble both
        // accelerate with bass loudness for a "spin harder on the
        // drop" feel. Compose freshly from the accumulated angles
        // each tick — incremental quaternion composition would
        // drift after thousands of ticks.
        let rotBoost = 1.0 + bassBoost * cubeBassRotationBoost
        metal.cubeYaw += Float(deltaTime) * cubeYawRate * rotBoost
        metal.cubeTumble += Float(deltaTime) * cubeTumbleRate * rotBoost
        let yawQ = simd_quatf(angle: metal.cubeYaw, axis: SIMD3<Float>(0, 1, 0))
        let tumbleQ = simd_quatf(angle: metal.cubeTumble, axis: SIMD3<Float>(1, 0, 0))
        let composed = yawQ * tumbleQ
        for child in root.children {
            if child.components[FractalCubeComponent.self] != nil {
                child.orientation = composed
                break
            }
        }
    }

    // MARK: - Kernel dispatch

    private static func defaultUniforms(state: FractalMetalState) -> FractalUniforms {
        FractalUniforms(
            cParam: baseCparam,
            viewCenter: SIMD2<Float>(0, 0),
            zoom: 0.55,
            iterationCount: 120,
            paletteHue: 0.5,
            paletteShift: 0,
            aspect: Float(state.textureWidth) / Float(state.textureHeight),
            time: 0,
            vocalsHue: 0,
            vocalsMix: 0,
            drumPulse: 0,
            rotation: 0,
            paletteCycle: 0,
            domainWarp: 0,
            bassBreath: 0
        )
    }

    /// Encode + commit one kernel dispatch into the LLT. Does NOT
    /// wait — the GPU work overlaps with the next animate tick.
    @MainActor
    private static func renderOnce(
        state: FractalMetalState,
        uniforms: FractalUniforms
    ) {
        guard let commandBuffer = state.commandQueue.makeCommandBuffer() else {
            return
        }
        let mtlTexture = state.lowLevelTexture.replace(using: commandBuffer)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.setComputePipelineState(state.pipeline)
        encoder.setTexture(mtlTexture, index: 0)
        var u = uniforms
        encoder.setBytes(&u, length: MemoryLayout<FractalUniforms>.stride, index: 0)

        // Threadgroup size: 16×16 is a sane default for compute
        // kernels on Apple GPUs. Total threads = textureWidth ×
        // textureHeight (one thread per output pixel).
        let threadsPerGrid = MTLSize(
            width: state.textureWidth,
            height: state.textureHeight,
            depth: 1
        )
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(
            threadsPerGrid,
            threadsPerThreadgroup: threadsPerGroup
        )
        encoder.endEncoding()
        commandBuffer.commit()
        // No wait — let GPU work overlap CPU's next frame prep.
    }
}
