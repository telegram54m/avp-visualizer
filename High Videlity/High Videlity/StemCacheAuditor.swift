//
//  StemCacheAuditor.swift
//
//  Runs over the local stem-features SQLite cache, looks for rows
//  whose metadata disagrees with the underlying stem bytes, and
//  returns a structured list of findings the maintenance UI can show
//  to the user. The user reviews findings and chooses what to delete.
//
//  Why this exists:
//  `AppModel.kickoffStemSeparation`'s Tier-1b fallback path looks up
//  cached features by (title, artist) and aliases the found key to
//  `shazam-<id>`. When Shazam misidentified the song at any point in
//  the past, that alias wrote a `shazam-<id>` pointer onto the wrong
//  underlying cache row. On subsequent plays of the truly-identified
//  song, the cache hits — but with stems computed from a different
//  audio file. The runtime title+duration validator in
//  `AppModel.applyStemResult` now rejects these at apply-time, so the
//  visualizer correctly falls back to band-split signals. But the bad
//  row stays on disk and keeps triggering REJECT logs.
//
//  Two detection strategies, used together:
//
//  • **MusicBrainz duration check.** For each row with a clean
//    (title, artist), look up the canonical recording length on
//    MusicBrainz. If the cached `durationSeconds` differs from MB's
//    best-match recording by more than 4 seconds — the same slop
//    [[AppModel.applyStemResult]] uses — flag the row as suspicious.
//    Some legitimate variants (radio edits, live versions) can differ
//    by more, so this is presented for user confirmation, never
//    auto-deleted.
//
//  • **Duplicate-payload check.** If two rows hold the same
//    `(nFrames, durationSeconds)` signature but have different
//    (title, artist) — that's the alias-bug pattern. Both legitimate
//    aliases (the pid↔shazam mirror written by `cache_alias`) and bug
//    rows produce duplicate payloads, but legitimate aliases share
//    the SAME metadata. Different metadata + same payload signature is
//    the smoking gun. Higher-confidence than the MB check on its own.
//
//  A row gets a compound severity when both flags trigger.
//

#if os(macOS)
import Foundation
import OSLog

private let auditLog = Logger(subsystem: "com.example.HighVidelity", category: "StemCacheAudit")

enum StemCacheAuditor {

    // MARK: - Findings model

    /// Why a specific row was flagged. A row may carry multiple
    /// findings; the UI sums their severity.
    enum FindingKind: Sendable, Equatable {
        /// MusicBrainz returned one or more recordings with lengths
        /// for this (title, artist), and the cached `durationSeconds`
        /// is outside the 4-second slop window of every single MB
        /// length we got back. This is INFO-only — many libraries
        /// contain a version (remaster, single edit, demo, live,
        /// regional release) MusicBrainz doesn't index, so a
        /// mismatch is not proof of corruption. Never pre-selected
        /// for deletion. `mbCandidates` is the list of MB-reported
        /// lengths so the UI can show the user what alternatives MB
        /// thinks exist for this title+artist.
        case durationMismatch(cached: Double, mbCandidates: [Double])
        /// Another row in the cache has the same payload signature
        /// (n_frames, duration_seconds) but different (title, artist).
        /// Strong indicator of a misidentification-induced alias.
        case duplicatePayload(otherKeys: [String])
        /// Row's stems_meta column was NULL — v1 protocol-version row.
        /// Harmless to delete (will be recomputed); shown so the user
        /// can clean up.
        case staleProtocolVersion(version: Int)
        /// Row has no title+artist at all, so we can't audit it. Shown
        /// as a low-confidence info item — not selected for deletion
        /// by default.
        case untaggable
    }

    struct Finding: Sendable, Identifiable {
        let id: String  // == row.cacheKey
        let row: StemCacheRow
        let kinds: [FindingKind]

        /// True when at least one finding is high-confidence — i.e.
        /// the row is very likely corrupted and safe to recommend
        /// for deletion. Used by the UI to pre-check the deletion
        /// box. Only `duplicatePayload` qualifies: identical stem
        /// bytes appearing under two different (title, artist) pairs
        /// is unambiguous evidence of the alias-bug pattern. Duration
        /// mismatch is INFO-only — MusicBrainz often lacks the exact
        /// version a library track holds (remasters, single edits,
        /// regional releases), so a length disagreement isn't proof
        /// of corruption.
        var isHighConfidence: Bool {
            for k in kinds {
                if case .duplicatePayload = k { return true }
            }
            return false
        }

