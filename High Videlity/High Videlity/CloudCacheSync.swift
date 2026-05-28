//
//  CloudCacheSync.swift
//  High Videlity
//
//  CloudKit sync layer for the two UserDefaults-backed song caches:
//   1. ShazamPhase2's preview-offset alignment cache
//      (`previewOffsetCache.v1` dict, value = TimeInterval).
//   2. TunebatBpmFetcher's GetSongBPM + MusicBrainz/AcousticBrainz
//      metadata cache (`HighVidelity.GetSongBPM.v9.*` keys, value =
//      dict of bpm + character axes).
//
//  Why this exists: both caches were local-only. The 2026-05-25 iOS
//  pivot ([[ios-system-music-pivot]]) made the alignment cache do
//  most of the visual-impact work on iPhone — but ONLY for songs the
//  user already calibrated on that device with mic-Shazam. On a
//  fresh iPhone, that's approximately zero songs. CloudKit sync of
//  these two caches means every song calibrated on the Mac (where
//  mic-Shazam runs naturally during normal listening) just works on
//  iPhone the first time it plays there.
//
//  Architecture:
//   - Local UserDefaults remains the synchronous fast path — nothing
//     in the hot path waits on the network.
//   - Writes fire-and-forget into CloudKit in background tasks.
//   - On a UserDefaults miss in the alignment or metadata caches
//     (cold cache, song never seen on this device), the read path
//     opportunistically awaits a single-record CloudKit fetch via
//     `database.record(for:)` — direct lookup by record ID, no query.
//     This works against any record type without CloudKit Dashboard
//     schema configuration.
//   - Cross-device sync is purely lazy. First lookup of each song on
//     a new device pays ~200-500ms; subsequent lookups are
//     local-instant. We had a launch-time bootstrap previously but
//     removed it (see the doc comment on `bootstrapSync()` below).
//
//  Conflict resolution: last-write-wins by CloudKit modification
//  date. For this data shape — deterministic-given-the-song
//  caches — conflicts are rare and benign.
//
//  Failure mode: if iCloud is unavailable (no account, no network,
//  capability not enabled), every call short-circuits to a no-op
//  silently and the app behaves exactly as it did pre-CloudKit.
//

import CloudKit
import Foundation
import OSLog

private let cloudLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "cloud-cache")

