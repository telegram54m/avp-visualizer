//
//  LibraryBrowserView.swift
//  High Videlity
//
//  macOS-only sheet that shows the user's scanned audio library. List
//  of filtered "looks-like-a-song" entries with multi-select; toolbar
//  actions for picking the root folder, rescanning, playing a single
//  selected entry through the visualizer, and batch-caching features
//  for any subset of selected rows.
//

#if os(macOS)
import SwiftUI

struct LibraryBrowserView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<URL> = []

    /// Library store now lives on AppModel as a singleton so the
    /// visualizer's transport HUD can access the same entries + sort
    /// for next-track navigation during library playback. We just
    /// alias it here for readability.
    private var store: LibraryStore { appModel.library }

    // Search + sort UI state stays per-view (these are display
    // concerns). The "current sort" used for next-track navigation
    // is mirrored into the singleton store via syncSortToStore() so
    // the HUD can read it without a reverse dependency on this view.
    @State private var searchText: String = ""
    @State private var sortField: SortField = .artist
    @State private var sortAscending: Bool = true

    enum SortField: String, CaseIterable, Identifiable {
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            content
                .frame(minWidth: 700, minHeight: 450)
                .navigationTitle("Audio Library")
                .toolbar { toolbarContent }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.scanState {
        case .noFolderPicked:
            emptyState
        case .scanning(let scanned, let matched):
            scanningState(scanned: scanned, matched: matched)
        case .idle, .done:
            listState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No library folder picked yet")
                .font(.headline)
            Text("Choose a folder containing your music files. The app will scan recursively, filter to entries that look like songs (vs. voice memos / podcasts), and let you queue them for feature caching or playback.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Pick Folder…") { store.pickFolder() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanningState(scanned: Int, matched: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning…")
                .font(.headline)
            Text("\(matched) songs found / \(scanned) files inspected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listState: some View {
        VStack(spacing: 0) {
            if let batch = store.batchProgress {
                batchHeader(batch)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
            }
            // Plain List with multi-select. `id: \.fileURL` lets
            // selection survive rescans / sort / filter changes.
            List(selection: $selection) {
                ForEach(displayedEntries) { entry in
                    LibraryRow(entry: entry, isCached: store.cachedURLs.contains(entry.fileURL))
                        .tag(entry.fileURL)
                }
            }
            .listStyle(.inset)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search title, artist, album")
            footer
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    /// Apply search filter + sort to the raw entries before display.
    private var displayedEntries: [LibraryEntry] {
        let filtered = filteredEntries(store.entries, search: searchText)
        return sortedEntries(filtered, by: sortField, ascending: sortAscending)
    }

    private func filteredEntries(_ entries: [LibraryEntry], search: String) -> [LibraryEntry] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { e in
            e.title.lowercased().contains(trimmed)
                || e.artist.lowercased().contains(trimmed)
                || (e.album?.lowercased().contains(trimmed) ?? false)
        }
    }

    private func sortedEntries(_ entries: [LibraryEntry], by field: SortField, ascending: Bool) -> [LibraryEntry] {
        let result: [LibraryEntry]
        switch field {
        case .title:
            result = entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            result = entries.sorted {
                let c = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if c == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return c == .orderedAscending
            }
        case .album:
            result = entries.sorted {
                let la = $0.album ?? ""
                let ra = $1.album ?? ""
                let c = la.localizedCaseInsensitiveCompare(ra)
                if c == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return c == .orderedAscending
            }
        }
        return ascending ? result : result.reversed()
    }

    private func batchHeader(_ batch: LibraryStore.BatchProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: batch.smoothFraction, total: 1.0)
                .frame(maxWidth: 200)
            Text("\(batch.completed) / \(batch.total)")
                .monospacedDigit()
                .font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(batch.currentTitle)
                    .lineLimit(1)
                Text(batch.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel") {
                store.cancelBatchQueue()
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Play") { playSelected() }
                .disabled(selection.count != 1)
            Button(cacheButtonLabel) { startBatchCache() }
                .disabled(selection.isEmpty)
                .buttonStyle(.borderedProminent)
        }
    }

    private var footerStatus: String {
        let shown = displayedEntries.count
        let total = store.entries.count
        let cachedShown = displayedEntries.filter { store.cachedURLs.contains($0.fileURL) }.count
        if shown == total {
            return "\(total) song\(total == 1 ? "" : "s") · \(cachedShown) cached"
        } else {
            return "\(shown) of \(total) · \(cachedShown) cached"
        }
    }

    /// Cache button text — changes when a batch is already running so
    /// the user knows their click will append to the queue rather
    /// than start fresh.
    private var cacheButtonLabel: String {
        if store.batchProgress != nil {
            return "Add \(selection.count) to Queue"
        }
        return "Cache Features (\(selection.count))"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Pick Folder…") { store.pickFolder() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(SortField.allCases) { field in
                    Button {
                        if sortField == field {
                            sortAscending.toggle()
                        } else {
                            sortField = field
                            sortAscending = true
                        }
                    } label: {
                        HStack {
                            Text(field.rawValue)
                            if sortField == field {
                                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Rescan") {
                Task { await store.rescan() }
            }
            .disabled(store.rootURL == nil)
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Actions

    private func playSelected() {
        guard selection.count == 1, let url = selection.first,
              let entry = store.entries.first(where: { $0.fileURL == url })
        else { return }
        let appModel = self.appModel
        let title = entry.title
        let artist = entry.artist
        let entryURL = entry.fileURL
        // Mirror current sort state into the singleton so the HUD's
        // next-track button advances through entries in the same
        // order the user is viewing.
        syncSortToStore()
        Task { await appModel.loadSong(from: url, title: title, artist: artist, libraryEntry: entryURL) }
        dismiss()
    }

    /// Push the view's local sort state into the singleton store so
    /// the visualizer HUD's next-track advances in the same order.
    private func syncSortToStore() {
        switch sortField {
        case .title: store.sortField = .title
        case .artist: store.sortField = .artist
        case .album: store.sortField = .album
        }
        store.sortAscending = sortAscending
    }

    private func startBatchCache() {
        let selectedEntries = store.entries.filter { selection.contains($0.fileURL) }
        guard !selectedEntries.isEmpty else { return }
        // Queue-based: appends to the worker's pending list and
        // ensures a worker is running. Subsequent clicks while a
        // batch is in progress just enqueue more — they don't
        // restart or interrupt the worker.
        let store = self.store
        let appModel = self.appModel
        // First batch in a session needs the provider's sidecar to
        // spin up — show a placeholder so the user sees "something
        // is happening" before the worker's first onProgress fires.
        if store.batchProgress == nil {
            store.setBatchProgress(.init(
                total: selectedEntries.count, completed: 0,
                currentTitle: "Preparing…",
                phase: "Starting sidecar (model load can take ~10s on first run)…",
                inProgressFraction: 0
            ))
        }
        Task {
            let provider = await appModel.ensureStemFeatureProvider()
            store.enqueueForCaching(selectedEntries, provider: provider)
        }
    }
}

// MARK: - Row

private struct LibraryRow: View {
    let entry: LibraryEntry
    let isCached: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Cached badge column — fixed width so rows align even
            // when some are cached and some aren't.
            Group {
                if isCached {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Stems cached")
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let album = entry.album {
                Text(album)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
            Text(formatDuration(entry.durationSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#endif  // os(macOS)
