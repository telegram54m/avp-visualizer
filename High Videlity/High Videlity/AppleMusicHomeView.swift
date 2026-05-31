//
//  AppleMusicHomeView.swift
//  High Videlity
//
//  Content-forward landing page for the Apple Music source. Lives
//  inside the source's NavigationStack (set up by RootShellView) and
//  is the default destination shown when the user picks "Apple Music"
//  in the sidebar.
//
//  Layout (top → bottom):
//    1. Persistent search bar (modern rounded surface). When the
//       user types, search results replace the rest of the feed.
//    2. For You — personal recommendation sections from MusicKit,
//       each rendered as a horizontal scroll of artwork cards.
//    3. Top Charts — Top Songs, Top Albums, Top Playlists rows,
//       each horizontal-scroll of cards.
//    4. "Library" scope — the user's own saved songs / albums /
//       artists / playlists, rendered inline via the scope picker
//       (the old AppleMusicLibraryView modal was retired in Phase 7).
//
//  Loading is opportunistic: recommendations + charts fetched on
//  appear, cached across navigation within the session. A reload
//  affordance in the toolbar refreshes the visible feed.
//

#if os(macOS)
import SwiftUI
import MusicKit

struct AppleMusicHomeView: View {

    @Environment(AppModel.self) private var appModel

    // Search field state owned here so search results replace the
    // feed inline. Live-debounced via `.onChange`.
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    /// Catalog (All Apple Music) vs. Library — drives whether the
    /// feed renders Apple's recommendations + charts or the user's
    /// own saved library content. Same content-feed scheme either
    /// way; just a different underlying source. Persisted per-
    /// session only; defaults to catalog so the discovery surface
    /// is what shows on first launch.
    enum HomeScope: String, CaseIterable, Identifiable {
        case catalog = "All Apple Music"
        case library = "Library"
        var id: String { rawValue }
    }
    @State private var scope: HomeScope = .catalog

    // Feed + library data now live in `appModel.appleMusic` (a long-
    // lived AppleMusicStore) instead of per-view @State, so navigating
    // away from and back to this landing page no longer re-fetches and
    // re-holds the recommendations / charts / full-library arrays. The
    // store loads once (idempotent) and is reused across navigations.
    private var store: AppleMusicStore { appModel.appleMusic }

