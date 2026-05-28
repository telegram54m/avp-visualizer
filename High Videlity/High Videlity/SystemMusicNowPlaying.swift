//
//  SystemMusicNowPlaying.swift
//
//  iOS-side parallel to MusicAppNowPlaying.swift (macOS / AppleScript).
//  Observes `MPMusicPlayerController.systemMusicPlayer` — the iOS system
//  music player that surfaces whatever the user is playing in the Music
//  app (or any other app that publishes to the system player). Emits a
//  callback on track changes and polls `currentPlaybackTime` so the
//  visualizer can use it as a clock without capturing audio.
//
//  Why this exists: iOS has no equivalent of macOS's Core Audio system
//  tap. Capturing the Music app's audio via the mic fights iOS's
//  `.playAndRecord` ducking (see ios-audio-session.md). The system-music
//  observer side-steps the audio path entirely — we read metadata +
//  position and drive the visualizer from preview-analyzed features at
//  the right offset (via the existing Shazam alignment system).
//
//  Limits:
//   • Apple Music / Music.app only. Spotify and browsers don't publish
//     to the system player; for those, fall back to mic mode (with the
//     documented quality compromise).
//   • Requires `NSAppleMusicUsageDescription` in Info.plist. The system
//     player itself doesn't need MediaLibrary auth — it just observes
//     what the system is doing — but reading `nowPlayingItem` metadata
//     does require usage description.
//

import Foundation
#if os(iOS)
import MediaPlayer
#endif

/// Lightweight observable mirror of MPMusicPlayerController.systemMusicPlayer.
/// All public state lives on @MainActor. Off-platform (macOS / visionOS /
/// tvOS) this is a no-op: `start()` does nothing, properties stay at
/// defaults, `isActive` never flips. AppModel's iOS-only didSet guards
/// the call sites anyway, so the no-op is defensive.
@MainActor
@Observable
final class SystemMusicNowPlaying {
    /// Currently-playing track title, or "" when nothing is playing.
    private(set) var title: String = ""
    /// Currently-playing track artist, or "" when nothing is playing.
    private(set) var artist: String = ""
    /// MPMediaItem.persistentID as a String (stable per-track in the
    /// user's library). "" when no track. Useful as cache key for
    /// preview frames.
    private(set) var persistentID: String = ""
    /// Full song duration in seconds (MPMediaItem.playbackDuration).
    /// 0 when no track. Different from the 30s preview's duration —
    /// the visualizer uses this to know where in the SONG we are so
    /// alignment can map it back into the preview's timeline.
    private(set) var durationSeconds: Double = 0
    /// Playhead position in seconds — polled at 10 Hz because there's
    /// no notification for playback time. 0 when no track / not started.
    private(set) var currentPlaybackTime: Double = 0
    /// True when MPMusicPlayerController.playbackState == .playing.
    /// False when paused, stopped, interrupted, or no track.
    private(set) var isPlaying: Bool = false
    /// True between start() and stop() — i.e. we're holding the
    /// notification subscription + the polling task is running. UI
    /// can use this to decide whether the observer is the active
    /// audio source.
    private(set) var isActive: Bool = false

    /// Fires once on each `nowPlayingItem` change, on the main actor.
    /// Payload: (title, artist, persistentID, durationSeconds).
    /// `persistentID == ""` means the track was cleared (no current
    /// item) — subscribers should release per-song state.
    ///
    /// Also fires once on `start()` to seed initial state.
    @ObservationIgnored
    var onTrackChange: ((String, String, String, Double) -> Void)?

    #if os(iOS)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Last persistentID we fired onTrackChange for. Used to suppress
    /// duplicate fires when the OS posts the notification but the
    /// underlying item hasn't actually changed (happens during state
    /// transitions: pause/resume, app foreground, etc.).
    @ObservationIgnored private var lastEmittedPID: String = ""
    #endif

