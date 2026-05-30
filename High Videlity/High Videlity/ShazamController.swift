//
//  ShazamController.swift
//  High Videlity
//
//  Listens to live audio (fan-out from MicListener) and identifies whatever
//  song is playing against Shazam's public catalog. Removes the manual
//  search step from the mic path — when the user enables "Listen with mic",
//  Shazam tells us what's playing and we auto-fetch the matching iTunes
//  preview for tonal analysis.
//
//  Phase 1 (this file): public-catalog auto-ID only. Phase 2 will add a
//  custom catalog built from the preview's audio so we can align the
//  preview's colour timeline to the actual song position via
//  `predictedCurrentMatchOffset`.
//

import AVFoundation
import Foundation
import OSLog
import ShazamKit

/// Visible via `log show --predicate 'subsystem == "com.jessegriffith.HighVidelity"'`.
private let shazamLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "shazam")

@MainActor
@Observable
final class ShazamController: NSObject {

    /// What the controller is currently doing.
    enum Status: Equatable {
        case idle
        case listening
        case matched(title: String, artist: String)
        case failed(String)
    }

    var status: Status = .idle
    /// Most recent successful match — full media item with all metadata.
    var lastMatch: SHMatchedMediaItem?
    /// Fires when a new match arrives so AppModel can react. Counter-based so
    /// the consumer can tell new matches from repeats of the same song.
    var matchCounter: Int = 0

    /// Called on the main actor when a new match arrives. Set by AppModel
    /// to trigger preview-fetch + visualizer load.
    var onMatch: ((SHMatchedMediaItem) -> Void)?

    @ObservationIgnored var session: SHSession?
    /// Audio-thread-readable mirror of `session`. The main-actor `session`
    /// property can't be read from a `nonisolated` audio-thread call site,
    /// so we keep a parallel non-isolated reference that's updated in
    /// lockstep. `SHSession` is documented thread-safe — its only
    /// thread-bound requirement is that `init` happens on main, which is
    /// where `start()` runs.
    @ObservationIgnored nonisolated(unsafe) var nonisolatedSession: SHSession?

    // MARK: - Phase 2 (custom-catalog alignment) storage
    // Declared here (not as a class extension) because Swift extensions
    // can't add stored properties, and the trick we tried (per-instance
    // dict keyed by ObjectIdentifier) fights the main-actor isolation
    // rules when the audio-thread feed path needs to read the nonisolated
    // session reference. See ShazamPhase2.swift for the methods that
    // operate on these fields.
    @ObservationIgnored var customSession: SHSession?
    @ObservationIgnored nonisolated(unsafe) var nonisolatedCustomSession: SHSession?
    @ObservationIgnored var customCatalog: SHCustomCatalog?
    /// Most recent alignment from a custom-catalog match. AppModel reads
    /// this in `playbackTime` to map song clock → preview index.
    var previewAlignment: PreviewAlignment?
    /// Set by AppModel once frames are loaded — used for modulo-wrap.
    @ObservationIgnored var previewDuration: TimeInterval?
    /// AppModel-provided callback returning the current song clock at the
    /// moment a custom-catalog match fires. AM-driven when AM is playing,
    /// wall-clock otherwise.
    @ObservationIgnored var currentSongPositionProvider: (@MainActor () -> (position: TimeInterval, isAMClock: Bool))?
    /// Normalized-title key of the most recently registered alignment.
    /// `registerForAlignment` skips re-registration when a new title is
    /// fuzzy-similar to this, preventing the public-catalog session's
    /// false-positive matches from blowing away an accumulating custom
    /// session every few seconds.
    @ObservationIgnored var lastRegisteredTitleKey: String?

    // MARK: - Hybrid Phase 2 + Phase 3 (per-song offset cache)
    //
    // When Phase 2 fires (custom catalog match) AND Phase 3 fires (public
    // catalog match) close in time for the same song, we can derive the
    // song-time at which the preview starts:
    //
    //   previewStartInSong = pcmo - previewOffset
    //
    // We persist that per (title, artist) so subsequent listens of the
    // same song get instant alignment from Phase 3's pcmo alone — no need
    // for Phase 2's finicky single-signature catalog match to fire.

    /// Most recently seen public-catalog match's pcmo + wall-clock.
    /// Used to derive `previewStartInSong` when Phase 2 fires close in time.
    @ObservationIgnored var lastPublicMatchPCMO: TimeInterval?
    @ObservationIgnored var lastPublicMatchWallClock: TimeInterval?
    /// Cached `previewStartInSong` for the currently-registered song (if
    /// any). Set on registerForAlignment via UserDefaults lookup. Used in
    /// the public-catalog match handler to synthesize a PreviewAlignment
    /// from Phase 3 data alone.
    @ObservationIgnored var currentSongPreviewStartInSong: TimeInterval?
    /// Normalized (title, artist) key of the currently-registered song.
    /// Used to look up + write to the cache.
    @ObservationIgnored var currentSongCacheKey: String?

    /// Begin listening. The `feed(_:at:)` method should be called from the
    /// audio thread for every captured buffer (typically wired through
    /// `MicListener.bufferHandler`).
    func start() {
        guard session == nil else { return }
        let s = SHSession()       // default = public catalog
        s.delegate = self
        session = s
        nonisolatedSession = s
        status = .listening
        shazamLog.info("HV-SHAZAM session started")
    }

    /// Stop listening and release the session.
    func stop() {
        let wasListening = session != nil
        session = nil
        nonisolatedSession = nil
        if case .listening = status { status = .idle }
        if wasListening { shazamLog.info("HV-SHAZAM session stopped") }
    }

