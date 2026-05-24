//
//  AtmosphereOverlay.swift
//  High Videlity
//
//  SwiftUI overlays that approximate the HTML reference's atmospheric
//  treatment: a pale lavender-grey fog wash (`THREE.Fog(0xd4d8de, 11, 44)`)
//  lifting darks, and a screen-space film-grain canvas tied to timbre
//  crispness. Composites on top of the RealityView so the result reads the
//  same way the HTML's `#grain` 2D canvas + `scene.fog` do — without
//  fighting RealityKit's CI post-process pipeline (see clouds.md memory
//  about the failed in-shader attempt at fog + grain).
//
//  visionOS is excluded: the immersive space has no straightforward
//  screen-space overlay. A head-locked fullscreen quad would be needed
//  there, and is deferred per the clouds.md handoff.
//

#if !os(visionOS)

import SwiftUI
import CoreGraphics

/// Pale lavender-grey wash. HTML uses `THREE.Fog(0xd4d8de, 11, 44)` which
/// is a PER-FRAGMENT SHADER fog — it blends each rendered pixel of geometry
/// toward the fog colour by `(depth-near)/(far-near)`, but leaves empty
/// regions untouched (those stay at `setClearColor(0x070709)`, which reads
/// as near-black). An earlier comment here claimed our uniform overlay
/// approximated the full HTML effect; it actually does the opposite: it
/// lifts everything including the supposed-to-be-near-black empty regions.
/// Verified in Clair de Lune side-by-side — HTML's background sits at
/// ~RGB(7,7,9), AVP at α=0.15 was lifting it to ~RGB(38,41,44) (visibly
/// grey, not the HTML black). Dropped to α=0.04 so the wash still contributes
/// a slight atmospheric haze to mid-depth beams without lifting the backdrop
/// out of HTML's clearcolor range.
///
/// The bloom on bright pixels already gives the cluster its "atmospheric
/// glow" — fog overlay should be very subtle, not the dominant atmospheric
/// effect.
///
/// (To get true HTML behaviour — fog-only-affects-geometry — we'd need a
/// depth-aware composite, which RealityView doesn't expose. Subtle uniform
/// wash is the practical compromise.)
struct FogOverlay: View {
    var body: some View {
        // Hybrid: α=0.07 + .plusLighter. Lower alpha than the original 0.15
        // keeps the backdrop near HTML's clearcolor (avoids the grey
        // wash from #1's normal blend at higher alphas), while
        // .plusLighter still adds proportional brightness to beam pixels
        // for a hint of atmospheric depth. Not depth-aware fog, but a
        // decent practical compromise within SwiftUI overlay limits.
        Rectangle()
            .fill(Color(red: 212.0/255, green: 216.0/255, blue: 222.0/255))
            .opacity(0.07)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// Tiled-noise film grain. Direct port of the HTML reference's `#grain`
/// canvas: a 256×256 monochrome noise tile, panned at a loudness-modulated
/// speed and composited with `mix-blend-mode: overlay` at an alpha set by
/// timbre crispness.
struct GrainOverlay: View {
    @Environment(AppModel.self) private var appModel

    @State private var noiseImage: CGImage = GrainOverlay.makeNoiseTile()

    // Drift accumulators in pixels. HTML integrates these each frame as
    // `grainX += dt * (8 + eLoud*380)` so the noise pattern visibly speeds
    // up on loud passages.
    @State private var grainX: Double = 0
    @State private var grainY: Double = 0
    @State private var lastTick: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { context in
            let now = context.date
            let eLoud   = Double(appModel.currentEnergy())
            let eTimbre = Double(appModel.currentTimbreBrightness())
            // HTML: crispness(tb) = clamp01((tb - 0.4) / 0.5)
            let grain = max(0, min(1, (eTimbre - 0.4) / 0.5))

            Canvas { gctx, size in
                guard grain > 0.04 else { return }
                // Peak alpha halved (0.13 → 0.065) per Jesse's
                // "noise is too strong, cut in half" brief — the
                // SwiftUI grain overlay was reading as a heavy
                // static dot pattern across the lake, drowning the
                // shader-driven water flow underneath.
                gctx.opacity = grain * 0.065
                let img = Image(noiseImage, scale: 1, label: Text(verbatim: ""))
                let ox = -grainX.truncatingRemainder(dividingBy: 256)
                let oy = -grainY.truncatingRemainder(dividingBy: 256)
                var y = oy
                while y < size.height {
                    var x = ox
                    while x < size.width {
                        gctx.draw(img, in: CGRect(x: x, y: y, width: 256, height: 256))
                        x += 256
                    }
                    y += 256
                }
            }
            .blendMode(.overlay)
            .allowsHitTesting(false)
            .onChange(of: now) { _, newDate in
                let dt: Double
                if let last = lastTick {
                    dt = max(0, min(0.1, newDate.timeIntervalSince(last)))
                } else {
                    dt = 0
                }
                lastTick = newDate
                grainX += dt * (8 + eLoud * 380)
                grainY += dt * (6 + eLoud * 300)
            }
        }
    }

    /// 256×256 RGBA tile of grey-on-grey noise (R=G=B=random byte, A=255).
    /// HTML builds this once at startup via `createImageData` + a per-pixel
    /// `Math.random()*255`. Same idea here.
    static func makeNoiseTile() -> CGImage {
        let dim = 256
        let bytesPerRow = dim * 4
        var data = [UInt8](repeating: 0, count: dim * bytesPerRow)
        for i in stride(from: 0, to: data.count, by: 4) {
            let v = UInt8.random(in: 0...255)
            data[i] = v
            data[i + 1] = v
            data[i + 2] = v
            data[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGImageAlphaInfo.premultipliedLast.rawValue
        return data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: dim,
                height: dim,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bmp
            )!
            return ctx.makeImage()!
        }
    }
}

#endif
