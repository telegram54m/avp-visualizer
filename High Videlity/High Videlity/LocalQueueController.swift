//
//  LocalQueueController.swift
//  High Videlity
//
//  Queue-and-auto-advance layer for local-file playback. Mirrors the
//  shape of the AM queue exposed by [[MusicKitController]] so the
//  Local Library source has the same Play-Now / Play-Next / Add-to-
//  Queue / Up-Next vocabulary.
//
//  Owns the queue state (`entries`, `currentIndex`). Does NOT own
//  the AVAudioPlayer — that still lives on AppModel — because
//  `startPlayback` / `stopPlayback` are deeply coupled to the
//  visualizer pipeline (audio session setup, mic/system-audio
//  mutual-exclusion guards). Instead this controller is the
//  AVAudioPlayer's delegate: when `audioPlayerDidFinishPlaying`
//  fires with `successfully = true`, it tells AppModel to advance
//  to the next queue entry.
//
//  `Item` is a thin wrapper around `LibraryEntry` so the controller
//  doesn't import AudioLibraryScanner into its public API and so the
//  UI can render upcoming rows without the file-size etc. baggage.
//

#if os(macOS)
import Foundation
import AVFoundation
import os

private let queueLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "LocalQueue")

@Observable
final class LocalQueueController: NSObject, AVAudioPlayerDelegate {

    /// One row in the local queue. Identified by `fileURL` because
    /// that's stable across re-scans and the same LibraryEntry can't
    /// legitimately appear twice at the same URL.
    struct Item: Identifiable, Hashable {
        let id: URL
        let entry: LibraryEntry
        var title: String { entry.title }
        var artist: String { entry.artist }
    }

    /// Full queue (already-played + current + upcoming). The current
    /// item lives at `currentIndex`. The audio player only knows about
    /// the current item; auto-advance from the delegate calls back to
    /// AppModel with the next entry.
    @ObservationIgnored private(set) var entries: [Item] = []
    @ObservationIgnored private(set) var currentIndex: Int = 0

    /// Observable mirror of the upcoming slice (items AFTER
    /// `currentIndex`). Recomputed whenever the queue mutates so
    /// SwiftUI views reading `upcomingItems` get a single
    /// invalidation per change rather than tracking the raw
    /// `entries` array (which we keep ObservationIgnored to avoid
    /// per-keystroke cascades when the queue is bulk-edited).
    private(set) var upcomingItems: [Item] = []

    /// Hook AppModel installs so the controller can request "load +
    /// play this entry through the visualizer pipeline" without
    /// importing the entire AppModel surface. Set once during
    /// AppModel init.
    @ObservationIgnored var onAdvance: ((LibraryEntry) -> Void)?
    /// Called when the queue is fully exhausted (current was last,
    /// finished playing). AppModel uses this to keep playback state
    /// clean and clear the "currently loaded" card if desired.
    @ObservationIgnored var onQueueExhausted: (() -> Void)?

    // MARK: - Query

    var currentItem: Item? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    var hasNext: Bool {
        currentIndex + 1 < entries.count
    }

    var hasPrevious: Bool {
        currentIndex > 0
    }

    // MARK: - Mutations

    /// Replace the queue with `newEntries` and set the current
    /// pointer to `startAt`. Caller is expected to immediately load
    /// + play the resulting current item via AppModel.
    func replace(with newEntries: [LibraryEntry], startAt: Int) {
        entries = newEntries.map { Item(id: $0.fileURL, entry: $0) }
        currentIndex = max(0, min(startAt, entries.count - 1))
        refreshUpcoming()
        queueLog.info("replace: count=\(self.entries.count) startAt=\(self.currentIndex)")
    }

    /// Insert one entry directly after the current item. Becomes the
    /// next track that auto-advance picks up.
    func insertNext(_ entry: LibraryEntry) {
        let item = Item(id: entry.fileURL, entry: entry)
        if entries.isEmpty {
            entries = [item]
            currentIndex = 0
        } else {
            let insertAt = currentIndex + 1
            entries.insert(item, at: min(insertAt, entries.count))
        }
        refreshUpcoming()
        queueLog.info("insertNext at \(self.currentIndex + 1) total=\(self.entries.count)")
    }

    /// Append entries to the tail of the queue. Bulk variant used by
    /// "Add album / artist to Queue".
    func appendTail(_ newEntries: [LibraryEntry]) {
        guard !newEntries.isEmpty else { return }
        let items = newEntries.map { Item(id: $0.fileURL, entry: $0) }
        if entries.isEmpty {
            entries = items
            currentIndex = 0
        } else {
            entries.append(contentsOf: items)
        }
        refreshUpcoming()
        queueLog.info("appendTail +\(newEntries.count) total=\(self.entries.count)")
    }

    /// Jump the current pointer to `index`. Caller loads + plays the
    /// resulting current item.
    func jump(to index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        refreshUpcoming()
    }

    /// Remove an upcoming entry by its `Item.id` (URL). Removing the
    /// current entry is rejected — UI should use skipToNext for that
    /// — to keep semantics simple (no "what plays now if I delete
    /// what's playing?" branch).
    func remove(id: URL) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard idx != currentIndex else { return }
        entries.remove(at: idx)
        if idx < currentIndex { currentIndex -= 1 }
        refreshUpcoming()
    }

    /// Clear the queue entirely. Doesn't stop playback (caller does).
    func clear() {
        entries = []
        currentIndex = 0
        refreshUpcoming()
    }

    private func refreshUpcoming() {
        let next = entries.indices.contains(currentIndex + 1)
            ? Array(entries[(currentIndex + 1)...])
            : []
        upcomingItems = next
    }

    // MARK: - Auto-advance

    /// Called by AppModel as part of advancing playback so we know
    /// where in the queue we are if the user mid-stream re-built it.
    func attach(to player: AVAudioPlayer) {
        player.delegate = self
    }

    /// AVAudioPlayerDelegate: called on the audio thread when the
    /// player runs off the end of the file. `successfully` is false
    /// when the player was stopped mid-stream (we don't auto-advance
    /// in that case — the user probably hit pause / loaded a
    /// different song).
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        // Hop to MainActor — the delegate fires on AVFoundation's
        // background queue and we're about to touch SwiftUI state +
        // call back into AppModel methods that aren't audio-safe.
        Task { @MainActor in
            self.advanceToNextIfPossible()
        }
    }

    @MainActor
    private func advanceToNextIfPossible() {
        if hasNext {
            currentIndex += 1
            refreshUpcoming()
            let next = entries[currentIndex].entry
            queueLog.info("auto-advance -> idx=\(self.currentIndex) \"\(next.title, privacy: .public)\"")
            onAdvance?(next)
        } else {
            queueLog.info("queue exhausted at idx=\(self.currentIndex)")
            onQueueExhausted?()
        }
    }
}
#endif
