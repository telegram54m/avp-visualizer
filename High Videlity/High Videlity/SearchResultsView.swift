//
//  SearchResultsView.swift
//  High Videlity
//
//  The Apple Music search surface. Owns the search field + scope
//  picker (Songs / Albums / Artists / Playlists) and renders the
//  matching result rows via `MediaRow`. Tap-to-play on songs;
//  tap-to-drill-down on albums / artists / playlists. Hover-revealed
//  actions for queue management; same actions in the context menu
//  so right-click reaches them anywhere on the row.
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
    /// Drives `.focused(_:)` on the search field. ⌘F bumps
    /// `appModel.focusSearchRequest`; the `.onChange` below flips
    /// this to true so the TextField takes first responder.
    @FocusState private var searchFieldFocused: Bool

    enum SearchScope: String, CaseIterable, Identifiable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    var body: some View {
        let mk = appModel.musicKit
        VStack(spacing: 12) {
            searchBar
            if !mk.searchQuery.isEmpty {
                Picker("", selection: $scope) {
                    ForEach(SearchScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
            }
            if mk.isSearching {
                ProgressView().controlSize(.small)
            } else if !mk.searchQuery.isEmpty {
                resultsForScope
            }
        }
        .onChange(of: appModel.focusSearchRequest) { _, _ in
            searchFieldFocused = true
        }
    }

    // MARK: - Search bar

    /// Modernized search field: glyph + textfield share a single
    /// rounded surface; an inline clear button appears once the user
    /// has typed something. Replaces the prior TextField + Button
    /// pairing which read as a form.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Apple Music", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { runSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    appModel.musicKit.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .frame(maxWidth: 400)
        .onChange(of: searchText) { _, _ in
            // Live-search debounce: cancel any pending search task
            // and schedule a new one after a short delay. Submitting
            // (Return) bypasses the debounce via runSearch().
            searchTask?.cancel()
            let query = searchText
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                await appModel.musicKit.search(query)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsForScope: some View {
        let mk = appModel.musicKit
        switch scope {
        case .songs:
            if mk.searchResults.isEmpty { emptyState("No songs match.") }
            else {
                resultList {
                    ForEach(mk.searchResults, id: \.id) { song in
                        songRow(song)
                    }
                }
            }
        case .albums:
            if mk.searchAlbums.isEmpty { emptyState("No albums match.") }
            else {
                resultList {
                    ForEach(mk.searchAlbums, id: \.id) { album in
                        albumRow(album)
                    }
                }
            }
        case .artists:
            if mk.searchArtists.isEmpty { emptyState("No artists match.") }
            else {
                resultList {
                    ForEach(mk.searchArtists, id: \.id) { artist in
                        artistRow(artist)
                    }
                }
            }
        case .playlists:
            if mk.searchPlaylists.isEmpty { emptyState("No playlists match.") }
            else {
                resultList {
                    ForEach(mk.searchPlaylists, id: \.id) { pl in
                        playlistRow(pl)
                    }
                }
            }
        }
    }

    private func resultList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2) {
            content()
        }
        .frame(maxWidth: 420)
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    // MARK: - Row builders

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
                .environment(appModel)
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
                .environment(appModel)
        } label: {
            MediaRow(
                artwork: artist.artwork,
                title: artist.name,
                subtitle: nil,
                artworkSize: 48,
                artworkCornerRadius: 24,
                accessory: .chevron,
                tappable: false
            )
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
                .environment(appModel)
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

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { await appModel.musicKit.search(query) }
    }
}
#endif
