//
//  ShazamPhase2.swift
//  High Videlity
//
//  ShazamKit Phase 2 — custom-catalog alignment. Closes the "preview cycles
//  every 30s out of sync with the actual song position" gap.
//
//  Phase 1 (ShazamController.swift) uses Shazam's public catalog to
//  identify what's playing. Phase 2 (this file) builds a SECOND session
//  bound to a CUSTOM catalog containing just the 30-second iTunes preview
//  we already downloaded for tonal analysis. When the custom session
//  matches the user's live audio (mic or system audio) against that
//  preview, Shazam returns `SHMatchedMediaItem.predictedCurrentMatchOffset`
//  — the preview-second that's happening "right now." Combined with the
//  current song clock (`musicKit.playbackTime` for in-app AM, or
//  wall-clock for mic mode), we know exactly where the preview sits
//  inside the full song. The visualizer indexes `frames` at the correct
//  offset instead of naive `songPosition % previewDuration`.
//
//  Storage for the Phase-2 fields (customSession, customCatalog, etc.)
//  lives in ShazamController.swift — Swift class extensions can't add
//  stored properties, and the per-instance-dict workaround fights
//  isolation rules when the audio-thread feed path needs to read the
//  nonisolated session reference.
//

import AVFoundation
import Foundation
import OSLog
import ShazamKit

private let alignLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "shazam-align")

/// What we learned from a custom-catalog match. Captures (a) the
/// preview-relative time the live audio matched at, and (b) the song
/// clock value at the moment of match. The two together let
/// `AppModel.playbackTime` map any future song clock value back to the
/// corresponding preview time:
///
///   `previewTime = (previewOffsetAtMatch + (now - songPositionAtMatch))`
///   `             .truncatingRemainder(dividingBy: previewDuration)`
struct PreviewAlignment {
    let previewOffsetAtMatch: TimeInterval
    let songPositionAtMatch: TimeInterval
    /// Marker so `AppModel` knows whether the alignment is calibrated
    /// against the frame-accurate AM clock or against wall-clock (which
    /// drifts under pause / silence).
    let usedAMClock: Bool
}

extension ShazamController {

    // MARK: - Custom catalog setup

