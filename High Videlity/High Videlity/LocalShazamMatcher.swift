//
//  LocalShazamMatcher.swift
//  High Videlity
//
//  Audio-fingerprint identification for local files. Decodes a
//  chunk of audio, generates an SHSignature, and matches it
//  against ShazamKit's public catalog. The result — a
//  `ShazamIdentity` carrying canonical title / artist / ISRC /
//  Apple Music catalog ID — becomes the source of truth for a
//  file's identity, replacing whatever ID3 / iTunes Match wrote
//  into the tags.
//
//  Why this matters: iTunes Match historically misidentifies
//  during the upload-match handshake — a file labeled "X — Y"
//  may actually contain audio for "A — B." Shazam works on the
//  audio fingerprint, not the tags, so it's the only authority
//  that can detect those mismatches. Conflicts are surfaced to
//  the UI; the user accepts or rejects.
//
//  Cache: per-file JSON in `~/Library/Caches/HighVidelity/
//  shazam-identity/<sha256>.json`, keyed by the same content
//  hash [[FrameFeatureCache]] uses. Filesystem-level so single-
//  file invalidation is just an `rm` — no SQLite migration step.
//
//  ToS: Shazam-matching files the user owns is the explicit
//  ShazamKit use case. ISRCs are public identifiers; AM catalog
//  IDs are pointers (clients resolve them through their own AM
//  subscription). Both are safe to store in the public-shared
//  CloudKit tier if we ever want cross-user identity sharing —
//  but that's a follow-up.
//

#if os(macOS)
import Foundation
import AVFoundation
import ShazamKit
import CryptoKit
import os

private let shazamMatchLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "shazam-match")

/// Observable singleton that ticks every time a Shazam match
/// completes — gives SwiftUI rows a dependency to read so the
/// conflict badge can re-render the moment the cache file lands
/// (the per-file JSON write isn't itself observable, and rows can't
/// know to re-fetch otherwise).
///
/// Usage in a row body:
/// ```
/// // Touch the version so SwiftUI tracks it; value is unused.
/// let _ = ShazamMatchSignal.shared.version
/// ConflictBadge(entry: entry)
/// ```
@MainActor
@Observable
final class ShazamMatchSignal {
    static let shared = ShazamMatchSignal()
    private(set) var version: Int = 0
    fileprivate func bump() { version &+= 1 }
}

/// Canonical "what is this file" answer from the audio
/// fingerprint. All fields optional because public-catalog
/// matches don't always have every metadata slot populated; the
/// non-nil ones are authoritative.
struct ShazamIdentity: Codable, Sendable, Hashable {
    let shazamID: String?
    let appleMusicID: String?
    let title: String?
    let artist: String?
    let isrc: String?
    let genres: [String]
    /// True when Shazam ran and returned a match. False when it
    /// ran but found no catalog hit (e.g., very obscure / unreleased
    /// audio). Lets the UI distinguish "we haven't checked" from
    /// "we checked, not in the catalog."
    let matched: Bool
    /// Epoch seconds. Lets us age out + re-run when the catalog
    /// has likely grown (currently unused — kept for future).
    let matchedAt: Double
    /// How many of the attempted offsets returned a match for THIS
    /// shazamID. Higher = more confident. A 1/4 match is much more
    /// likely a false positive than a 4/4 match.
    let confirmedOffsets: Int?
    /// Total offsets attempted (for ratio context — lets us add or
    /// drop offsets later without invalidating older cache entries).
    let totalOffsets: Int?
    /// True when at least two offsets returned different shazamIDs.
    /// Surfaces "the fingerprint is ambiguous" in the UI — happens
    /// when the audio briefly resembles multiple catalog items, or
    /// when the file's a mashup / DJ mix.
    let conflictingMatches: Bool?
}

/// State of the tagged-vs-fingerprint comparison for a file.
enum MetadataConflict: Sendable, Equatable {
    /// No Shazam match has been run yet — UI shows no badge.
    case unverified
    /// Shazam ran but the file isn't in the public catalog (rare;
    /// happens for very obscure / personal recordings, or when the
    /// actual audio is something Shazam doesn't index). Not a
    /// conflict; we just can't authoritatively verify.
    case unmatched
    /// Shazam matched at exactly one offset — likely a spurious
    /// fingerprint coincidence rather than a real identity. Carries
    /// the unreliable identity for the tooltip but the UI treats
    /// this as "low confidence, don't trust." Threshold for promoting
    /// to `.conflict` is ≥2 offsets agreeing.
    case lowConfidence(ShazamIdentity)
    /// Shazam-resolved identity agrees with the tagged metadata
    /// (≥2 offsets confirmed the same shazamID).
    case confirmed
    /// Tags disagree with the fingerprint (≥2 offsets agree on a
    /// different identity). Carries the Shazam-side identity so the
    /// UI tooltip can render the side-by-side.
    case conflict(ShazamIdentity)
}

