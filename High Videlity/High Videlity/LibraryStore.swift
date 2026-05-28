//
//  LibraryStore.swift
//  High Videlity
//
//  Observable state for the user's scanned audio library. Owns:
//   • the selected root folder (persisted across launches via
//     security-scoped bookmark in UserDefaults),
//   • the most recent scan results,
//   • scan + batch-cache progress so the browser UI can render live
//     status without polling.
//
//  macOS-only (the scanner is macOS-only). On other platforms this
//  type compiles as a thin stub so AppModel doesn't need #if-guards
//  around every reference.
//

import Foundation
import OSLog

#if os(macOS)
import AppKit

private let storeLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "library-store")

@MainActor
@Observable
final class LibraryStore {

    /// Most recent scan results. Empty until `rescan()` runs.
    private(set) var entries: [LibraryEntry] = []

    /// Granular scan state for the UI.
    enum ScanState: Sendable {
        case idle
        case scanning(scanned: Int, matched: Int)
        case done(matched: Int)
        case noFolderPicked
    }
    private(set) var scanState: ScanState = .noFolderPicked

    /// Current cache-batch progress. Nil when no batch is running.
    /// `phase` describes the slow step currently running for
    /// `currentTitle`. `inProgressFraction` is the 0-1 sub-progress
    /// WITHIN the current entry (driven by the sidecar's per-chunk
    /// Demucs progress events) so the bar moves smoothly during the
    /// long compute phase instead of jumping per-song.
    struct BatchProgress: Sendable {
        let total: Int
        let completed: Int
        let currentTitle: String
        let phase: String
        let inProgressFraction: Double

        /// Smooth 0-1 progress for a ProgressView, combining
        /// completed entries and sub-progress within the current one.
        var smoothFraction: Double {
            guard total > 0 else { return 0 }
            return (Double(completed) + inProgressFraction) / Double(total)
        }
    }
    private(set) var batchProgress: BatchProgress?

    /// File URLs we've batch-cached at some point. Persists across
    /// launches in UserDefaults so the "cached" badge survives a
    /// rescan. Imperfect — a song cached organically via Music.app
    /// playback won't appear here — but accurate for everything the
    /// user explicitly batch-processed from the library browser.
    private(set) var cachedURLs: Set<URL> = []

    /// Sort state for the library list. Mirrored from the browser
    /// view's per-view state so the visualizer's transport HUD can
    /// compute "next track" using the same ordering the user picked.
    /// Defaults to artist-ascending — same default LibraryBrowserView
    /// uses for first render.
    enum SortField: String, Sendable {
        case title, artist, album
    }
    var sortField: SortField = .artist
    var sortAscending: Bool = true

    /// The resolved root folder URL — nil if the user has never
    /// picked one (or if the bookmark resolution failed, e.g. the
    /// folder was deleted / moved while the app was closed).
    private(set) var rootURL: URL?

    /// True while `rootURL` is held under a security scope. We
    /// `startAccessingSecurityScopedResource` once on resolve and
    /// hold it for the app's lifetime — the alternative is wrapping
    /// every file read in a start/stop pair which is brittle when
    /// the reads happen on background tasks.
    @ObservationIgnored private var securityScopeActive = false

    private static let bookmarkKey = "LibraryStore.rootBookmark.v1"
    private static let cachedURLsKey = "LibraryStore.cachedURLs.v1"

    init() {
        resolveBookmark()
        loadCachedURLs()
        // If a previously-picked folder resolved successfully, scan it
        // automatically. Otherwise the user sees an empty list on
        // every launch and has to click Rescan before anything
        // appears — confusing because the folder pick already
        // persisted across launches.
        if rootURL != nil {
            Task { await rescan() }
        }
    }

