//
//  LocalPlaybackHUD.swift
//  High Videlity
//
//  Bottom-right overlay shown over the visualizer when a local
//  AVAudioPlayer is the active audio source — i.e., when the user
//  imported an audio file or picked one from the library browser.
//  Hidden when other audio paths are active (mic / system audio /
//  Music.app / Apple Music); those have their own controls.
//
//  Controls:
//   • Restart current track
//   • Play / pause toggle
//   • Next track (LIBRARY MODE ONLY) — advances through the library
//     in the user's last-chosen sort order via LibraryStore.
//
//  Layout matches the macOS NowPlayingBadge pattern (bottom-right,
//  source name + transport row). Scrubbing / seeking still deferred.
//

import SwiftUI

struct LocalPlaybackHUD: View {

    @Environment(AppModel.self) private var appModel

    /// 1 Hz timer drives an isPlaying refresh — AVAudioPlayer doesn't
    /// publish state changes, and we don't want the HUD's play/pause
    /// icon to stay stale if playback finishes mid-song or the user
    /// toggles externally.
    @State private var tickerTrigger: Date = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            #if os(macOS)
            inspectorRow
            #endif
            sourceLine
            transportRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .task(id: tickerTrigger) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            tickerTrigger = Date()
        }
    }

    #if os(macOS)
    /// Inspector toggle + "Local Library" tag, matching the
    /// system-audio NowPlayingBadge's top row. Lets the user open
    /// the Up Next / inspector panel from inside the visualizer
    /// without leaving the full-bleed view.
    private var inspectorRow: some View {
        HStack(spacing: 6) {
            Button {
                appModel.showNowPlayingInspector = true
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Open Now Playing panel")
            .accessibilityLabel("Open Now Playing panel")

            Text("Local Library")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
    #endif

    /// Title — Artist when both are known; just title or "Local file"
    /// fallback otherwise. Caps at one line to keep the HUD compact.
    private var sourceLine: some View {
        let title = appModel.currentTrackTitle
        let artist = appModel.currentTrackArtist
        let display: String
        if !title.isEmpty && !artist.isEmpty {
            display = "\(title) — \(artist)"
        } else if !title.isEmpty {
            display = title
        } else {
            display = "Local file"
        }
        return Text(display)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
        // No frame constraint — Text sizes to content, matches the
        // NowPlayingBadge sibling overlay. Truncation kicks in if a
        // parent constrains the width.
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            // Previous: jumps to the prior queue entry when the
            // local queue has one; otherwise restarts the current
            // track (familiar dual-action pattern from Music.app).
            Button {
                #if os(macOS)
                if appModel.localQueue.hasPrevious {
                    Task { await appModel.localPlayerSkipToPrevious() }
                } else {
                    appModel.restartLocalPlayback()
                }
                #else
                appModel.restartLocalPlayback()
                #endif
                tickerTrigger = Date()
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 24, height: 24)
            }
            .help(previousButtonHelp)

            Button {
                if appModel.isLocalPlaybackPlaying {
                    appModel.pauseLocalPlayback()
                } else {
                    appModel.resumeLocalPlayback()
                }
                tickerTrigger = Date()
            } label: {
                Image(systemName: appModel.isLocalPlaybackPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .help(appModel.isLocalPlaybackPlaying ? "Pause" : "Play")

            // Next: prefers the queue when populated, falls back to
            // walking the LibraryStore's sort order (the original
            // behavior for one-off library plays with no queue).
            #if os(macOS)
            if appModel.localQueue.hasNext || appModel.currentLibraryEntryURL != nil {
                Button {
                    if appModel.localQueue.hasNext {
                        Task { await appModel.localPlayerSkipToNext() }
                    } else {
                        playNextLibraryEntry()
                    }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 24, height: 24)
                }
                .help(appModel.localQueue.hasNext ? "Next in queue" : "Next track in library")
            }
            #endif
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.white)
    }

    /// Help text for the prev/restart button. Distinguishes the two
    /// modes so the tooltip matches what'll actually happen.
    private var previousButtonHelp: String {
        #if os(macOS)
        return appModel.localQueue.hasPrevious ? "Previous in queue" : "Restart from beginning"
        #else
        return "Restart from beginning"
        #endif
    }

    #if os(macOS)
    /// Advance to the next library entry in the user's chosen sort
    /// order. Wraps to the first entry past the end. No-op if the
    /// library is empty (shouldn't happen — the button is hidden
    /// when there's no current library entry to derive "next" from).
    private func playNextLibraryEntry() {
        guard let currentURL = appModel.currentLibraryEntryURL else { return }
        let library = appModel.library
        guard let next = library.nextEntry(after: currentURL) ?? library.firstEntry() else {
            return
        }
        let appModel = self.appModel
        let url = next.fileURL
        let title = next.title
        let artist = next.artist
        Task {
            await appModel.loadSong(from: url, title: title, artist: artist, libraryEntry: url)
        }
    }
    #endif
}