    /// Register the preview audio file we just downloaded as a reference
    /// signature. Once the custom session sees live audio (mic or system
    /// audio) that matches this preview, the alignment delegate fires
    /// with the preview-relative position, which AppModel converts into a
    /// "preview offset within the full song" so the color timeline tracks
    /// the actual song position.
    ///
    /// **De-duped by fuzzy title.** If the currently-registered title
    /// shares enough significant words with the new title, we skip the
    /// re-registration — same heuristic used elsewhere for track-change
    /// detection. Shazam's public catalog can fire false-positive matches
    /// for unrelated songs while the user is listening to one song
    /// consistently; re-registering on every match would throw away the
    /// previous custom session before it had time to accumulate the
    /// 5-15 seconds of buffer Shazam needs to match against the catalog.
    func registerForAlignment(audioURL: URL, title: String, artist: String) async {
        // Skip if the new title is similar to what we just registered.
        let newKey = ShazamController.normalizedTitleKey(title)
        if let prev = lastRegisteredTitleKey,
           !prev.isEmpty,
           !newKey.isEmpty,
           ShazamController.titlesAreSimilar(prev, newKey) {
            alignLog.info("HV-ALIGN re-register skipped (similar to current \"\(prev, privacy: .public)\"): \(title, privacy: .public)")
            return
        }

        previewAlignment = nil   // discard alignment from any prior song

        // Hybrid Tier-2: look up cached previewStartInSong for this song.
        // If we have it (from a prior listening session where Phase 2 +
        // Phase 3 both fired and we derived the offset), Phase 3 alone
        // can synthesize alignment going forward — Phase 2's finicky
        // single-signature catalog match doesn't need to fire.
        let cacheKey = Self.cacheKey(title: title, artist: artist)
        self.currentSongCacheKey = cacheKey
        if let cached = Self.cachedPreviewStartInSong(for: cacheKey) {
            self.currentSongPreviewStartInSong = cached
            alignLog.info("HV-ALIGN cache HIT for \(title, privacy: .public): previewStartInSong=\(cached, privacy: .public)s — Phase 3 will synthesize")
        } else {
            self.currentSongPreviewStartInSong = nil
        }
        // Reset Phase-3 anchor too — fresh start per song registration.
        self.lastPublicMatchPCMO = nil
        self.lastPublicMatchWallClock = nil

        do {
            let signature = try await Self.generateSignature(forFileAt: audioURL)
            let mediaItem = SHMediaItem(properties: [
                .title: title,
                .artist: artist,
                .shazamID: UUID().uuidString
            ])
            let catalog = SHCustomCatalog()
            try catalog.addReferenceSignature(signature, representing: [mediaItem])

            let newSession = SHSession(catalog: catalog)
            newSession.delegate = self
            self.customSession = newSession
            self.nonisolatedCustomSession = newSession
            self.customCatalog = catalog
            self.lastRegisteredTitleKey = newKey

            alignLog.info("HV-ALIGN registered \(title, privacy: .public) — \(artist, privacy: .public) (custom catalog ready)")
        } catch {
            alignLog.error("HV-ALIGN signature generation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Lowercase, alphanumeric-only normalization of a title for the
    /// fuzzy-match registration de-dupe. Strips punctuation, parens,
    /// "(Original Mix)" style suffixes get partly normalized away.
    static func normalizedTitleKey(_ title: String) -> String {
        var out = ""
        var prevSpace = true
        for c in title.lowercased() {
            if c.isLetter || c.isNumber {
                out.append(c)
                prevSpace = false
            } else if !prevSpace {
                out.append(" ")
                prevSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Two normalized titles considered "the same song" if their 4+ char
    /// word sets overlap by ≥50% of the smaller set. Same heuristic used
    /// elsewhere for live-mode track-change detection.
    static func titlesAreSimilar(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        let aWords = Set(a.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let bWords = Set(b.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let smaller = min(aWords.count, bWords.count)
        guard smaller > 0 else { return false }
        let shared = aWords.intersection(bWords).count
        return Double(shared) / Double(smaller) >= 0.5
    }

    /// Build an `SHSignature` from an audio file by chunked reads into
    /// PCM buffers fed to `SHSignatureGenerator`. Off the main actor —
    /// decode + signature generation can take 100–500ms on a 30s preview.
    ///
    /// **Format normalization** is critical. Shazam's custom-catalog
    /// matching crashes with "Audio format mismatch" if the live audio
    /// fed to `matchStreamingBuffer` doesn't match the format used when
    /// the catalog's reference signature was generated. iTunes 30s
    /// previews are typically 44.1 kHz stereo; mic input on macOS is
    /// usually 48 kHz mono non-interleaved Float32. Convert the file's
    /// decoded audio into the canonical mic-side format during signature
    /// generation so both sides agree.
    private nonisolated static func generateSignature(forFileAt url: URL) async throws -> SHSignature {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let sourceFormat = file.processingFormat
            let fileLength = AVAudioFrameCount(file.length)

            // Different approach: instead of trying to match an arbitrary
            // target format (which kept producing "Audio format mismatch"
            // crashes against the live mic stream), pre-read the mic's
            // ACTUAL format from AVAudioEngine.inputNode and convert the
            // preview to exactly that. SHSession's internal format check
            // appears to be flag-strict — even when our target's numeric
            // values match the mic, subtle differences in AVAudioConverter's
            // output flags (interleaved vs not, channel layout tag) make
            // Shazam crash. Sourcing the format from the engine directly
            // sidesteps the guesswork.
            let engine = AVAudioEngine()
            let micFormat = engine.inputNode.outputFormat(forBus: 0)
            // micFormat might have channels=2 (some interfaces); force
            // mono since we don't have a stereo path on the wire.
            guard let targetFormat = AVAudioFormat(
                commonFormat: micFormat.commonFormat,
                sampleRate: micFormat.sampleRate,
                channels: 1,
                interleaved: micFormat.isInterleaved
            ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw NSError(domain: "ShazamPhase2", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Format converter setup failed"])
            }

            // Single-pass conversion. The 30s preview is small (≤ ~5 MB
            // even at 44.1k stereo Float32) so reading it whole into
            // memory is fine and avoids the chunked-read+convert loop's
            // off-by-one tendencies that produced 90ms signatures
            // instead of 30s during the first attempt.
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: fileLength) else {
                throw NSError(domain: "ShazamPhase2", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Input PCM buffer alloc failed"])
            }
            try file.read(into: inputBuffer)

            // Output capacity = roughly input frames × sample-rate ratio,
            // with margin for converter's internal framing.
            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
            ) + 4096
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw NSError(domain: "ShazamPhase2", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "Output PCM buffer alloc failed"])
            }

            // One-shot convert with end-of-stream signaling.
            final class Once { var fired = false }
            let once = Once()
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if once.fired {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                once.fired = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            var convError: NSError?
            converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
            if let err = convError { throw err }

            let generator = SHSignatureGenerator()
            try generator.append(outputBuffer, at: nil)
            return generator.signature()
        }.value
    }

    /// Tear down the custom session + clear last alignment. AppModel
    /// calls this on song unload / track change / explicit reset.
    func clearAlignmentRegistration() {
        customSession = nil
        nonisolatedCustomSession = nil
        customCatalog = nil
        previewAlignment = nil
    }

    /// Provide the preview's duration (used by the alignment math to
    /// wrap modulo). Set once `frames` is populated:
    /// `duration = frames.count / 30`.
    func setPreviewDuration(_ seconds: TimeInterval) {
        self.previewDuration = seconds
    }

    // MARK: - Audio-thread fan-out + match handler

    /// Audio-thread feed that fans out to BOTH the public-catalog session
    /// (Phase 1 — song identification) and the custom-catalog session
    /// (Phase 2 — preview alignment). Callers wire this in place of
    /// `feed(_:at:)` when they want both behaviors.
    ///
    /// `SHSession.matchStreamingBuffer` is thread-safe per Apple docs;
    /// no main-actor dispatch needed.
    /// `time` is optional for the same reason as `ShazamController.feed`:
    /// non-mic streaming sources (Process Tap) don't supply continuously-
    /// incrementing sample times, and `nil` tells Shazam to skip the
    /// contiguity check. Mic path still passes a valid AVAudioTime.
    nonisolated func feedBoth(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        nonisolatedSession?.matchStreamingBuffer(buffer, at: time)
        nonisolatedCustomSession?.matchStreamingBuffer(buffer, at: time)
    }

    /// Invoked from the SHSessionDelegate when the CUSTOM session fires
    /// a match. Reads the live song clock via the AppModel-supplied
    /// provider, snapshots both values into a `PreviewAlignment`, and
    /// publishes it on `previewAlignment`. AppModel observes that and
    /// uses it in `playbackTime` to align the color timeline.
    @MainActor
    func recordCustomCatalogMatch(_ match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let previewOffset = item.predictedCurrentMatchOffset
        let (songPos, isAM) = currentSongPositionProvider?() ?? (CACurrentMediaTime(), false)
        let alignment = PreviewAlignment(
            previewOffsetAtMatch: previewOffset,
            songPositionAtMatch: songPos,
            usedAMClock: isAM
        )
        self.previewAlignment = alignment
        alignLog.info("HV-ALIGN matched: previewOffset=\(previewOffset, privacy: .public)s songPos=\(songPos, privacy: .public)s AM=\(isAM, privacy: .public)")

        // Hybrid Tier-2: if Phase 3 recently fired for the same song, we
        // know the song-time at this moment. Combined with previewOffset
        // from this Phase 2 match, we can derive the songtime-offset of
        // the preview within the full song. Persist it so future plays
        // of this song get instant alignment from Phase 3 alone.
        if let pcmo = lastPublicMatchPCMO,
           let pcmoWallClock = lastPublicMatchWallClock,
           let cacheKey = currentSongCacheKey {
            // Extrapolate pcmo to "now" (songPos) assuming continuous
            // 1× playback since pcmo was captured. The Phase 3 match is
            // typically 1-3 seconds stale.
            let extrapolatedPcmo = pcmo + (songPos - pcmoWallClock)
            let previewStartInSong = extrapolatedPcmo - previewOffset
            // Guard against pathological values (e.g. wall-clock drift
            // making extrapolation huge). Reasonable range: 0..~300s
            // since preview can be anywhere in a typical song.
            if previewStartInSong > -10 && previewStartInSong < 600 {
                Self.savePreviewStartInSong(previewStartInSong, for: cacheKey)
                self.currentSongPreviewStartInSong = previewStartInSong
                alignLog.info("HV-ALIGN cached previewStartInSong=\(previewStartInSong, privacy: .public)s for \(cacheKey, privacy: .public)")
            }
        }
    }

    // MARK: - Hybrid Phase 3: synthesize alignment from public-catalog pcmo

    /// Called from the public-catalog SHSessionDelegate path whenever a
    /// match fires for the currently-registered song. If we have a
    /// cached `previewStartInSong` for this song, we can synthesize a
    /// `PreviewAlignment` immediately — no need to wait for Phase 2's
    /// custom-catalog session to match.
    @MainActor
    func recordPublicCatalogMatchForAlignment(pcmo: TimeInterval, songMatchesCurrentRegistration: Bool) {
        let now = CACurrentMediaTime()
        // Always remember the latest pcmo + wall-clock — useful both for
        // synthesizing alignment now AND for the inverse path (deriving
        // previewStartInSong when Phase 2 fires shortly after).
        self.lastPublicMatchPCMO = pcmo
        self.lastPublicMatchWallClock = now

        guard songMatchesCurrentRegistration,
              let previewStartInSong = currentSongPreviewStartInSong,
              let duration = previewDuration,
              duration > 0
        else { return }

        // pcmo IS the song-time of the matched sample. With the cached
        // previewStartInSong, we can compute exactly where in the preview
        // we should be right now.
        var previewTime = (pcmo - previewStartInSong)
            .truncatingRemainder(dividingBy: duration)
        if previewTime < 0 { previewTime += duration }

        // Wrap into a synthetic PreviewAlignment so the existing
        // extrapolation in `alignedPreviewTime` keeps doing the right
        // thing between Phase 3 matches.
        let alignment = PreviewAlignment(
            previewOffsetAtMatch: previewTime,
            songPositionAtMatch: now,
            usedAMClock: false
        )
        self.previewAlignment = alignment
        alignLog.info("HV-ALIGN synthesized via Phase-3 cache: pcmo=\(pcmo, privacy: .public)s previewTime=\(previewTime, privacy: .public)s")
    }

    // MARK: - UserDefaults-backed cache

    /// Look up cached previewStartInSong for a (title, artist) key.
    /// Returns nil if the song has never been calibrated.
    fileprivate static func cachedPreviewStartInSong(for key: String) -> TimeInterval? {
        let dict = UserDefaults.standard.dictionary(forKey: previewOffsetCacheKey) ?? [:]
        return dict[key] as? TimeInterval
    }

    /// Persist a calibrated previewStartInSong for future plays of this song.
    fileprivate static func savePreviewStartInSong(_ value: TimeInterval, for key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: previewOffsetCacheKey) ?? [:]
        dict[key] = value
        UserDefaults.standard.set(dict, forKey: previewOffsetCacheKey)
    }

    /// Build the cache key. Uses the normalized title plus the original
    /// artist (lowercased, trimmed). Title alone could collide across
    /// different songs with similar names; artist disambiguates.
    fileprivate static func cacheKey(title: String, artist: String) -> String {
        let titleN = normalizedTitleKey(title)
        let artistN = artist
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(titleN)|\(artistN)"
    }

    private static let previewOffsetCacheKey = "previewOffsetCache.v1"

    /// Compute the preview time corresponding to the current song clock,
    /// given the last-recorded alignment. Returns nil if no alignment
    /// has been captured yet OR preview duration is unknown.
    ///
    /// Used by `AppModel.playbackTime` to drive the visualizer's index
    /// into `frames`.
    func alignedPreviewTime(currentSongPosition now: TimeInterval) -> TimeInterval? {
        guard let alignment = previewAlignment,
              let duration = previewDuration,
              duration > 0 else { return nil }
        let delta = now - alignment.songPositionAtMatch
        let raw = alignment.previewOffsetAtMatch + delta
        // Modulo-wrap with safety for negative deltas (song clock might
        // be moments before the match time if the user scrubbed back).
        var wrapped = raw.truncatingRemainder(dividingBy: duration)
        if wrapped < 0 { wrapped += duration }
        return wrapped
    }
}
