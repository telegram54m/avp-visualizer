//
//  LocalSongsListView.swift
//  High Videlity
//
//  Sortable table view of every song in the user's scanned local
//  music folder. Pushed via NavigationLink from the Local Library
//  page's "Show all" affordance — that page shows a few sample
//  rows inline for context; this is the canonical "browse my
//  whole local library" surface.
//
//  Mirrors LibrarySongsListView in structure (debounced filter,
//  off-main filter+sort via Task.detached, 500-row display cap
//  with a "Show all" footer) but reads `[LibraryEntry]` from
//  `appModel.library.entries` instead of MusicKit songs and has no
//  cloud-status scope — local files are by definition all owned.
//
//  Adds a tiny "cached" status glyph column showing whether the
//  feature cache has been built for each file, since that's the
//  local-library equivalent of "this row is fully ready for the
//  visualizer."
//

#if os(macOS)
import SwiftUI

struct LocalSongsListView: View {
    let entries: [LibraryEntry]
    let appModel: AppModel

    @State private var sortOrder: [KeyPathComparator<SortableEntry>] = [
        KeyPathComparator(\.title, order: .forward)
    ]
    @State private var selection: SortableEntry.ID?
    @State private var filterText: String = ""
    @State private var debouncedFilter: String = ""
    @State private var debounceTask: Task<Void, Never>?

    @State private var mappedEntries: [SortableEntry] = []

    /// The actually-displayed list. Recomputed off-main when
    /// `debouncedFilter`, `sortOrder`, or `mappedEntries` change.
    /// Same rationale as [[LibrarySongsListView]]: keeping `rows`
    /// as `@State` avoids re-running filter+sort on every body
    /// eval (the filter bar reads `filterText`, which triggers
    /// body re-eval on every keystroke).
    @State private var rows: [SortableEntry] = []
    @State private var recomputeTask: Task<Void, Never>?

    @State private var matchCount: Int = 0
    @State private var showAll: Bool = false
    private static let displayCap = 500

    /// Sortable adapter wrapping `LibraryEntry`. Mirrors the
    /// `SortableSong` pattern in [[LibrarySongsListView]] —
    /// normalize optionals (`album`, `genre`) and pre-lowercase a
    /// composite `searchKey` so filter passes are zero-allocation
    /// per keystroke.
    struct SortableEntry: Identifiable, Hashable {
        let id: URL
        let entry: LibraryEntry
        let title: String
        let artist: String
        let album: String
        let durationSeconds: Double
        let searchKey: String
    }

    private func scheduleRowsRecompute() {
        recomputeTask?.cancel()
        let mapped = mappedEntries
        let q = debouncedFilter
        let sort = sortOrder
        let cap = showAll ? Int.max : Self.displayCap
        recomputeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> (capped: [SortableEntry], total: Int) in
                let filtered: [SortableEntry]
                if q.isEmpty {
                    filtered = mapped
                } else {
                    filtered = mapped.filter { $0.searchKey.contains(q) }
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

    private func rebuildMappedEntries() {
        if entries.count == mappedEntries.count { return }
        if entries.count > mappedEntries.count,
           sharesPrefix(with: entries) {
            let appended = entries[mappedEntries.count...].map(makeSortable)
            mappedEntries.append(contentsOf: appended)
        } else {
            mappedEntries = entries.map(makeSortable)
        }
        scheduleRowsRecompute()
    }

    private func makeSortable(_ entry: LibraryEntry) -> SortableEntry {
        let album = entry.album ?? ""
        let key = "\(entry.title) \(entry.artist) \(album)".lowercased()
        return SortableEntry(
            id: entry.fileURL,
            entry: entry,
            title: entry.title,
            artist: entry.artist,
            album: album,
            durationSeconds: entry.durationSeconds,
            searchKey: key
        )
    }

    private func sharesPrefix(with entries: [LibraryEntry]) -> Bool {
        let probe = min(mappedEntries.count, 5)
        for i in 0..<probe {
            if mappedEntries[i].id != entries[i].fileURL { return false }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { row in
                    cacheIcon(for: row.entry)
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
            .contextMenu(forSelectionType: SortableEntry.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Play Now") {
                        Task { await appModel.playLocalEntry(row.entry) }
                    }
                    Button("Play Next") {
                        Task { await appModel.queueNextLocal(row.entry) }
                    }
                    Button("Add to Queue") {
                        Task { await appModel.queueLastLocal(row.entry) }
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Task { await appModel.playLocalEntry(row.entry) }
                }
            }
        }
        .navigationTitle("Local Songs")
        .navigationSubtitle("\(matchCount) of \(entries.count)")
        .task(id: entries.count) {
            rebuildMappedEntries()
        }
        .onChange(of: filterText) { _, newValue in
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
            if showAll && !newValue.isEmpty { showAll = false }
            scheduleRowsRecompute()
        }
        .onChange(of: sortOrder) { _, _ in
            scheduleRowsRecompute()
        }
        .onChange(of: showAll) { _, _ in
            scheduleRowsRecompute()
        }
    }

    // MARK: - Cache-status icon

    /// Cached-vs-not glyph. Matches [[LocalSongRow]]'s in-row badge
    /// so visual vocabulary stays consistent between the preview
    /// list on the home page and this full table.
    @ViewBuilder
    private func cacheIcon(for entry: LibraryEntry) -> some View {
        if appModel.library.cachedURLs.contains(entry.fileURL) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Feature cache built")
        } else {
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
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func playEntry(_ entry: LibraryEntry) {
        Task {
            await appModel.loadSong(
                from: entry.fileURL,
                title: entry.title,
                artist: entry.artist,
                libraryEntry: entry.fileURL
            )
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
