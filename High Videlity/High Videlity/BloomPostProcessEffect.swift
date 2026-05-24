//
//  BloomPostProcessEffect.swift
//  High Videlity
//
//  Real Gaussian bloom for the windowed visualizer on iOS / iPadOS /
//  macOS / tvOS. Hooked into the RealityView via
//  `content.renderingEffects.customPostProcessing`. visionOS doesn't have
//  this API; on the AVP we get optical bloom from HDR-boosted extended-sRGB
//  colors and the OLED display's native rolloff instead.
//
//  GOTCHA: this only works if the scene contains NO explicit PerspectiveCamera
//  entity. `RealityViewCameraContent` already manages an implicit virtual
//  camera, and adding our own crashes the renderCallbacks bridge with
//  EXC_BREAKPOINT inside ARView.renderCallbacks.setter. VisualizerView drives
//  framing by transforming the world (head-locked pattern) instead of
//  moving an explicit camera entity.
//

#if !os(visionOS)

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import RealityKit

@available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
final class BloomPostProcessEffect: PostProcessEffect, @unchecked Sendable {

    /// CIContext is expensive to construct (compiles Metal shaders on first
    /// use), so we build it once in `prepare` and reuse it every frame.
    private var ciContext: CIContext?

    /// Pre-generated noise tile for the grain pass. Built once in `prepare`
    /// (random bytes → CGImage → CIImage). Per-frame we tile + translate
    /// + additive-blend at small amplitude. Bypasses CIRandomGenerator,
    /// which had premultiplied-alpha / colour-space issues in the linear
    /// working space.
    private var noiseImage: CIImage?

    /// Bloom strength tuning. Higher radius = wider glow; higher intensity =
    /// brighter glow. Intensity 1.0 (was 1.6) prevents HDR-boosted cloud
    /// pixels from blooming all the way to clipped white when several
    /// bright sprites overlap. Radius 14 (was 10, originally 18) — Clair de
    /// Lune side-by-side showed the HTML reference's halos have soft
    /// atmospheric haze around them ("translucent envelopes"), while AVP
    /// halos read as crisp pencil lines. 10 was tuned for thin-rod
    /// readability but left no haze. 14 reintroduces some atmosphere
    /// without going all the way back to 18's core-washout.
    let radius: Float = 14
    // Intensity dropped 1.0 → 0.65 in the HTML-fidelity pass (session 10).
    // At 1.0 the bloom was smearing additive core/halo brightness wide
    // enough at the convergence to mask the alpha-blended shard cones
    // that give HTML its "translucent geometry with bright cores" look.
    // 0.65 keeps cores visibly glowing but lets the shards re-emerge as
    // discernible faceted forms in the midground.
    let intensity: Float = 0.65

    /// Atmospheric fog wash — DISABLED. The CIColorMatrix linear-mix at
    /// alpha 0.012 was lifting the background to ~sRGB 0.45 (should
    /// have been ~sRGB 0.21 per the math). Something about the linear-
    /// space color-matrix bias in CI doesn't behave the way I reasoned.
    /// Worth revisiting with a different approach — maybe pre-convert
    /// the fog color via sRGB→linear curve, or apply fog in a different
    /// color space.
    private let fogAlpha: CGFloat = 0
    private let fogR: CGFloat = 212.0 / 255   // sRGB lavender-grey, ≈ linear 0.65
    private let fogG: CGFloat = 216.0 / 255
    private let fogB: CGFloat = 222.0 / 255

    /// Grain amplitude — additive 0..grainStrength applied per pixel.
    /// Empirical: at 0.015 the background lifted to ~sRGB 0.5 even though
    /// math says it should land near sRGB 0.20. Something in the CI
    /// pipeline (color-space conversion? extended-linear interpretation
    /// of the noise bytes?) is amplifying ~10×. Dropping 10× to compensate
    /// while we figure out the root cause.
    private let grainStrength: CGFloat = 0.0015

    func prepare(for device: MTLDevice) {
        let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace
        ])

        noiseImage = Self.makeNoiseTile(size: 1024)
    }

    /// Builds a single tile of grayscale noise. Tiled and translated per
    /// frame so the grain animates instead of staying static. 1024 covers
    /// most viewport sizes in a single tile so seams aren't visible — a
    /// 256-pixel tile produced an obvious grid pattern at every boundary
    /// because the noise isn't seamless across edges.
    private static func makeNoiseTile(size: Int) -> CIImage? {
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let v = UInt8.random(in: 0...255)
            bytes[i] = v
            bytes[i + 1] = v
            bytes[i + 2] = v
            bytes[i + 3] = 255
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: size, height: size,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: srgb,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        // Tag the CIImage with the source sRGB space so when it enters
        // the linear working space, CI converts. Without this, byte
        // value 128 (sRGB mid-grey) is read as linear 0.5 = sRGB ~0.74
        // (much brighter), and even a small CIColorMatrix scale lifts
        // the whole frame to bright grey.
        return CIImage(cgImage: cgImage, options: [.colorSpace: srgb])
    }

    func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        guard let ciContext else { return }

        let textureColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        guard let source = CIImage(
            mtlTexture: context.sourceColorTexture,
            options: [.colorSpace: textureColorSpace]
        ) else { return }

        // RealityKit hands us a top-down texture; CIImage's coordinate
        // system is bottom-up. Flip Y so the output isn't upside-down.
        let flipped = source
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: source.extent.height))
        let extent = flipped.extent

        // 1) Bloom on the source — picks up bright cloud centres and
        //    spreads them into soft halos.
        let bloom = CIFilter.bloom()
        bloom.inputImage = flipped
        bloom.radius = radius
        bloom.intensity = intensity
        var output = bloom.outputImage?.cropped(to: extent) ?? flipped

        // 2) Fog mix — output = output*(1-α) + fogColor*α. CIColorMatrix
        //    expresses this directly: scale each channel by (1-α), add a
        //    bias of fogColor*α. No alpha compositing, no premultiplied
        //    surprises.
        let keep = 1 - fogAlpha
        output = output.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: fogR * fogAlpha,
                y: fogG * fogAlpha,
                z: fogB * fogAlpha,
                w: 0
            ),
        ]).cropped(to: extent)

        // 3) Grain — tile the noise image, animate it with `context.time`,
        //    map 0..1 → -grainStrength..+grainStrength via CIColorMatrix,
        //    then add to the image. Symmetric noise reads as real grain
        //    (darkens AND brightens) rather than a one-sided overlay.
        // Grain pass disabled 2026-05-20 — attempts to apply noise via
        // CIRandomGenerator and via pre-generated CGImage tiles all
        // produced output ~10× brighter than the math suggested, even
        // after dropping grainStrength to 0.0015. The amplification
        // isn't proportional to the multiplier, so either CIColorMatrix
        // isn't behaving how I think on noise images in the extended-
        // linearSRGB working space, or the CGImage byte values are
        // being interpreted at a wrong scale. Worth revisiting with a
        // SwiftUI Canvas overlay approach instead of fighting CI.
        _ = noiseImage  // keep prepare()'d but unused; suppress warning

        ciContext.render(
            output,
            to: context.targetColorTexture,
            commandBuffer: context.commandBuffer,
            bounds: extent,
            colorSpace: textureColorSpace
        )
    }
}

#endif