        var headline: String {
            return "\(row.title ?? "(no title)") — \(row.artist ?? "(no artist)")"
        }

        /// One-line summary for each kind, suitable for a UI list cell.
        var details: [String] {
            kinds.map { kind in
                switch kind {
                case let .durationMismatch(cached, mbCandidates):
                    let candidates = mbCandidates
                        .map { String(format: "%.0fs", $0) }
                        .joined(separator: ", ")
                    return String(
                        format: "Cached duration %.1fs doesn't match any MusicBrainz version (%@). " +
                        "Could just mean MusicBrainz doesn't index your exact release (remaster, single edit, etc.) — verify before removing.",
                        cached, candidates
                    )
                case let .duplicatePayload(otherKeys):
                    let suffix = otherKeys.count == 1
                        ? "another row"
                        : "\(otherKeys.count) other rows"
                    let preview = otherKeys.prefix(2).joined(separator: ", ")
                    let more = otherKeys.count > 2 ? " (…)" : ""
                    return "Identical stem bytes as \(suffix) with different metadata: \(preview)\(more)"
                case let .staleProtocolVersion(version):
                    return "Stale protocol version \(version) — would be recomputed on next play."
                case .untaggable:
                    return "No title/artist — can't verify against MusicBrainz."
                }
            }
        }
    }

    struct Progress: Sendable {
        let stage: Stage
        let completed: Int
        let total: Int

        enum Stage: Sendable {
            case enumerating
            case checkingMusicBrainz
            case correlating
        }
    }

    struct Report: Sendable {
        let totalRows: Int
        let findings: [Finding]
        /// Number of rows the MB lookup couldn't resolve (not in MB,
        /// or network failure). Not a finding — just diagnostic.
        let unmatchedMBLookups: Int
    }

    // MARK: - Run