    /// Open NSOpenPanel for a folder pick. On success, persists a
    /// security-scoped bookmark + kicks off a scan.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan This Folder"
        panel.message = "Choose your music library root. The app will scan recursively for audio files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyRoot(url, makeBookmark: true)
        Task { await rescan() }
    }

    /// Re-scan the currently-selected root folder.
    func rescan() async {
        guard let root = rootURL else {
            scanState = .noFolderPicked
            return
        }
        scanState = .scanning(scanned: 0, matched: 0)
        // Snapshot progress callback that hops back to main for state
        // mutation. Scanner runs on a background task.
        let found = await AudioLibraryScanner.scan(rootURL: root) { [weak self] scanned, matched in
            Task { @MainActor [weak self] in
                self?.scanState = .scanning(scanned: scanned, matched: matched)
            }
        }
        entries = found
        scanState = .done(matched: found.count)
        storeLog.info("HV-LIB rescan complete: \(found.count) entries")
    }

    /// Update the batch-progress observable from a (potentially
    /// off-actor) batch runner.
    func setBatchProgress(_ progress: BatchProgress?) {
        batchProgress = progress
    }

    // MARK: - Batch queue (multi-click cache accumulation)

    /// Entries queued for caching but not yet handed to the batch
    /// worker. Mutated through `enqueueForCaching` / `drainQueue` so
    /// invariants stay tight.
    private(set) var pendingQueue: [LibraryEntry] = []

    /// Long-running batch worker task. Spawned on first
    /// `enqueueForCaching` call; runs until the queue empties; nil
    /// when idle. Subsequent enqueues append to the queue without
    /// spawning a second task — the running one drains them.
    @ObservationIgnored private var batchWorkerTask: Task<Void, Never>?

    /// Append `entries` to the queue, deduping anything already
    /// queued or already in the in-flight batch. Ensures a single
    /// batch worker task is running to drain the queue. Caller
    /// supplies the provider since LibraryStore deliberately doesn't
    /// hold an AppModel reference (avoids a retain cycle).
    func enqueueForCaching(
        _ entries: [LibraryEntry],
        provider: StemFeatureProvider
    ) {
        // Dedupe against current queue + in-flight title
        let alreadyQueued = Set(pendingQueue.map { $0.fileURL })
        let inFlight = batchProgress?.currentTitle ?? ""
        let fresh = entries.filter {
            !alreadyQueued.contains($0.fileURL)
                && "\($0.title) — \($0.artist)" != inFlight
        }
        guard !fresh.isEmpty else { return }
        pendingQueue.append(contentsOf: fresh)

        // Make sure a worker is running.
        guard batchWorkerTask == nil else { return }
        let store = self
        batchWorkerTask = Task.detached(priority: .utility) {
            await store.runBatchWorker(provider: provider)
            await MainActor.run {
                store.batchWorkerTask = nil
            }
        }
    }

    /// Cancel any in-flight batch + clear the queue. Called by the
    /// browser sheet's Cancel button on the batch progress header.
    func cancelBatchQueue() {
        batchWorkerTask?.cancel()
        pendingQueue.removeAll()
    }

    /// Pop everything currently queued atomically. Returns the
    /// snapshot the caller should process. Worker loop calls this
    /// per iteration so anything appended during processing gets
    /// picked up on the next iteration.
    private func drainQueueSnapshot() -> [LibraryEntry] {
        let snapshot = pendingQueue
        pendingQueue.removeAll()
        return snapshot
    }

    /// Worker loop: drain snapshots until the queue is empty across
    /// a full pass. Runs off-actor via Task.detached; hops to
    /// MainActor only for the queue read/write + progress updates.
    nonisolated private func runBatchWorker(provider: StemFeatureProvider) async {
        defer {
            // Reset the visible progress bar when the worker exits
            // (queue drained or task cancelled). Without this the
            // browser sheet keeps showing the last-tick state long
            // after all work is done.
            Task { @MainActor [weak self] in self?.setBatchProgress(nil) }
        }
        while true {
            if Task.isCancelled { return }
            let batch = await MainActor.run { self.drainQueueSnapshot() }
            if batch.isEmpty { return }
            _ = await LibraryBatchCacher.cacheAll(
                batch, provider: provider,
                onProgress: { [weak self] completed, total, currentTitle, phase, frac in
                    Task { @MainActor in
                        self?.setBatchProgress(.init(
                            total: total, completed: completed,
                            currentTitle: currentTitle, phase: phase,
                            inProgressFraction: frac
                        ))
                    }
                },
                onEntryDone: { [weak self] entry, outcome in
                    Task { @MainActor in
                        switch outcome {
                        case .shazamIdentifiedAndCached, .unidentifiedButCached, .alreadyCached:
                            self?.markCached(entry.fileURL)
                        case .failed:
                            break
                        }
                    }
                }
            )
        }
    }

    /// Return the entry immediately following `url` in the current
    /// sort order. Wraps to the first entry when at the end. Nil when
    /// the library is empty or `url` isn't in it (caller can default
    /// to entries.first in that case). Used by the visualizer
    /// transport HUD's next-track button.
    func nextEntry(after url: URL) -> LibraryEntry? {
        let sorted = sortedEntries()
        guard !sorted.isEmpty else { return nil }
        guard let currentIdx = sorted.firstIndex(where: { $0.fileURL == url }) else {
            return sorted.first
        }
        let nextIdx = (currentIdx + 1) % sorted.count
        return sorted[nextIdx]
    }

    /// First entry by the user's current sort order. Used as the HUD's
    /// "next track" target when nothing is playing yet (or the current
    /// playing URL isn't in the library).
    func firstEntry() -> LibraryEntry? {
        sortedEntries().first
    }

    /// Apply the current `sortField` + `sortAscending` to `entries`.
    /// Same ordering used by the browser view's `displayedEntries`,
    /// minus search filtering (the HUD ignores search — it advances
    /// through the whole library, not the search subset).
    private func sortedEntries() -> [LibraryEntry] {
        let base: [LibraryEntry]
        switch sortField {
        case .title:
            base = entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            base = entries.sorted {
                let c = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if c == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return c == .orderedAscending
            }
        case .album:
            base = entries.sorted {
                let la = $0.album ?? ""
                let ra = $1.album ?? ""
                let c = la.localizedCaseInsensitiveCompare(ra)
                if c == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return c == .orderedAscending
            }
        }
        return sortAscending ? base : base.reversed()
    }

    /// Mark a file URL as cached. Persists immediately.
    func markCached(_ url: URL) {
        guard !cachedURLs.contains(url) else { return }
        cachedURLs.insert(url)
        persistCachedURLs()
    }

    /// Drop all cached marks (e.g., after clearAllCachedFeatures).
    func clearCachedMarks() {
        cachedURLs.removeAll()
        persistCachedURLs()
    }

    // MARK: - Cached-URL persistence

    private func loadCachedURLs() {
        guard let paths = UserDefaults.standard.array(forKey: Self.cachedURLsKey) as? [String] else {
            return
        }
        cachedURLs = Set(paths.map { URL(fileURLWithPath: $0) })
    }

    private func persistCachedURLs() {
        let paths = cachedURLs.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.cachedURLsKey)
    }

    // MARK: - Bookmark persistence

    private func applyRoot(_ url: URL, makeBookmark: Bool) {
        // Release any prior scope first.
        if securityScopeActive, let prior = rootURL {
            prior.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
        rootURL = url
        securityScopeActive = url.startAccessingSecurityScopedResource()
        if makeBookmark {
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
                storeLog.info("HV-LIB saved bookmark for \(url.path, privacy: .public)")
            } catch {
                storeLog.notice("HV-LIB bookmark save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            scanState = .noFolderPicked
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            applyRoot(url, makeBookmark: isStale)
            scanState = .idle
            storeLog.info("HV-LIB resolved bookmark for \(url.path, privacy: .public) (stale=\(isStale))")
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            scanState = .noFolderPicked
            storeLog.notice("HV-LIB bookmark resolve failed: \(String(describing: error), privacy: .public)")
        }
    }

    deinit {
        // We deliberately don't `stopAccessingSecurityScopedResource`
        // on the rootURL here — the resolved URL is local to this
        // instance and the scope dies with the process anyway. macOS
        // is forgiving about not calling stop, as long as we paired
        // start with our own object lifetime.
    }
}

#else  // !os(macOS)

/// Stub LibraryStore so cross-platform code can reference it without
/// #if guards. iOS / visionOS / tvOS get a separate library browser
/// (MPMediaQuery-based) in a future change.
@MainActor
@Observable
final class LibraryStore {
    private(set) var entries: [Never] = []
    enum ScanState: Sendable { case idle, noFolderPicked }
    private(set) var scanState: ScanState = .noFolderPicked
}

#endif
