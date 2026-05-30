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
            // columns. Now the canonical home for transport +
            // Up Next + Lyrics — the right-side inspector drawer
            // was retired in favor of a popover from the footer's
            // source block.
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
                #if os(macOS)
                row(.mac)
                #endif
                row(.microphone)
            } header: {
                sectionHeader("SOURCES")
            }
            Section {
                row(.visualizers)
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
        case .mac:
            #if os(macOS)
            NavigationStack { MacSourceView() }
            #else
            // .mac is sidebar-listed only on macOS (#if at row site),
            // so this branch is unreachable on iOS/visionOS. Empty
            // placeholder keeps the switch exhaustive.
            NavigationStack { EmptyView() }
            #endif
        case .microphone:
            NavigationStack { MicrophoneSourceView() }
        case .visualizers:
            NavigationStack { SettingsSourceView() }
        }
    }

    // MARK: - Visualizer overlay

    private var visualizerOverlay: some View {
        // Back-chevron overlay removed — the floating
        // GlobalNowPlayingFooter inside the viz carries the same
        // toggle ("Close Visualizer" pill on the right edge), so a
        // separate top-leading button is redundant. Closing happens
        // exactly where the user already looks to manage playback.
        VisualizerView()
            .environment(appModel)
            .ignoresSafeArea()
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
    /// Popover toggle for the source block. Replaces the inspector
    /// drawer — Up Next + Lyrics live inside [[NowPlayingPopover]].
    @State private var showSourcePopover = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                sourceBlockTappable
                Spacer(minLength: 16)
                // Pick the transport that matches the active source.
                // Local wins if local playback is current (the queue
                // owns the audio path); otherwise AM if AM is loaded.
                if isLocalPlaybackActive {
                    LocalMiniTransport()
                        .environment(appModel)
                } else if appModel.musicKit.isPlaying || appModel.musicKit.nowPlaying != nil {
                    MiniTransport(musicKit: appModel.musicKit)
                        .environment(appModel)
                }
                Spacer(minLength: 16)
                // Visualizer chrome — the unified control chip
                // (current mode | next mode | open/close) reads as
                // one capsule. The BPM pill stays adjacent as a
                // separate debug widget; it's not part of the
                // viz-control vocabulary, so blending it in would
                // dilute the chip's "viz controls" message.
                BpmPillExpander()
                    .environment(appModel)
                VisualizerControlChip()
                    .environment(appModel)
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

    /// True when the local-file player owns the audio path. Local
    /// playback isn't reflected on `musicKit.nowPlaying`, so the
    /// footer needs an explicit check to render its source block.
    private var isLocalPlaybackActive: Bool {
        appModel.hasLocalPlaybackSource || appModel.localQueue.currentItem != nil
    }

    /// True when there's enough context to render the popover (some
    /// kind of track is loaded, or the AM player has a queue worth
    /// surfacing). When false the source block stays tap-inert.
    private var hasPopoverContext: Bool {
        appModel.musicKit.nowPlaying != nil
            || isLocalPlaybackActive
            || !appModel.musicKit.upcomingItems.isEmpty
            || !(isLocalPlaybackActive ? appModel.localQueue.upcomingItems.isEmpty : true)
    }

    /// The source block wrapped in a Button that opens a popover
    /// carrying Up Next + Lyrics — the same content the inspector
    /// drawer used to host. Click anywhere on the block (artwork,
    /// title, artist) to open.
    @ViewBuilder
    private var sourceBlockTappable: some View {
        if hasPopoverContext {
            Button {
                showSourcePopover.toggle()
            } label: {
                sourceBlock
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSourcePopover, arrowEdge: .bottom) {
                NowPlayingPopover()
                    .environment(appModel)
                    .frame(width: 380, height: 460)
            }
        } else {
            sourceBlock
        }
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
        } else if isLocalPlaybackActive {
            // Local file. No MusicKit artwork — fall back to the
            // same hash-tinted gradient placeholder used elsewhere in
            // the Local Library surfaces so the visual vocabulary
            // stays consistent across the source's cards/rows/footer.
            let title = appModel.currentTrackTitle.isEmpty ? "Untitled track" : appModel.currentTrackTitle
            let artist = appModel.currentTrackArtist
            HStack(spacing: 12) {
                LocalArtTile(hashSeed: title + artist, size: 52, cornerRadius: 6)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("Local Library")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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

    // openVisualizerButton retired — its open/close toggle is now
    // the third segment of [[VisualizerControlChip]], paired with
    // the current-mode name + next-mode cycle in one unified
    // capsule.

}

// MARK: - Local mini transport

/// Mirror of [[MiniTransport]] for the local AVAudioPlayer pipeline.
/// Lives separately because the local source has its own queue +
/// transport methods on AppModel (`localPlayerSkipTo…`,
/// `pauseLocalPlayback`, etc.) and its own "is playing" signal
/// (`isLocalPlaybackPlaying`) — there's no shared transport
/// protocol yet, just two parallel shapes.
private struct LocalMiniTransport: View {
    @Environment(AppModel.self) private var appModel
    @State private var showSessionControls = false

    var body: some View {
        VStack(spacing: 6) {
            transportRow
            // The scrubber sits inside this VStack so its width
            // exactly matches the transport row above. Using
            // `.frame(maxWidth: .infinity)` lets the scrubber expand
            // to the VStack's column width, which the transport row
            // (the wider of the two) already establishes.
            LocalFooterScrubber()
                .environment(appModel)
                .frame(maxWidth: .infinity)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            // Sleep timer — leftmost. Note the timer acts on
            // ApplicationMusicPlayer only; for local playback it's
            // a no-op (footer in the popover explains). Kept here
            // for layout parity with the AM transport.
            Button {
                showSessionControls.toggle()
            } label: {
                Image(systemName: appModel.musicKit.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
            }
            .buttonStyle(.plain)
            .help(appModel.musicKit.sleepTimerActive ? "Sleep timer running" : "Sleep timer")
            .popover(isPresented: $showSessionControls, arrowEdge: .bottom) {
                SessionControlsView().environment(appModel)
            }

            Button {
                Task { await appModel.localPlayerSkipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!appModel.localQueue.hasPrevious)
            .help("Previous")

            Button {
                appModel.restartLocalPlayback()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Restart track")

            Button {
                if appModel.isLocalPlaybackPlaying {
                    appModel.pauseLocalPlayback()
                } else {
                    appModel.resumeLocalPlayback()
                }
            } label: {
                Image(systemName: appModel.isLocalPlaybackPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help(appModel.isLocalPlaybackPlaying ? "Pause" : "Play")

            Button {
                Task { await appModel.localPlayerSkipToNext() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!appModel.localQueue.hasNext)
            .help("Next")

            // AirPlay — rightmost. macOS routes the entire system
            // audio output through the picked device, so local
            // playback via AVAudioPlayer follows the AirPlay
            // selection too.
            AirPlayButton()
                .frame(width: 28, height: 22)
                .help("AirPlay output")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
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
    @Environment(AppModel.self) private var appModel
    @State private var showSessionControls = false

    var body: some View {
        VStack(spacing: 6) {
            transportRow
            AMFooterScrubber(musicKit: musicKit)
                .frame(maxWidth: .infinity)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            // Sleep timer — leftmost (per spec). Glyph fills while
            // a timer is armed.
            Button {
                showSessionControls.toggle()
            } label: {
                Image(systemName: musicKit.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
            }
            .buttonStyle(.plain)
            .help(musicKit.sleepTimerActive ? "Sleep timer running" : "Sleep timer")
            .popover(isPresented: $showSessionControls, arrowEdge: .bottom) {
                SessionControlsView().environment(appModel)
            }

            Button {
                Task { await musicKit.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .help("Previous")

            Button {
                musicKit.restartCurrent()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Restart track")

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

            // AirPlay route picker — rightmost. AVRoutePickerView
            // controls the macOS system audio output, so works for
            // every source (AM, local, mic-monitored, system-tap).
            AirPlayButton()
                .frame(width: 28, height: 22)
                .help("AirPlay output")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
    }
}

// MARK: - Footer scrubber

/// AM scrubber — binds to `musicKit.playbackTime` (an @Observable
/// property updated by the ApplicationMusicPlayer polling loop at
/// ~30 Hz). Uses the same scrub-draft pattern as
/// [[NowPlayingView.ScrubberRow]]: hold thumb position locally while
/// dragging, only seek on release.
private struct AMFooterScrubber: View {
    let musicKit: MusicKitController
    @State private var scrubDraft: Double?

    var body: some View {
        let duration = max(musicKit.currentDuration, 1)
        let displayed = scrubDraft ?? musicKit.playbackTime
        scrubberLayout(
            current: displayed,
            duration: duration,
            onChange: { newValue in scrubDraft = newValue },
            onCommit: {
                if let draft = scrubDraft {
                    musicKit.seek(to: draft)
                    scrubDraft = nil
                }
            }
        )
    }
}

/// Local-file scrubber. AVAudioPlayer's `currentTime` isn't
/// observable — it's freshly read on each access — so we drive a
/// 4 Hz redraw via TimelineView. Enough cadence for the thumb to look
/// fluid without burning UI work the rest of the footer doesn't need.
/// Same scrub-draft pattern as the AM row: thumb sticks under the
/// cursor during drag, seek fires on release.
private struct LocalFooterScrubber: View {
    @Environment(AppModel.self) private var appModel
    @State private var scrubDraft: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let current = appModel.localPlaybackCurrentTime ?? 0
            let duration = max(appModel.localPlaybackDuration ?? 0, 1)
            let displayed = scrubDraft ?? current
            scrubberLayout(
                current: displayed,
                duration: duration,
                onChange: { newValue in scrubDraft = newValue },
                onCommit: {
                    if let draft = scrubDraft {
                        appModel.seekLocalPlayback(to: draft)
                        scrubDraft = nil
                    }
                }
            )
        }
    }
}

/// Shared scrubber layout — glass scrubber track with elapsed /
/// remaining timestamps tucked beneath. Pulled out so both
/// source-specific scrubbers share the visual vocabulary without
/// duplicating it.
@ViewBuilder
private func scrubberLayout(
    current: Double,
    duration: Double,
    onChange: @escaping (Double) -> Void,
    onCommit: @escaping () -> Void
) -> some View {
    VStack(spacing: 2) {
        GlassScrubber(
            current: current,
            duration: duration,
            onChange: onChange,
            onCommit: onCommit
        )
        HStack {
            Text(formatScrubberTime(current))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("-" + formatScrubberTime(max(duration - current, 0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private func formatScrubberTime(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}

/// Custom scrubber matching the footer's calm-chrome vocabulary: a
/// 2pt material track + a small (7pt) translucent bead rendered with
/// the same `.glassEffect()` as the sidebar's GlassIcon. Replaces the
/// default SwiftUI Slider so we can shrink the thumb to ~half the
/// default size and make it read as glass rather than a solid puck.
///
/// Drag anywhere along the bar to scrub — the thumb is small enough
/// that requiring the user to hit it exactly would be cruel. The
/// `onChange` callback fires continuously during drag (so the live
/// elapsed/remaining text updates), and `onCommit` fires once on
/// release (when we seek the underlying player).
private struct GlassScrubber: View {
    let current: Double
    let duration: Double
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    /// Half the SwiftUI Slider's default thumb diameter (~14pt) per
    /// design ask. Affects hit-target friendliness — the whole row
    /// captures drag, but the visual bead is intentionally small.
    private let thumbDiameter: CGFloat = 7
    private let trackHeight: CGFloat = 2
    /// Vertical hit target — generous so the user can grab the bar
    /// without precision aim despite the small bead.
    private let rowHeight: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let safeDuration = max(duration, 1)
            let progress = min(max(current / safeDuration, 0), 1)
            let usableWidth = max(w - thumbDiameter, 0)
            let thumbX = usableWidth * CGFloat(progress)
            let fillWidth = thumbX + thumbDiameter / 2

            ZStack(alignment: .leading) {
                // Background track.
                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)
                // Progress fill — primary tint at low opacity so it
                // reads as "filled" without competing with the bead.
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: max(0, fillWidth), height: trackHeight)
                // Glass bead. `.fill(.clear)` + `.glassEffect()`
                // produces the translucent-puck look — same modifier
                // as [[GlassIcon]] but applied to a circle. A thin
                // outer stroke gives the bead a subtle defined edge
                // against the gradient-tinted footer background.
                Circle()
                    .fill(Color.clear)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .glassEffect(in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.primary.opacity(0.25), lineWidth: 0.5)
                    }
                    .offset(x: thumbX)
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard usableWidth > 0 else { return }
                        // Map x to track position. Subtract half the
                        // thumb so a tap at x=0 puts the bead's
                        // center at the left edge, not the bead's
                        // left edge — feels more natural.
                        let localX = g.location.x - thumbDiameter / 2
                        let frac = min(max(Double(localX / usableWidth), 0), 1)
                        onChange(frac * safeDuration)
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: rowHeight)
    }
}

#endif
