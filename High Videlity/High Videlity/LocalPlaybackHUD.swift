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
            Button {
                appModel.restartLocalPlayback()
                tickerTrigger = Date()
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 24, height: 24)
            }
            .help("Restart from beginning")

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

            // Next-track is library-only. Hidden for one-off file
            // imports since "next" has no defined meaning there.
            #if os(macOS)
            if appModel.currentLibraryEntryURL != nil {
                Button {
                    playNextLibraryEntry()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 24, height: 24)
                }
                .help("Next track in library")
            }
            #endif
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.white)
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
