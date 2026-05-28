//
//  UpNextView.swift
//  High Videlity
//
//  Lists the upcoming queue entries from ApplicationMusicPlayer.
//  Tap a row to jump to that song (queue-replace); right-click for
//  Remove. Hidden when the queue has nothing queued ahead of the
//  current track — no point taking up vertical space.
//
//  Reads `appModel.musicKit.upcomingItems`, which the MusicKit
//  polling loop refreshes whenever the queue's signature actually
//  changes. See `MusicKitController.refreshUpcoming`.
//
//  Rows render using `Queue.Entry.title` / `subtitle` directly so
//  they appear immediately on insert, even before MusicKit finishes
//  resolving the underlying Song. Tap-to-jump is enabled only when
//  the Song has resolved (needed for the queue rebuild that
//  skipToQueuedSong does).
//
//  Phase 1 cut: list + tap-to-jump + remove. Reorder via drag is
//  deferred (needs richer queue mutation API on MusicKit's side
//  than `entries.removeAll` and re-inserting).
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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Up Next")
                        .font(.headline)
                    Spacer()
                    Text("\(mk.upcomingItems.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 4) {
                    ForEach(Array(mk.upcomingItems.enumerated()), id: \.element.id) { idx, item in
                        upNextRow(item, position: idx + 1)
                    }
                }
            }
            .frame(maxWidth: 380)
        }
    }

    private func upNextRow(_ item: MusicKitController.UpNextItem, position: Int) -> some View {
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
}