    var body: some View {
        let mk = appModel.musicKit
        ScrollView {
            // LazyVStack so each section (For You row, Top Songs,
            // Top Albums, Top Playlists, library sections) is only
            // materialized when it scrolls into the viewport. The
            // For You feed routinely returns 6-10 sections, each
            // owning a horizontal scroll of cards; building them all
            // up front was the source of the initial-render lag.
            // The horizontal LazyHStack inside each section is
            // unchanged — already lazy on the cross axis.
            LazyVStack(alignment: .leading, spacing: 28) {
                searchAndScopeRow
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                if mk.authStatus == .notDetermined {
                    authConnectPrompt
                        .padding(.horizontal, 24)
                } else if !mk.isAuthorized {
                    authDeniedPrompt
                        .padding(.horizontal, 24)
                } else if mk.hasResolvedSubscription && !mk.canPlayCatalogContent {
                    subscriptionRequiredPrompt(mk: mk)
                        .padding(.horizontal, 24)
                } else {
                    switch scope {
                    case .catalog:
                        // Catalog search results vs. discovery feed
                        // depends on whether a catalog search is
                        // live. In library scope we always show
                        // libraryContent (and the filter is applied
                        // by `visibleLibraryX` computed properties).
                        if !mk.searchQuery.isEmpty {
                            SearchResultsContent()
                                .padding(.horizontal, 24)
                        } else {
                            feedContent
                        }
                    case .library:
                        libraryContent
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Apple Music")
        .task { await loadFeed() }
        // Subscription status resolves asynchronously after the
        // subscription observer's first emit. If `loadFeed` ran
        // before that emit, it bailed early — re-trigger when the
        // value flips so the feed populates without requiring the
        // user to hit Refresh.
        .onChange(of: mk.canPlayCatalogContent) { _, canPlay in
            if canPlay { Task { await loadFeed() } }
        }
        // Same race for the auth flip — if the user grants Apple
        // Music access from this screen, refresh once auth lands.
        .onChange(of: mk.isAuthorized) { _, authed in
            if authed { Task { await loadFeed() } }
        }
        // Lazy-load library data only when the user first switches
        // to library scope. Avoids paying for the four library
        // requests on every app launch when most sessions stay in
        // catalog mode.
        .onChange(of: scope) { _, newScope in
            if newScope == .library {
                Task { await loadLibrary() }
            }
        }
        .onChange(of: appModel.focusSearchRequest) { _, _ in
            searchFieldFocused = true
        }
    }

    // MARK: - Search + scope row

    /// Search bar + scope picker side-by-side. Search bar gets the
    /// elastic width; scope picker is fixed-size so it doesn't
    /// rebalance as the search query grows or shrinks. Picker uses
    /// the segmented style so its current state is always visible
    /// at a glance, matching macOS music-app conventions.
    private var searchAndScopeRow: some View {
        HStack(spacing: 12) {
            searchBar
            Picker("", selection: $scope) {
                ForEach(HomeScope.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .labelsHidden()
        }
        .frame(maxWidth: 820)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { runSearchNow() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    appModel.musicKit.searchQuery = ""
                    appModel.musicKit.searchResults = []
                    appModel.musicKit.searchAlbums = []
                    appModel.musicKit.searchArtists = []
                    appModel.musicKit.searchPlaylists = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .frame(maxWidth: 520)
        .onChange(of: searchText) { _, _ in
            // Library scope filters locally — no network search. The
            // existing libraryContent body reads `visibleLibraryX`
            // computed accessors that apply the filter, so the only
            // side effect needed here is canceling any pending
            // catalog search task that might still be queued.
            searchTask?.cancel()
            guard scope == .catalog else { return }
            let query = searchText
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                await appModel.musicKit.search(query)
            }
        }
        // Clear the catalog search bar when switching scopes so a
        // returning user doesn't see stale catalog matches mid-
        // library-browse. We don't blow away searchText itself
        // because users may want their query to carry across scopes.
        .onChange(of: scope) { _, newScope in
            if newScope == .library {
                appModel.musicKit.searchQuery = ""
                appModel.musicKit.searchResults = []
                appModel.musicKit.searchAlbums = []
                appModel.musicKit.searchArtists = []
                appModel.musicKit.searchPlaylists = []
            } else if !searchText.isEmpty {
                // Switched back to catalog with a live query — re-fire
                // the catalog search so the results match the field.
                runSearchNow()
            }
        }
    }

    private var searchPlaceholder: String {
        switch scope {
        case .catalog: return "Search Apple Music"
        case .library: return "Filter library"
        }
    }

    private func runSearchNow() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { await appModel.musicKit.search(query) }
    }

    // MARK: - Feed content

    @ViewBuilder
    private var feedContent: some View {
        if store.feedLoading && store.recommendations.isEmpty && store.charts.songs.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 40)
        } else {
            if !store.recommendations.isEmpty {
                ForEach(store.recommendations, id: \.id) { rec in
                    recommendationSection(rec)
                }
            }
            if !store.charts.songs.isEmpty {
                horizontalRow(title: "Top Songs") {
                    ForEach(store.charts.songs.prefix(20)) { song in
                        SongCard(song: song, appModel: appModel)
                    }
                }
            }
            if !store.charts.albums.isEmpty {
                horizontalRow(title: "Top Albums") {
                    ForEach(store.charts.albums.prefix(20)) { album in
                        AlbumCard(album: album, appModel: appModel)
                    }
                }
            }
            if !store.charts.playlists.isEmpty {
                horizontalRow(title: "Top Playlists") {
                    ForEach(store.charts.playlists.prefix(20)) { pl in
                        PlaylistCard(playlist: pl, appModel: appModel)
                    }
                }
            }
        }
    }

    // MARK: - Library feed

    /// Library scope content. Same content-feed scheme as the
    /// catalog feed, but each horizontal row is wrapped in an
    /// `AlphabetIndexedRow` that exposes a hover-revealed A-Z
    /// scrubber for fast jumps through long lists. Full lists
    /// are rendered — no `.prefix` caps — because library views
    /// in modern music apps are expected to be exhaustive.
    @ViewBuilder
    private var libraryContent: some View {
        if store.libraryLoading && allLibraryEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 40)
        } else if allLibraryEmpty {
            EmptyPlaceholder(
                systemImage: "music.note.house",
                title: "Your library is empty",
                message: "Save songs, albums, artists, or playlists to your Apple Music library and they'll show up here."
            )
            .frame(minHeight: 240)
        } else if allVisibleLibraryEmpty {
            // A live filter that excluded everything — surface the
            // distinction so the user knows it's the query, not the
            // library, that's empty.
            EmptyPlaceholder(
                systemImage: "magnifyingglass",
                title: "No matches in your library",
                message: "Try a different spelling, or clear the filter to see everything again."
            )
            .frame(minHeight: 200)
        } else {
            if !visibleLibraryAlbums.isEmpty {
                AlphabetIndexedRow(
                    title: "Albums",
                    items: visibleLibraryAlbums,
                    firstLetter: { albumLetter($0) }
                ) { album in
                    AlbumCard(album: album, appModel: appModel)
                }
            }
            if !visibleLibraryArtists.isEmpty {
                AlphabetIndexedRow(
                    title: "Artists",
                    items: visibleLibraryArtists,
                    firstLetter: { artistLetter($0) }
                ) { artist in
                    LibraryArtistCard(artist: artist, appModel: appModel)
                }
            }
            if !visibleLibraryPlaylists.isEmpty {
                AlphabetIndexedRow(
                    title: "Playlists",
                    items: visibleLibraryPlaylists,
                    firstLetter: { playlistLetter($0) }
                ) { pl in
                    PlaylistCard(playlist: pl, appModel: appModel)
                }
            }
            if !visibleLibrarySongs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Songs")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        NavigationLink {
                            LibrarySongsListView(
                                songs: store.librarySongs,
                                appModel: appModel
                            )
                        } label: {
                            HStack(spacing: 3) {
                                Text("Show all (\(store.librarySongs.count))")
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    VStack(spacing: 2) {
                        ForEach(visibleLibrarySongs.prefix(12), id: \.id) { song in
                            SongResultRow(song: song, appModel: appModel)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private var allLibraryEmpty: Bool { store.allLibraryEmpty }

    private var allVisibleLibraryEmpty: Bool {
        visibleLibrarySongs.isEmpty
            && visibleLibraryAlbums.isEmpty
            && visibleLibraryArtists.isEmpty
            && visibleLibraryPlaylists.isEmpty
    }

    // MARK: - Library filter

    /// Trimmed lowercased search text used to filter the library
    /// when scope is library. Empty when no filter is in effect.
    private var libraryQuery: String {
        guard scope == .library else { return "" }
        return searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleLibrarySongs: [Song] {
        let q = libraryQuery
        guard !q.isEmpty else { return store.librarySongs }
        return store.librarySongs.filter {
            $0.title.lowercased().contains(q)
                || $0.artistName.lowercased().contains(q)
                || ($0.albumTitle?.lowercased().contains(q) ?? false)
        }
    }

    private var visibleLibraryAlbums: [Album] {
        let q = libraryQuery
        guard !q.isEmpty else { return store.libraryAlbums }
        return store.libraryAlbums.filter {
            $0.title.lowercased().contains(q)
                || $0.artistName.lowercased().contains(q)
        }
    }

    private var visibleLibraryArtists: [Artist] {
        let q = libraryQuery
        guard !q.isEmpty else { return store.libraryArtists }
        return store.libraryArtists.filter { $0.name.lowercased().contains(q) }
    }

    private var visibleLibraryPlaylists: [Playlist] {
        let q = libraryQuery
        guard !q.isEmpty else { return store.libraryPlaylists }
        return store.libraryPlaylists.filter {
            $0.name.lowercased().contains(q)
                || ($0.curatorName?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - First-letter helpers for the A-Z scrubber

    /// Skip leading "The " when picking the bucket letter — same
    /// convention macOS Music uses ("The Beatles" → B, "The xx" → X).
    /// Non-alphabetic leads fall into the "#" bucket so numeric or
    /// symbolic titles aren't silently dropped from the scrubber.
    private func bucketLetter(from raw: String) -> Character {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("the ") {
            trimmed = String(trimmed.dropFirst(4))
        }
        guard let first = trimmed.first else { return "#" }
        let upper = Character(String(first).uppercased())
        return upper.isLetter ? upper : "#"
    }
    private func albumLetter(_ album: Album) -> Character { bucketLetter(from: album.title) }
    private func artistLetter(_ artist: Artist) -> Character { bucketLetter(from: artist.name) }
    private func playlistLetter(_ playlist: Playlist) -> Character { bucketLetter(from: playlist.name) }

    /// One "For You" recommendation section — horizontal scroll of
    /// album / playlist / station cards. Section title comes from the
    /// recommendation itself ("More Like X", "Made for You", etc).
    private func recommendationSection(_ rec: MusicPersonalRecommendation) -> some View {
        horizontalRow(title: rec.title ?? "Recommended for You") {
            ForEach(Array(rec.items.enumerated()), id: \.offset) { _, item in
                RecommendationCard(item: item, appModel: appModel)
            }
        }
    }

    /// Generic horizontal card row scaffolding: title above, horizontal
    /// ScrollView below. Keeps section padding + spacing uniform.
    private func horizontalRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Auth / subscription prompts

    private var authConnectPrompt: some View {
        VStack(spacing: 10) {
            Button("Connect Apple Music") {
                Task { await appModel.musicKit.requestAuthorization() }
            }
            .buttonStyle(GradientPillButtonStyle())
            Text("Sign in to search, queue, and play.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var authDeniedPrompt: some View {
        EmptyPlaceholder(
            systemImage: "exclamationmark.triangle",
            title: "Apple Music access denied",
            message: "Open System Settings → Privacy & Security → Media & Apple Music to grant access."
        )
    }

    private func subscriptionRequiredPrompt(mk: MusicKitController) -> some View {
        EmptyPlaceholder(
            systemImage: "music.note.tv",
            title: "Apple Music subscription required",
            message: "You're connected, but full-track playback needs an active Apple Music subscription."
        )
    }

    // MARK: - Loading

    // Feed + library loading now live on the shared AppleMusicStore so
    // the data survives navigation. These thin wrappers keep the
    // .task / .onChange call sites unchanged. Both store methods are
    // idempotent (load-once unless `force`).
    private func loadFeed(force: Bool = false) async {
        await store.loadFeed(mk: appModel.musicKit, force: force)
    }

    private func loadLibrary(force: Bool = false) async {
        await store.loadLibrary(mk: appModel.musicKit, force: force)
    }
}


// MARK: - Library artist card

/// Artist card for the library feed. Uses circular artwork to mirror
/// how artists are surfaced elsewhere in the app (ArtistDetailView's
/// hero, the SearchResultsContent's artist row). Library artists
/// often have nil artwork; ArtworkView's placeholder handles that.
private struct LibraryArtistCard: View {
    let artist: Artist
    let appModel: AppModel
    var body: some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                ArtworkView(artwork: artist.artwork, size: 140, cornerRadius: 70)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(artist.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(width: 140)
            }
            .frame(width: 140)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search results content
//
// Content-feed restyle: instead of a scope picker that hides three
// of four result types at a time, show ALL types simultaneously as
// feed-style sections. Songs render as rows (informationally dense
// and tap-to-play is the dominant gesture), albums / artists /
// playlists as horizontal card scrollers (artwork-forward, fast to
// scan). Empty sections hide themselves so partial-match queries
// don't show three "No X match" lines.
//
// Separate view struct so the search results' own observation reads
// don't invalidate the feed scaffolding above.

private struct SearchResultsContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let mk = appModel.musicKit
        if mk.isSearching && allEmpty(mk: mk) {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.top, 40)
        } else if allEmpty(mk: mk) {
            EmptyPlaceholder(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try a different spelling, or search for an album or artist instead."
            )
            .frame(minHeight: 200)
        } else {
            // Lazy on the vertical axis so the four search sections
            // (Songs / Albums / Artists / Playlists) only build
            // when scrolled to. Mirrors the home feed's LazyVStack
            // strategy.
            LazyVStack(alignment: .leading, spacing: 28) {
                if !mk.searchResults.isEmpty {
                    songsSection(songs: mk.searchResults)
                }
                if !mk.searchAlbums.isEmpty {
                    horizontalCardRow(title: "Albums") {
                        ForEach(mk.searchAlbums.prefix(20), id: \.id) { album in
                            AlbumSearchCard(album: album, appModel: appModel)
                        }
                    }
                }
                if !mk.searchArtists.isEmpty {
                    horizontalCardRow(title: "Artists") {
                        ForEach(mk.searchArtists.prefix(20), id: \.id) { artist in
                            ArtistSearchCard(artist: artist, appModel: appModel)
                        }
                    }
                }
                if !mk.searchPlaylists.isEmpty {
                    horizontalCardRow(title: "Playlists") {
                        ForEach(mk.searchPlaylists.prefix(20), id: \.id) { pl in
                            PlaylistSearchCard(playlist: pl, appModel: appModel)
                        }
                    }
                }
            }
            .padding(.horizontal, -24)  // counteract parent horizontal padding so horizontal rows extend edge-to-edge
            .padding(.horizontal, 24)   // restore visual position; cards inside add their own padding
        }
    }

    private func allEmpty(mk: MusicKitController) -> Bool {
        mk.searchResults.isEmpty
            && mk.searchAlbums.isEmpty
            && mk.searchArtists.isEmpty
            && mk.searchPlaylists.isEmpty
    }

    /// "Songs" section header + a vertical stack of song result rows.
    /// Caps at 8 visible rows for any single query so the section
    /// doesn't dominate vertical scroll when there are matches in
    /// the other types — the user can see the cap was reached when
    /// the album / artist / playlist rows are still cut short.
    private func songsSection(songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Songs")
                .font(.title3.weight(.semibold))
            VStack(spacing: 2) {
                ForEach(songs.prefix(8)) { song in
                    SongResultRow(song: song, appModel: appModel)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    /// Title above, horizontal-scroll card row below. Same scaffolding
    /// the home feed uses for For You / Top Charts so visually the
    /// search surface and the discovery surface read as siblings.
    private func horizontalCardRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Search result cards
//
// Artwork-forward vertical cards for album / artist / playlist search
// hits. Same shape as the home-feed MediaCard so the two surfaces
// share a visual vocabulary.

private struct AlbumSearchCard: View {
    let album: Album
    let appModel: AppModel
    var body: some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            MediaCard(
                artwork: album.artwork,
                title: album.title,
                subtitle: album.artistName
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(album: album) }
            } label: { Label("Play Album", systemImage: "play.fill") }
        }
    }
}

private struct ArtistSearchCard: View {
    let artist: Artist
    let appModel: AppModel
    var body: some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            ArtistCircleCard(artwork: artist.artwork, name: artist.name)
        }
        .buttonStyle(.plain)
    }
}

private struct PlaylistSearchCard: View {
    let playlist: Playlist
    let appModel: AppModel
    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            MediaCard(
                artwork: playlist.artwork,
                title: playlist.name,
                subtitle: playlist.curatorName ?? ""
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(playlist: playlist) }
            } label: { Label("Play Playlist", systemImage: "play.fill") }
        }
    }
}

/// Circular-artwork card used for Artist hits — mirrors Apple Music's
/// own artist treatment. Fixed-width column so the row aligns even
/// with two-line names.
private struct ArtistCircleCard: View {
    let artwork: Artwork?
    let name: String

    private let cardWidth: CGFloat = 140
    private let artworkSize: CGFloat = 140

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ArtworkView(
                artwork: artwork,
                size: artworkSize,
                cornerRadius: artworkSize / 2
            )
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .frame(width: cardWidth)
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
    }
}

// MARK: - Search result row shells
//
// Small wrappers so the home file can reuse the same MediaRow
// patterns established in SearchResultsView without taking a runtime
// dependency on that struct's body (which still owns the standalone
// search bar used by the old shell).

private struct SongResultRow: View {
    let song: Song
    let appModel: AppModel
    var body: some View {
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
}

private struct AlbumResultRow: View {
    let album: Album
    let appModel: AppModel
    var body: some View {
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
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ArtistResultRow: View {
    let artist: Artist
    let appModel: AppModel
    var body: some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
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
}

private struct PlaylistResultRow: View {
    let playlist: Playlist
    let appModel: AppModel
    var body: some View {
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
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feed cards
//
// Vertical artwork-on-top cards used in horizontal scroll rows for
// recommendations + charts. Fixed 140pt width so rows align cleanly
// regardless of title length. Long titles wrap to two lines and
// truncate beyond.

private struct RecommendationCard: View {
    let item: MusicPersonalRecommendation.Item
    let appModel: AppModel

    var body: some View {
        switch item {
        case .album(let album):
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                MediaCard(
                    artwork: album.artwork,
                    title: album.title,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    Task { await appModel.musicKit.play(album: album) }
                } label: { Label("Play Album", systemImage: "play.fill") }
            }
        case .playlist(let playlist):
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                MediaCard(
                    artwork: playlist.artwork,
                    title: playlist.name,
                    subtitle: playlist.curatorName ?? ""
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    Task { await appModel.musicKit.play(playlist: playlist) }
                } label: { Label("Play Playlist", systemImage: "play.fill") }
            }
        case .station(let station):
            Button {
                Task { await appModel.musicKit.play(station: station) }
            } label: {
                MediaCard(
                    artwork: station.artwork,
                    title: station.name,
                    subtitle: "Station"
                )
            }
            .buttonStyle(.plain)
        @unknown default:
            EmptyView()
        }
    }
}

private struct SongCard: View {
    let song: Song
    let appModel: AppModel

    var body: some View {
        Button {
            Task { await appModel.playAppleMusicSong(song) }
        } label: {
            MediaCard(
                artwork: song.artwork,
                title: song.title,
                subtitle: song.artistName
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await appModel.playAppleMusicSong(song) } } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { Task { await appModel.musicKit.queueNext(song) } } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button { Task { await appModel.musicKit.queueLast(song) } } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
        }
    }
}

private struct AlbumCard: View {
    let album: Album
    let appModel: AppModel

    var body: some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            MediaCard(
                artwork: album.artwork,
                title: album.title,
                subtitle: album.artistName
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(album: album) }
            } label: { Label("Play Album", systemImage: "play.fill") }
        }
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist
    let appModel: AppModel

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            MediaCard(
                artwork: playlist.artwork,
                title: playlist.name,
                subtitle: playlist.curatorName ?? ""
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await appModel.musicKit.play(playlist: playlist) }
            } label: { Label("Play Playlist", systemImage: "play.fill") }
        }
    }
}

/// Vertical-orientation media card with artwork above and title /
/// subtitle below. Fixed-width so horizontal scroll rows stay
/// aligned; the artwork's shadow gives the row some depth.
private struct MediaCard: View {
    let artwork: Artwork?
    let title: String
    let subtitle: String?

    private let cardWidth: CGFloat = 140
    private let artworkSize: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: artwork, size: artworkSize, cornerRadius: 6)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(width: cardWidth, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
    }
}
#endif
