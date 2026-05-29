//
//  RootShellView.swift
//  High Videlity
//
//  Phase 7 — macOS shell. NavigationSplitView with a Source sidebar,
//  source-specific detail panel, and a persistent GlobalNowPlayingFooter
//  at the bottom that survives source switches.
//
//  When `appModel.showVisualizer == true`, the entire window swaps to
//  the full-bleed VisualizerView (no sidebar, no footer) per the plan's
//  "Visualizer itself stays full-screen overlay" guidance. The viz has
//  its own close affordance (the back-chevron-style "Exit" overlay
//  added below) so the user can return to the shell without leaving
//  the app.
//
//  iOS / visionOS still render `ContentView` from `High_VidelityApp` —
//  porting them is deliberately deferred (per the plan, "Mac-first per
//  phase, port iOS after").
//

#if os(macOS)
import SwiftUI
import MusicKit

struct RootShellView: View {

    @Environment(AppModel.self) private var appModel

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            if appModel.showVisualizer {
                visualizerOverlay
            } else {
                shellLayout
            }
            // Hidden shortcut buttons live in a ZStack overlay so they
            // exist in BOTH shell + visualizer modes — without this,
            // space / ←→ stop working as soon as you open the viz.
            KeyboardShortcuts()
                .environment(appModel)
        }
        // Frosted-translucent window background. The
        // VisualEffectBackground paints the system-supplied
        // material; the TransparentWindowConfigurator flips the
        // host NSWindow to non-opaque + clear background so the
        // material is what actually shows. The black overlay tunes
        // total transmission — `.hudWindow` alone passes ~70%, so
        // an extra 25%-opaque black layer brings the combined
        // transmission to 0.7 × 0.75 = 0.525, roughly halfway
        // between "fully translucent material" and "35% see-through"
        // (the two prior calibration points). Frost/blur is the
        // material's job; the overlay only darkens. Suppressed in
        // visualizer mode so the viz scene renders against pure
        // black (the material would wash out HDR additive blends).
        .background {
            if !appModel.showVisualizer {
                ZStack {
                    VisualEffectBackground()
                    Color.black.opacity(0.25)
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .background(TransparentWindowConfigurator())
        .onAppear {
            // First-launch presentation. The sheet flips the AppStorage
            // flag on completion/skip, so we never present it again
            // unless the user manually resets it.
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(appModel)
        }
    }

    // MARK: - Shell layout

    private var shellLayout: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            // Persistent footer below the SplitView, spanning both
            // columns. Match the macOS chrome with a thin material
            // background + top divider — quietly present without
            // competing with the source detail panels for attention.
            GlobalNowPlayingFooter()
                .environment(appModel)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<SidebarSource?>(
            get: { appModel.selectedSource },
            set: { if let v = $0 { appModel.selectedSource = v } }
        )) {
            Section {
                row(.appleMusic)
                row(.local)
                row(.spotify)
                row(.youTubeMusic)
            } header: {
                sectionHeader("SOURCES")
            }
            Section {
                row(.settings)
            } header: {
                sectionHeader("APP")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        .navigationTitle("High Videlity")
    }

    /// Tracking-spaced caps for section headers. Smaller and lighter
    /// than the default; pulls the section title closer to a modern
    /// AM/Spotify "DISCOVER" style than SwiftUI's default header.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(1.0)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    /// Per-source row. The icon sits inside a translucent glass
    /// capsule — material backdrop + thin highlight stroke — so the
    /// row reads as a calm chrome element rather than a saturated
    /// brand chip. Brand color shows up as a subtle tint on the
    /// glyph itself; the background is uniform across all sources.
    private func row(_ source: SidebarSource) -> some View {
        HStack(spacing: 12) {
            GlassIcon(systemImage: source.systemImage,
                      glyphTint: glyphTint(for: source))
            Text(source.displayName)
                .font(.callout)
            Spacer(minLength: 4)
            if !source.isImplemented {
                Text("Soon")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .tag(source)
    }

    private func glyphTint(for source: SidebarSource) -> Color {
        if let rgb = source.tintColorRGB {
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return .secondary
    }

    // MARK: - Detail

    /// Each source gets its OWN NavigationStack so drill-down rows
    /// (album → AlbumDetailView, artist → ArtistDetailView, etc.)
    /// have somewhere to push. Phase 7's switch to NavigationSplitView
    /// removed the app-level NavigationStack that previously hosted
    /// these pushes; without re-establishing per-source stacks here,
    /// every NavigationLink inside the source detail panels is a
    /// no-op. Per-source stacks also mean the back chevron is scoped
    /// to that source — switching the sidebar selection resets the
    /// stack rather than carrying an unrelated push from another
    /// source.
    @ViewBuilder
    private var detail: some View {
        switch appModel.selectedSource {
        case .appleMusic:
            NavigationStack { AppleMusicSourceView() }
        case .local:
            NavigationStack { LocalSourceView() }
        case .spotify:
            NavigationStack { ComingSoonView(source: .spotify) }
        case .youTubeMusic:
            NavigationStack { ComingSoonView(source: .youTubeMusic) }
        case .settings:
            NavigationStack { SettingsSourceView() }
        }
    }

    // MARK: - Visualizer overlay

    private var visualizerOverlay: some View {
        VisualizerView()
            .environment(appModel)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button {
                    appModel.showVisualizer = false
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(16)
                .help("Back to library")
                .accessibilityLabel("Back to library")
            }
    }
}

// MARK: - Global Now-Playing Footer

/// Source-agnostic bar at the bottom of the shell. Shows whatever is
/// currently producing audio (Apple Music song, mic, macOS system-
/// audio tap source) and exposes the "Open Visualizer" entry point so
/// it's always one click away regardless of which sidebar Source is
/// active. Compact transport (prev/play-pause/next) appears only when
/// MusicKit is driving in-app playback — for mic / system-audio modes
/// the user can use the source app's own transport.
struct GlobalNowPlayingFooter: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                sourceBlock
                Spacer(minLength: 16)
                if appModel.musicKit.isPlaying || appModel.musicKit.nowPlaying != nil {
                    MiniTransport(musicKit: appModel.musicKit)
                }
                Spacer(minLength: 16)
                openVisualizerButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background {
            // Material backdrop + art-derived gradient tint. MusicKit's
            // Artwork exposes `backgroundColor` pre-computed by Apple
            // (no async image fetch needed), so this is essentially
            // free per track change.
            ZStack {
                Rectangle().fill(.thinMaterial)
                if let cg = appModel.musicKit.nowPlaying?.artwork?.backgroundColor {
                    LinearGradient(
                        colors: [
                            Color(cgColor: cg).opacity(0.32),
                            Color(cgColor: cg).opacity(0.08)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .blendMode(.plusLighter)
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appModel.musicKit.nowPlaying?.id)
    }

    // Left side: source-agnostic now-playing block. When MusicKit has
    // a track, lean into the artwork — that's the visual anchor of the
    // whole footer. Otherwise show a quieter status row.
    @ViewBuilder
    private var sourceBlock: some View {
        if let np = appModel.musicKit.nowPlaying {
            HStack(spacing: 12) {
                ArtworkView(artwork: np.artwork, size: 52, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(np.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = np.albumTitle {
                        Text(album)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        } else if appModel.useSystemAudio {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 52, height: 52)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(systemAudioFooterLabel)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("System audio")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if appModel.useMic {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 52, height: 52)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening with mic")
                        .font(.callout.weight(.medium))
                    Text("External audio")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 52, height: 52)
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Pick a song to begin")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var systemAudioFooterLabel: String {
        let raw = appModel.systemAudio.tappedProcessName ?? "System audio"
        return SystemAudioSourcePicker.friendlyName(raw)
    }

    private var openVisualizerButton: some View {
        Button {
            appModel.showVisualizer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Open Visualizer")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(Color.accentColor.gradient)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .shadow(color: .accentColor.opacity(0.35), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Glass icon

/// Liquid-glass icon badge for sidebar rows. A small rounded-square
/// material backdrop with a subtle top-edge highlight and a thin
/// outer stroke; the SF Symbol glyph sits on top tinted with the
/// owning source's brand color. Reads as "calm chrome" rather than a
/// saturated brand chip.
///
/// macOS 26+ exposes the proper `.glassEffect()` modifier on
/// `View` (the "liquid glass" introduced in the same release).
/// We use it directly — the deployment target is macOS 26 so we
/// don't need a fallback path. If we ever lower the target, wrap
/// the call with `if #available(macOS 26.0, *)` and substitute
/// `.background(.regularMaterial, in: shape)` for older OSes.
private struct GlassIcon: View {
    let systemImage: String
    let glyphTint: Color

    private let size: CGFloat = 28
    private let corner: CGFloat = 7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(glyphTint)
            .frame(width: size, height: size)
            .glassEffect(in: shape)
    }
}

// MARK: - Keyboard shortcuts
//
// Hidden buttons in a single struct so we can drop the whole bundle
// into the root view via .background or a ZStack overlay. Each
// `.keyboardShortcut(...)` modifier registers a shortcut that fires
// the button's action when nothing else has consumed the key event
// (text fields' first-responder absorbs space and arrows normally,
// so these don't interfere with typing in the search field).
//
// `.hidden()` keeps them off-screen visually but still part of the
// view hierarchy — the shortcut dispatcher reaches them either way.
struct KeyboardShortcuts: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            // Space — play/pause. modifiers: [] = no modifier key.
            Button("Play/Pause") {
                Task { await appModel.musicKit.togglePlayPause() }
            }
            .keyboardShortcut(.space, modifiers: [])

            // ← / → — prev / next track.
            Button("Previous Track") {
                Task { await appModel.musicKit.skipToPrevious() }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Next Track") {
                Task { await appModel.musicKit.skipToNext() }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            // ⌘F — jump to Apple Music search and focus the field.
            // The counter bump is observed by SearchResultsView, which
            // calls .focus() on its TextField in response.
            Button("Find") {
                appModel.selectedSource = .appleMusic
                appModel.showVisualizer = false
                appModel.focusSearchRequest &+= 1
            }
            .keyboardShortcut("f", modifiers: [.command])

            // ⌘L — open Local Library source.
            Button("Local Library") {
                appModel.selectedSource = .local
                appModel.showVisualizer = false
            }
            .keyboardShortcut("l", modifiers: [.command])
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Mini transport for the footer — separate View struct so its 8 Hz
// observation of `musicKit.isPlaying` doesn't invalidate the rest of
// the footer body. Same lesson as Phase 6's ScrubberRow extraction.
private struct MiniTransport: View {
    let musicKit: MusicKitController

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Task { await musicKit.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .help("Previous")

            Button {
                Task { await musicKit.togglePlayPause() }
            } label: {
                Image(systemName: musicKit.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help(musicKit.isPlaying ? "Pause" : "Play")

            Button {
                Task { await musicKit.skipToNext() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .help("Next")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
    }
}

#endif
