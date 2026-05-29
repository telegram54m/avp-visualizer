//
//  AlbumDetailView.swift
//  High Videlity
//
//  Drill-down view for an Album from search results. Shows album
//  art + title + artist + release year, then a track list with
//  per-row play / queue / Play Next actions. Top-level buttons
//  to Play Album and Add Album to Queue.
//
//  Tracks load asynchronously via `Album.with([.tracks])` on
//  appear — the search-result Album doesn't include tracks by
//  default.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct AlbumDetailView: View {

    @Environment(AppModel.self) private var appModel
    let album: Album

    @State private var detailed: Album?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHero(
                    eyebrow: "ALBUM",
                    title: album.title,
                    subtitle: album.artistName,
                    metadata: metadataLine,
                    artwork: album.artwork,
                    tintColor: album.artwork?.backgroundColor,
                    primaryAction: (
                        label: "Play",
                        systemImage: "play.fill",
                        perform: { Task { await appModel.musicKit.play(album: album) } }
                    ),
                    secondaryAction: (
                        label: "Add to Queue",
                        systemImage: "text.append",
                        perform: { Task { await addAlbumToQueue() } }
                    )
                )
                VStack(alignment: .leading, spacing: 16) {
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

    /// Dot-separated metadata line under the artist row in the hero —
    /// year, track count, total duration when known. Skips any
    /// segment with no data so the line stays clean.
    private var metadataLine: String {
        var parts: [String] = []
        if let year = albumYear { parts.append(year) }
        if let count = detailed?.tracks?.count, count > 0 {
            parts.append("\(count) tracks")
        }
        if let totalSeconds = totalDurationSeconds, totalSeconds > 0 {
            parts.append(formatTotalDuration(totalSeconds))
        }
        return parts.joined(separator: " · ")
    }

    private var totalDurationSeconds: TimeInterval? {
        guard let tracks = detailed?.tracks else { return nil }
        let total = tracks.compactMap { $0.duration }.reduce(0, +)
        return total > 0 ? total : nil
    }

    private func formatTotalDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
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
        return TrackRow(
            position: position,
            title: track.title,
            subtitle: nil,
            durationSeconds: track.duration,
            hoverActions: actions,
            contextActions: contextActions,
            isDisabled: song == nil
        ) {
            if let song { Task { await appModel.playAppleMusicSong(song) } }
        }
    }

    private var albumYear: String? {
        guard let date = album.releaseDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        return fmt.string(from: date)
    }

    private func loadDetail() async {
        guard detailed == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await album.with([.tracks])
            detailed = loaded
        } catch {
            loadError = "Couldn't load tracks: \(error.localizedDescription)"
        }
    }

    /// Append every track on the album to the end of the queue.
    private func addAlbumToQueue() async {
        guard let tracks = detailed?.tracks else { return }
        for track in tracks {
            if let song = songFromTrack(track) {
                await appModel.musicKit.queueLast(song)
            }
        }
    }

    /// MusicKit's `Track` is an enum of song/musicVideo. Extract the
    /// Song case; nil for music videos (we don't play those).
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
