//
//  LibrarySongsListView.swift
//  High Videlity
//
//  Sortable table view of every song in the user's Apple Music
//  library. Pushed via NavigationLink from the Library scope's
//  "Show all" affordance — the home feed renders a few song rows
//  inline for context, but the canonical "browse my whole library"
//  surface is this table.
//
//  Uses SwiftUI's `Table` on macOS so sort indicators, column
//  resize, and keyboard navigation come free. Songs already loaded
//  by `AppleMusicHomeView.loadLibrary` are passed in via init —
//  this view doesn't refetch.
//

#if os(macOS)
import SwiftUI
import MusicKit
import os

private let libSongsLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "LibrarySongs")

struct LibrarySongsListView: View {
    let songs: [Song]
    let appModel: AppModel

    @State private var sortOrder: [KeyPathComparator<SortableSong>] = [
        KeyPathComparator(\.title, order: .forward)
    ]
    @State private var selection: SortableSong.ID?
    /// Live text in the filter field. Bound to the TextField so the
    /// user sees their typing immediately.
    @State private var filterText: String = ""
    /// Debounced (200ms after last keystroke) lowercased filter
    /// actually applied to `rows`. Without the debounce, every
    /// character forced a full filter + sort pass over 11k rows,
    /// which beach-balled on fast typers.
    @State private var debouncedFilter: String = ""
    @State private var debounceTask: Task<Void, Never>?

    /// Cached map of `songs` → `SortableSong` adapters. Allocated
    /// once on appear / songs change. Without this cache the map
    /// ran on every body eval (11k+ allocations per call) which,
    /// combined with `Table`'s diff and Image loads in the row,
    /// stalled the main thread for the long beach ball after a
    /// sort click. The displayed `rows` derives filter+sort from
    /// this cache — those operations are cheap on already-mapped
    /// wrappers.
    @State private var mappedSongs: [SortableSong] = []

    /// The actually-displayed list. Recomputed off-main whenever
    /// `debouncedFilter`, `sortOrder`, or `mappedSongs` changes.
    /// Kept as `@State` (rather than a computed) because the filter
    /// bar reads `filterText` on every keystroke — that re-evaluated
    /// the prior computed `rows` (full filter + sort over 11k items)
    /// per keystroke even when `debouncedFilter` hadn't changed,
    /// which was the dominant beach-ball cause when backspacing
    /// through a long filter.
    @State private var rows: [SortableSong] = []
    @State private var recomputeTask: Task<Void, Never>?

    /// Total matching count before the display cap is applied.
    /// Drives the navigation subtitle + the "Show all" affordance.
    @State private var matchCount: Int = 0
    /// When false, cap displayed rows to `displayCap` so SwiftUI
    /// Table's diff doesn't stall the main thread on the
    /// many-thousand-row transitions (clearing a filter to reveal
    /// the full library, etc.). Even with filter+sort moved off
    /// main, the Table diff itself is main-thread work and
    /// beach-balls on 11k rows. The "Show all" button lifts the cap
    /// for the rare case the user actually wants the whole list.
    @State private var showAll: Bool = false
    /// Max rows to render by default. Picked empirically — large
    /// enough that most browse-without-filter sessions never notice
    /// it, small enough that the Table diff stays well under a
    /// perceptible frame.
    private static let displayCap = 500

    /// Library-scope filter: distinguish songs you actually own
    /// (purchased / iTunes Match / sideloaded) from songs added
    /// from the Apple Music catalog (which evaporate if your
    /// subscription lapses). Backed by [[CloudStatusLoader]] which
    /// bridges to iTunesLibrary — MusicKit's `Song` doesn't expose
    /// cloud status directly.
    enum LibraryScope: Hashable { case all, owned, added }
    @State private var scope: LibraryScope = .all
    /// Per-song cloud kind keyed by (title, artist, album). Empty
    /// until `loadCloudStatus` completes; the scope picker stays
    /// hidden while empty so users don't see a non-functional UI.
    @State private var cloudLookup: [String: CloudKind] = [:]
    @State private var cloudLoaded: Bool = false

    /// We wrap `Song` in a sortable adapter so all the columns can
    /// declare typed `KeyPathComparator` values — Song's optional
    /// duration / albumTitle don't fit `Comparable` cleanly, so the
    /// adapter normalizes them to non-optionals.
    ///
    /// `searchKey` is precomputed at map-time as
    /// `"title artist album".lowercased()`, so the filter becomes a
    /// single substring check per row with zero allocations per
    /// keystroke. Without this, filtering 11k songs was lowercasing
    /// 44k strings (3 fields × 11k rows + the query) per keystroke,
    /// which compounded with the sort to produce the beach ball.
    struct SortableSong: Identifiable, Hashable {
        let id: MusicItemID
        // NOTE: deliberately does NOT embed the MusicKit `Song`.
        // `Song` is a heavyweight value type (nested artwork +
        // relationship metadata); embedding it here meant the same
        // ~11k Songs were retained THREE times simultaneously — once
        // in the parent's `songs: [Song]`, once in `mappedSongs`, and
        // again in `rows` (up to 11k more under "Show all"). That was
        // the ~1.4 GB spike on the all-songs list. We keep only the
        // `id` + the few display strings the table renders, and look
        // the full `Song` back up from the parent `songs` array on the
        // rare play/queue action (see `song(for:)`).
        let title: String
        let artist: String
        let album: String
        let durationSeconds: Double
        let searchKey: String
        /// Resolved at map-time from the iTunesLibrary lookup —
        /// `.unknown` until the load completes, then either
        /// `.owned` or `.added` based on cloud + DRM + purchase
        /// status. Drives the scope filter and the row badge.
        let cloudKind: CloudKind
    }

