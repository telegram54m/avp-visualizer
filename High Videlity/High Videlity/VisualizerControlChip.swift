//
//  VisualizerControlChip.swift
//  High Videlity
//
//  Unified three-segment capsule for visualizer chrome — reads as
//  one control rather than the prior pile of separate pills:
//
//   ┌───────────────────────────────────────────────┐
//   │  Crystal   │   → Clouds   │   ×   /   ✦       │
//   └───────────────────────────────────────────────┘
//      current      cycle to        close (in viz)
//      mode name    next mode       or open (in shell)
//
//  - Single thin-material capsule background
//  - Subtle dividers between segments so they read as parts of a
//    unit but each segment's hit area is independent
//  - Left segment is currently inert (display-only); future: open
//    the Visualizers source page for the full grid picker
//  - Middle segment cycles to the next VisualizerMode.allCases
//    entry, wrapping
//  - Right segment toggles `appModel.showVisualizer` — glyph + tint
//    flip between the open and close states for instant context
//

#if !os(visionOS)
import SwiftUI

struct VisualizerControlChip: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let isOpen = appModel.showVisualizer
        HStack(spacing: 0) {
            currentSegment
            divider
            nextSegment
            divider
            toggleSegment(isOpen: isOpen)
        }
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isOpen)
        .animation(.easeInOut(duration: 0.15), value: appModel.mode)
    }

    // MARK: - Segments

    /// Current mode name. Inert today — the displayed text is the
    /// status indicator paired with the cycle button to its right.
    /// Could be wired to open the Visualizers source page for the
    /// full grid picker if we want a quick jump from the chrome.
    private var currentSegment: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(appModel.mode.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Current visualizer")
    }

    /// Cycle to next mode. Label previews the next mode's name so
    /// the user sees where they're going before they click.
    private var nextSegment: some View {
        Button {
            cycleMode()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.forward")
                    .font(.caption2.weight(.semibold))
                Text(nextModeName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch to \(nextModeName)")
    }

    /// Open / Close toggle. Tint shifts between the two states so
    /// the chip carries the "is the viz visible right now" cue
    /// without the user having to read the glyph.
    private func toggleSegment(isOpen: Bool) -> some View {
        Button {
            appModel.showVisualizer.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOpen ? "xmark" : "play.fill")
                    .font(.caption.weight(.semibold))
                Text(isOpen ? "Close" : "Open")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isOpen ? Color.primary : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                // Highlight the toggle segment when open so the
                // close affordance reads as "active and ready to
                // dismiss," not as a generic chrome button.
                if isOpen {
                    Color.clear
                } else {
                    Capsule()
                        .fill(Color.accentColor)
                        .padding(.vertical, -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Close visualizer" : "Open visualizer")
    }

    /// 1pt vertical divider between segments. `Color.primary`
    /// opacity 0.12 reads as subtle separation against the thin-
    /// material background without ever looking like a hard rule.
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 18)
    }

    // MARK: - Mode-cycle helpers

    private var nextMode: VisualizerMode {
        let modes = VisualizerMode.allCases
        let idx = modes.firstIndex(of: appModel.mode) ?? 0
        return modes[(idx + 1) % modes.count]
    }

    private var nextModeName: String {
        nextMode.displayName
    }

    private func cycleMode() {
        appModel.mode = nextMode
    }
}
#endif
