//
//  SearchResultsView.swift
//  High Videlity
//
//  The Apple Music search surface. Owns the search field + scope
//  picker (Songs / Albums / Artists / Playlists) and renders the
//  matching result rows. Tap-to-play on songs; tap-to-drill-down
//  on albums / artists / playlists. Context menu on every row for
//  Add to Queue / Play Next.
//
//  Reads `appModel.musicKit.search*` arrays — all four are
//  populated by a single round-trip in `MusicKitController.search`
//  so switching scopes is instant (no re-fetch).
//
//  Drill-down detail views are pushed via NavigationLink, hosted
//  by the top-level NavigationStack in High_VidelityApp.swift.
//  Not available on visionOS (no NavigationStack there); those
//  rows are non-interactive (album/artist/playlist drilldown
//  becomes a Phase 7 / shell concern on visionOS).
//

import SwiftUI
import MusicKit

#if !os(visionOS)
struct SearchResultsView: View {

    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var scope: SearchScope = .songs

    enum SearchScope: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    var body: some View {
        let mk = appModel.musicKit
        VStack(spacing: 10) {
            // Search bar.
            HStack(spacing: 8) {
                TextField("Search Apple Music…", text: $searchText)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .frame(maxWidth: 320)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Scope picker — only shown once a search has fired.
            if !mk.searchQuery.isEmpty {
                Picker("", selection: $scope) {
                    ForEach(SearchScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
            }

            // Loading / results.
            if mk.isSearching {
                ProgressView().controlSize(.small)
            } else if !mk.searchQuery.isEmpty {
                resultsForScope
            }
        }
    }

    @ViewBuilder
    private var resultsForScope: some View {
        let mk = appModel.musicKit
        switch scope {
        case .songs:
            if mk.searchResults.isEmpty { emptyState("No songs match.") }
            else {
                VStack(spacing: 6) {
                    ForEach(mk.searchResults, id: \.id) { song in
                        songRow(song)
                    }
                }
                .frame(maxWidth: 380)
            }
        case .albums:
            if mk.searchAlbums.isEmpty { emptyState("No albums match.") }
            else {
                VStack(spacing: 6) {
                    ForEach(mk.searchAlbums, id: \.id) { album in
                        albumRow(album)
                    }
                }
                .frame(maxWidth: 380)
            }
        case .artists:
            if mk.searchArtists.isEmpty { emptyState("No artists match.") }
            else {
                VStack(spacing: 6) {
                    ForEach(mk.searchArtists, id: \.id) { artist in
                        artistRow(artist)
                    }
                }
                .frame(maxWidth: 380)
            }
        case .playlists:
            if mk.searchPlaylists.isEmpty { emptyState("No playlists match.") }
            else {
                VStack(spacing: 6) {
                    ForEach(mk.searchPlaylists, id: \.id) { pl in
                        playlistRow(pl)
                    }
                }
                .frame(maxWidth: 380)
            }
        }
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Row builders

    private func songRow(_ song: Song) -> some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            HStack(spacing: 10) {
                ArtworkView(artwork: song.artwork, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(song.artistName)
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

    private func albumRow(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
                .environment(appModel)
        } label: {
            HStack(spacing: 10) {
                ArtworkView(artwork: album.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).lineLimit(1)
                    Text(album.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(album: album) }
            } label: { Label("Play Album", systemImage: "play.fill") }
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
                .environment(appModel)
        } label: {
            HStack(spacing: 10) {
                ArtworkView(artwork: artist.artwork, size: 48, cornerRadius: 24)
                Text(artist.name).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
                .environment(appModel)
        } label: {
            HStack(spacing: 10) {
                ArtworkView(artwork: playlist.artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).lineLimit(1)
                    if let curator = playlist.curatorName {
                        Text(curator)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(playlist: playlist) }
            } label: { Label("Play Playlist", systemImage: "play.fill") }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { await appModel.musicKit.search(query) }
    }
}
#endif
