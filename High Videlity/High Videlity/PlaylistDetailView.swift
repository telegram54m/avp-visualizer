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
                DetailHero(
                    eyebrow: "PLAYLIST",
                    title: playlist.name,
                    subtitle: playlist.curatorName,
                    metadata: metadataLine,
                    artwork: playlist.artwork,
                    tintColor: playlist.artwork?.backgroundColor,
                    primaryAction: (
                        label: "Play",
                        systemImage: "play.fill",
                        perform: { Task { await appModel.musicKit.play(playlist: playlist) } }
                    ),
                    secondaryAction: (
                        label: "Add to Queue",
                        systemImage: "text.append",
                        perform: { Task { await addPlaylistToQueue() } }
                    )
                )
                VStack(alignment: .leading, spacing: 12) {
                    if let desc = playlist.standardDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .padding(.bottom, 4)
                    }
                    trackList
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task {
            await loadDetail()
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let count = detailed?.tracks?.count, count > 0 {
            parts.append("\(count) tracks")
        }
        return parts.joined(separator: " · ")
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
        let actions: [MediaRowAction] = song.map { s in
            [
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(s) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(s) }
                }
            ]
        } ?? []
        let contextActions: [MediaRowAction] = song.map { s in
            [
                MediaRowAction(systemImage: "play.fill", help: "Play Now") {
                    Task { await appModel.playAppleMusicSong(s) }
                },
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(s) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(s) }
                }
            ]
        } ?? []
        // Use MediaRow rather than TrackRow because playlist tracks
        // span multiple albums — per-track artwork is meaningful.
        // `_ = position` keeps the parameter so callers still index
        // correctly; future enhancement could surface it inline.
        _ = position
        return MediaRow(
            artwork: track.artwork,
            title: track.title,
            subtitle: track.artistName,
            artworkSize: 40,
            accessory: song == nil ? .none : .play,
            hoverActions: actions,
            contextActions: contextActions
        ) {
            if let song { Task { await appModel.playAppleMusicSong(song) } }
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