/// Singleton actor that owns CloudKit interactions for the two
/// UserDefaults-backed caches. All public API is async; all calls
/// are safe to invoke from anywhere and tolerate iCloud being
/// unavailable.
actor CloudCacheSync {

    static let shared = CloudCacheSync()

    private let container: CKContainer
    private let database: CKDatabase
    /// Public CloudKit database — shared across all users of the app.
    /// Used for the cross-user stem-features cache (see #5 /
    /// `fetchStemFeatures` / `saveStemFeatures`). First listener to
    /// run Demucs on a song uploads the per-stem features; every
    /// subsequent listener gets a cloud cache hit and skips the
    /// ~30-60s separation entirely.
    private let publicDatabase: CKDatabase

    /// Record type for the alignment cache. recordName = normalized
    /// "title|artist" (the same key used by ShazamPhase2's
    /// fileprivate cacheKey).
    private static let previewOffsetRecordType = "PreviewOffset"

    /// Record type for the metadata cache. Schema version embedded
    /// in the type name so a future schema bump (v10, v11, ...)
    /// doesn't fight pre-existing records.
    private static let metadataRecordType = "SongMetadataV9"

    /// Internal flag — flips to false if any operation surfaces an
    /// "iCloud not available" style error so we stop hammering the
    /// network for this app launch.
    private var cloudAvailable: Bool = true

    private init() {
        self.container = CKContainer(identifier: "iCloud.jessegriffith.High-Videlity")
        self.database = container.privateCloudDatabase
        self.publicDatabase = container.publicCloudDatabase
    }

    // MARK: - Preview offset (alignment) cache

    /// Fetch the cached preview-start-in-song for a normalized
    /// "title|artist" key. Returns nil on miss OR on any failure
    /// (network, no iCloud account, record not found).
    func fetchPreviewOffset(key: String) async -> TimeInterval? {
        guard cloudAvailable else { return nil }
        let recordID = CKRecord.ID(recordName: Self.sanitizeRecordName(key))
        do {
            let record = try await database.record(for: recordID)
            if let v = record["previewStartInSong"] as? Double {
                return v
            }
            return nil
        } catch let ckErr as CKError {
            handleCKError(ckErr, op: "fetchPreviewOffset")
            return nil
        } catch {
            cloudLog.notice("HV-CLOUD fetchPreviewOffset error \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Push a calibrated preview-start-in-song to CloudKit. Fire and
    /// forget — caller doesn't wait. Errors are logged but do not
    /// propagate.
    func savePreviewOffset(_ value: TimeInterval, for key: String) async {
        guard cloudAvailable else { return }
        let recordID = CKRecord.ID(recordName: Self.sanitizeRecordName(key))
        let record = CKRecord(recordType: Self.previewOffsetRecordType, recordID: recordID)
        record["previewStartInSong"] = value as CKRecordValue
        record["normalizedKey"] = key as CKRecordValue
        do {
            // Save with .changedKeys policy is the safe last-write-wins
            // semantic for our shape — overwriting only the fields we
            // explicitly set.
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            cloudLog.info("HV-CLOUD pushed previewOffset \(key, privacy: .public)=\(value, privacy: .public)s")
        } catch let ckErr as CKError {
            handleCKError(ckErr, op: "savePreviewOffset")
        } catch {
            cloudLog.notice("HV-CLOUD savePreviewOffset error \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Song metadata cache

    /// Fetch the cached metadata dict for a normalized "title|artist"
    /// key. Returns the dict shape that TunebatBpmFetcher's writeCache
    /// uses (so the caller can drop it into UserDefaults verbatim).
    /// Returns nil on miss or any failure.
    func fetchMetadata(key: String) async -> [String: Any]? {
        guard cloudAvailable else { return nil }
        let recordID = CKRecord.ID(recordName: Self.sanitizeRecordName(key))
        do {
            let record = try await database.record(for: recordID)
            return recordToMetadataDict(record)
        } catch let ckErr as CKError {
            handleCKError(ckErr, op: "fetchMetadata")
            return nil
        } catch {
            cloudLog.notice("HV-CLOUD fetchMetadata error \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Push a metadata dict to CloudKit. Mirrors the dict shape used
    /// by TunebatBpmFetcher.writeCache. NEGATIVE caches (bpm == 0)
    /// are intentionally NOT pushed — they're an artifact of one
    /// device's failed lookup; another device may have a different
    /// network path or API key state.
    func saveMetadata(_ dict: [String: Any], for key: String) async {
        guard cloudAvailable else { return }
        if let bpm = dict["bpm"] as? Double, bpm <= 0 { return }
        let recordID = CKRecord.ID(recordName: Self.sanitizeRecordName(key))
        let record = CKRecord(recordType: Self.metadataRecordType, recordID: recordID)
        metadataDictToRecord(dict, key: key, record: record)
        do {
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            cloudLog.info("HV-CLOUD pushed metadata \(key, privacy: .public)")
        } catch let ckErr as CKError {
            handleCKError(ckErr, op: "saveMetadata")
        } catch {
            cloudLog.notice("HV-CLOUD saveMetadata error \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Stem features (public DB, cross-user shared cache)

    /// Record type for the public-DB stem cache. v2 suffix matches
    /// the sidecar's PROTOCOL_VERSION — a future v3 (different feature
    /// layout) would use `StemFeaturesV3` so older records don't
    /// confuse newer builds.
    private static let stemFeaturesRecordType = "StemFeaturesV2"

    /// Stem-features cache record name format: `shazam-<shazamID>`.
    /// This is the same key the local SQLite cache uses for
    /// shazam-identified songs (see #3 / `AppModel.kickoffStemSeparation`),
    /// so a single string flows through three storage tiers.
    private static func stemRecordID(forShazamID shazamID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "shazam-\(shazamID)")
    }

    /// Try to fetch pre-computed stem features for a song that's been
    /// Shazam-identified. Returns nil on miss or any error. Bypasses
    /// the local Demucs run entirely when it succeeds — the first
    /// listener anywhere pays the ~30-60s separation cost, everyone
    /// else gets a sub-second cache hit.
    func fetchStemFeatures(shazamID: String) async -> StemSeparationResult? {
        guard cloudAvailable, !shazamID.isEmpty else { return nil }
        let recordID = Self.stemRecordID(forShazamID: shazamID)
        do {
            let record = try await publicDatabase.record(for: recordID)
            guard let asset = record["featuresAsset"] as? CKAsset,
                  let assetURL = asset.fileURL else {
                cloudLog.notice("HV-CLOUD public-stem record missing featuresAsset for \(shazamID, privacy: .public)")
                return nil
            }
            let blob = try Data(contentsOf: assetURL)
            let stemsMetaJSON = (record["stemsMetaJSON"] as? String) ?? "[]"
            let model = (record["model"] as? String) ?? "htdemucs"
            let sampleRate = (record["sampleRate"] as? Int) ?? 44100
            let frameRate = (record["frameRate"] as? Int) ?? 30
            let durationSeconds = record["durationSeconds"] as? Double
            let result = try StemSeparationResult.fromCloudPayload(
                model: model,
                sampleRate: sampleRate,
                frameRate: frameRate,
                durationSeconds: durationSeconds,
                stemsMetaJSON: stemsMetaJSON,
                featuresBlob: blob
            )
            cloudLog.notice("HV-CLOUD public-stem HIT for \(shazamID, privacy: .public) (\(blob.count) bytes, \(result.stems.count) stems)")
            return result
        } catch let ckErr as CKError {
            if ckErr.code != .unknownItem {
                handleCKError(ckErr, op: "fetchStemFeatures")
            }
            return nil
        } catch {
            cloudLog.notice("HV-CLOUD fetchStemFeatures error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Upload freshly-computed stem features for a Shazam-identified
    /// song so other users skip the compute on their first listen.
    /// Fire-and-forget; caller doesn't wait. No-op when the result
    /// has no `rawFeaturesBlob` (e.g., the result was itself derived
    /// from a cloud payload — we don't echo back what's already there)
    /// or when iCloud is unavailable.
    func saveStemFeatures(
        shazamID: String,
        title: String?, artist: String?,
        result: StemSeparationResult
    ) async {
        guard cloudAvailable, !shazamID.isEmpty,
              let blob = result.rawFeaturesBlob,
              let metaJSON = result.rawStemsMetaJSON else {
            return
        }
        let recordID = Self.stemRecordID(forShazamID: shazamID)
        let record = CKRecord(recordType: Self.stemFeaturesRecordType, recordID: recordID)
        record["stemsMetaJSON"] = metaJSON as CKRecordValue
        record["model"] = result.model as CKRecordValue
        record["protocolVersion"] = 2 as CKRecordValue  // matches sidecar PROTOCOL_VERSION
        record["sampleRate"] = result.sampleRate as CKRecordValue
        record["frameRate"] = result.frameRate as CKRecordValue
        if let d = result.durationSeconds {
            record["durationSeconds"] = d as CKRecordValue
        }
        if let title, !title.isEmpty {
            record["title"] = title as CKRecordValue
        }
        if let artist, !artist.isEmpty {
            record["artist"] = artist as CKRecordValue
        }
        record["shazamID"] = shazamID as CKRecordValue

        // Write the blob to a temp file so we can attach it as a
        // CKAsset. CloudKit handles upload + storage; the file can
        // be removed after the save completes.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-stem-upload-\(UUID().uuidString).bin")
        do {
            try blob.write(to: tmpURL)
            record["featuresAsset"] = CKAsset(fileURL: tmpURL)
        } catch {
            cloudLog.notice("HV-CLOUD saveStemFeatures temp-file write failed: \(String(describing: error), privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            _ = try await publicDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            cloudLog.notice("HV-CLOUD public-stem pushed shazamID=\(shazamID, privacy: .public) (\(blob.count) bytes)")
        } catch let ckErr as CKError {
            // Common case: another listener uploaded first → serverRecordChanged.
            // For a write-only cache this is fine; their copy is just as
            // valid as ours. Log and move on.
            if ckErr.code == .serverRecordChanged {
                cloudLog.info("HV-CLOUD public-stem already exists for \(shazamID, privacy: .public) (raced another listener)")
            } else {
                handleCKError(ckErr, op: "saveStemFeatures")
            }
        } catch {
            cloudLog.notice("HV-CLOUD saveStemFeatures error: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Cross-device sync

    /// Cross-device sync is handled ENTIRELY by the on-demand fetch
    /// path: `fetchPreviewOffset(key:)` and `fetchMetadata(key:)` use
    /// `database.record(for: recordID)` (direct lookup by record ID,
    /// no query) which works against any record type without schema
    /// configuration. The first lookup of each song on a new device
    /// pays ~200-500ms; subsequent lookups are local-instant.
    ///
    /// We previously had a launch-time `bootstrapSync()` that
    /// proactively pulled all changed records into local UserDefaults
    /// so even the first lookup was instant. It used `CKQuery` with
    /// either `modificationDate > sinceDate` or `TRUEPREDICATE`, both
    /// of which require fields in the auto-created schema to be
    /// marked QUERYABLE — a CloudKit Dashboard step that doesn't
    /// happen automatically. We removed it because:
    ///   • Lazy fetch already covers the cross-device case (just
    ///     slower per-song first lookup).
    ///   • Bootstrap added ongoing ops cost: every new record type
    ///     and every dev→prod schema deploy needs Dashboard touches
    ///     to add queryable indexes.
    ///   • If we ever want proactive discovery back, the right shape
    ///     is CKSubscription (push notification on remote write), not
    ///     polling — which we'd build fresh anyway.
    ///
    /// Kept as an explicit no-op so app launch can keep calling
    /// `bootstrapSync()` without a code change here if the design
    /// ever flips back.
    func bootstrapSync() async {
        // Intentional no-op. See the doc comment above.
    }

    // MARK: - Self-test (DEBUG only)

    #if DEBUG
    /// One-shot end-to-end roundtrip: write a sentinel record, fetch
    /// it back, verify contents, delete it. Logs a single definitive
    /// PASS / FAIL line so Jesse can `grep` the log after launch and
    /// know whether the CloudKit wiring is actually live.
    ///
    /// Failure modes classified:
    ///   • `accountStatus != available` → user needs to sign into iCloud
    ///   • `notAuthenticated` CKError → same
    ///   • `permissionFailure` → Xcode capability or provisioning profile
    ///   • `networkUnavailable` / `networkFailure` → transient
    ///   • content mismatch → unlikely, but caught explicitly
    ///   • bare `unknownItem` after the initial write → sync is broken
    ///     somewhere between save and fetch
    func runSelfTest() async {
        // Account status first — most common cause of failure is
        // simply not being signed in. CloudKit's own error messages
        // for this case can be confusing, so log it directly.
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                cloudLog.notice("HV-CLOUD self-test accountStatus=available")
            case .noAccount:
                cloudLog.notice("HV-CLOUD self-test FAIL accountStatus=noAccount (sign into iCloud in System Settings)")
                return
            case .restricted:
                cloudLog.notice("HV-CLOUD self-test FAIL accountStatus=restricted")
                return
            case .couldNotDetermine:
                cloudLog.notice("HV-CLOUD self-test FAIL accountStatus=couldNotDetermine (likely network)")
                return
            case .temporarilyUnavailable:
                cloudLog.notice("HV-CLOUD self-test FAIL accountStatus=temporarilyUnavailable")
                return
            @unknown default:
                cloudLog.notice("HV-CLOUD self-test FAIL accountStatus=unknown")
                return
            }
        } catch {
            cloudLog.notice("HV-CLOUD self-test FAIL accountStatus error: \(String(describing: error), privacy: .public)")
            return
        }

        let testRecordName = "self-test-sentinel"
        let testRecordID = CKRecord.ID(recordName: testRecordName)
        let sentinel = "ok-\(UUID().uuidString.prefix(8))"

        // 1. Write
        let record = CKRecord(recordType: "SelfTest", recordID: testRecordID)
        record["sentinel"] = sentinel as CKRecordValue
        record["writtenAt"] = Date() as CKRecordValue
        do {
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
        } catch let ckErr as CKError {
            cloudLog.notice("HV-CLOUD self-test FAIL write CKError \(ckErr.code.rawValue) (\(String(describing: ckErr.code), privacy: .public)): \(ckErr.localizedDescription, privacy: .public)")
            return
        } catch {
            cloudLog.notice("HV-CLOUD self-test FAIL write error: \(String(describing: error), privacy: .public)")
            return
        }

        // 2. Fetch back
        let fetched: CKRecord
        do {
            fetched = try await database.record(for: testRecordID)
        } catch let ckErr as CKError {
            cloudLog.notice("HV-CLOUD self-test FAIL fetch CKError \(ckErr.code.rawValue) (\(String(describing: ckErr.code), privacy: .public)): \(ckErr.localizedDescription, privacy: .public)")
            return
        } catch {
            cloudLog.notice("HV-CLOUD self-test FAIL fetch error: \(String(describing: error), privacy: .public)")
            return
        }

        // 3. Verify content
        guard let echoed = fetched["sentinel"] as? String else {
            cloudLog.notice("HV-CLOUD self-test FAIL fetched record missing sentinel field")
            return
        }
        guard echoed == sentinel else {
            cloudLog.notice("HV-CLOUD self-test FAIL content mismatch: wrote \(sentinel, privacy: .public), read \(echoed, privacy: .public)")
            return
        }

        // 4. Delete (best-effort cleanup; don't fail the test if this errors)
        do {
            _ = try await database.modifyRecords(
                saving: [],
                deleting: [testRecordID],
                savePolicy: .changedKeys,
                atomically: true
            )
        } catch {
            cloudLog.notice("HV-CLOUD self-test cleanup delete failed (non-fatal): \(String(describing: error), privacy: .public)")
        }

        cloudLog.notice("HV-CLOUD self-test PASS — wrote+fetched+verified+deleted sentinel '\(sentinel, privacy: .public)'")
    }

    /// Public-DB sibling of `runSelfTest`. Verifies the cross-user
    /// path independently from the private-DB sync — they share a
    /// container but live in different databases and could fail
    /// independently (e.g., missing CloudKit Dashboard deploy of the
    /// public schema, or a future public-DB-specific permission
    /// reject). Uses a per-launch UUID record name so concurrent
    /// runs from multiple devices / users don't collide.
    func runPublicSelfTest() async {
        guard cloudAvailable else {
            cloudLog.notice("HV-CLOUD public self-test SKIP — cloudAvailable=false")
            return
        }
        let recordName = "selftest-pub-\(UUID().uuidString)"
        let recordID = CKRecord.ID(recordName: recordName)
        let sentinel = "ok-\(UUID().uuidString.prefix(8))"

        let record = CKRecord(recordType: "SelfTestPublic", recordID: recordID)
        record["sentinel"] = sentinel as CKRecordValue
        record["writtenAt"] = Date() as CKRecordValue
        do {
            _ = try await publicDatabase.modifyRecords(
                saving: [record], deleting: [],
                savePolicy: .changedKeys, atomically: true
            )
        } catch let ckErr as CKError {
            cloudLog.notice("HV-CLOUD public self-test FAIL write CKError \(ckErr.code.rawValue) (\(String(describing: ckErr.code), privacy: .public)): \(ckErr.localizedDescription, privacy: .public)")
            return
        } catch {
            cloudLog.notice("HV-CLOUD public self-test FAIL write error: \(String(describing: error), privacy: .public)")
            return
        }

        let fetched: CKRecord
        do {
            fetched = try await publicDatabase.record(for: recordID)
        } catch let ckErr as CKError {
            cloudLog.notice("HV-CLOUD public self-test FAIL fetch CKError \(ckErr.code.rawValue) (\(String(describing: ckErr.code), privacy: .public)): \(ckErr.localizedDescription, privacy: .public)")
            return
        } catch {
            cloudLog.notice("HV-CLOUD public self-test FAIL fetch error: \(String(describing: error), privacy: .public)")
            return
        }

        guard let echoed = fetched["sentinel"] as? String else {
            cloudLog.notice("HV-CLOUD public self-test FAIL fetched record missing sentinel field")
            return
        }
        guard echoed == sentinel else {
            cloudLog.notice("HV-CLOUD public self-test FAIL content mismatch: wrote \(sentinel, privacy: .public), read \(echoed, privacy: .public)")
            return
        }

        // Best-effort delete. Failure here is non-fatal; the sentinel
        // record will linger in public DB until manually cleaned, but
        // it's tiny.
        do {
            _ = try await publicDatabase.modifyRecords(
                saving: [], deleting: [recordID],
                savePolicy: .changedKeys, atomically: true
            )
        } catch {
            cloudLog.notice("HV-CLOUD public self-test cleanup delete failed (non-fatal): \(String(describing: error), privacy: .public)")
        }

        cloudLog.notice("HV-CLOUD public self-test PASS — wrote+fetched+verified+deleted sentinel '\(sentinel, privacy: .public)' on publicCloudDatabase")
    }
    #endif

    // MARK: - Error / availability handling

    /// Inspect a CKError and decide whether to mark CloudKit
    /// unavailable for the rest of this app launch. We stop trying
    /// on the "no account" / "not authenticated" class of errors —
    /// they aren't going to fix themselves without user action.
    /// Transient network errors do NOT flip the flag.
    private func handleCKError(_ err: CKError, op: String) {
        switch err.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted:
            cloudAvailable = false
            cloudLog.notice("HV-CLOUD \(op, privacy: .public) — iCloud unavailable, disabling sync for this launch")
        case .unknownItem:
            // Record-not-found is the normal "cache miss" path,
            // not a real error. Don't log.
            break
        default:
            cloudLog.notice("HV-CLOUD \(op, privacy: .public) CKError \(err.code.rawValue): \(err.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Record <-> dict marshalling

    private func recordToMetadataDict(_ record: CKRecord) -> [String: Any] {
        var dict: [String: Any] = [:]
        let doubleFields = [
            "bpm", "danceability", "acousticness", "aggressiveness",
            "happiness", "voiceVocal", "timbreBrightness", "party", "relaxed"
        ]
        for field in doubleFields {
            if let v = record[field] as? Double {
                dict[field] = v
            }
        }
        let stringFields = ["title", "artist", "timeSig", "keyOf"]
        for field in stringFields {
            if let v = record[field] as? String, !v.isEmpty {
                dict[field] = v
            }
        }
        return dict
    }

    private func metadataDictToRecord(_ dict: [String: Any], key: String, record: CKRecord) {
        record["normalizedKey"] = key as CKRecordValue
        let doubleFields = [
            "bpm", "danceability", "acousticness", "aggressiveness",
            "happiness", "voiceVocal", "timbreBrightness", "party", "relaxed"
        ]
        for field in doubleFields {
            if let v = dict[field] as? Double {
                record[field] = v as CKRecordValue
            }
        }
        let stringFields = ["title", "artist", "timeSig", "keyOf"]
        for field in stringFields {
            if let v = dict[field] as? String, !v.isEmpty {
                record[field] = v as CKRecordValue
            }
        }
    }

    /// CKRecord.ID names must avoid certain characters and a leading
    /// underscore. Our normalized keys are already alphanumeric +
    /// spaces + pipe — replace whitespace and pipe with safe chars
    /// (CloudKit accepts letters, digits, _ and -). Hash collisions
    /// are vanishingly unlikely at our scale and the cost of a
    /// collision is just an overwrite of a song record.
    static func sanitizeRecordName(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch == " " || ch == "|" {
                out.append("_")
            }
            // drop anything else
        }
        // Guard against leading underscore (reserved by CloudKit) and
        // empty names. Prefix with "s_" if needed.
        if out.isEmpty || out.first == "_" {
            out = "s" + out
        }
        return out
    }
}