    /// Feed a buffer captured on the audio thread into the matching session.
    /// Safe to call when stopped — silently no-ops without a live session.
    ///
    /// **No main-actor dispatch.** `SHSession.matchStreamingBuffer` is
    /// documented thread-safe (the session uses a private serial queue
    /// internally), so calling directly from the audio thread saves a
    /// `Task { @MainActor ... }` allocation per IOProc call — ~100/sec
    /// at typical sample rates. That dispatch volume was queueing on
    /// main and starving RealityKit's render loop, manifesting as
    /// jittery visualizer animation in live system-audio mode.
    /// `time` is optional because Core Audio Process Tap input timestamps
    /// don't provide a continuously-incrementing `mSampleTime` the way
    /// ShazamKit's contiguity check requires — feeding a constructed
    /// AVAudioTime from those samples triggers a stream of Code=101 "audio
    /// is not contiguous" errors, and Shazam never produces a match. Per
    /// Apple's `SHSession.matchStreamingBuffer(_:at:)` docs, passing `nil`
    /// tells Shazam to treat audio as "arrives as available" and skip the
    /// contiguity check — the right contract for streaming taps. Mic path
    /// still passes a valid AVAudioTime from `AVAudioEngine` inputNode.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        nonisolatedSession?.matchStreamingBuffer(buffer, at: time)
    }
}

extension ShazamController: SHSessionDelegate {

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Route based on which session fired. The Phase-2 custom
            // catalog session is a different SHSession instance than the
            // Phase-1 public catalog session; we identify it by comparing
            // against the stored reference.
            if let custom = self.customSession, session === custom {
                self.recordCustomCatalogMatch(match)
                return
            }
            // Phase-1 path: public-catalog song identification.
            // De-dupe: ignore repeat matches of the song we already
            // identified. Shazam re-fires every few seconds while the same
            // song keeps playing.
            //
            // The catalog routinely returns DIFFERENT shazamIDs for the
            // same recording on successive matches (single / album /
            // remaster / regional pressings — this is the root of the
            // one-song-→-14-rows bug). A naive shazamID-only comparison
            // treats each as a "new" song and re-fires onMatch, which
            // re-kicks the whole stem pipeline. Suppress when EITHER the
            // shazamID matches OR the ISRC matches — ISRC is the
            // recording identity, stable across all those catalog IDs.
            // (Title-similarity is deliberately NOT used here: onMatch
            // also drives preview-fetch + alignment, and we don't want
            // to swallow a genuine change to a similarly-titled song.
            // Same-title resilience for the override/stem wipe lives
            // downstream in AppModel.handleShazamMatch.)
            let last = self.lastMatch
            let sameShazamID = last?.shazamID == item.shazamID
            let sameISRC: Bool = {
                guard let a = last?.isrc, let b = item.isrc,
                      !a.isEmpty, !b.isEmpty else { return false }
                return a.caseInsensitiveCompare(b) == .orderedSame
            }()
            let isSameSong = sameShazamID || sameISRC
            self.lastMatch = item
            self.status = .matched(
                title: item.title ?? "Unknown",
                artist: item.artist ?? "Unknown"
            )
            let title = item.title ?? "?"
            let artist = item.artist ?? "?"
            let pcmo = item.predictedCurrentMatchOffset
            // Hybrid Tier-2 hook: every public-catalog match (repeat or
            // new) feeds the Phase-3 path so it can update its anchor
            // and, when the song matches the currently-registered one
            // AND a cached previewStartInSong exists, synthesize a
            // PreviewAlignment immediately. This is what makes "second
            // listen of this song = instant alignment."
            let matchesCurrentRegistration: Bool
            if let registered = self.lastRegisteredTitleKey {
                let matchKey = ShazamController.normalizedTitleKey(title)
                matchesCurrentRegistration = ShazamController.titlesAreSimilar(registered, matchKey)
            } else {
                matchesCurrentRegistration = false
            }
            self.recordPublicCatalogMatchForAlignment(
                pcmo: pcmo,
                songMatchesCurrentRegistration: matchesCurrentRegistration
            )

            if isSameSong {
                shazamLog.info("HV-SHAZAM repeat match \(title, privacy: .public) pcmo=\(pcmo, privacy: .public)s (suppressed)")
                return
            }
            self.matchCounter += 1
            shazamLog.info("HV-SHAZAM NEW match \(title, privacy: .public) — \(artist, privacy: .public) pcmo=\(pcmo, privacy: .public)s firing onMatch")
            self.onMatch?(item)
        }
    }

    nonisolated func session(
        _ session: SHSession,
        didNotFindMatchFor signature: SHSignature,
        error: Error?
    ) {
        // "Didn't find" fires every few seconds while listening to silence
        // or noise; only flip status if we never had a match. Otherwise hold
        // the last identified track so the visualizer keeps its colour
        // palette while the next song is being identified.
        let sigDuration = signature.duration
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Log only for the CUSTOM session — public session's "no match"
            // fires constantly during silence and floods the log. Custom
            // session no-match while a song is genuinely playing is the
            // interesting diagnostic.
            if let custom = self.customSession, session === custom {
                shazamLog.info("HV-SHAZAM-NOMATCH custom session no-match (sigDuration=\(sigDuration, privacy: .public)s)")
            }
            if case .listening = self.status {
                // stay in .listening
            }
            if let error = error {
                print("[Shazam] no match: \(error.localizedDescription)")
            }
        }
    }
}
