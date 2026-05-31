//
//  SourceDetailViews.swift
//  High Videlity
//
//  Phase 7 — per-Source detail panels driven by the sidebar in
//  `RootShellView`. macOS-only for now; iOS/visionOS still use the
//  legacy ContentView until a later phase ports them.
//
//  Each view is a thin reorganization of pieces that lived in
//  ContentView pre-Phase-7. The intent is NOT to redesign the
//  surfaces — that's risky and the user just wants the IA to make
//  sense. The Apple Music / Local detail views still trigger the
//  same sheets (LibraryBrowserView, etc.) they did before, and the
//  AM library now lives inline as a scope in AppleMusicHomeView.
//  Settings carries the controls that used to be
//  inline with the rest of ContentView's mode picker block.
//

#if os(macOS)
import SwiftUI
import MusicKit
import UniformTypeIdentifiers

// MARK: - Apple Music

/// Apple Music source root. Hosts the content-forward landing feed
/// (`AppleMusicHomeView`) — For You recommendations, top charts,
/// library entry — instead of the prior search-bar + buttons +
/// sheets layout. Library and Browse are no longer modals; library
/// pushes via NavigationLink, browse content now lives inline on
/// this page.
struct AppleMusicSourceView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showSubscriptionOffer = false

    var body: some View {
        AppleMusicHomeView()
            // Apple's standard subscribe-or-trial sheet. Hoisted to
            // the source root so it can be presented from anywhere
            // in the stack (the home view's subscription CTA, a
            // hypothetical future "upgrade" link, etc.).
            .musicSubscriptionOffer(isPresented: $showSubscriptionOffer)
            // Play error banner — surfaced as a SwiftUI overlay on
            // the home so it can sit above whatever content is
            // showing (feed or search results) without rewriting the
            // home's layout.
            .overlay(alignment: .top) {
                if let err = appModel.musicKit.lastPlayError {
                    playErrorBanner(err, mk: appModel.musicKit)
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2),
                       value: appModel.musicKit.lastPlayError)
    }

    /// Banner shown above the feed when the most recent play attempt
    /// failed. Retry uses the captured `lastPlayAttemptSong` so the
    /// user doesn't have to re-pick from search results.
    private func playErrorBanner(_ message: String, mk: MusicKitController) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                HStack(spacing: 10) {
                    if let song = mk.lastPlayAttemptSong {
                        Button("Retry") {
                            Task { await appModel.playAppleMusicSong(song) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Dismiss") {
                        mk.lastPlayError = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 520)
    }
}

// MARK: - Local Library

struct LocalSourceView: View {

    @Environment(AppModel.self) private var appModel
    @State private var showFilePicker = false
    @State private var showLibraryBrowser = false
    /// Inline search text. Filters all sections (Albums / Artists /
    /// All Songs) on title + artist + album substring match,
    /// case-insensitive. Library is small enough (~300-1k entries)
    /// that filter runs on-keystroke without debounce.
    @State private var filterText: String = ""

    /// Lowercased + trimmed filter applied to entries. Empty string
    /// means "no filter" — return entries unchanged.
    private func filtered(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.title.lowercased().contains(q) { return true }
            if entry.artist.lowercased().contains(q) { return true }
            if let album = entry.album, album.lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        let allEntries = appModel.library.entries
        let visibleEntries = filtered(allEntries)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if allEntries.isEmpty {
                    // Welcome / empty state — keep the original
                    // hero + action cards as the welcoming UI when
                    // no folder has been scanned yet.
                    heroBlock
                    actionGrid
                } else {
                    // Content-forward layout — the user's music IS
                    // the page. Currently-playing info lives on the
                    // persistent GlobalNowPlayingFooter and the Now
                    // Playing inspector; no need to duplicate it as
                    // a card here.
                    libraryToolbar(totalCount: allEntries.count, matchCount: visibleEntries.count)
                    if visibleEntries.isEmpty {
                        emptyFilterState
                    } else {
                        librarySections(entries: visibleEntries)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: allEntries.isEmpty ? 760 : .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Local Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import a file…", systemImage: "doc.badge.plus")
                    }
                    Button {
                        appModel.library.pickFolder()
                    } label: {
                        Label(appModel.library.rootURL == nil ? "Pick a folder…" : "Change folder…",
                              systemImage: "folder.badge.gearshape")
                    }
                    if appModel.library.rootURL != nil {
                        Button {
                            Task { await appModel.library.rescan() }
                        } label: {
                            Label("Rescan folder", systemImage: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button {
                        showLibraryBrowser = true
                    } label: {
                        Label("Open library browser…", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("Add music or manage library")
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await appModel.loadSong(from: url) }
        }
        .sheet(isPresented: $showLibraryBrowser) {
            LibraryBrowserView()
                .environment(appModel)
        }
    }

    // MARK: - Hero (empty-state)

    /// Welcoming header. Glyph + headline + supporting paragraph —
    /// roughly matches the empty-state vocabulary used elsewhere in
    /// the app so the local-library entry doesn't feel like a stray
    /// form among modern surfaces.
    private var heroBlock: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Your local music")
                    .font(.title2.weight(.semibold))
                Text("Play files on this Mac and build a reusable feature cache so the visualizer reacts instantly on repeat plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Two action cards shown only in the empty state. Once the
    /// library has entries, the toolbar Menu carries the same
    /// actions in a compact form.
    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
            spacing: 12
        ) {
            ActionCard(
                systemImage: "doc.badge.plus",
                title: "Import a file",
                subtitle: "Pick a single audio file from your Mac and play it through the visualizer.",
                perform: { showFilePicker = true }
            )
            ActionCard(
                systemImage: "folder.fill.badge.gearshape",
                title: "Browse audio library",
                subtitle: "Point at a folder of music and batch-cache features for every track inside.",
                perform: { showLibraryBrowser = true }
            )
        }
    }

    // MARK: - Content-forward layout

    /// Compact toolbar at the top of the populated library view.
    /// Folder name + entry count on the left so the user always knows
    /// what they're looking at.
    /// Hero + filter on one row. Hero (glyph + folder name + song
    /// count) takes the leading slot; the filter capsule sits at the
    /// trailing edge, max-bounded so it doesn't dominate when the
    /// window is wide. On a typical 300-song local library the
    /// filter is O(n) per keystroke with zero perceived latency —
    /// no debounce needed.
    private func libraryToolbar(totalCount: Int, matchCount: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.library.rootURL?.lastPathComponent ?? "Your library")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("\(appModel.library.entries.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            filterBar(totalCount: totalCount, matchCount: matchCount)
                .frame(maxWidth: 360)
        }
    }

    /// Inline search capsule rendered inside the libraryToolbar's
    /// right side. Matches the LibrarySongsListView filter-bar
    /// vocabulary so the two pages feel like the same surface.
    private func filterBar(totalCount: Int, matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter songs, artists, albums", text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Text("\(matchCount) of \(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    /// "Filter matched nothing" placeholder. Shown in place of the
    /// album / artist / songs sections when `filterText` excludes
    /// every entry — friendlier than rendering empty rows.
    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("No songs, artists, or albums in your library match the filter.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Clear filter") { filterText = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// All the populated sections — recently cached carousel, album
    /// rows, then a "All Songs" list. Lifts pieces from
    /// LibraryBrowserView in a content-feed shape.
    private func librarySections(entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            albumRow(entries: entries)
            artistRow(entries: entries)
            allSongsSection(entries: entries)
        }
    }

    /// Horizontal scroll of unique albums from the scanned library.
    /// Built lazily by deduping entries on (album, artist) — local
    /// files don't expose artwork through LibraryEntry, so cards use
    /// a gradient placeholder keyed off the album name. Returns nil
    /// when the library is small enough that this row would just
    /// duplicate the songs list.
    @ViewBuilder
    private func albumRow(entries: [LibraryEntry]) -> some View {
        let groups = uniqueAlbums(from: entries)
        if groups.count >= 4 {
            AlphabetIndexedRow(
                title: "Albums",
                items: groups,
                firstLetter: { alphabetBucket($0.album ?? "") }
            ) { group in
                LocalAlbumCard(
                    title: group.album ?? "Unknown Album",
                    subtitle: group.artist.isEmpty ? "Unknown Artist" : group.artist,
                    tracks: group.entries,
                    appModel: appModel
                )
            }
        }
    }

    /// Horizontal scroll of unique artists from the scanned library.
    @ViewBuilder
    private func artistRow(entries: [LibraryEntry]) -> some View {
        let artists = uniqueArtists(from: entries)
        if artists.count >= 4 {
            AlphabetIndexedRow(
                title: "Artists",
                items: artists,
                firstLetter: { alphabetBucket($0.name) }
            ) { artist in
                LocalArtistCard(
                    name: artist.name,
                    trackCount: artist.entries.count,
                    tracks: artist.entries,
                    appModel: appModel
                )
            }
        }
    }

    /// Preview slice of the library + a "Show all" link that pushes
    /// `LocalSongsListView` for the canonical sortable / filterable
    /// table. The home page renders only the first handful of rows
    /// so it stays light no matter how big the scanned folder gets;
    /// big libraries route through the dedicated table.
    private func allSongsSection(entries: [LibraryEntry]) -> some View {
        let previewLimit = 6
        let preview = Array(entries.prefix(previewLimit))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All Songs")
                    .font(.title3.weight(.semibold))
                Spacer()
                if entries.count > previewLimit {
                    NavigationLink {
                        LocalSongsListView(entries: entries, appModel: appModel)
                            .environment(appModel)
                    } label: {
                        Text("Show all (\(entries.count))")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
            }
            VStack(spacing: 2) {
                ForEach(preview) { entry in
                    LocalSongRow(entry: entry, appModel: appModel)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: - Grouping helpers

    /// Group library entries by (album, artist) preserving the order
    /// of first appearance. "Unknown Album" merges entries with nil
    /// album so the page doesn't fragment into singletons.
    private func uniqueAlbums(from entries: [LibraryEntry]) -> [AlbumGroup] {
        var order: [String] = []
        var byKey: [String: AlbumGroup] = [:]
        for entry in entries {
            let key = "\(entry.album ?? "Unknown Album")::\(entry.artist)"
            if byKey[key] == nil {
                byKey[key] = AlbumGroup(
                    key: key,
                    album: entry.album,
                    artist: entry.artist,
                    entries: []
                )
                order.append(key)
            }
            byKey[key]?.entries.append(entry)
        }
        return order.compactMap { byKey[$0] }
    }

    private func uniqueArtists(from entries: [LibraryEntry]) -> [ArtistGroup] {
        var order: [String] = []
        var byName: [String: ArtistGroup] = [:]
        for entry in entries {
            let name = entry.artist.isEmpty ? "Unknown Artist" : entry.artist
            if byName[name] == nil {
                byName[name] = ArtistGroup(name: name, entries: [])
                order.append(name)
            }
            byName[name]?.entries.append(entry)
        }
        return order.compactMap { byName[$0] }
    }

    struct AlbumGroup: Identifiable {
        let key: String
        let album: String?
        let artist: String
        var entries: [LibraryEntry]
        var id: String { key }
    }

    struct ArtistGroup: Identifiable {
        let name: String
        var entries: [LibraryEntry]
        var id: String { name }
    }
}

// MARK: - Local row + card components

/// Row for a single LibraryEntry inside the All-Songs list. Local
/// files don't have MusicKit artwork; a gradient-tinted placeholder
/// derived from the title hash gives each row a subtle visual
/// distinction without requiring any per-file art lookup.
private struct LocalSongRow: View {
    let entry: LibraryEntry
    let appModel: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            Task { await appModel.playLocalEntry(entry) }
        } label: {
            HStack(spacing: 12) {
                LocalArtTile(hashSeed: entry.title + entry.artist, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(entry.artist.isEmpty ? (entry.album ?? "—") : entry.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ConflictBadge(entry: entry)
                if appModel.library.cachedURLs.contains(entry.fileURL) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Cached")
                }
                Text(formatDuration(entry.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button {
                Task { await appModel.playLocalEntry(entry) }
            } label: { Label("Play Now", systemImage: "play.fill") }
            Button {
                Task { await appModel.queueNextLocal(entry) }
            } label: { Label("Play Next", systemImage: "text.insert") }
            Button {
                Task { await appModel.queueLastLocal(entry) }
            } label: { Label("Add to Queue", systemImage: "text.append") }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct LocalAlbumCard: View {
    let title: String
    let subtitle: String
    let tracks: [LibraryEntry]
    let appModel: AppModel

    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalArtTile(hashSeed: title + subtitle, size: 140, cornerRadius: 6)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(width: 140, alignment: .leading)
            Text("\(subtitle) · \(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        // Finder-style: single-click opens detail, double-click plays
        // the whole album as a queue. `count: 2` first so SwiftUI
        // defers `count: 1` past the double-click window — without
        // that ordering, count:1 fires immediately and count:2 never
        // gets a chance.
        .onTapGesture(count: 2) {
            playAlbum()
        }
        .onTapGesture(count: 1) {
            showDetail = true
        }
        .contextMenu {
            Button {
                playAlbum()
            } label: { Label("Play Album", systemImage: "play.fill") }
            Button {
                Task { await appModel.queueLastLocalEntries(tracks) }
            } label: { Label("Add Album to Queue", systemImage: "text.append") }
        }
        .navigationDestination(isPresented: $showDetail) {
            LocalAlbumDetailView(
                title: title,
                subtitle: subtitle,
                tracks: tracks,
                appModel: appModel
            )
        }
    }

    private func playAlbum() {
        Task { await appModel.playLocalEntries(tracks, startAt: 0) }
    }
}

private struct LocalArtistCard: View {
    let name: String
    let trackCount: Int
    let tracks: [LibraryEntry]
    let appModel: AppModel

    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalArtTile(hashSeed: name, size: 140, cornerRadius: 70)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(width: 140, alignment: .leading)
            Text("\(trackCount) song\(trackCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            playArtist()
        }
        .onTapGesture(count: 1) {
            showDetail = true
        }
        .contextMenu {
            Button {
                playArtist()
            } label: { Label("Play Artist", systemImage: "play.fill") }
            Button {
                Task { await appModel.queueLastLocalEntries(tracks) }
            } label: { Label("Add Artist to Queue", systemImage: "text.append") }
        }
        .navigationDestination(isPresented: $showDetail) {
            LocalArtistDetailView(name: name, tracks: tracks, appModel: appModel)
        }
    }

    private func playArtist() {
        Task { await appModel.playLocalEntries(tracks, startAt: 0) }
    }
}

/// Procedural artwork tile for local files. Derives two complementary
/// hues from the seed string's hash so each (album / artist) gets a
/// distinct but visually unified gradient. Music-note glyph overlays
/// the gradient for instant recognizability.
struct LocalArtTile: View {
    let hashSeed: String
    let size: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        let hue1 = stableHue(hashSeed, offset: 0)
        let hue2 = stableHue(hashSeed, offset: 0.18)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue1, saturation: 0.55, brightness: 0.62),
                        Color(hue: hue2, saturation: 0.65, brightness: 0.32)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
    }

    /// Hash-stable hue in 0..1. Uses DJBX33A so the same seed maps to
    /// the same hue between launches.
    private func stableHue(_ seed: String, offset: Double) -> Double {
        var hash: UInt32 = 5381
        for byte in seed.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        let frac = Double(hash % 1000) / 1000.0
        return (frac + offset).truncatingRemainder(dividingBy: 1.0)
    }
}

// MARK: - Settings

/// "Pick the visualizer that animates whatever audio is playing"
/// surface. Used to live under Settings → Audio Input + Visualizer,
/// but Settings had only this one functional thing left after Mac /
/// Microphone moved to dedicated sidebar sources — so the whole
/// surface became the Visualizers page.
struct SettingsSourceView: View {

    @Environment(AppModel.self) private var appModel
    @State private var showStemCacheAudit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                grid
                Divider()
                cycleToggleRow
                Divider()
                stemCacheMaintenanceRow
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 880, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Visualizers")
        .sheet(isPresented: $showStemCacheAudit) {
            StemCacheAuditSheet()
                .environment(appModel)
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    /// "Verify stem cache" entry point. The audit reads every cached
    /// row and looks up each (title, artist) against MusicBrainz to
    /// find rows whose stored stem bytes likely came from a different
    /// song — see [[StemCacheAuditor]] for the detection strategy +
    /// the alias-bug history that motivates this.
    private var stemCacheMaintenanceRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Verify stem cache")
                    .font(.callout)
                Text("Scan the on-disk stem-features cache for rows whose metadata disagrees with the audio they were computed from. Cross-checks each entry against MusicBrainz. Slow — about a second per cached song.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button("Verify…") { showStemCacheAudit = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 600, alignment: .leading)
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Visualizer modes")
                    .font(.title2.weight(.semibold))
                Text("Each mode is a different 3D scene that reacts to whatever audio is currently driving the analyzer. Tap to switch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: 14)],
            spacing: 14
        ) {
            ForEach(VisualizerMode.allCases) { mode in
                VisualizerThumbnailCard(
                    mode: mode,
                    isSelected: appModel.mode == mode
                ) {
                    appModel.mode = mode
                }
            }
        }
    }

    private var cycleToggleRow: some View {
        // Read the tick so SwiftUI re-renders this row when the
        // setter mutates UserDefaults — see [[AppModel.cycleVisualizersTick]].
        let _ = appModel.cycleVisualizersTick
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cycle on track change")
                    .font(.callout)
                Text("Advance to the next visualizer mode every time the song changes (manual skip, queue auto-advance, or AM next).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(
                get: { appModel.cycleVisualizersOnTrackChange },
                set: { appModel.cycleVisualizersOnTrackChange = $0 }
            ))
            .labelsHidden()
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

// MARK: - Visualizer thumbnail card

/// One card in the Visualizers grid. Renders an Asset-catalog image
/// `viz-thumb-{mode.rawValue}` if it exists, otherwise a procedural
/// gradient + SF Symbol fallback so the page is functional before
/// real screenshots get dropped in.
private struct VisualizerThumbnailCard: View {
    let mode: VisualizerMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    }
                HStack {
                    Text(mode.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        // Asset-catalog lookup first. NSImage(named:) returns nil for
        // missing assets, so we can fall back gracefully to the
        // procedural placeholder. Drop a PNG named e.g.
        // "viz-thumb-crystal" into Assets.xcassets to replace.
        let assetName = "viz-thumb-\(mode.rawValue)"
        if let _ = NSImage(named: assetName) {
            Image(assetName)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
        }
    }

    /// Hash-tinted gradient with the mode's representative glyph.
    /// Each mode gets a distinct color theme so the grid is scannable
    /// before real screenshots ship.
    private var placeholder: some View {
        let theme = Self.theme(for: mode)
        return ZStack {
            LinearGradient(
                colors: theme.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: theme.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
    }

    private struct Theme {
        let gradient: [Color]
        let symbol: String
    }

    private static func theme(for mode: VisualizerMode) -> Theme {
        switch mode {
        case .crystal:
            return Theme(gradient: [.purple, .pink], symbol: "diamond.fill")
        case .clouds:
            return Theme(gradient: [.cyan, .indigo], symbol: "cloud.fill")
        case .rings:
            return Theme(gradient: [.orange, .red], symbol: "circle.hexagongrid.fill")
        case .slipstream:
            return Theme(gradient: [.teal, .blue], symbol: "arrow.forward.circle.fill")
        case .ambient:
            return Theme(gradient: [.indigo, .purple], symbol: "sparkles")
        case .dodecahedron:
            return Theme(gradient: [.yellow, .red], symbol: "cube.transparent.fill")
        case .fractal:
            return Theme(gradient: [.pink, .green], symbol: "circle.dotted.circle.fill")
        }
    }
}

/// Material-card section used in Settings to group related controls.
/// Title + glyph on top, content stack below. Same visual language
/// as macOS's System Settings cards.
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }
}

// MARK: - System Audio source picker
//
// Lifted out of ContentView so SettingsSourceView (and any future
// surface) can drop it in without duplicating the menu plumbing.

struct SystemAudioSourcePicker: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let listener = appModel.systemAudio
        let currentChoice = appModel.preferredSystemAudioProcessName

        HStack(spacing: 6) {
            Text("Source:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Auto (pick first playing music app)") {
                    appModel.switchSystemAudioSource(toName: nil)
                }
                Divider()
                ForEach(listener.availableProcesses) { proc in
                    Button {
                        appModel.switchSystemAudioSource(toName: proc.name)
                    } label: {
                        HStack {
                            Text(Self.friendlyName(proc.name))
                            if proc.isPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.green)
                            }
                            if currentChoice == proc.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if listener.availableProcesses.isEmpty {
                    Text("No audio processes found")
                }
                Divider()
                Button("Refresh list") { listener.refreshAvailableProcesses() }
            } label: {
                HStack(spacing: 4) {
                    Text(currentLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear { listener.refreshAvailableProcesses() }
        }
        .font(.caption)
    }

    private var currentLabel: String {
        if let now = appModel.systemAudio.tappedProcessName,
           appModel.systemAudio.isActive {
            return Self.friendlyName(now)
        }
        if let pref = appModel.preferredSystemAudioProcessName {
            return Self.friendlyName(pref)
        }
        return "Auto"
    }

    static func friendlyName(_ raw: String) -> String {
        switch raw {
        case "RemotePlayerService": return "Apple Music"
        default: return raw
        }
    }
}

// MARK: - Microphone source

/// "Listen to whatever's in the room via the built-in mic" surface.
/// Owns the [[AppModel.useMic]] toggle that previously lived in
/// Settings → Audio Input. Same hero + card vocabulary as the empty-
/// state LocalSourceView.
struct MicrophoneSourceView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                toggleCard
                if appModel.useMic, appModel.micListener.isAuthorized == false {
                    permissionWarning
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Microphone")
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone input")
                    .font(.title2.weight(.semibold))
                Text("Capture live audio in the room — vinyl, an external speaker, an instrument — and visualize it as it plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var toggleCard: some View {
        SettingsCard(title: "Listen", systemImage: "waveform") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen with mic")
                        .font(.callout)
                    Text("Stream the built-in microphone through the visualizer's live analyzer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { appModel.useMic },
                    set: { appModel.useMic = $0 }
                ))
                .labelsHidden()
            }
        }
    }

    private var permissionWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Microphone permission denied — enable in System Settings → Privacy & Security → Microphone.")
                .font(.callout)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 600, alignment: .leading)
    }
}

// MARK: - Mac (system audio tap) source

#if os(macOS)
/// "Visualize whatever's making sound on this Mac" surface. Owns
/// the [[AppModel.useSystemAudio]] toggle + the
/// [[SystemAudioSourcePicker]] that previously lived in Settings →
/// Audio Input. The picker is the "list of tappable processes" the
/// user can choose — pinning to Music.app / Spotify / a browser /
/// any other audio-emitting process.
struct MacSourceView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                tapCard
                if appModel.useSystemAudio,
                   let msg = appModel.systemAudio.errorMessage,
                   appModel.systemAudio.isAuthorized == false {
                    permissionWarning(msg)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Mac")
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("System audio")
                    .font(.title2.weight(.semibold))
                Text("Tap any audio-emitting process on this Mac — Music.app, Spotify, a browser tab, anything — and visualize it without rerouting through Loopback or BlackHole.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var tapCard: some View {
        SettingsCard(title: "Listen", systemImage: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tap system audio")
                            .font(.callout)
                        Text("CoreAudio process tap — no virtual driver required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: Binding(
                        get: { appModel.useSystemAudio },
                        set: { appModel.useSystemAudio = $0 }
                    ))
                    .labelsHidden()
                }
                if appModel.useSystemAudio {
                    Divider()
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Source")
                                .font(.callout)
                            Text("Which process to listen to.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        SystemAudioSourcePicker()
                    }
                }
            }
        }
    }

    private func permissionWarning(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(msg)
                .font(.callout)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 600, alignment: .leading)
    }
}
#endif

#endif
