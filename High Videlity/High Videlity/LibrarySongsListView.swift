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
        let song: Song
        let title: String
        let artist: String
        let album: String
        let durationSeconds: Double
        let searchKey: String
    }

    /// Filter + sort applied to the cached `mappedSongs`. Uses the
    /// debounced filter value + precomputed `searchKey` so neither
    /// the filter pass nor any allocations happen per keystroke.
    /// Sort still runs on every body eval but operates on the
    /// already-mapped wrappers (cheap String/Double comparisons).
    private var rows: [SortableSong] {
        let q = debouncedFilter
        let filtered: [SortableSong]
        if q.isEmpty {
            filtered = mappedSongs
        } else {
            filtered = mappedSongs.filter { $0.searchKey.contains(q) }
        }
        return filtered.sorted(using: sortOrder)
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
    }

    private func makeSortable(_ song: Song) -> SortableSong {
        let album = song.albumTitle ?? ""
        let key = "\(song.title) \(song.artistName) \(album)".lowercased()
        return SortableSong(
            id: song.id,
            song: song,
            title: song.title,
            artist: song.artistName,
            album: album,
            durationSeconds: song.duration ?? 0,
            searchKey: key
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
            .contextMenu(forSelectionType: SortableSong.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Play Now") {
                        Task { await appModel.playAppleMusicSong(row.song) }
                    }
                    Button("Play Next") {
                        Task { await appModel.musicKit.queueNext(row.song) }
                    }
                    Button("Add to Queue") {
                        Task { await appModel.musicKit.queueLast(row.song) }
                    }
                }
            } primaryAction: { ids in
                // Double-click on a row plays it.
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Task { await appModel.playAppleMusicSong(row.song) }
                }
            }
        }
        .navigationTitle("Songs")
        .navigationSubtitle("\(rows.count) of \(songs.count)")
        .task(id: songs.count) {
            // Rebuild the cache whenever the input length changes.
            // (Length is a cheap proxy for "the songs array
            // changed" — we don't expect mutation that preserves
            // length in this view, since `songs` is passed by the
            // home feed as a snapshot.)
            rebuildMappedSongs()
        }
        .onChange(of: filterText) { _, newValue in
            // 200ms debounce — fast typers don't trigger a refilter
            // on every character. Clearing the field (newValue
            // empty) applies immediately so the table snaps back
            // to full library without a perceived delay.
            debounceTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty {
                debouncedFilter = ""
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    debouncedFilter = trimmed
                }
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
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
