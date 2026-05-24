//
//  PlatformColor.swift
//  High Videlity
//
//  Bridges UIColor (iOS / iPadOS / tvOS / visionOS) and NSColor (macOS) so
//  visualizer code can use `PlatformColor(hue:saturation:brightness:alpha:)`
//  without per-platform branching. Both initializers have the same signature
//  and produce equivalent HSB→RGB colors.
//

import CoreGraphics

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

extension PlatformColor {
    /// Wraps a CGColor as a PlatformColor. NSColor's initializer is failable;
    /// on macOS this falls back to black if the CGColor is somehow invalid
    /// (shouldn't happen for any CGColor we construct ourselves).
    static func fromCGColor(_ cgColor: CGColor) -> PlatformColor {
        #if canImport(UIKit)
        return PlatformColor(cgColor: cgColor)
        #else
        return PlatformColor(cgColor: cgColor) ?? .black
        #endif
    }

    /// Reads RGBA components from a color. macOS NSColor requires conversion
    /// to a calibrated RGB color space before getRed will return values; UIKit
    /// handles this internally.
    func rgbaComponents() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if canImport(UIKit)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let converted = usingColorSpace(.sRGB) ?? self
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return (r, g, b, a)
    }

    /// Builds a color in extended sRGB so that RGB values above 1.0 survive
    /// material assignment intact — driving an HDR-capable display past SDR
    /// white. The OLED rolloff on visionOS / iPhone Pro / iPad Pro / studio
    /// displays then provides natural optical bloom that approximates what a
    /// real post-process bloom pass would do, without needing one. With
    /// `hdrBoost = 1.0` this is equivalent to a normal HSB-init color; boost
    /// values above 1.0 push the same hue into the HDR range.
    ///
    /// Shared by CloudVisualizer (HDR-boosted main / core sprites) and
    /// CrystalVisualizer (HDR-boosted beam cores / halos / shards) so the
    /// non-bloom-having macOS pathway can still read as bright glowing
    /// geometry instead of pure-black additive smears.
    static func hdrColor(hue: CGFloat, saturation: CGFloat,
                         brightness: CGFloat, hdrBoost: CGFloat = 1.0) -> PlatformColor {
        let base = PlatformColor(hue: hue, saturation: saturation,
                                 brightness: brightness, alpha: 1)
        let (r, g, b, _) = base.rgbaComponents()
        let cs = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        guard let cg = CGColor(colorSpace: cs,
                               components: [r * hdrBoost, g * hdrBoost, b * hdrBoost, 1]) else {
            return base
        }
        return PlatformColor.fromCGColor(cg)
    }
}