    /// Audit the local stem-features cache. Streams `Progress`
    /// updates so the UI can show a progress bar; emits one terminal
    /// `Report`. Cancellation is honored at every MB round-trip.
    ///
    /// Cost: ~1 MusicBrainz round-trip per cached row with a
    /// non-empty (title, artist). MB targets ~1 req/sec per their
    /// AUP — we pace at 1.1s between requests to be safe. A user with
    /// 200 cached songs will sit through ~4 minutes of audit time.
    /// Acceptable as a maintenance action they invoke manually.
    @MainActor
    static func runAudit(
        provider: StemFeatureProvider,
        progress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Report {
        // 1. Enumerate cache rows.
        progress(Progress(stage: .enumerating, completed: 0, total: 0))
        let rows = try await provider.cacheAudit()
        auditLog.log("HV-CACHE-AUDIT enumerated \(rows.count) rows")

        // 2. Duplicate-payload bucketing. Bucket by (nFrames,
        // duration rounded to 0.1s) — strict equality on nFrames +
        // tight rounding on duration is enough to coalesce
        // legitimate alias rows (which truly carry identical
        // payloads — `cache_alias` copies bytes verbatim) and the
        // corrupted alias rows we're hunting for. We then drop
        // buckets where every row shares the same (title, artist)
        // pair — those are the legitimate aliases.
        progress(Progress(stage: .correlating, completed: 0, total: rows.count))
        let dupeOtherKeysByCacheKey = correlateDuplicatePayloads(rows: rows)

        // 3. MusicBrainz duration lookups. Dedupe by (title, artist) —
        // many cache rows can share the same wrong tag (the alias-bug
        // pattern produces buckets of dozens of identically-mistagged
        // rows), so one lookup per unique pair is enough.
        struct TagPair: Hashable {
            let title: String
            let artist: String
        }
        var uniquePairs: [TagPair] = []
        var seenPairs: Set<TagPair> = []
        for row in rows {
            let t = (row.title ?? "")
            let a = (row.artist ?? "")
            guard !t.isEmpty, !a.isEmpty else { continue }
            let pair = TagPair(title: t, artist: a)
            if seenPairs.insert(pair).inserted {
                uniquePairs.append(pair)
            }
        }
        var candidatesByPair: [TagPair: [Double]] = [:]
        var unmatchedPairs = 0

        for (i, pair) in uniquePairs.enumerated() {
            try Task.checkCancellation()
            progress(Progress(
                stage: .checkingMusicBrainz,
                completed: i,
                total: uniquePairs.count
            ))
            let candidates = await fetchMusicBrainzDurations(
                title: pair.title, artist: pair.artist)
            if !candidates.isEmpty { candidatesByPair[pair] = candidates }
            else { unmatchedPairs += 1 }
            // 1.1s pace between MB requests — AUP limit.
            if i < uniquePairs.count - 1 {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
        }
        let unmatchedCount = unmatchedPairs

        // 4. Compose findings.
        var findings: [Finding] = []
        for row in rows {
            var kinds: [FindingKind] = []

            // Duplicate-payload finding.
            if let others = dupeOtherKeysByCacheKey[row.cacheKey], !others.isEmpty {
                kinds.append(.duplicatePayload(otherKeys: others))
            }

            // Duration mismatch finding. Only fires when MB returned
            // at least one candidate AND none of them are within slop
            // of the cached duration. A single MB recording within
            // slop is treated as a match, even if the top-ranked one
            // isn't — MB's score ranking has no relationship to
            // "which version is in the user's library" (album vs.
            // single edit vs. remaster all coexist with similar
            // scores). This is the correctness fix after my v1 audit
            // flagged ~legit rows that just happened to be a
            // different release of the same recording than MB's top
            // hit.
            if let cached = row.durationSeconds, cached > 0,
               !(row.title ?? "").isEmpty, !(row.artist ?? "").isEmpty {
                let pair = TagPair(title: row.title ?? "", artist: row.artist ?? "")
                if let candidates = candidatesByPair[pair], !candidates.isEmpty {
                    let anyClose = candidates.contains { abs(cached - $0) <= 4.0 }
                    if !anyClose {
                        kinds.append(.durationMismatch(
                            cached: cached, mbCandidates: candidates))
                    }
                }
            }

            // Stale protocol version (v1 rows that won't ever be
            // read — sidecar's lookup discards them on read).
            // Current production version is 3 (see sidecar.py).
            // Don't surface v3 as stale — that's the current version
            // even though our Swift binary unpacker still uses the
            // wire header version 2 magic.
            if row.protocolVersion < 2 {
                kinds.append(.staleProtocolVersion(version: row.protocolVersion))
            }

            // Untaggable (info-only).
            if (row.title ?? "").isEmpty || (row.artist ?? "").isEmpty {
                kinds.append(.untaggable)
            }

            if !kinds.isEmpty {
                findings.append(Finding(id: row.cacheKey, row: row, kinds: kinds))
            }
        }

        // Sort: high-confidence first, then by row creation time
        // (newest first) so the most recent corruption surfaces at
        // the top.
        findings.sort { lhs, rhs in
            if lhs.isHighConfidence != rhs.isHighConfidence {
                return lhs.isHighConfidence && !rhs.isHighConfidence
            }
            return lhs.row.createdAt > rhs.row.createdAt
        }

        auditLog.log("HV-CACHE-AUDIT done: \(findings.count) findings out of \(rows.count) rows, \(unmatchedCount) unmatched MB lookups")
        return Report(
            totalRows: rows.count,
            findings: findings,
            unmatchedMBLookups: unmatchedCount
        )
    }

    /// Delete the given cache keys. Used by the maintenance UI after
    /// the user confirms removals. Returns the count of rows actually
    /// deleted (sidecar returns deleted=false for keys with no
    /// matching row — already cleaned up earlier, harmless).
    static func deleteRows(
        provider: StemFeatureProvider,
        cacheKeys: [String]
    ) async throws -> Int {
        var deleted = 0
        for key in cacheKeys {
            try Task.checkCancellation()
            if try await provider.deleteCacheRow(forKey: key) {
                deleted += 1
            }
        }
        auditLog.log("HV-CACHE-AUDIT deleted \(deleted) of \(cacheKeys.count) requested rows")
        return deleted
    }

    // MARK: - Internals

    /// For each cache row, list the OTHER rows that share its payload
    /// signature AND have a different (title, artist) pair. Returns a
    /// map from row's cacheKey → array of other cacheKeys.
    ///
    /// Legitimate alias rows (e.g. `musicapp-pid-X` paired with
    /// `shazam-Y` for the same song) have identical metadata after
    /// `cache_alias` copied it verbatim — those buckets get pruned
    /// out and don't show up here.
    private static func correlateDuplicatePayloads(
        rows: [StemCacheRow]
    ) -> [String: [String]] {
        struct PayloadKey: Hashable {
            let nFrames: Int
            // Quantize duration to 0.1s to coalesce floating-point
            // wobble across rounding paths (sidecar rounds to 0.001s
            // on write; cache_alias copies verbatim).
            let durationDeciSec: Int
        }
        var buckets: [PayloadKey: [StemCacheRow]] = [:]
        for r in rows where r.nFrames > 0 && (r.durationSeconds ?? 0) > 0 {
            let key = PayloadKey(
                nFrames: r.nFrames,
                durationDeciSec: Int(((r.durationSeconds ?? 0) * 10).rounded())
            )
            buckets[key, default: []].append(r)
        }

        var result: [String: [String]] = [:]
        for (_, group) in buckets where group.count > 1 {
            // Bucket by metadata identity inside the payload bucket.
            // If all rows in a bucket share the same (lowercased
            // title, lowercased artist), that's a legitimate alias —
            // skip it entirely.
            let metadataIdentity: (StemCacheRow) -> String = { r in
                "\((r.title ?? "").lowercased())|\((r.artist ?? "").lowercased())"
            }
            let identities = Set(group.map(metadataIdentity))
            if identities.count <= 1 {
                continue  // legitimate aliases — all share metadata
            }
            // At least two distinct (title, artist) pairs map to the
            // same payload — bug pattern. For each row, list the
            // OTHER keys in the same bucket whose metadata differs.
            for r in group {
                let mine = metadataIdentity(r)
                let others = group
                    .filter { $0.cacheKey != r.cacheKey && metadataIdentity($0) != mine }
                    .map { $0.cacheKey }
                if !others.isEmpty {
                    result[r.cacheKey] = others
                }
            }
        }
        return result
    }

    /// Query MusicBrainz `/recording/?query=...` and return EVERY
    /// distinct length (in seconds) it reports for that title+artist.
    /// One MB query routinely returns the album version, single edit,
    /// remaster, regional release, demo, live take — all with
    /// different lengths but the same title+artist. The auditor
    /// treats a row's cached duration as MATCHING if it's within
    /// slop of ANY of these candidates, so we don't false-positive
    /// on legitimate version variants.
    ///
    /// Returned values are sorted ascending and deduped (rounded to
    /// 1s — recordings differing by sub-second are noise from
    /// different masterings of the same length).
    private static func fetchMusicBrainzDurations(
        title: String, artist: String
    ) async -> [Double] {
        guard !title.isEmpty, !artist.isEmpty else { return [] }
        let query = "recording:\"\(escapeForLucene(title))\" AND artist:\"\(escapeForLucene(artist))\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            // Generous limit — version variants we care about
            // (album / single / remaster / live) often sit further
            // down than the top 5 results.
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "HighVidelity/0.1 (https://telegram54m.github.io/avp-visualizer)",
            forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordings = json["recordings"] as? [[String: Any]]
            else { return [] }
            // Collect every sane length, dedupe at 1-second resolution.
            var seen: Set<Int> = []
            var lengths: [Double] = []
            for rec in recordings {
                guard let lengthMS = rec["length"] as? NSNumber else { continue }
                let seconds = lengthMS.doubleValue / 1000.0
                guard seconds > 30, seconds < 7200 else { continue }
                let bucket = Int(seconds.rounded())
                if seen.insert(bucket).inserted {
                    lengths.append(seconds)
                }
            }
            return lengths.sorted()
        } catch {
            return []
        }
    }

    /// Lucene-special-char escape (mirrors MusicBrainzBpmFetcher's).
    private static func escapeForLucene(_ s: String) -> String {
        let reserved: Set<Character> = [
            "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]",
            "^", "\"", "~", "*", "?", ":", "\\", "/"
        ]
        var out = ""
        for ch in s {
            if reserved.contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
#endif
