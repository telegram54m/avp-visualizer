//
//  MusicKitController.swift
//  High Videlity
//
//  Drives Apple Music playback inside the app via `ApplicationMusicPlayer`.
//  This is the actual production path for "user listens to their Apple
//  Music on the AVP": we play the song through their AM subscription, read
//  the playback clock directly (no DRM needed — we don't touch the audio
//  buffers), and fetch the same song's unencrypted iTunes preview in
//  parallel for tonal analysis.
//
//  Requires the "MusicKit" capability on the app's bundle ID (enabled via
//  Apple Developer console + Xcode signing) and `NSAppleMusicUsageDescription`
//  in Info.plist.
//

import Foundation
import MusicKit

@MainActor
@Observable
final class MusicKitController {

    // MARK: - Auth

    /// Current authorization status. Reflects `MusicAuthorization.currentStatus`
    /// — re-read after `requestAuthorization()`.
    var authStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    var isAuthorized: Bool { authStatus == .authorized }

    func requestAuthorization() async {
        authStatus = await MusicAuthorization.request()
    }

    // MARK: - Search

    var isSearching: Bool = false
    var searchResults: [Song] = []
    /// Last search query — exposed so the UI can show what's being searched.
    var searchQuery: String = ""

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }

        isSearching = true
        defer { isSearching = false }

        var request = MusicCatalogSearchRequest(term: trimmed, types: [Song.self])
        request.limit = 10
        do {
            let response = try await request.response()
            searchResults = Array(response.songs)
        } catch {
            print("[MusicKit] search failed: \(error)")
            searchResults = []
        }
    }

    // MARK: - Playback

    /// The song currently queued/playing via ApplicationMusicPlayer.
    var nowPlaying: Song?
    /// Mirror of `ApplicationMusicPlayer.shared.playbackTime`, refreshed at
    /// ~30 Hz by the polling task. This is what the visualizer reads — exact
    /// playback position inside the full song, frame-accurate, no DRM issue.
    var playbackTime: TimeInterval = 0
    var isPlaying: Bool = false

    private let player = ApplicationMusicPlayer.shared
    private var pollTask: Task<Void, Never>?

    /// Queue and start playback. If `context` is provided, the full set is
    /// queued (with `song` as the starting entry) so prev/next controls
    /// can advance through it. Falls back to single-song queue otherwise.
    func play(_ song: Song, context: [Song] = []) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }

        nowPlaying = song
        // Single-song queue. The earlier multi-song variant using
        // `ApplicationMusicPlayer.Queue(for:startingAt:)` caused
        // prepareToPlay to fail with MPMusicPlayerControllerErrorDomain.6
        // ("Failed to prepare to play") — likely a quirk of how that
        // queue init initializes vs an array literal, possibly related
        // to the catalog-lookup state of non-starting Song instances.
        // Single-song works reliably. Next/prev controls will be no-ops
        // until we figure out a queue init that prepareToPlay accepts.
        player.queue = [song]
        do {
            try await player.prepareToPlay()
            try await player.play()
            startPolling()
        } catch {
            print("[MusicKit] play failed: \(error)")
        }
    }

    func pause() {
        player.pause()
    }

    func resume() async {
        do { try await player.play() } catch {
            print("[MusicKit] resume failed: \(error)")
        }
    }

    /// Toggle pause/resume based on the player's current state.
    func togglePlayPause() async {
        if player.state.playbackStatus == .playing {
            pause()
        } else {
            await resume()
        }
    }

    /// Restart the current entry from the beginning.
    func restartCurrent() {
        player.restartCurrentEntry()
    }

    /// Advance to the next queued entry. No-op when at the end of the queue.
    func skipToNext() async {
        do { try await player.skipToNextEntry() } catch {
            print("[MusicKit] skipToNext failed: \(error)")
        }
    }

    /// Go back to the previous queued entry. No-op at the start of the queue.
    func skipToPrevious() async {
        do { try await player.skipToPreviousEntry() } catch {
            print("[MusicKit] skipToPrevious failed: \(error)")
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        player.stop()
        playbackTime = 0
        isPlaying = false
        nowPlaying = nil
    }

    /// Drain the player's non-Observable scalar state into @Observable
    /// properties at ~30 Hz. The visualizer reads `playbackTime` once per
    /// frame; this polling frequency is plenty for that.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self = self, !Task.isCancelled {
                self.playbackTime = self.player.playbackTime
                self.isPlaying = (self.player.state.playbackStatus == .playing)
                // Track queue advances (next/prev controls move the
                // current entry without going through `play(_:)`).
                // The queue's currentEntry's item is the live MusicItem;
                // cast to Song when possible so the visualizer's "now
                // playing" badge updates label automatically.
                if let entryItem = self.player.queue.currentEntry?.item,
                   case let .song(s) = entryItem,
                   s.id != self.nowPlaying?.id {
                    self.nowPlaying = s
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }
}
