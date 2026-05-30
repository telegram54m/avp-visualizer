//
//  LibraryBatchCacher.swift
//  High Videlity
//
//  Drives batch processing of LibraryEntry objects through the
//  three-tier cache hierarchy from [[stem-cache-architecture]]:
//
//    Per entry:
//      1. Shazam-identify the file (offline match against public
//         catalog using a signature generated from the audio bytes).
//      2. If identified → use `shazam-<id>` as the primary stem cache
//         key, fire TunebatBpmFetcher metadata lookup (CloudKit private
//         DB sync as a side effect), and run the tier sequence for
//         stems (local SQLite → CloudKit public DB → fresh Demucs).
//      3. If NOT identified → fall back to a content-hash key
//         (`hash-<sha256-prefix>`) and skip metadata + CloudKit public-DB
//         (those need Shazam ID). Stems still cached locally.
//
//  Processing is strictly sequential — the sidecar's Demucs run
//  saturates Metal on M1 Pro; parallel jobs would stall each other.
//  Cancellation is supported via the standard Task cancellation
//  mechanism (the runner checks `Task.isCancelled` between entries).
//

#if os(macOS)
import AudioAnalysis
import AVFoundation
import CryptoKit
import Foundation
import OSLog
import ShazamKit

private let batchLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "library-batch")

enum LibraryBatchCacher {

    /// Per-entry outcome reported back to the caller so the UI can
    /// show a summary at end of batch.
    enum Outcome: Sendable {
        case shazamIdentifiedAndCached(shazamID: String, fromCache: Bool)
        case unidentifiedButCached(hashKey: String, fromCache: Bool)
        case alreadyCached
        case failed(reason: String)
    }

    /// Process every entry serially. `onProgress` fires throughout
    /// each entry with the current phase and a 0-1 sub-fraction (for
    /// the in-progress entry — driven by Demucs chunk events during
    /// the Compute Stems phase). `completed` counts entries fully
    /// finished; the final entry ticks to `total` when it lands.
    /// `onEntryDone` fires once per entry with its final outcome so
    /// the caller can update per-entry state (e.g. "cached" badges).
    /// On `Task.isCancelled`, returns early.
    nonisolated static func cacheAll(
        _ entries: [LibraryEntry],
        provider: StemFeatureProvider,
        onProgress: @escaping @Sendable (
            _ completed: Int, _ total: Int,
            _ currentTitle: String, _ phase: String,
            _ inProgressFraction: Double
        ) -> Void,
        onEntryDone: @escaping @Sendable (_ entry: LibraryEntry, _ outcome: Outcome) -> Void
    ) async -> [Outcome] {
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(entries.count)
        let total = entries.count

        // Save the provider's existing onProgress (the visualizer's
        // chunked-progress hook) so we can restore it after the batch.
        // During batch we install our own handler that fans out into
        // the BatchProgress sub-fraction.
        let previousProviderProgress = await provider.currentOnProgress()
        defer {
            // Restore on actor at deferred-time via a fresh Task —
            // defer can't itself await. The provider stays usable for
            // the visualizer once batch winds down.
            Task { await provider.setOnProgress(previousProviderProgress) }
        }

        for (index, entry) in entries.enumerated() {
            if Task.isCancelled {
                batchLog.notice("HV-BATCH cancelled at \(index)/\(total, privacy: .public)")
                break
            }
            let title = "\(entry.title) — \(entry.artist)"
            let phaseClosure: @Sendable (String, Double) -> Void = { phase, frac in
                onProgress(index, total, title, phase, frac)
            }
            phaseClosure("Starting…", 0)
            let outcome = await processOne(
                entry: entry, provider: provider, onPhase: phaseClosure
            )
            outcomes.append(outcome)
            onEntryDone(entry, outcome)
            // Tick `completed` up AFTER this row finishes (sub-fraction
            // resets to 0 since the NEXT row starts at 0).
            onProgress(index + 1, total, title, "Done", 0)
            batchLog.info("HV-BATCH [\(index + 1)/\(total, privacy: .public)] \(entry.title, privacy: .public): \(describe(outcome), privacy: .public)")
        }
        return outcomes
    }

