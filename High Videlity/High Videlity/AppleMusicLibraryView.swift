//
//  AppleMusicLibraryView.swift
//  High Videlity
//
//  Browse the user's Apple Music library — Songs / Albums / Artists /
//  Playlists. Presented as a sheet on macOS (Phase 7 will rehome it
//  into the sidebar). Lazy-loads each category's data on first tab
//  switch; cached for the lifetime of the sheet.
//
//  Per-row actions mirror SearchResultsView (Play / Play Next /
//  Add to Queue for songs; Play Album / Add to Queue for albums;
//  Play Playlist / Add to Queue for playlists). Albums and playlists
//  navigate to their existing detail views via NavigationStack so
//  the user can drill into individual tracks.
//
//  Recently-played is intentionally not wired yet — MusicKit's
//  `MusicRecentlyPlayedRequest<T>` requires types I haven't
//  confirmed; will add once the right generic surface is known.
//

import SwiftUI
import MusicKit

struct AppleMusicLibraryView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Category: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    @State private var selected: Category = .albums

    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var loading: Set<Category> = []

    // Track which categories have been loaded so we don't refetch
    // every tab switch. Set on first successful load; "Reload" button
    // in the toolbar clears the marker for the current category to
    // force a refetch.
    @State private var loadedOnce: Set<Category> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Category", selection: $selected) {
                    ForEach(Category.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                Group {
                    switch selected {
                    case .songs:     songsList
                    case .albums:    albumsList
                    case .artists:   artistsList
                    case .playlists: playlistsList
                    }
                }
            }
            .navigationTitle("My Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        loadedOnce.remove(selected)
                        Task { await loadIfNeeded(selected, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload")
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .task { await loadIfNeeded(selected) }
        .onChange(of: selected) { _, new in
            Task { await loadIfNeeded(new) }
        }
    }

    // MARK: - Per-category lists

    @ViewBuilder
    private var songsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loading.contains(.songs) && songs.isEmpty {
                    ProgressView().padding()
                } else if songs.isEmpty {
                    Text("No songs in your library yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(songs, id: \.id) { song in
                        songRow(song)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var albumsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loading.contains(.albums) && albums.isEmpty {
                    ProgressView().padding()
                } else if albums.isEmpty {
                    Text("No albums in your library yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(albums, id: \.id) { album in
                        albumRow(album)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var artistsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loading.contains(.artists) && artists.isEmpty {
                    ProgressView().padding()
                } else if artists.isEmpty {
                    Text("No artists in your library yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(artists, id: \.id) { artist in
                        artistRow(artist)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var playlistsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loading.contains(.playlists) && playlists.isEmpty {
                    ProgressView().padding()
                } else if playlists.isEmpty {
                    Text("No playlists in your library yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(playlists, id: \.id) { pl in
                        playlistRow(pl)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    // MARK: - Rows

    private func songRow(_ song: Song) -> some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            HStack(spacing: 10) {
                artwork(song.artwork, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.playAppleMusicSong(song) } } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { Task { await appModel.musicKit.queueNext(song) } } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { Task { await appModel.musicKit.queueLast(song) } } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            HStack(spacing: 10) {
                artwork(album.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).lineLimit(1)
                    Text(album.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.musicKit.play(album: album) } } label: {
                Label("Play Album", systemImage: "play.fill")
            }
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            HStack(spacing: 10) {
                artwork(artist.artwork, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            HStack(spacing: 10) {
                artwork(playlist.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).lineLimit(1)
                    if let curator = playlist.curatorName, !curator.isEmpty {
                        Text(curator)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.musicKit.play(playlist: playlist) } } label: {
                Label("Play Playlist", systemImage: "play.fill")
            }
        }
    }

    @ViewBuilder
    private func artwork(_ art: Artwork?, size: CGFloat) -> some View {
        if let art, let url = art.url(width: Int(size * 2), height: Int(size * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Loading

    private func loadIfNeeded(_ category: Category, force: Bool = false) async {
        if !force, loadedOnce.contains(category) { return }
        guard !loading.contains(category) else { return }
        loading.insert(category)
        defer { loading.remove(category) }

        switch category {
        case .songs:
            songs = await appModel.musicKit.librarySongs()
        case .albums:
            albums = await appModel.musicKit.libraryAlbums()
        case .artists:
            artists = await appModel.musicKit.libraryArtists()
        case .playlists:
            playlists = await appModel.musicKit.libraryPlaylists()
        }
        loadedOnce.insert(category)
    }
}
