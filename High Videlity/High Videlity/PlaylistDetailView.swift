//
//  PlaylistDetailView.swift
//  High Videlity
//
//  Drill-down view for a Playlist from search results. Header with
//  art + name + curator + description, then the track list with
//  per-row + top-level actions. Tracks load via
//  `Playlist.with([.tracks])` on appear.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct PlaylistDetailView: View {

    @Environment(AppModel.self) private var appModel
    let playlist: Playlist

    @State private var detailed: Playlist?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionButtons
                trackList
            }
            .padding()
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .task {
            await loadDetail()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(artwork: playlist.artwork, size: 140, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.title2).bold().lineLimit(2)
                if let curator = playlist.curatorName {
                    Text(curator).font(.subheadline).foregroundStyle(.secondary)
                }
                if let count = detailed?.tracks?.count, count > 0 {
                    Text("\(count) tracks").font(.caption).foregroundStyle(.secondary)
                }
                if let desc = playlist.standardDescription, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await appModel.musicKit.play(playlist: playlist) }
            } label: {
                Label("Play Playlist", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { await addPlaylistToQueue() }
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if let err = loadError {
            Text(err).font(.caption).foregroundStyle(.red)
        } else if let tracks = detailed?.tracks, !tracks.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    trackRow(track, position: idx + 1)
                }
            }
        }
    }

    private func trackRow(_ track: Track, position: Int) -> some View {
        let song = songFromTrack(track)
        return Button {
            if let song { Task { await appModel.playAppleMusicSong(song) } }
        } label: {
            HStack(spacing: 10) {
                Text("\(position)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                ArtworkView(artwork: track.artwork, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let dur = track.duration {
                    Text(formatDuration(dur))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .disabled(song == nil)
        .contextMenu {
            if let song {
                Button {
                    Task { await appModel.playAppleMusicSong(song) }
                } label: { Label("Play Now", systemImage: "play.fill") }
                Button {
                    Task { await appModel.musicKit.queueNext(song) }
                } label: { Label("Play Next", systemImage: "text.insert") }
                Button {
                    Task { await appModel.musicKit.queueLast(song) }
                } label: { Label("Add to Queue", systemImage: "text.append") }
            }
        }
    }

    private func loadDetail() async {
        guard detailed == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await playlist.with([.tracks])
            detailed = loaded
        } catch {
            loadError = "Couldn't load tracks: \(error.localizedDescription)"
        }
    }

    private func addPlaylistToQueue() async {
        guard let tracks = detailed?.tracks else { return }
        for track in tracks {
            if let song = songFromTrack(track) {
                await appModel.musicKit.queueLast(song)
            }
        }
    }

    private func songFromTrack(_ track: Track) -> Song? {
        if case let .song(s) = track { return s }
        return nil
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
