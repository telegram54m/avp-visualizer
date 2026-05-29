//
//  UpNextView.swift
//  High Videlity
//
//  Lists the upcoming queue entries from ApplicationMusicPlayer.
//  Tap a row to jump to that song; hover to reveal the remove
//  action; right-click for the same actions.
//
//  Reads `appModel.musicKit.upcomingItems`, which the MusicKit
//  polling loop refreshes whenever the queue's signature actually
//  changes (see `MusicKitController.refreshUpcoming`).
//
//  Rows render via the shared `MediaRow` component on macOS for
//  consistency with search results; visionOS still uses the
//  bordered-button fallback because MediaRow is macOS-only.
//

import SwiftUI
import MusicKit

struct UpNextView: View {
    let appModel: AppModel

    var body: some View {
        let mk = appModel.musicKit
        if mk.upcomingItems.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Up Next")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(mk.upcomingItems.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)

                #if os(macOS)
                VStack(spacing: 2) {
                    ForEach(Array(mk.upcomingItems.enumerated()), id: \.element.id) { _, item in
                        upNextRow(item)
                    }
                }
                #else
                VStack(spacing: 4) {
                    ForEach(Array(mk.upcomingItems.enumerated()), id: \.element.id) { idx, item in
                        legacyRow(item, position: idx + 1)
                    }
                }
                #endif
            }
            .frame(maxWidth: 420)
        }
    }

    #if os(macOS)
    /// Row backed by MediaRow. Tap = jump to song (queue rebuild),
    /// hover trash glyph = remove from queue.
    private func upNextRow(_ item: MusicKitController.UpNextItem) -> some View {
        let song = item.song
        let canPlay = song != nil
        return MediaRow(
            artwork: song?.artwork,
            title: item.title,
            subtitle: item.artist.isEmpty ? nil : item.artist,
            artworkSize: 40,
            accessory: canPlay ? .play : .none,
            hoverActions: [
                MediaRowAction(systemImage: "trash", help: "Remove from Queue") {
                    appModel.musicKit.removeFromQueue(entryID: item.id)
                    appModel.musicKit.refreshUpcoming()
                }
            ],
            contextActions: canPlay ? [
                MediaRowAction(systemImage: "play.fill", help: "Play Now") {
                    if let song { Task { await appModel.musicKit.skipToQueuedSong(song) } }
                },
                MediaRowAction(systemImage: "trash", help: "Remove from Queue") {
                    appModel.musicKit.removeFromQueue(entryID: item.id)
                    appModel.musicKit.refreshUpcoming()
                }
            ] : [
                MediaRowAction(systemImage: "trash", help: "Remove from Queue") {
                    appModel.musicKit.removeFromQueue(entryID: item.id)
                    appModel.musicKit.refreshUpcoming()
                }
            ]
        ) {
            if let song { Task { await appModel.musicKit.skipToQueuedSong(song) } }
        }
    }
    #else
    private func legacyRow(_ item: MusicKitController.UpNextItem, position: Int) -> some View {
        Button {
            if let song = item.song {
                Task { await appModel.musicKit.skipToQueuedSong(song) }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(position)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "forward.end.fill")
                    .imageScale(.small)
                    .foregroundStyle(item.song == nil ? .tertiary : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .disabled(item.song == nil)
        .contextMenu {
            if let song = item.song {
                Button {
                    Task { await appModel.musicKit.skipToQueuedSong(song) }
                } label: { Label("Play Now", systemImage: "play.fill") }
            }
            Button(role: .destructive) {
                appModel.musicKit.removeFromQueue(entryID: item.id)
                appModel.musicKit.refreshUpcoming()
            } label: { Label("Remove from Queue", systemImage: "trash") }
        }
    }
    #endif
}