/// Number of offset agreements required to treat a Shazam match as
/// trustworthy. 1/N is treated as `.lowConfidence` (often a spurious
/// fingerprint coincidence); ≥2 promotes to confirmed / conflict.
private let confidenceThreshold = 2

enum LocalShazamMatcher {

    /// In-memory dedupe for in-flight matches. Without this, two UI
    /// surfaces opportunistically matching the same file on play
    /// could fire two signature passes in parallel.
    @MainActor
    private static var inflight: [URL: Task<ShazamIdentity?, Never>] = [:]

    // MARK: - Public API

    /// Cached identity for this file, or nil if we haven't run the
    /// match yet. Synchronous — pure disk read.
    static func cachedIdentity(for fileURL: URL) -> ShazamIdentity? {
        guard let hash = FrameFeatureCache.hashForFile(fileURL) else { return nil }
        return loadFromDisk(hash: hash)
    }

    /// Return cached identity if present; otherwise run a fresh
    /// match and cache the result. De-duplicated against any
    /// in-flight match for the same file.
    @MainActor
    static func resolve(fileURL: URL) async -> ShazamIdentity? {
        if let cached = cachedIdentity(for: fileURL) { return cached }
        if let existing = inflight[fileURL] { return await existing.value }
        let task = Task { () -> ShazamIdentity? in
            let result = await runMatch(fileURL: fileURL)
            await MainActor.run { inflight[fileURL] = nil }
            return result
        }
        inflight[fileURL] = task
        return await task.value
    }

    /// Run a match unconditionally (bypassing cache) and write the
    /// result. UI uses this for an explicit "Re-verify" action.
    static func forceMatch(fileURL: URL) async -> ShazamIdentity? {
        await runMatch(fileURL: fileURL)
    }

    /// Compare cached Shazam identity (if any) against the entry's
    /// tagged metadata and report the conflict state. Pure — safe to
    /// call from any SwiftUI body for live badge updates.
    static func conflict(for entry: LibraryEntry) -> MetadataConflict {
        guard let identity = cachedIdentity(for: entry.fileURL) else {
            return .unverified
        }
        if !identity.matched { return .unmatched }
        // Sub-threshold matches are likely false positives. Don't
        // commit to a conflict claim with such weak evidence —
        // surface the suspicious identity but in the low-confidence
        // visual state so the user knows not to trust it.
        let confirmed = identity.confirmedOffsets ?? 1
        if confirmed < confidenceThreshold {
            return .lowConfidence(identity)
        }
        let tagTitle = Self.normalize(entry.title)
        let tagArtist = Self.normalize(entry.artist)
        let shTitle = Self.normalize(identity.title ?? "")
        let shArtist = Self.normalize(identity.artist ?? "")
        // Both sides must agree on title AND artist for "confirmed."
        // Either side disagreeing flags conflict.
        if tagTitle == shTitle && tagArtist == shArtist {
            return .confirmed
        }
        return .conflict(identity)
    }