    /// Subscribe to MPMusicPlayerController notifications + start the
    /// polling task. Idempotent — calling while already active is a no-op.
    /// On non-iOS platforms this returns immediately without side effects.
    func start() {
        guard !isActive else { return }
        isActive = true
        #if os(iOS)
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()

        let nc = NotificationCenter.default
        let onItem = nc.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            // Notification queue is .main — but it's NSOperationQueue's
            // main, not Swift Concurrency's MainActor. Hop explicitly.
            Task { @MainActor [weak self] in self?.snapshotItem() }
        }
        let onState = nc.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.snapshotPlaybackState() }
        }
        observers = [onItem, onState]

        // Poll currentPlaybackTime at 10 Hz. MediaPlayer doesn't post
        // notifications for time updates — there's no equivalent to
        // AVPlayer's periodic time observer for the system player.
        // 10 Hz is plenty: visualizers running at 60 fps will read the
        // same currentPlaybackTime ~6 times before it updates, but
        // since they're interpolating from preview frames (analyzed at
        // 30 fps) anyway, the practical resolution is 30 Hz at best —
        // and the polled value is monotonic, so visual jitter is
        // imperceptible.
        pollTask = Task { @MainActor [weak self] in
            while let self, self.isActive {
                self.currentPlaybackTime = MPMusicPlayerController
                    .systemMusicPlayer.currentPlaybackTime
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            }
        }

        // Seed initial state so subscribers see whatever's already
        // playing (we may turn on while music is mid-track).
        snapshotItem()
        snapshotPlaybackState()
        #endif
    }

    /// Tear down observers + polling task. Idempotent.
    func stop() {
        guard isActive else { return }
        isActive = false
        #if os(iOS)
        pollTask?.cancel()
        pollTask = nil
        let nc = NotificationCenter.default
        for obs in observers { nc.removeObserver(obs) }
        observers = []
        MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()
        // Reset published state so any UI that's still observing
        // shows a clean "nothing playing" until the observer restarts.
        title = ""
        artist = ""
        persistentID = ""
        durationSeconds = 0
        currentPlaybackTime = 0
        isPlaying = false
        lastEmittedPID = ""
        #endif
    }

    /// Transport: skip to the next item in whatever queue Music.app /
    /// the system player is on. Visualizer's onTrackChange handler
    /// fires shortly after via the system notification, so per-song
    /// state (preview frames, overrides, stems) reloads automatically.
    /// No-op outside iOS.
    func skipToNext() {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.skipToNextItem()
        #endif
    }

    /// Transport: skip to previous item (or restart current track,
    /// depending on Music.app's "previous-vs-restart" threshold —
    /// same behavior as the lock-screen prev button).
    func skipToPrevious() {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem()
        #endif
    }

    /// Transport: toggle play/pause. Reads current playbackState to
    /// pick the right direction (the system player has no symmetric
    /// toggle method).
    func togglePlayPause() {
        #if os(iOS)
        let player = MPMusicPlayerController.systemMusicPlayer
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
        #endif
    }

    /// Transport: restart the current track from 0.
    func restart() {
        #if os(iOS)
        MPMusicPlayerController.systemMusicPlayer.skipToBeginning()
        #endif
    }

    #if os(iOS)
    /// Read MPMediaItem fields into our published state. Fires
    /// onTrackChange when persistentID changes.
    private func snapshotItem() {
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        let newTitle = item?.title ?? ""
        let newArtist = item?.artist ?? ""
        // MPMediaItem.persistentID is UInt64. Stringify so we can use ""
        // as the "no track" sentinel without colliding with a real ID.
        let newPID: String = item.map { String($0.persistentID) } ?? ""
        let newDuration = item?.playbackDuration ?? 0

        title = newTitle
        artist = newArtist
        persistentID = newPID
        durationSeconds = newDuration
        // Reset playhead snapshot — the next poll tick will overwrite.
        // Without this, a track change leaves the previous song's
        // currentPlaybackTime momentarily, which can mis-seed visualizers
        // that read playbackTime at the moment of the track-change
        // callback.
        currentPlaybackTime = 0

        if newPID != lastEmittedPID {
            lastEmittedPID = newPID
            onTrackChange?(newTitle, newArtist, newPID, newDuration)
        }
    }

    private func snapshotPlaybackState() {
        isPlaying = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    }
    #endif
}
