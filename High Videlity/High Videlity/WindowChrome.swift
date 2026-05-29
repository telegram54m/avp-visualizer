//
//  WindowChrome.swift
//  High Videlity
//
//  AppKit bridges that let the SwiftUI `RootShellView` host its
//  content inside a translucent, frosted NSWindow. macOS-only.
//
//  Two pieces:
//
//    1. `VisualEffectBackground` — an `NSViewRepresentable` wrapper
//       around `NSVisualEffectView`. The shell view uses it as a
//       full-window background; together with the window-level
//       transparency in `TransparentWindowConfigurator`, this is
//       what gives the app the "see-through glass" look.
//
//    2. `TransparentWindowConfigurator` — a hidden NSView that locates
//       its hosting `NSWindow` once mounted and turns off opacity +
//       backgroundColor. Applied via a `.background(...)` modifier on
//       the shell so it runs once per window without leaking AppKit
//       state across the rest of the SwiftUI tree.
//
//  These bridges only render on macOS — the file is wrapped in
//  `#if os(macOS)` so iOS / visionOS builds skip the AppKit
//  imports cleanly.
//

#if os(macOS)
import AppKit
import SwiftUI

/// Material the SwiftUI shell uses for its background. Exposed as a
/// representable so consumers can pick a `material` + `blendingMode`
/// per surface (RootShellView vs. eventual sub-windows). Defaults
/// match "transparent floating macOS window with frost" — `behindWindow`
/// blending lets the desktop / other apps show through.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        // `.active` keeps the frost visible even when the window
        // loses key focus — without it, the background goes
        // semi-opaque whenever the user switches to another app.
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// Hidden NSView that walks up to its hosting `NSWindow` and switches
/// it to non-opaque, clear-background. Without this the
/// `VisualEffectBackground` material would render on top of the
/// window's default white/dark fill — the frost would be there but
/// you wouldn't see through to the desktop behind.
///
/// Drop the view into the SwiftUI tree via
/// `.background(TransparentWindowConfigurator())` — `.background`
/// keeps it out of the layout flow and ensures it lives as long as
/// the host window does.
struct TransparentWindowConfigurator: NSViewRepresentable {
    /// Optional extra alpha applied to the WHOLE window (content +
    /// material). Default 1.0 = no additional transparency on the
    /// content itself; the see-through effect comes entirely from
    /// the material + clear background. Lower this only if you want
    /// the content to fade too — most users don't.
    var alphaValue: CGFloat = 1.0

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't in the window's view hierarchy at make-time,
        // so defer the window lookup to the next runloop tick — by
        // then the SwiftUI representable has been attached and
        // `view.window` resolves to the host NSWindow.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.alphaValue = alphaValue
            // Titlebar treatment that visually merges with the
            // material background: hide the title text + colored
            // bar so the frost flows up to the traffic lights.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // alphaValue may change at runtime; re-apply.
        DispatchQueue.main.async { [weak nsView] in
            nsView?.window?.alphaValue = alphaValue
        }
    }
}
#endif
