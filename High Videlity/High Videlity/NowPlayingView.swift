//
//  NowPlayingView.swift
//  High Videlity
//
//  Full now-playing surface — album art, title/artist, scrubber +
//  transport, AirPlay route picker, and a tabbed Up Next / Lyrics
//  area. Hosted as a macOS `.inspector(...)` panel from ContentView.
//
//  Reads `appModel.musicKit` live: `nowPlaying` drives the header,
//  `playbackTime` / `currentDuration` drive the scrubber, `isPlaying`
//  toggles the play-pause glyph. Writes via the new `seek(to:)`,
//  `togglePlayPause()`, etc. helpers on MusicKitController.
//
//  Mac-first per Phase 3 scope — visionOS still uses the legacy
//  in-line now-playing label; iOS shell rework comes later.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct NowPlayingView: View {

    @Environment(AppModel.self) private var appModel

    /// Scrubber thumb position while the user is dragging. nil when
    /// they're not — at which point we display the live playbackTime
    /// straight from the polling loop. Holding it lets the thumb
    /// stay where the cursor is instead of snapping back per poll
    /// tick.
    @State private var scrubDraft: Double?

    enum SecondaryTab: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case lyrics = "Lyrics"
        var id: String { rawValue }
    }
    @State private var tab: SecondaryTab = .upNext

    var body: some View {
        let mk = appModel.musicKit
        let np = mk.nowPlaying
        VStack(spacing: 14) {
            if np != nil {
                header(np: np!)
                transportRow
                scrubber
                Divider()
                secondaryTabs
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

    // MARK: - Header

    private func header(np: Song) -> some View {
        VStack(spacing: 10) {
            ArtworkView(artwork: np.artwork, size: 220, cornerRadius: 10)
                .shadow(radius: 8, y: 4)
            VStack(spacing: 2) {
                Text(np.title)
                    .font(.title3)
                    .bold()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(np.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = np.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transport

    private var transportRow: some View {
        let mk = appModel.musicKit
        return HStack(spacing: 20) {
            Button {
                Task { await mk.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill").imageScale(.large)
            }
            .buttonStyle(.borderless)

            Button {
                Task { await mk.togglePlayPause() }
            } label: {
                Image(systemName: mk.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
            }
            .buttonStyle(.borderless)

            Button {
                Task { await mk.skipToNext() }
            } label: {
                Image(systemName: "forward.fill").imageScale(.large)
            }
            .buttonStyle(.borderless)

            // AirPlay picker — system route flyout. Small fixed
            // width so it doesn't dominate the row.
            AirPlayButton()
                .frame(width: 32, height: 24)
                .padding(.leading, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        let mk = appModel.musicKit
        let duration = max(mk.currentDuration, 1)  // avoid /0 on slider
        // Use the local draft while the user is dragging; otherwise
        // mirror the live playbackTime.
        let displayed = scrubDraft ?? mk.playbackTime
        return VStack(spacing: 2) {
            Slider(
                value: Binding<Double>(
                    get: { min(max(displayed, 0), duration) },
                    set: { newValue in scrubDraft = newValue }
                ),
                in: 0...duration,
                onEditingChanged: { isEditing in
                    if !isEditing, let draft = scrubDraft {
                        mk.seek(to: draft)
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

    // MARK: - Secondary content (Up Next | Lyrics)

    private var secondaryTabs: some View {
        Picker("", selection: $tab) {
            ForEach(SecondaryTab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
    }

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

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
