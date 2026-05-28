//
//  ArtistDetailView.swift
//  High Videlity
//
//  Drill-down view for an Artist from search results. Header (large
//  artwork + name), then Top Songs list (tappable to play / queue)
//  and Albums grid (tappable into AlbumDetailView). Relationships
//  fetched via `Artist.with([.topSongs, .albums])` on appear.
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct ArtistDetailView: View {

    @Environment(AppModel.self) private var appModel
    let artist: Artist

    @State private var detailed: Artist?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let err = loadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else {
                    topSongsSection
                    albumsSection
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .task {
            await loadDetail()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(artwork: artist.artwork, size: 140, cornerRadius: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name).font(.title2).bold().lineLimit(2)
                if let genres = artist.genreNames, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if let songs = detailed?.topSongs, !songs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Songs").font(.headline)
                VStack(spacing: 4) {
                    ForEach(songs, id: \.id) { song in
                        topSongRow(song)
                    }
                }
            }
        }
    }

    private func topSongRow(_ song: Song) -> some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            HStack(spacing: 10) {
                ArtworkView(artwork: song.artwork, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(song.albumTitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill").imageScale(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .contextMenu {
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

    @ViewBuilder
    private var albumsSection: some View {
        if let albums = detailed?.albums, !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Albums").font(.headline)
                // 3-column grid on macOS; SwiftUI's adaptive grid
                // fills as many columns as fit the container.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(albums, id: \.id) { album in
                        albumGridCell(album)
                    }
                }
            }
        }
    }

    private func albumGridCell(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
                .environment(appModel)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(artwork: album.artwork, size: 130, cornerRadius: 6)
                Text(album.title)
                    .font(.caption)
                    .lineLimit(2)
                if let date = album.releaseDate {
                    let fmt = DateFormatter()
                    Text({ fmt.dateFormat = "yyyy"; return fmt.string(from: date) }())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(album: album) }
            } label: { Label("Play Album", systemImage: "play.fill") }
        }
    }

    private func loadDetail() async {
        guard detailed == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await artist.with([.topSongs, .albums])
            detailed = loaded
        } catch {
            loadError = "Couldn't load artist: \(error.localizedDescription)"
        }
    }
}
#endif