    // MARK: - Per-entry pipeline

    nonisolated private static func processOne(
        entry: LibraryEntry,
        provider: StemFeatureProvider,
        onPhase: @escaping @Sendable (String, Double) -> Void
    ) async -> Outcome {
        // 1. Try to Shazam-identify the file. ~1-3s on M1 Pro for a
        //    typical pop song; longer for instrumentals / live cuts
        //    that the public catalog struggles to match.
        onPhase("Identifying with Shazam…", 0.05)
        let shazamResult = await identifyWithShazam(fileURL: entry.fileURL)

        // Hash-key is the device-local "play time identity" — we
        // always compute it so we can alias to it after caching,
        // which lets AppModel find cached features at play time
        // without having to re-run Shazam. cacheKeyForFile is the
        // public version of hashFirstMB.
        guard let hashKey = Self.cacheKeyForFile(entry.fileURL),
              let frameHash = FrameFeatureCache.hashForFile(entry.fileURL) else {
            return .failed(reason: "could not hash file")
        }

        // Pre-warm the frame-feature cache (the [FeatureFrame]
        // timeline AnalysisTimeline.analyze produces — separate from
        // stems). Without this, even after batch-caching a song the
        // first play still re-runs the 30-second AnalysisTimeline.
        // Cheap when the cache already has it (skipped); ~5-10s when
        // missing.
        //
        // Tier A parallelization ([[swift-sidecar-port-spec]] Phase 2
        // follow-up): kick this off as a detached task BEFORE Shazam,
        // cache lookups, and stem separation. AnalysisTimeline.analyze
        // runs on the CPU via Accelerate vDSP; the stem provider's
        // htdemucs runs on the GPU via mlx-swift Metal. They don't
        // contend, so they get to overlap for free. Wall-clock per
        // song drops by 5-10s of full-mix work — proportionally bigger
        // once stems land in Release build.
        //
        // We await the task right before returning the Outcome so the
        // caller sees a single done-event per entry. Errors are
        // non-fatal: stems can still cache without frames; first play
        // will fall back to fresh analysis.
        let entryTitleForLog = entry.title
        let frameTask: Task<Void, Never>?
        if FrameFeatureCache.cachedFrames(forHash: frameHash) == nil {
            let fileURL = entry.fileURL
            frameTask = Task.detached(priority: .utility) {
                do {
                    let audio = try AudioFileDecoder.decode(contentsOf: fileURL)
                    let frames = AnalysisTimeline.analyze(audio)
                    FrameFeatureCache.storeFrames(frames, forHash: frameHash)
                } catch {
                    batchLog.notice("HV-BATCH frame pre-warm failed for \(entryTitleForLog, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            frameTask = nil
        }
        // Closure that awaits the parallel frame task if any. Called
        // from every return path below so the outcome reflects all
        // work for this entry.
        @Sendable func awaitFrameTaskIfNeeded() async {
            if let t = frameTask {
                await t.value
            }
        }

        let primaryKey: String   // canonical recording key
        let shazamID: String?
        let isrc: String?
        switch shazamResult {
        case .matched(let id, _, _, let code):
            // Canonical key = the RECORDING, not the catalog entry.
            // ISRC collapses all of a recording's Shazam IDs AND all
            // files of it to one row; shazamID is only the fallback
            // when the match carried no ISRC. This is the fix for the
            // one-song-→-14-rows bug: 14 catalog IDs share one ISRC.
            primaryKey = StemCacheKey.canonical(isrc: code, shazamID: id, fallback: hashKey)
            shazamID = id.isEmpty ? nil : id
            isrc = StemCacheKey.normalizeISRC(code).isEmpty ? nil : code
        case .unmatched:
            primaryKey = hashKey
            shazamID = nil
            isrc = nil
        case .error(let reason):
            await awaitFrameTaskIfNeeded()
            return .failed(reason: "shazam identify: \(reason)")
        }
        // Whether we have a cross-user-shareable recording identity at
        // all (ISRC or Shazam ID). Drives CloudKit participation.
        let hasRecordingIdentity = (isrc != nil) || (shazamID != nil)

        // 2. Side-quest: if Shazam identified the song, fire the
        //    metadata lookup. It caches in UserDefaults + pushes to
        //    CloudKit private DB so other devices benefit. Fire and
        //    forget — don't block stem caching on it.
        if case .matched(_, let title, let artist, _) = shazamResult {
            Task.detached(priority: .background) {
                _ = await TunebatBpmFetcher.lookup(title: title, artist: artist)
            }
        }

        // 3. Three-tier cache resolution for stems (matches
        //    AppModel.kickoffStemSeparation's logic, minus the
        //    visualizer-coupling parts).
        do {
            // Tier 1: local SQLite read-only lookup.
            onPhase("Checking local cache…", 0.10)
            if let _ = try? await provider.cachedFeatures(forKey: primaryKey) {
                // Belt-and-suspenders: ensure the hash-key alias
                // exists even when this song was cached under
                // shazam-key in an earlier session (before the
                // alias-on-write step was added). Without this,
                // play-time lookup-by-hash misses and the visualizer
                // falls back to band-split.
                if primaryKey != hashKey {
                    _ = try? await provider.alias(primaryKey: primaryKey, aliasKey: hashKey)
                }
                await awaitFrameTaskIfNeeded()
                return .alreadyCached
            }

            // Tier 1b: the SAME recording may already be cached under a
            // DIFFERENT key from a prior scan — its content hash, an
            // older `shazam-<id>` row (pre-ISRC-canonicalization), or a
            // (title, artist) match. Find it and ALIAS to the canonical
            // key instead of recomputing. This is what stops N library
            // entries of one recording (e.g. the same song on 13 albums,
            // each matching a different catalog ID) from each computing
            // their own row — they all resolve to one canonical row.
            var aliasCandidates: [String] = [hashKey]
            if let shazamID { aliasCandidates.append(StemCacheKey.shazam(shazamID)) }
            for candidate in aliasCandidates where candidate != primaryKey {
                if (try? await provider.cachedFeatures(forKey: candidate)) != nil {
                    _ = try? await provider.alias(primaryKey: candidate, aliasKey: primaryKey)
                    if primaryKey != hashKey {
                        _ = try? await provider.alias(primaryKey: primaryKey, aliasKey: hashKey)
                    }
                    await awaitFrameTaskIfNeeded()
                    return .alreadyCached
                }
            }
            if !entry.title.isEmpty && !entry.artist.isEmpty,
               let foundKey = try? await provider.findCacheKey(title: entry.title, artist: entry.artist),
               foundKey != primaryKey,
               (try? await provider.cachedFeatures(forKey: foundKey)) != nil {
                _ = try? await provider.alias(primaryKey: foundKey, aliasKey: primaryKey)
                if primaryKey != hashKey {
                    _ = try? await provider.alias(primaryKey: primaryKey, aliasKey: hashKey)
                }
                await awaitFrameTaskIfNeeded()
                return .alreadyCached
            }

            // Tier 2: CloudKit public DB (only when we have a
            // cross-user recording identity — ISRC or Shazam ID).
            if hasRecordingIdentity {
                onPhase("Checking cloud cache…", 0.15)
            }
            if hasRecordingIdentity,
               let cloudHit = await CloudCacheSync.shared.fetchStemFeatures(isrc: isrc, shazamID: shazamID) {
                if let blob = cloudHit.rawFeaturesBlob,
                   let metaJSON = cloudHit.rawStemsMetaJSON {
                    let meta = decodeMetaArray(metaJSON)
                    try? await provider.putCachedFeatures(
                        forKey: primaryKey,
                        featuresBlob: blob,
                        stemsMeta: meta,
                        durationSeconds: cloudHit.durationSeconds,
                        title: entry.title,
                        artist: entry.artist
                    )
                    // Also alias to hash-key so play-time lookup hits
                    // without re-running Shazam.
                    if primaryKey != hashKey {
                        _ = try? await provider.alias(primaryKey: primaryKey, aliasKey: hashKey)
                    }
                }
                await awaitFrameTaskIfNeeded()
                return (shazamID ?? "").isEmpty
                    ? .unidentifiedButCached(hashKey: primaryKey, fromCache: true)
                    : .shazamIdentifiedAndCached(shazamID: shazamID!, fromCache: true)
            }

            // Tier 3: full Demucs separation. throttleMS is set so
            // the sidecar emits per-chunk progress envelopes (only the
            // throttled path emits them — fast path is silent). 100ms
            // is plenty fast on M1 Pro while still giving us ~12
            // chunk-events per song for visible bar movement.
            onPhase("Computing stems…", 0.20)
            await provider.setOnProgress { fraction in
                // Map Demucs chunk fraction [0,1] into our overall
                // sub-progress range [0.20, 0.95] so the visible
                // motion happens during the long part. Final 5%
                // covers the cache-write + (optional) cloud push.
                let mapped = 0.20 + fraction * 0.75
                let pct = Int((fraction * 100).rounded())
                onPhase("Computing stems… \(pct)%", mapped)
            }
            let result = try await provider.separate(
                filePath: entry.fileURL.path,
                cacheKey: primaryKey,
                forceRefresh: false,
                title: entry.title,
                artist: entry.artist,
                throttleMS: 100
            )
            onPhase("Saving…", 0.95)

            // Always alias to hash-key so play-time lookup hits
            // without re-running Shazam. (Skipped when primary IS
            // hash-key — that's the unmatched fallback case, row's
            // already there.)
            if primaryKey != hashKey {
                _ = try? await provider.alias(primaryKey: primaryKey, aliasKey: hashKey)
            }

            // Push fresh stems to CloudKit public DB, keyed by the
            // recording identity (ISRC preferred, Shazam ID fallback)
            // so the GLOBAL cache holds exactly one record per
            // recording regardless of how many catalog IDs match it.
            if !result.fromCache, hasRecordingIdentity {
                let titleCopy = entry.title
                let artistCopy = entry.artist
                let isrcCopy = isrc
                let shazamCopy = shazamID
                Task.detached(priority: .background) {
                    await CloudCacheSync.shared.saveStemFeatures(
                        isrc: isrcCopy,
                        shazamID: shazamCopy,
                        title: titleCopy, artist: artistCopy,
                        result: result
                    )
                }
            }

            // Wait for the parallel frame analysis to finish so the
            // outcome reflects ALL work for this entry — if it's still
            // running when stems finish, this is the only place we
            // block on it. In the cache-miss case where stems take
            // ~15s and frames take ~5-10s, this await is essentially
            // free (frames already done). In the cache-hit case it
            // returned earlier with its own await.
            await awaitFrameTaskIfNeeded()

            if let shazamID {
                return .shazamIdentifiedAndCached(shazamID: shazamID, fromCache: result.fromCache)
            } else if let isrc {
                return .shazamIdentifiedAndCached(shazamID: "isrc:\(isrc)", fromCache: result.fromCache)
            } else {
                return .unidentifiedButCached(hashKey: primaryKey, fromCache: result.fromCache)
            }
        } catch {
            await awaitFrameTaskIfNeeded()
            return .failed(reason: "stem separate: \(error)")
        }
    }

    // MARK: - Shazam offline identification

    private enum ShazamIdResult: Sendable {
        case matched(shazamID: String, title: String, artist: String, isrc: String)
        case unmatched
        case error(reason: String)
    }

    /// Generate a signature from the file's audio + match against the
    /// public catalog. Uses `SHSession.result(from:)` (one-shot async)
    /// rather than the streaming buffer path — simpler for a known
    /// finite file.
    nonisolated private static func identifyWithShazam(fileURL: URL) async -> ShazamIdResult {
        let signature: SHSignature
        do {
            signature = try await generateSignature(fileURL: fileURL)
        } catch {
            return .error(reason: "signature gen: \(error)")
        }

        let session = SHSession()  // default = public catalog
        do {
            let result = try await session.result(from: signature)
            switch result {
            case .match(let match):
                guard let item = match.mediaItems.first else {
                    return .unmatched
                }
                return .matched(
                    shazamID: item.shazamID ?? "",
                    title: item.title ?? "",
                    artist: item.artist ?? "",
                    isrc: item.isrc ?? ""
                )
            case .noMatch:
                return .unmatched
            @unknown default:
                return .unmatched
            }
        } catch {
            return .error(reason: "shazam session: \(error)")
        }
    }

    /// Decode an audio file into a canonical 44.1 kHz mono Float32
    /// PCM buffer and feed it to SHSignatureGenerator. The Shazam
    /// fingerprint is format-agnostic at the algorithm level but the
    /// API takes PCM buffers, so we still need to decode.
    nonisolated private static func generateSignature(fileURL: URL) async throws -> SHSignature {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: fileURL)
            let sourceFormat = file.processingFormat
            let fileLength = AVAudioFrameCount(file.length)
            let canonicalFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100, channels: 1, interleaved: false
            )!
            guard let converter = AVAudioConverter(from: sourceFormat, to: canonicalFormat),
                  let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: fileLength)
            else {
                throw NSError(domain: "LibraryBatchCacher", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "input buffer alloc failed"])
            }
            try file.read(into: inputBuffer)