    /// Fuzzy-equal normalization for metadata strings. Strips common
    /// parenthetical suffixes like `(feat. X)` / `(Live)` / `(Remix)`
    /// so a live or remix version of a song doesn't false-positive as
    /// a conflict. Collapses whitespace + lowercases.
    private static func normalize(_ s: String) -> String {
        var out = s.lowercased()
        // Drop everything from the first ` (` onward — covers
        // "(feat. X)", "(Live)", "(Remix)", "(Deluxe Edition)" etc.
        if let openParen = out.range(of: " (") {
            out = String(out[..<openParen.lowerBound])
        }
        if let openBracket = out.range(of: " [") {
            out = String(out[..<openBracket.lowerBound])
        }
        // Strip "feat. X" / "ft. X" that lives without parens.
        for marker in [" feat. ", " feat ", " ft. ", " ft "] {
            if let r = out.range(of: marker) {
                out = String(out[..<r.lowerBound])
            }
        }
        // Collapse whitespace + trim.
        out = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Match runner

    /// Time offsets (seconds) to try when one-shot matching a file.
    /// All start at 30 s or later — electronic / industrial / film-
    /// score releases often have long instrumental intros where a
    /// 15 s clip catches near-silence or non-distinctive ambience
    /// that yields false matches against unrelated catalog items.
    /// 30 / 60 / 90 / 150 covers verse / first-chorus / chorus-
    /// repeat / bridge for typical track structures.
    private static let matchOffsetsSeconds: [Double] = [30, 60, 90, 150]

    private static func runMatch(fileURL: URL) async -> ShazamIdentity? {
        // Try every offset (no short-circuit). Collect each match's
        // SHMatchedMediaItem so we can vote on consensus afterwards.
        // A single hit out of four is much more likely a false
        // positive than a 4/4 consensus; the badge UX surfaces the
        // ratio so the user can judge confidence.
        var hits: [(offset: Double, item: SHMatchedMediaItem)] = []
        var didError = false
        let totalAttempts = matchOffsetsSeconds.count
        for offset in matchOffsetsSeconds {
            do {
                let signature = try await generateSignature(fileURL: fileURL, startSeconds: offset)
                let session = SHSession()  // default = public catalog
                let result = try await session.result(from: signature)
                switch result {
                case .match(let match):
                    if let item = match.mediaItems.first {
                        hits.append((offset, item))
                        shazamMatchLog.info("HV-SHAZAM MATCH @ \(offset, format: .fixed(precision: 0))s shazamID=\(item.shazamID ?? "nil", privacy: .public) title=\"\(item.title ?? "", privacy: .public)\" artist=\"\(item.artist ?? "", privacy: .public)\"")
                    }
                case .noMatch:
                    shazamMatchLog.info("HV-SHAZAM NOMATCH @ \(offset, format: .fixed(precision: 0))s")
                @unknown default:
                    shazamMatchLog.error("HV-SHAZAM unexpected result @ \(offset, format: .fixed(precision: 0))s — likely error case")
                    didError = true
                }
            } catch {
                shazamMatchLog.info("HV-SHAZAM offset \(offset, format: .fixed(precision: 0))s failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                didError = true
                continue
            }
        }

        // Consensus vote: group hits by shazamID, pick the group
        // with the most votes. Ties go to whichever came first
        // (i.e., the earlier offset). The chosen identity becomes
        // the canonical answer; the loser-groups count as the
        // `conflictingMatches` flag.
        let identity: ShazamIdentity
        if hits.isEmpty {
            // No offset matched. Cache the unmatched result so
            // future plays don't re-run unless the user explicitly
            // re-verifies. Skip cache write on hard errors so we
            // can retry on the next play.
            if didError {
                shazamMatchLog.info("HV-SHAZAM \(fileURL.lastPathComponent, privacy: .public): all \(totalAttempts) offsets errored — not caching")
                return nil
            }
            identity = Self.empty(matched: false, totalOffsets: totalAttempts)
        } else {
            let groups = Dictionary(grouping: hits) { $0.item.shazamID ?? "" }
            // Pick the largest group; ties → group containing the
            // earliest offset.
            let winnerEntry = groups.max(by: { a, b in
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                let aMin = a.value.map(\.offset).min() ?? .infinity
                let bMin = b.value.map(\.offset).min() ?? .infinity
                return aMin > bMin
            })!
            let winnerHits = winnerEntry.value
            let winnerItem = winnerHits.first!.item
            let conflicting = groups.count > 1
            identity = ShazamIdentity(
                shazamID: winnerItem.shazamID,
                appleMusicID: winnerItem.appleMusicID,
                title: winnerItem.title,
                artist: winnerItem.artist,
                isrc: winnerItem.isrc,
                genres: winnerItem.genres,
                matched: true,
                matchedAt: Date().timeIntervalSince1970,
                confirmedOffsets: winnerHits.count,
                totalOffsets: totalAttempts,
                conflictingMatches: conflicting
            )
            shazamMatchLog.info("HV-SHAZAM consensus for \(fileURL.lastPathComponent, privacy: .public): \"\(identity.title ?? "", privacy: .public)\" by \"\(identity.artist ?? "", privacy: .public)\" — \(winnerHits.count)/\(totalAttempts) offsets agree, conflictingGroups=\(groups.count - 1)")
        }

        if let hash = FrameFeatureCache.hashForFile(fileURL) {
            writeToDisk(hash: hash, identity: identity)
        }
        return identity
    }

    private static func empty(matched: Bool, totalOffsets: Int = 0) -> ShazamIdentity {
        ShazamIdentity(
            shazamID: nil, appleMusicID: nil, title: nil, artist: nil,
            isrc: nil, genres: [], matched: matched,
            matchedAt: Date().timeIntervalSince1970,
            confirmedOffsets: 0,
            totalOffsets: totalOffsets,
            conflictingMatches: false
        )
    }

    // MARK: - Signature generation

    /// Decode the file to canonical 44.1 kHz mono Float32 PCM and
    /// feed it through SHSignatureGenerator. Lifted from
    /// [[LibraryBatchCacher]] which used the same pipeline for its
    /// Shazam-as-cache-key path; consolidating here so both call
    /// sites share one signature path.
    private static func generateSignature(fileURL: URL, startSeconds: Double) async throws -> SHSignature {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: fileURL)
            let sourceFormat = file.processingFormat
            // Shazam's PUBLIC catalog rejects signatures outside
            // the 3-12 second window (empirically verified —
            // SHSession.result raises SHErrorCodeSignatureInvalid
            // with the range in its recovery suggestion). Take 10 s
            // starting at `startSeconds` into the file — comfortably
            // inside the valid range, long enough to be a robust
            // fingerprint. If the requested offset is past the end
            // (short song), throw — the caller's offset loop will
            // move on.
            let totalFrames = AVAudioFrameCount(file.length)
            let sampleRate = sourceFormat.sampleRate
            let preferredStart = AVAudioFrameCount(startSeconds * sampleRate)
            let preferredLength = AVAudioFrameCount(10.0 * sampleRate)
            guard totalFrames > preferredStart + AVAudioFrameCount(sampleRate) else {
                throw NSError(domain: "LocalShazamMatcher", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "offset \(startSeconds)s past end of file"])
            }
            let startFrame = preferredStart
            let sliceLength = min(preferredLength, totalFrames - startFrame)
            file.framePosition = AVAudioFramePosition(startFrame)

            let canonicalFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100, channels: 1, interleaved: false
            )!
            guard let converter = AVAudioConverter(from: sourceFormat, to: canonicalFormat),
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sliceLength)
            else {
                throw NSError(domain: "LocalShazamMatcher", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
            }
            try file.read(into: inputBuffer, frameCount: sliceLength)
            shazamMatchLog.info("HV-SHAZAM signature input: \(fileURL.lastPathComponent, privacy: .public) @ \(startSeconds, format: .fixed(precision: 0))s sourceSR=\(sampleRate) channels=\(sourceFormat.channelCount) startFrame=\(startFrame) sliceFrames=\(inputBuffer.frameLength) totalFrames=\(totalFrames)")
            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * canonicalFormat.sampleRate / sampleRate
            ) + 4096
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: outputCapacity) else {
                throw NSError(domain: "LocalShazamMatcher", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "output buffer alloc failed"])
            }
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return inputBuffer
            }
            var convErr: NSError?
            let convStatus = converter.convert(to: outputBuffer, error: &convErr, withInputFrom: inputBlock)
            if let err = convErr { throw err }
            shazamMatchLog.info("HV-SHAZAM signature output: convStatus=\(String(describing: convStatus), privacy: .public) outputFrames=\(outputBuffer.frameLength) capacity=\(outputCapacity)")
            let generator = SHSignatureGenerator()
            try generator.append(outputBuffer, at: nil)
            return generator.signature()
        }.value
    }

    // MARK: - Disk cache

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HighVidelity/shazam-identity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for hash: String) -> URL {
        cacheDir.appendingPathComponent("\(hash).json")
    }

    private static func loadFromDisk(hash: String) -> ShazamIdentity? {
        let url = cacheURL(for: hash)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShazamIdentity.self, from: data)
    }

    private static func writeToDisk(hash: String, identity: ShazamIdentity) {
        let url = cacheURL(for: hash)
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? data.write(to: url, options: .atomic)
        // Tick the observable signal so rows re-render their badge.
        // Hop to MainActor because writes can come from the
        // background match Task.
        Task { @MainActor in
            ShazamMatchSignal.shared.bump()
        }
    }
}
#endif
