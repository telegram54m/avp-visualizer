//
//  NowPlayingView.swift
//  High Videlity
//
//  Full now-playing surface — album art, title/artist, scrubber +
//  transport, AirPlay route picker, and a tabbed Up Next / Lyrics
//  area. Hosted as a macOS `.inspector(...)` panel from ContentView
//  AND VisualizerView, mounted only when the shared
//  `appModel.showNowPlayingInspector` flag is true (see the call
//  sites — both wrap the content closure with that gate so the panel
//  fully tears down on close).
//
//  **Observation scoping (performance):** the polling task in
//  `MusicKitController` mutates `playbackTime` ~8 Hz. If the scrubber
//  / transport were just computed-property `some View` chunks of the
//  parent body, every read of `mk.playbackTime` would track against
//  THIS view's observation context — meaning every 125 ms poll would
//  invalidate the entire panel (header artwork, Up Next list, lyrics
//  view, all of it) just to redraw the scrubber thumb. While viz is
//  running at 100 fps that single observer was costing 60 fps. The
//  fix: extract the high-frequency-reading rows into their own
//  `View` structs (`ScrubberRow`, `TransportRow`) so their bodies
//  carry their own observation scopes. A `playbackTime` mutation now
//  only invalidates `ScrubberRow`, not the rest of the panel.
//
//  Mac-first per Phase 3 scope — visionOS still uses the legacy
//  in-line now-playing label; iOS shell rework comes later.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct NowPlayingView: View {

    @Environment(AppModel.self) private var appModel

    enum SecondaryTab: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case lyrics = "Lyrics"
        var id: String { rawValue }
    }
    @State private var tab: SecondaryTab = .upNext

    var body: some View {
        // Reading `mk.nowPlaying` is fine in the outer body — it
        // only changes on track change, not 8 Hz. The scrubber and
        // transport reads of playbackTime / isPlaying live in
        // dedicated child views so their invalidation doesn't
        // cascade up through this body.
        let np = appModel.musicKit.nowPlaying
        VStack(spacing: 14) {
            // Close affordance — needed in viz mode where the badge
            // button that opened the drawer is hidden while the drawer
            // is up. On the main screen the toolbar button can also
            // close it; this gives a consistent in-panel exit.
            HStack {
                Spacer()
                Button {
                    appModel.showNowPlayingInspector = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide Now Playing panel")
                .accessibilityLabel("Hide Now Playing panel")
            }
            if let np {
                NowPlayingHeader(song: np)
                TransportRow(musicKit: appModel.musicKit)
                ScrubberRow(musicKit: appModel.musicKit)
                Divider()
                Picker("", selection: $tab) {
                    ForEach(SecondaryTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                secondaryContent
                Spacer(minLength: 0)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Search Apple Music and tap a song to begin.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Secondary content (Up Next | Lyrics)

    @ViewBuilder
    private var secondaryContent: some View {
        switch tab {
        case .upNext:
            // The standalone UpNextView in ContentView shows the same
            // queue; the inspector instance is the primary surface
            // when the now-playing panel is open. They share state
            // via MusicKitController, so changes from either pane
            // reflect in both.
            ScrollView {
                UpNextView(appModel: appModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .lyrics:
            LyricsView()
        }
    }
}

// MARK: - Header (only invalidates on track change)

private struct NowPlayingHeader: View {
    let song: Song

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(artwork: song.artwork, size: 220, cornerRadius: 10)
                .shadow(radius: 8, y: 4)
            VStack(spacing: 2) {
                Text(song.title)
                    .font(.title3)
                    .bold()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(song.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = song.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Transport (invalidates only on isPlaying / sleepTimer changes)

private struct TransportRow: View {
    let musicKit: MusicKitController
    @Environment(AppModel.self) private var appModel
    @State private var showSessionControls = false

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await musicKit.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill").imageScale(.large)
            }
            .buttonStyle(.borderless)

            Button {
                Task { await musicKit.togglePlayPause() }
            } label: {
                Image(systemName: musicKit.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
            }
            .buttonStyle(.borderless)

            Button {
                Task { await musicKit.skipToNext() }
            } label: {
                Image(systemName: "forward.fill").imageScale(.large)
            }
            .buttonStyle(.borderless)

            // AirPlay picker — system route flyout. Small fixed
            // width so it doesn't dominate the row.
            AirPlayButton()
                .frame(width: 32, height: 24)
                .padding(.leading, 10)

            // Phase 6 — sleep timer. Glyph flips to the filled "zzz"
            // variant while a timer is armed.
            Button {
                showSessionControls.toggle()
            } label: {
                Image(systemName: musicKit.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help(musicKit.sleepTimerActive
                ? "Sleep timer running"
                : "Sleep timer")
            .popover(isPresented: $showSessionControls, arrowEdge: .top) {
                SessionControlsView()
                    .environment(appModel)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Scrubber (the 8 Hz reader — isolated to its own body)

private struct ScrubberRow: View {
    let musicKit: MusicKitController

    /// Scrubber thumb position while the user is dragging. nil when
    /// they're not — at which point we display the live playbackTime
    /// straight from the polling loop. Holding it lets the thumb
    /// stay where the cursor is instead of snapping back per poll
    /// tick.
    @State private var scrubDraft: Double?

    var body: some View {
        let duration = max(musicKit.currentDuration, 1)  // avoid /0 on slider
        let displayed = scrubDraft ?? musicKit.playbackTime
        VStack(spacing: 2) {
            Slider(
                value: Binding<Double>(
                    get: { min(max(displayed, 0), duration) },
                    set: { newValue in scrubDraft = newValue }
                ),
                in: 0...duration,
                onEditingChanged: { isEditing in
                    if !isEditing, let draft = scrubDraft {
                        musicKit.seek(to: draft)
                        scrubDraft = nil
                    }
                }
            )
            HStack {
                Text(formatTime(displayed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
