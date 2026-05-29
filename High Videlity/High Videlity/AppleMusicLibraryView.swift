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
        // Lives inside the AM source's NavigationStack now (rather
        // than as a modal sheet), so the reload action sits in the
        // shared toolbar instead of a Close-pair.
        .toolbar {
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
        .task { await loadIfNeeded(selected) }
        .onChange(of: selected) { _, new in
            Task { await loadIfNeeded(new) }
        }
    }

    // MARK: - Per-category lists

    @ViewBuilder
    private var songsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if loading.contains(.songs) && songs.isEmpty {
                    ProgressView().padding()
                } else if songs.isEmpty {
                    EmptyPlaceholder(
                        systemImage: "music.note.list",
                        title: "No songs yet",
                        message: "Songs you save to your Apple Music library will appear here."
                    )
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
            LazyVStack(alignment: .leading, spacing: 2) {
                if loading.contains(.albums) && albums.isEmpty {
                    ProgressView().padding()
                } else if albums.isEmpty {
                    EmptyPlaceholder(
                        systemImage: "square.stack",
                        title: "No albums yet",
                        message: "Albums you add to your library will appear here."
                    )
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
            LazyVStack(alignment: .leading, spacing: 2) {
                if loading.contains(.artists) && artists.isEmpty {
                    ProgressView().padding()
                } else if artists.isEmpty {
                    EmptyPlaceholder(
                        systemImage: "person.2",
                        title: "No artists yet",
                        message: "Artists from your saved music will appear here."
                    )
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
            LazyVStack(alignment: .leading, spacing: 2) {
                if loading.contains(.playlists) && playlists.isEmpty {
                    ProgressView().padding()
                } else if playlists.isEmpty {
                    EmptyPlaceholder(
                        systemImage: "music.note.list",
                        title: "No playlists yet",
                        message: "Playlists you create or follow will appear here."
                    )
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
        MediaRow(
            artwork: song.artwork,
            title: song.title,
            subtitle: song.artistName,
            artworkSize: 44,
            accessory: .play,
            hoverActions: [
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(song) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(song) }
                }
            ],
            contextActions: [
                MediaRowAction(systemImage: "play.fill", help: "Play Now") {
                    Task { await appModel.playAppleMusicSong(song) }
                },
                MediaRowAction(systemImage: "text.insert", help: "Play Next") {
                    Task { await appModel.musicKit.queueNext(song) }
                },
                MediaRowAction(systemImage: "text.append", help: "Add to Queue") {
                    Task { await appModel.musicKit.queueLast(song) }
                }
            ]
        ) {
            Task { await appModel.playAppleMusicSong(song) }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            MediaRow(
                artwork: album.artwork,
                title: album.title,
                subtitle: album.artistName,
                artworkSize: 52,
                accessory: .chevron,
                tappable: false,
                hoverActions: [
                    MediaRowAction(systemImage: "play.fill", help: "Play Album") {
                        Task { await appModel.musicKit.play(album: album) }
                    }
                ],
                contextActions: [
                    MediaRowAction(systemImage: "play.fill", help: "Play Album") {
                        Task { await appModel.musicKit.play(album: album) }
                    }
                ]
            ) {}
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            MediaRow(
                artwork: artist.artwork,
                title: artist.name,
                subtitle: nil,
                artworkSize: 44,
                artworkCornerRadius: 22,
                accessory: .chevron,
                tappable: false
            )
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            MediaRow(
                artwork: playlist.artwork,
                title: playlist.name,
                subtitle: playlist.curatorName,
                artworkSize: 52,
                accessory: .chevron,
                tappable: false,
                hoverActions: [
                    MediaRowAction(systemImage: "play.fill", help: "Play Playlist") {
                        Task { await appModel.musicKit.play(playlist: playlist) }
                    }
                ],
                contextActions: [
                    MediaRowAction(systemImage: "play.fill", help: "Play Playlist") {
                        Task { await appModel.musicKit.play(playlist: playlist) }
                    }
                ]
            ) {}
        }
        .buttonStyle(.plain)
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
