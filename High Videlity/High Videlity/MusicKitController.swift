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
import OSLog

private let mkLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "musickit")

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
    /// Songs matching the last search query.
    var searchResults: [Song] = []
    /// Albums matching the last search query.
    var searchAlbums: [Album] = []
    /// Artists matching the last search query.
    var searchArtists: [Artist] = []
    /// Playlists matching the last search query.
    var searchPlaylists: [Playlist] = []
    /// Last search query — exposed so the UI can show what's being searched.
    var searchQuery: String = ""

    /// Per-type result limit. The MusicCatalogSearchRequest packs all
    /// types into one round-trip so the only cost of asking for more
    /// is the catalog server's response time + a slightly larger
    /// payload. 25 each gives a meaningful list per scope without
    /// drowning the UI.
    private static let searchLimit = 25

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            searchAlbums = []
            searchArtists = []
            searchPlaylists = []
            return
        }
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }

        isSearching = true
        defer { isSearching = false }

        // Single round-trip fetches all four result types. The UI's
        // scope picker just switches between the populated arrays —
        // no extra requests needed when the user changes scope.
        var request = MusicCatalogSearchRequest(
            term: trimmed,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = Self.searchLimit
        do {
            let response = try await request.response()
            searchResults = Array(response.songs)
            searchAlbums = Array(response.albums)
            searchArtists = Array(response.artists)
            searchPlaylists = Array(response.playlists)
        } catch {
            print("[MusicKit] search failed: \(error)")
            searchResults = []
            searchAlbums = []
            searchArtists = []
            searchPlaylists = []
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

    /// Fires whenever the player advances to a different track — both
    /// user-driven (skipToNext / skipToPrevious / restart) AND
    /// queue auto-advance at end-of-song. AppModel hooks this to
    /// re-fire the visualizer pipeline (preview load + Tier 3 synth
    /// + alignment register + cloud-stems lookup on iOS, or just
    /// state reset on macOS where the system-audio tap continues
    /// uninterrupted across the advance).
    ///
    /// Set BEFORE calling `play(_:)` — late assignment misses the
    /// initial track-change event.
    var onTrackChange: ((Song) -> Void)?

    /// Queue and start playback. If `context` is provided AND contains
    /// `song`, the full set is queued (with `song` as the starting
    /// entry) so prev/next controls + auto-advance walk through it.
    /// Falls back to single-song queue otherwise.
    ///
    /// Historical note: an earlier attempt at multi-song queues via
    /// `Queue(for:startingAt:)` failed prepareToPlay with
    /// `MPMusicPlayerControllerErrorDomain.6` ("Failed to prepare to
    /// play"). Re-tested 2026-05-28; behavior on the current MusicKit
    /// build is TBD. Keep a single-song fallback path so a regression
    /// degrades gracefully to today's behavior instead of breaking
    /// playback entirely.
    func play(_ song: Song, context: [Song] = []) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }

        nowPlaying = song

        // Prefer multi-song queue when caller passed a valid context
        // (>1 item, includes the starting song). Single-song queue is
        // the fallback.
        let preferMulti = context.count > 1 && context.contains(where: { $0.id == song.id })

        if preferMulti {
            do {
                player.queue = ApplicationMusicPlayer.Queue(for: context, startingAt: song)
                try await player.prepareToPlay()
                try await player.play()
                startPolling()
                return
            } catch {
                print("[MusicKit] multi-song queue prepareToPlay failed (\(error)); falling back to single-song queue")
                // Fall through to single-song path.
            }
        }

        player.queue = [song]
        do {
            try await player.prepareToPlay()
            try await player.play()
            startPolling()
        } catch {
            print("[MusicKit] play failed: \(error)")
        }
    }

    // MARK: - Queue mutation

    /// Insert a song right after the currently-playing entry, so it
    /// plays as soon as the current song finishes (or immediately on
    /// `skipToNext`). Backs the "Play Next" UI action.
    func queueNext(_ song: Song) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        // If the queue is empty (no current playback), seed it with
        // this song and start.
        guard player.queue.currentEntry != nil else {
            await play(song)
            return
        }
        do {
            try await player.queue.insert([song], position: .afterCurrentEntry)
        } catch {
            print("[MusicKit] queueNext failed: \(error)")
        }
    }

    /// Append a song to the end of the queue. Backs the "Add to Queue"
    /// UI action. Seeds an empty queue if nothing is currently
    /// playing — pressing "Add to Queue" with no current playback
    /// should still produce sound.
    func queueLast(_ song: Song) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        guard player.queue.currentEntry != nil else {
            await play(song)
            return
        }
        do {
            try await player.queue.insert([song], position: .tail)
        } catch {
            print("[MusicKit] queueLast failed: \(error)")
        }
    }

    /// Replace the queue with an album's tracks and start playing.
    /// Useful for "Play Album" actions.
    func play(album: Album) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        do {
            player.queue = ApplicationMusicPlayer.Queue(for: [album])
            try await player.prepareToPlay()
            try await player.play()
            startPolling()
        } catch {
            print("[MusicKit] play(album:) failed: \(error)")
        }
    }

    /// Replace the queue with a radio station and start playing.
    /// Stations are infinite-feed catalog items; tapping plays them
    /// directly (no detail view).
    func play(station: Station) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        do {
            player.queue = ApplicationMusicPlayer.Queue(for: [station])
            try await player.prepareToPlay()
            try await player.play()
            startPolling()
        } catch {
            print("[MusicKit] play(station:) failed: \(error)")
        }
    }

    /// Replace the queue with a playlist's tracks and start playing.
    func play(playlist: Playlist) async {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return }
        }
        do {
            player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
            try await player.prepareToPlay()
            try await player.play()
            startPolling()
        } catch {
            print("[MusicKit] play(playlist:) failed: \(error)")
        }
    }

    /// One upcoming row's worth of data. Uses `Queue.Entry`'s built-in
    /// title/subtitle (populated immediately by MusicKit) so rows
    /// render before `entry.item` finishes resolving into a Song. The
    /// optional `song` is filled in when item resolution completes —
    /// drives "Skip To" by giving us the Song for queue rebuild.
    struct UpNextItem: Identifiable, Equatable {
        let id: String  // Queue.Entry.ID — typed as String per MusicKit
        let title: String
        let artist: String
        let song: Song?

        static func == (lhs: UpNextItem, rhs: UpNextItem) -> Bool {
            // Equality on (id, title, artist, song-presence) — enough
            // to detect "this row materially changed" between polls.
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.artist == rhs.artist
                && (lhs.song?.id == rhs.song?.id)
        }
    }

    /// Snapshot of the upcoming queue entries (excluding the currently-
    /// playing one). The polling loop refreshes this whenever the
    /// signature actually changes — direct reads of `player.queue.entries`
    /// don't participate in @Observable so UI would never refresh from
    /// those.
    var upcomingItems: [UpNextItem] = []
    /// Last-published signature so the polling loop can short-circuit
    /// when nothing material has changed (avoid 30 Hz invalidations).
    @ObservationIgnored private var lastUpcomingSignature: [UpNextItem] = []

    /// Recompute `upcomingItems` from the player's live queue. Idempotent.
    /// Called from the polling loop; can also be called manually after
    /// known queue mutations to get a same-tick refresh.
    func refreshUpcoming() {
        let entries = player.queue.entries
        let currentID = player.queue.currentEntry?.id
        // Locate the current entry. If absent (no playback yet) we
        // treat the entire entries array as upcoming. If present, we
        // drop entries up to and including it.
        let upcoming: ArraySlice<ApplicationMusicPlayer.Queue.Entry>
        if let currentID,
           let currentIndex = entries.firstIndex(where: { $0.id == currentID }) {
            upcoming = entries.dropFirst(currentIndex + 1)
        } else {
            upcoming = entries[...]
        }
        let next = upcoming.map { entry -> UpNextItem in
            let song: Song? = {
                guard let item = entry.item, case let .song(s) = item else { return nil }
                return s
            }()
            return UpNextItem(
                id: entry.id,
                title: entry.title,
                artist: entry.subtitle ?? song?.artistName ?? "",
                song: song
            )
        }
        if next != lastUpcomingSignature {
            // One-line diag so we can see queue state through the log
            // stream while debugging the Up Next render. Cheap — only
            // fires on actual change.
            print("[MusicKit] upcoming refresh: \(next.count) upcoming, totalEntries=\(entries.count), currentID=\(currentID ?? "nil")")
            upcomingItems = next
            lastUpcomingSignature = next
        }
    }

    /// Remove an entry from the queue by index in `player.queue.entries`.
    /// Caller (typically UpNextView) supplies the index from its
    /// rendered list. Removing the current entry is rejected; use
    /// `skipToNext()` instead.
    func removeFromQueue(entryID: ApplicationMusicPlayer.Queue.Entry.ID) {
        guard player.queue.currentEntry?.id != entryID else { return }
        player.queue.entries.removeAll { $0.id == entryID }
    }

    /// Jump immediately to an arbitrary queued song. MusicKit doesn't
    /// expose direct currentEntry assignment, so this rebuilds the
    /// queue from the target onward. Side effect: songs BEFORE the
    /// target are removed from the queue (they're considered "already
    /// listened to" semantically). Songs AFTER the target survive.
    ///
    /// Fires exactly one `onTrackChange` (when the player's polling
    /// loop notices currentEntry differs from `nowPlaying`), so the
    /// visualizer pipeline runs once for the new song with no
    /// thrashing through intermediates.
    func skipToQueuedSong(_ song: Song) async {
        let entries = player.queue.entries
        guard let idx = entries.firstIndex(where: { entry in
            guard let item = entry.item, case let .song(s) = item else { return false }
            return s.id == song.id
        }) else { return }
        let remaining: [Song] = entries[idx...].compactMap { entry in
            guard let item = entry.item, case let .song(s) = item else { return nil }
            return s
        }
        guard let first = remaining.first else { return }
        nowPlaying = first
        do {
            player.queue = ApplicationMusicPlayer.Queue(for: remaining, startingAt: first)
            try await player.prepareToPlay()
            try await player.play()
        } catch {
            print("[MusicKit] skipToQueuedSong failed: \(error)")
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

    /// Seek the current track to a specific time. Backs the scrubber
    /// slider in NowPlayingView. `ApplicationMusicPlayer.playbackTime`
    /// is settable per Apple docs — assigning to it jumps the
    /// playhead. Only meaningful while there's a current entry; no-op
    /// when nothing is loaded.
    func seek(to seconds: TimeInterval) {
        guard player.queue.currentEntry != nil else { return }
        let clamped = max(0, seconds)
        player.playbackTime = clamped
        // Update our @Observable mirror immediately so the slider's
        // binding sees the move on the next render — the polling loop
        // would update within 33ms anyway, but binding-side latency
        // produces a visible "thumb snaps back" flicker without this.
        playbackTime = clamped
    }

    /// Duration of the currently-playing track, if known. Reads
    /// `nowPlaying?.duration` — MusicKit's Song has an optional
    /// duration that's populated for catalog tracks.
    var currentDuration: TimeInterval {
        nowPlaying?.duration ?? 0
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
        // Poll at 8 Hz, not 30. Each wake-up runs on @MainActor and
        // mutates two @Observable properties (playbackTime, isPlaying);
        // at 30 Hz that competed with the RealityKit visualizer's
        // render thread for the main thread, dropping viz FPS from
        // 100+ to ~20 once the visualizer opened (the polling Task
        // had higher priority and the OS gave it more wake slots).
        // 125 ms latency on track-change detection is imperceptible
        // for the scrubber and Up Next refresh.
        pollTask = Task { @MainActor [weak self] in
            while let self = self, !Task.isCancelled {
                // Mutate only when the values actually change so any
                // view bound to playbackTime / isPlaying only re-
                // renders on real change instead of 8 times/sec.
                let newPlaybackTime = self.player.playbackTime
                if abs(newPlaybackTime - self.playbackTime) > 0.05 {
                    self.playbackTime = newPlaybackTime
                }
                let newIsPlaying = (self.player.state.playbackStatus == .playing)
                if newIsPlaying != self.isPlaying {
                    self.isPlaying = newIsPlaying
                }
                if let entryItem = self.player.queue.currentEntry?.item,
                   case let .song(s) = entryItem,
                   s.id != self.nowPlaying?.id {
                    self.nowPlaying = s
                    self.onTrackChange?(s)
                }
                self.refreshUpcoming()
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }
    }

    // MARK: - User library

    /// User's library songs, most-recent-first. Generous limit for v1
    /// (~100); pagination via `nextBatch()` is deferred until we hit
    /// a real "library too big to fit in memory" complaint.
    func librarySongs(limit: Int = 100) async -> [Song] {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return [] }
        }
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = limit
            let response = try await request.response()
            return Array(response.items)
        } catch {
            print("[MusicKit] librarySongs failed: \(error)")
            return []
        }
    }

    /// User's library albums, most-recent-first. Each item carries
    /// artwork, so this drives a grid/list with album covers.
    func libraryAlbums(limit: Int = 100) async -> [Album] {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return [] }
        }
        do {
            var request = MusicLibraryRequest<Album>()
            request.limit = limit
            let response = try await request.response()
            return Array(response.items)
        } catch {
            print("[MusicKit] libraryAlbums failed: \(error)")
            return []
        }
    }

    /// User's library artists. Plays-as-radio when tapped via
    /// ArtistDetailView's existing top-songs path.
    func libraryArtists(limit: Int = 100) async -> [Artist] {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return [] }
        }
        do {
            var request = MusicLibraryRequest<Artist>()
            request.limit = limit
            let response = try await request.response()
            return Array(response.items)
        } catch {
            print("[MusicKit] libraryArtists failed: \(error)")
            return []
        }
    }

    /// User's library playlists (both Apple-curated saved playlists
    /// AND user-created ones).
    func libraryPlaylists(limit: Int = 100) async -> [Playlist] {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return [] }
        }
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = limit
            let response = try await request.response()
            return Array(response.items)
        } catch {
            print("[MusicKit] libraryPlaylists failed: \(error)")
            return []
        }
    }

    // MARK: - Browse (For You + Charts)

    /// Apple Music's personal recommendations for this user.
    /// Returns a list of recommendation sections — each section
    /// groups a few items (typically playlists, albums, stations).
    /// Renders as a "For You" surface in BrowseView.
    func recommendations() async -> [MusicPersonalRecommendation] {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return [] }
        }
        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = 25
            let response = try await request.response()
            return Array(response.recommendations)
        } catch {
            print("[MusicKit] recommendations failed: \(error)")
            return []
        }
    }

    /// Top Songs / Top Albums / Top Playlists charts for the user's
    /// current storefront. Returns the three typed arrays together so
    /// BrowseView can render them in parallel sections without three
    /// separate round-trips. Genre filter is deferred — first cut
    /// uses the storefront-wide top charts.
    struct Charts {
        var songs: [Song] = []
        var albums: [Album] = []
        var playlists: [Playlist] = []
    }

    func charts() async -> Charts {
        if !isAuthorized {
            await requestAuthorization()
            guard isAuthorized else { return Charts() }
        }
        do {
            var request = MusicCatalogChartsRequest(
                kinds: [.mostPlayed],
                types: [Song.self, Album.self, Playlist.self]
            )
            request.limit = 30
            let response = try await request.response()
            // Each `MusicCatalogChart` exposes `items` of its
            // concrete type. We collect across all chart sections
            // since the storefront may segment Top Songs into
            // multiple curated chart objects.
            var out = Charts()
            for chart in response.songCharts {
                out.songs.append(contentsOf: chart.items)
            }
            for chart in response.albumCharts {
                out.albums.append(contentsOf: chart.items)
            }
            for chart in response.playlistCharts {
                out.playlists.append(contentsOf: chart.items)
            }
            return out
        } catch {
            print("[MusicKit] charts failed: \(error)")
            return Charts()
        }
    }

    // NOTE: recently-played albums/playlists is intentionally deferred.
    // `MusicRecentlyPlayedRequest<Album>` fails to compile —
    // MusicKit's `MusicRecentlyPlayedRequestable` is implemented by a
    // narrower set of types than I initially assumed. Will revisit
    // with the right type (likely `MusicLibrarySection.Item` or a
    // `MusicRecentlyPlayedContainerRequest()` returning a mixed
    // enum). For Phase 4 v1, the four library queries above give the
    // user enough surface to find anything in their library.
}