    /// Recompute `rows` off-main from current `mappedSongs`,
    /// `debouncedFilter`, and `sortOrder`. Cancels any in-flight
    /// recompute so a burst of input changes only produces one
    /// Table update at the end. On 11k songs the prior on-main
    /// computed property blocked the main thread per keystroke
    /// (because the filter bar reads `filterText`, forcing body
    /// re-eval) — moving the work off-main keeps the field
    /// responsive even when each transition triggers a large
    /// Table diff.
    private func scheduleRowsRecompute() {
        recomputeTask?.cancel()
        let mapped = mappedSongs
        let q = debouncedFilter
        let sort = sortOrder
        let cap = showAll ? Int.max : Self.displayCap
        let scopeFilter = scope
        recomputeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> (capped: [SortableSong], total: Int) in
                var pool = mapped
                // Scope filter is cheap (one bool check per row) and
                // runs before the text filter so the text pass
                // operates on a smaller set when scope is narrow.
                switch scopeFilter {
                case .all: break
                case .owned: pool = pool.filter { $0.cloudKind == .owned }
                case .added: pool = pool.filter { $0.cloudKind == .added }
                }
                let filtered: [SortableSong]
                if q.isEmpty {
                    filtered = pool
                } else {
                    filtered = pool.filter { $0.searchKey.contains(q) }
                }
                if Task.isCancelled { return ([], 0) }
                let sorted = filtered.sorted(using: sort)
                if Task.isCancelled { return ([], 0) }
                let capped = sorted.count > cap ? Array(sorted.prefix(cap)) : sorted
                return (capped, sorted.count)
            }.value
            if Task.isCancelled { return }
            rows = result.capped
            matchCount = result.total
        }
    }

    /// Sync `mappedSongs` with the input `songs`. Incremental —
    /// only the newly-appended tail is mapped, so each pagination
    /// page costs O(pageSize) instead of O(songs.count). With 112
    /// pages of 100 songs streaming in, the prior full-rebuild
    /// approach was doing ~628k allocations total; this version
    /// does ~11k.
    ///
    /// Defensive full-rebuild branch handles the rare case where
    /// `songs` shrinks or otherwise diverges from the cache.
    private func rebuildMappedSongs() {
        if songs.count == mappedSongs.count { return }
        if songs.count > mappedSongs.count,
           // Sanity check: the existing cache is a strict prefix
           // of the new songs array. If it isn't (rare), fall
           // through to a full rebuild.
           sharesPrefix(with: songs) {
            let appended = songs[mappedSongs.count...].map(makeSortable)
            mappedSongs.append(contentsOf: appended)
        } else {
            mappedSongs = songs.map(makeSortable)
        }
        scheduleRowsRecompute()
    }

    /// Look the full `Song` back up from the parent `songs` array by
    /// id. Used only on user-initiated play/queue — an O(n) scan over
    /// ~11k items is microseconds and happens at most once per click,
    /// which is the right trade for not retaining 11k Songs twice over
    /// in `mappedSongs`/`rows`.
    private func song(for id: SortableSong.ID) -> Song? {
        songs.first { $0.id == id }
    }

    private func makeSortable(_ song: Song) -> SortableSong {
        let album = song.albumTitle ?? ""
        let key = "\(song.title) \(song.artistName) \(album)".lowercased()
        let cloudKey = CloudStatusLoader.key(
            title: song.title,
            artist: song.artistName,
            album: album
        )
        return SortableSong(
            id: song.id,
            title: song.title,
            artist: song.artistName,
            album: album,
            durationSeconds: song.duration ?? 0,
            searchKey: key,
            cloudKind: cloudLookup[cloudKey] ?? .unknown
        )
    }

    /// Cheap prefix check — confirm the first few cached IDs still
    /// match the corresponding `songs` entries. If MusicKit ever
    /// re-orders pages on us, fall back to full rebuild. Bounded
    /// to a handful of comparisons so even very long lists pay
    /// only constant cost here.
    private func sharesPrefix(with songs: [Song]) -> Bool {
        let probe = min(mappedSongs.count, 5)
        for i in 0..<probe {
            if mappedSongs[i].id != songs[i].id { return false }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                // Artwork dropped from the row — AsyncImage requests
                // per row plus Table's virtualization-on-sort were
                // the main beach-ball culprit on 11k+ song libraries.
                // The table is for sorting/scanning by metadata,
                // not for browsing artwork — that's what the home
                // feed and detail surfaces are for.
                TableColumn("") { row in
                    cloudIcon(for: row.cloudKind)
                }
                .width(20)
                TableColumn("Title", value: \.title) { row in
                    Text(row.title).lineLimit(1)
                }
                .width(min: 200, ideal: 360)
                TableColumn("Artist", value: \.artist) { row in
                    Text(row.artist).lineLimit(1)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Album", value: \.album) { row in
                    Text(row.album).lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Time", value: \.durationSeconds) { row in
                    Text(formatDuration(row.durationSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70, max: 90)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !showAll && matchCount > rows.count {
                    HStack(spacing: 8) {
                        Text("Showing first \(rows.count) of \(matchCount)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show all") { showAll = true }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .contextMenu(forSelectionType: SortableSong.ID.self) { ids in
                if let id = ids.first, let song = song(for: id) {
                    Button("Play Now") {
                        Task { await appModel.playAppleMusicSong(song) }
                    }
                    Button("Play Next") {
                        Task { await appModel.musicKit.queueNext(song) }
                    }
                    Button("Add to Queue") {
                        Task { await appModel.musicKit.queueLast(song) }
                    }
                }
            } primaryAction: { ids in
                // Double-click on a row plays it.
                if let id = ids.first, let song = song(for: id) {
                    Task { await appModel.playAppleMusicSong(song) }
                }
            }
        }
        .navigationTitle("Songs")
        .navigationSubtitle("\(matchCount) of \(songs.count)")
        .task(id: songs.count) {
            // Rebuild the cache whenever the input length changes.
            // (Length is a cheap proxy for "the songs array
            // changed" — we don't expect mutation that preserves
            // length in this view, since `songs` is passed by the
            // home feed as a snapshot.)
            rebuildMappedSongs()
        }
        .task {
            // Load cloud-status lookup once per view appearance.
            // Off-main inside the loader; we just await + publish.
            // First-call TCC prompt happens here on cold start —
            // user can deny, in which case `cloudLookup` stays
            // empty and the scope picker auto-hides.
            if !cloudLoaded {
                let map = await CloudStatusLoader.load()
                cloudLookup = map
                cloudLoaded = true
                // Re-map the existing songs so each carries its
                // newly-resolved cloudKind. ~11k allocations once.
                mappedSongs = songs.map(makeSortable)
                // Diagnostic: how many MusicKit songs actually
                // matched an iTunesLibrary entry. If hits is much
                // less than mappedSongs.count, the (title/artist/
                // album) normalization needs revising.
                var owned = 0, added = 0, unknown = 0
                for s in mappedSongs {
                    switch s.cloudKind {
                    case .owned: owned += 1
                    case .added: added += 1
                    case .unknown: unknown += 1
                    }
                }
                libSongsLog.info("cloudKind re-map: total=\(mappedSongs.count) owned=\(owned) added=\(added) unknown=\(unknown)")
                scheduleRowsRecompute()
            }
        }
        .onChange(of: filterText) { _, newValue in
            // 200ms debounce on every transition — including the
            // empty case. Previously the empty branch was applied
            // immediately for a "snappy clear", but that was the
            // worst case on 11k songs: it forced an instant diff
            // from the filtered set → full library + sort, which
            // beach-balled when the user held backspace through a
            // long filter. Treating empty like any other change
            // collapses a rapid backspace burst into a single
            // recompute at the end of the burst.
            debounceTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    debouncedFilter = trimmed
                }
            }
        }
        .onChange(of: debouncedFilter) { _, newValue in
            // Each new filter starts in capped mode again so the
            // user doesn't pay the Show-all cost on a fresh query.
            if showAll && !newValue.isEmpty { showAll = false }
            scheduleRowsRecompute()
        }
        .onChange(of: sortOrder) { _, _ in
            scheduleRowsRecompute()
        }
        .onChange(of: showAll) { _, _ in
            scheduleRowsRecompute()
        }
        .onChange(of: scope) { _, _ in
            // Switching scope can yield a much larger or smaller
            // result set — same cap+recompute story as filter
            // changes. Reset showAll so a switch from a narrow
            // scope to "All" doesn't suddenly try to render the
            // entire 11k library.
            if showAll { showAll = false }
            scheduleRowsRecompute()
        }
    }

    // MARK: - Cloud-status icon

    @ViewBuilder
    private func cloudIcon(for kind: CloudKind) -> some View {
        switch kind {
        case .owned:
            // No glyph — owned is the default expectation. Leaving
            // the column blank keeps scanning quiet; the eye picks
            // up the cloud-marked rows as the unusual case.
            Color.clear.frame(width: 14, height: 14)
        case .added:
            Image(systemName: "cloud")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .help("Added from Apple Music")
        case .unknown:
            // Either the iTunesLibrary load hadn't completed when
            // the row was mapped, or the (title/artist/album) key
            // didn't match — either way we show nothing rather
            // than a misleading badge.
            Color.clear.frame(width: 14, height: 14)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter songs", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 360, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            }

            if cloudLoaded && !cloudLookup.isEmpty {
                Picker("Scope", selection: $scope) {
                    Text("All").tag(LibraryScope.all)
                    Text("Owned").tag(LibraryScope.owned)
                    Text("Added").tag(LibraryScope.added)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