            let outputCapacity = AVAudioFrameCount(
                Double(inputBuffer.frameLength) * canonicalFormat.sampleRate / sourceFormat.sampleRate
            ) + 4096
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: outputCapacity) else {
                throw NSError(domain: "LibraryBatchCacher", code: -2,
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
            converter.convert(to: outputBuffer, error: &convErr, withInputFrom: inputBlock)
            if let err = convErr { throw err }

            let generator = SHSignatureGenerator()
            try generator.append(outputBuffer, at: nil)
            return generator.signature()
        }.value
    }

    // MARK: - Content-hash key

    /// Stable cache key derived from the file's content (SHA-256 of
    /// the first 1 MB, hex-encoded, prefixed `hash-`). Used as the
    /// device-local "play time identity" — every batch-cached song
    /// gets an alias under this key so AppModel can find cached
    /// features when the user plays the file later without re-running
    /// Shazam. Returns nil only if the file can't be read.
    nonisolated static func cacheKeyForFile(_ fileURL: URL) -> String? {
        guard let hash = hashFirstMB(of: fileURL) else { return nil }
        return "hash-\(hash)"
    }

    /// SHA-256 of the first 1 MB of the file, hex-encoded. 1 MB is
    /// enough that two different songs almost never collide (the
    /// encoded audio header + first second of PCM bytes differ even
    /// for remasters), and it's cheap to hash on M1 Pro.
    nonisolated private static func hashFirstMB(of fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        guard !prefix.isEmpty else { return nil }
        let digest = SHA256.hash(data: prefix)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    nonisolated private static func decodeMetaArray(_ json: String) -> [(name: String, nFrames: Int)] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String,
                  let nf = d["n_frames"] as? Int else { return nil }
            return (name: name, nFrames: nf)
        }
    }

    nonisolated private static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .shazamIdentifiedAndCached(let id, let fromCache):
            return "shazam=\(id) cached=\(fromCache)"
        case .unidentifiedButCached(let key, let fromCache):
            return "unid key=\(key.prefix(16))… cached=\(fromCache)"
        case .alreadyCached:
            return "already cached"
        case .failed(let reason):
            return "FAILED: \(reason)"
        }
    }
}

#endif  // os(macOS)
