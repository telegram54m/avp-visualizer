//
//  StemFeatureProviderSwiftBackend.swift — in-process Swift
//  replacement for the Python sidecar. Phase 2 of
//  [[swift-sidecar-port-spec]].
//
//  Surface mirrors `StemFeatureProvider`'s actor so we can switch
//  between backends with a build flag (`STEM_USE_SWIFT`) without any
//  caller changes. See Phase 2 docs in
//  ~/.claude/.../memory/phase0-result-2026-05-30.md (perf) and
//  ~/.claude/.../memory/phase1-result-2026-05-30.md (features).
//
//  This is the first-cut implementation: separation runs end-to-end
//  (no chunking yet — fits within htdemucs's 7.8-second training
//  segment, so we just pad short songs and process long songs as a
//  single forward pass for now). The chunking + progress + abandon
//  surface lands in Phase 2b.
//

import AVFoundation
import Foundation
import HTDemucsSwift
import FeatureDerive
import MLX
import SQLite3

// When STEM_USE_SWIFT is defined (via OTHER_SWIFT_FLAGS=-DSTEM_USE_SWIFT),
// this typealias remaps the public name `StemFeatureProvider` to the
// in-process Swift backend below — all callers (AppModel,
// LibraryBatchCacher, StemCacheAuditor) continue to spell it
// `StemFeatureProvider`, the typealias swaps the implementation.
//
// The matching `#if !STEM_USE_SWIFT` block in StemFeatureProvider.swift
// disables the macOS Python actor + non-macOS stub when the flag is set,
// so we don't end up with two declarations of the same name.
#if STEM_USE_SWIFT
public typealias StemFeatureProvider = StemFeatureProviderSwiftBackend
#endif

// MARK: - Configuration

public struct StemSwiftConfiguration: Sendable {
    public let safetensorsPath: URL
    public let filterbankDir: URL
    public let cachePath: URL

    public init(safetensorsPath: URL, filterbankDir: URL, cachePath: URL) {
        self.safetensorsPath = safetensorsPath
        self.filterbankDir = filterbankDir
        self.cachePath = cachePath
    }

    /// Default configuration. Prefers `Bundle.main.url(forResource:)`
    /// for the htdemucs weights + librosa filterbanks; falls back to the
    /// dev-tree probe artifact paths when those aren't bundled (e.g.
    /// running outside the app target). Cache always goes to
    /// `~/Library/Caches/HighVidelity/stem_features.sqlite`.
    ///
    /// To bundle the safetensors for a real build:
    ///   1. Run `tools/export_weights.py htdemucs`
    ///   2. Copy / symlink `htdemucs.safetensors` into
    ///      `High Videlity/High Videlity/Resources/`
    ///      (the `.gitignore` there keeps the 196 MB blob out of git)
    public static func localDevDefaults() -> StemSwiftConfiguration {
        let bundle = Bundle.main

        let safetensors: URL = {
            if let bundled = bundle.url(forResource: "htdemucs", withExtension: "safetensors") {
                return bundled
            }
            let repoRoot = "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer"
            return URL(fileURLWithPath:
                "\(repoRoot)/StemAnalysis/HTDemucsSwiftProbe/artifacts/htdemucs.safetensors")
        }()

        let filterbankDir: URL = {
            // FeatureDeriver looks for `chroma_filterbank.f32` and
            // `mel_filterbank.f32` directly under this directory.
            if let chromaURL = bundle.url(forResource: "chroma_filterbank", withExtension: "f32") {
                return chromaURL.deletingLastPathComponent()
            }
            let repoRoot = "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer"
            return URL(fileURLWithPath:
                "\(repoRoot)/StemAnalysis/FeatureDeriveSwiftProbe/artifacts/parity")
        }()

        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/HighVidelity/stem_features.sqlite")

        return StemSwiftConfiguration(
            safetensorsPath: safetensors,
            filterbankDir: filterbankDir,
            cachePath: cache
        )
    }
}

// MARK: - Actor

public actor StemFeatureProviderSwiftBackend {
    /// Mirrors the nested `StemFeatureProvider.AliasResult` shape so a
    /// build-flag typealias swap is drop-in for callers.
    public struct AliasResult: Sendable, Codable {
        public let aliased: Bool
        public let reason: String?
    }

    public static let protocolVersion = 2
    public static let modelName = "htdemucs"
    public static let sampleRate = 44_100
    public static let frameRate = 30

    private let configuration: StemSwiftConfiguration
    private var model: HTDemucs?
    private var deriver: FeatureDeriver?
    private var db: OpaquePointer?

    private var onProgress: (@Sendable (Double) -> Void)?
    private var cancellationFlag = false

    public init(configuration: StemSwiftConfiguration = .localDevDefaults()) {
        self.configuration = configuration
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard model == nil else { return }
        guard FileManager.default.fileExists(atPath: configuration.safetensorsPath.path) else {
            throw StemSidecarError.protocolViolation(
                "htdemucs.safetensors not found at \(configuration.safetensorsPath.path) — " +
                "run StemAnalysis/HTDemucsSwiftProbe/tools/export_weights.py htdemucs"
            )
        }
        let m = HTDemucs(sources: ["drums", "bass", "other", "vocals"])
        try m.loadWeights(from: configuration.safetensorsPath)
        self.model = m
        self.deriver = try FeatureDeriver(
            sr: Self.sampleRate,
            frameRate: Self.frameRate,
            filterbankDir: configuration.filterbankDir
        )
        try openCache()
    }

    public func stop() async {
        if db != nil { sqlite3_close(db); db = nil }
    }

    public func ping() async throws { /* in-process, always up */ }

    public func setOnProgress(_ callback: (@Sendable (Double) -> Void)?) {
        self.onProgress = callback
    }
    public func currentOnProgress() -> (@Sendable (Double) -> Void)? { onProgress }

    /// Matches `StemFeatureProvider.abandon()` signature (`async throws`)
    /// so the build-flag typealias is drop-in for callers. We don't
    /// actually throw — the in-process backend can always set the flag.
    public func abandon() async throws { cancellationFlag = true }

    // MARK: Separate

    public func separate(
        filePath: String,
        cacheKey: String? = nil,
        forceRefresh: Bool = false,
        model overrideModel: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        throttleMS: Int = 0
    ) async throws -> StemSeparationResult {
        try await ensureStarted()
        cancellationFlag = false
        let modelName = overrideModel ?? Self.modelName

        if let key = cacheKey, !key.isEmpty, !forceRefresh,
           let cached = try cacheLookup(cacheKey: key, model: modelName) {
            return cached
        }

        let audio = try Self.loadAudio(
            at: URL(fileURLWithPath: filePath),
            targetSampleRate: Self.sampleRate
        )
        let durationSeconds = Double(audio.frameCount) / Double(Self.sampleRate)

        let separateStart = Date()
        let stems = try await runChunked(
            audio: audio,
            throttleMS: throttleMS
        )
        let separationSeconds = Date().timeIntervalSince(separateStart)

        let featureStart = Date()
        let features = try deriveAllFeatures(stems: stems)
        let featureSeconds = Date().timeIntervalSince(featureStart)

        let (blob, stemsMetaJSON) = packStems(features)
        let result = StemSeparationResult(
            model: modelName,
            sampleRate: Self.sampleRate,
            frameRate: Self.frameRate,
            stems: features,
            timing: .init(
                separationSeconds: separationSeconds,
                featureSeconds: featureSeconds
            ),
            fromCache: false,
            durationSeconds: durationSeconds
        )

        if let key = cacheKey, !key.isEmpty {
            try cacheStore(
                cacheKey: key, model: modelName,
                durationSeconds: durationSeconds,
                title: title, artist: artist,
                blob: blob, stemsMetaJSON: stemsMetaJSON
            )
        }
        return result
    }

    // MARK: Cache I/O

    public func cacheStats() async throws -> StemCacheStats {
        try await ensureStarted()
        var count = 0; var sizeBytes = 0
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*), COALESCE(SUM(LENGTH(features_blob)), 0) FROM stem_features"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("cache_stats prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(stmt, 0))
            sizeBytes = Int(sqlite3_column_int64(stmt, 1))
        }
        return StemCacheStats(
            entries: count, sizeBytes: sizeBytes,
            cachePath: configuration.cachePath.path,
            protocolVersion: Self.protocolVersion
        )
    }

    public func clearAllCachedFeatures() async throws -> Int {
        try await ensureStarted()
        let stats = try await cacheStats()
        let removed = stats.entries
        guard sqlite3_exec(db, "DELETE FROM stem_features", nil, nil, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("clearAll"), trace: nil)
        }
        return removed
    }

    public func alias(primaryKey: String, aliasKey: String) async throws -> AliasResult {
        try await ensureStarted()
        var stmt: OpaquePointer?
        let sql = """
            SELECT model, protocol_version, duration_seconds, title, artist,
                   created_at, features_blob, stems_meta
              FROM stem_features WHERE cache_key = ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("alias prepare"), trace: nil)
        }
        sqlite3_bind_text(stmt, 1, primaryKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return AliasResult(aliased: false, reason: "primary not found")
        }
        let modelStr = String(cString: sqlite3_column_text(stmt, 0))
        let pv = Int(sqlite3_column_int(stmt, 1))
        let dur = sqlite3_column_double(stmt, 2)
        let title = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let artist = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let createdAt = Int(sqlite3_column_int64(stmt, 5))
        let blobLen = Int(sqlite3_column_bytes(stmt, 6))
        let blob = Data(bytes: sqlite3_column_blob(stmt, 6)!, count: blobLen)
        let meta = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        sqlite3_finalize(stmt)

        try cacheStoreRaw(
            cacheKey: aliasKey, model: modelStr, protocolVersion: pv,
            durationSeconds: dur, title: title, artist: artist,
            createdAt: createdAt, blob: blob, stemsMetaJSON: meta
        )
        return AliasResult(aliased: true, reason: nil)
    }

    public func findCacheKey(title: String, artist: String,
                              model: String = "htdemucs") async throws -> String? {
        try await ensureStarted()
        var stmt: OpaquePointer?
        let sql = "SELECT cache_key FROM stem_features WHERE artist = ? AND title = ? AND model = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("findCacheKey prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, artist, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, model, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }

    public func cachedFeatures(forKey key: String,
                                model: String = "htdemucs") async throws -> StemSeparationResult? {
        try await ensureStarted()
        return try cacheLookup(cacheKey: key, model: model)
    }

    /// Public cache write — mirrors `StemFeatureProvider.putCachedFeatures`.
    /// Used by the CloudKit fetch path to persist a downloaded blob
    /// to the local SQLite cache.
    public func putCachedFeatures(
        forKey key: String,
        featuresBlob: Data,
        stemsMeta: [(name: String, nFrames: Int)],
        model: String = "htdemucs",
        durationSeconds: Double? = nil,
        title: String? = nil,
        artist: String? = nil
    ) async throws {
        try await ensureStarted()
        let metaArray: [[String: Any]] = stemsMeta.map {
            ["name": $0.name, "n_frames": $0.nFrames]
        }
        let metaData = try JSONSerialization.data(withJSONObject: metaArray)
        let metaJSON = String(data: metaData, encoding: .utf8) ?? "[]"
        try cacheStoreRaw(
            cacheKey: key, model: model,
            protocolVersion: Self.protocolVersion,
            durationSeconds: durationSeconds ?? 0,
            title: title, artist: artist,
            createdAt: Int(Date().timeIntervalSince1970),
            blob: featuresBlob, stemsMetaJSON: metaJSON
        )
    }

    /// Enumerate every cache row (no blobs — just metadata). Mirrors
    /// `StemFeatureProvider.cacheAudit`.
    public func cacheAudit() async throws -> [StemCacheRow] {
        try await ensureStarted()
        var rows: [StemCacheRow] = []
        var stmt: OpaquePointer?
        let sql = """
            SELECT cache_key, model, protocol_version, duration_seconds,
                   title, artist, created_at,
                   LENGTH(features_blob) AS file_size_bytes,
                   stems_meta
              FROM stem_features ORDER BY created_at DESC
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("cacheAudit prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cacheKey = String(cString: sqlite3_column_text(stmt, 0))
            let modelStr = String(cString: sqlite3_column_text(stmt, 1))
            let pv = Int(sqlite3_column_int(stmt, 2))
            let durRaw = sqlite3_column_double(stmt, 3)
            let dur: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : durRaw
            let title = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let artist = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let createdAt = Int(sqlite3_column_int64(stmt, 6))
            let sizeBytes = Int(sqlite3_column_int64(stmt, 7))
            // Decode stems_meta JSON to count frames (= sum of per-stem n_frames? no — n_frames is the first stem's count, all stems have the same)
            let metaText = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            var nFrames = 0
            if let metaText, let data = metaText.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first,
               let n = first["n_frames"] as? Int {
                nFrames = n
            }
            rows.append(StemCacheRow(
                cacheKey: cacheKey, model: modelStr, protocolVersion: pv,
                durationSeconds: dur, title: title, artist: artist,
                createdAt: createdAt, fileSizeBytes: sizeBytes, nFrames: nFrames
            ))
        }
        return rows
    }

    /// Delete a single cache row by key. Mirrors
    /// `StemFeatureProvider.deleteCacheRow`. Returns true when a row
    /// actually got deleted.
    @discardableResult
    public func deleteCacheRow(forKey key: String) async throws -> Bool {
        try await ensureStarted()
        var stmt: OpaquePointer?
        let sql = "DELETE FROM stem_features WHERE cache_key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("delete prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StemSidecarError.sidecarError(message: sqlError("delete exec"), trace: nil)
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Audio loading

    /// Minimal mono/stereo float32 buffer at a known sample rate.
    struct LoadedAudio {
        let samples: [Float]   // interleaved-by-channel: [c0_s0, c1_s0, c0_s1, c1_s1, ...]
        let channels: Int
        let frameCount: Int    // samples / channels
    }

    /// Load any AV-decodable file, convert to `targetSampleRate` Float32
    /// stereo (or mono → duplicated to stereo). Output samples are
    /// laid out non-interleaved (channel-contiguous): first all of
    /// channel 0, then all of channel 1.
    static func loadAudio(at url: URL, targetSampleRate: Int) throws -> LoadedAudio {
        let file = try AVAudioFile(forReading: url)
        let srcFmt = file.processingFormat
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 2,
            interleaved: false
        )!
        let conv = AVAudioConverter(from: srcFmt, to: outFmt)!

        // Read whole file (acceptable for small files; chunking lands later).
        let srcCap = AVAudioFrameCount(file.length)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: srcCap) else {
            throw StemSidecarError.sidecarError(message: "PCMBuffer alloc failed", trace: nil)
        }
        try file.read(into: srcBuf)

        // Output capacity scaled by sample-rate ratio + padding.
        let ratio = Double(targetSampleRate) / srcFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw StemSidecarError.sidecarError(message: "out buffer alloc failed", trace: nil)
        }
        var consumed = false
        var convErr: NSError?
        let _ = conv.convert(to: outBuf, error: &convErr) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return srcBuf
        }
        if let convErr {
            throw StemSidecarError.sidecarError(
                message: "audio convert: \(convErr.localizedDescription)", trace: nil
            )
        }

        let frames = Int(outBuf.frameLength)
        let ch = Int(outFmt.channelCount)
        var out = [Float](repeating: 0, count: frames * ch)
        guard let chData = outBuf.floatChannelData else {
            throw StemSidecarError.sidecarError(message: "no floatChannelData", trace: nil)
        }
        // Non-interleaved layout: channel 0 first, then channel 1.
        for c in 0 ..< ch {
            for i in 0 ..< frames {
                out[c * frames + i] = chData[c][i]
            }
        }
        return LoadedAudio(samples: out, channels: ch, frameCount: frames)
    }

    // MARK: - Model run

    /// Chunked separation following sidecar.py's pattern: 8-second
    /// chunks (~one model `segment`), run model forward per chunk,
    /// concatenate per-stem stereo audio. Features get derived ONCE
    /// at the end on the full concatenated audio (v3 fix from sidecar
    /// — librosa's center=True would otherwise inject ~1s of skew
    /// across all the per-chunk boundaries).
    private func runChunked(
        audio: LoadedAudio,
        throttleMS: Int
    ) async throws -> [String: (left: [Float], right: [Float])] {
        guard let model else {
            throw StemSidecarError.notStarted
        }

        // Chunk length must be <= htdemucs's training segment
        // (7.8s for the default model). I had hardcoded 8.0s here and
        // it tripped HTDemucs.forward's `mix.shape.last <= trainingLength`
        // precondition on the first real song longer than 8 seconds.
        // Read from the model so the chunker is always correct even if
        // a future model is swapped in. Subtract a tiny epsilon so an
        // integer-sample round-up never pushes us over.
        let chunkSec = max(0.5, Double(model.segment) - 0.01)
        let chunkSamples = Int(chunkSec * Double(Self.sampleRate))
        let nSamples = audio.frameCount
        let nChunks = (nSamples + chunkSamples - 1) / chunkSamples
        let sources = model.sources

        // Per-stem audio accumulators (channel-major to match LoadedAudio layout).
        var leftAccum: [String: [Float]] = [:]
        var rightAccum: [String: [Float]] = [:]
        for s in sources {
            leftAccum[s] = []; leftAccum[s]!.reserveCapacity(nSamples)
            rightAccum[s] = []; rightAccum[s]!.reserveCapacity(nSamples)
        }

        // audio.samples is laid out [channel 0 then channel 1], each of length nSamples.
        let leftStart = 0
        let rightStart = nSamples

        for chunkIdx in 0 ..< nChunks {
            if cancellationFlag {
                throw StemSidecarError.abandoned(reason: "cancelled at chunk \(chunkIdx)/\(nChunks)")
            }
            let pos = chunkIdx * chunkSamples
            let end = min(pos + chunkSamples, nSamples)
            let len = end - pos

            // Build the chunk as a contiguous Float buffer in (1, 2, len).
            // Pull left[pos..end] then right[pos..end] from audio.samples.
            var chunkBuf = [Float](repeating: 0, count: 2 * len)
            for i in 0 ..< len {
                chunkBuf[i] = audio.samples[leftStart + pos + i]
                chunkBuf[len + i] = audio.samples[rightStart + pos + i]
            }
            let mix = MLXArray(chunkBuf, [1, 2, len])
            let outArr = model(mix)
            eval(outArr)
            let outShape = outArr.shape
            let T = outShape[3]
            // Trim model output to the chunk's actual length (model pads
            // short inputs to its training segment internally and then
            // trims; defensively trim here too).
            let trim = min(T, len)
            let flat: [Float] = outArr[0].asArray(Float.self)
            for (sIdx, src) in sources.enumerated() {
                // (S, C, T) layout: stem sIdx starts at sIdx * 2 * T.
                let stemBase = sIdx * 2 * T
                let leftPtr = stemBase
                let rightPtr = stemBase + T
                leftAccum[src]!.append(contentsOf: flat[leftPtr ..< (leftPtr + trim)])
                rightAccum[src]!.append(contentsOf: flat[rightPtr ..< (rightPtr + trim)])
            }

            // Progress report — sidecar reserves the last 10% for feature derivation.
            let fraction = Double(chunkIdx + 1) / Double(nChunks) * 0.9
            onProgress?(fraction)

            // Throttle between chunks (not after the last one).
            if throttleMS > 0 && chunkIdx < nChunks - 1 {
                try? await Task.sleep(nanoseconds: UInt64(throttleMS) * 1_000_000)
            }
        }

        var result: [String: (left: [Float], right: [Float])] = [:]
        for s in sources {
            result[s] = (left: leftAccum[s]!, right: rightAccum[s]!)
        }
        return result
    }

    // MARK: - Features

    /// Derive per-stem chromagram + rms + onset (mono'd to mean of
    /// channels), returning the `StemFeatures` map ready for packing.
    private func deriveAllFeatures(
        stems: [String: (left: [Float], right: [Float])]
    ) throws -> [String: StemFeatures] {
        guard let deriver else {
            throw StemSidecarError.notStarted
        }
        var out: [String: StemFeatures] = [:]
        for (name, channels) in stems {
            // Mono mix: per-sample mean of L+R.
            let n = channels.left.count
            var mono = [Float](repeating: 0, count: n)
            for i in 0 ..< n {
                mono[i] = (channels.left[i] + channels.right[i]) * 0.5
            }
            let f = deriver.derive(mono: mono)
            // Reshape flat chroma [N*12] into [N][12] for StemFeatures.
            var chromaRows: [[Float]] = []
            chromaRows.reserveCapacity(f.nFrames)
            for frame in 0 ..< f.nFrames {
                let base = frame * 12
                chromaRows.append(Array(f.chromagram[base ..< (base + 12)]))
            }
            out[name] = StemFeatures(
                chromagram: chromaRows,
                loudness: f.loudness,
                onset: f.onset,
                nFrames: f.nFrames
            )
        }
        return out
    }

    // MARK: - Binary packer (HVSF v2)

    /// Pack `features` into the HVSF v2 binary blob format that
    /// sidecar.py emits. Layout documented in `StemFeatureProvider.unpackBinaryStems`:
    ///
    ///   Header (8 bytes): "HVSF" magic | u8 version=2 | u8 chroma_bins=12 | 2B reserved
    ///   Per stem (in iteration order — drums/bass/other/vocals):
    ///     u32 LE name_length, name bytes (UTF-8),
    ///     u32 LE n_frames,
    ///     float32 LE [n_frames * 12] chromagram (row-major),
    ///     float32 LE [n_frames] loudness,
    ///     u8[ceil(n_frames/8)] onset (LSB-first bits within each byte).
    ///
    /// Returns (blob, stemsMetaJSON) — the JSON encodes per-stem
    /// {name, n_frames} in iteration order so the Swift unpacker can
    /// recover the exact byte offsets.
    private func packStems(_ features: [String: StemFeatures]) -> (Data, String) {
        // Stable iteration order — htdemucs's source order.
        let order = ["drums", "bass", "other", "vocals"]
        var blob = Data()

        // Header.
        blob.append(contentsOf: [0x48, 0x56, 0x53, 0x46])  // "HVSF"
        blob.append(UInt8(Self.protocolVersion))           // version
        blob.append(UInt8(12))                              // chroma_bins
        blob.append(contentsOf: [0, 0])                    // reserved

        var metaList: [[String: Any]] = []
        for name in order {
            guard let f = features[name] else { continue }
            let nFrames = f.nFrames
            metaList.append(["name": name, "n_frames": nFrames])

            // u32 LE name_length, name bytes.
            let nameBytes = Array(name.utf8)
            blob.append(u32LE(UInt32(nameBytes.count)))
            blob.append(contentsOf: nameBytes)

            // u32 LE n_frames.
            blob.append(u32LE(UInt32(nFrames)))

            // float32 LE [n_frames * 12] chromagram, row-major.
            var chromaFlat = [Float](); chromaFlat.reserveCapacity(nFrames * 12)
            for row in f.chromagram { chromaFlat.append(contentsOf: row) }
            chromaFlat.withUnsafeBufferPointer { p in
                blob.append(Data(buffer: p))
            }

            // float32 LE [n_frames] loudness.
            f.loudness.withUnsafeBufferPointer { p in
                blob.append(Data(buffer: p))
            }

            // u8[ceil(nFrames/8)] onset, LSB-first within byte.
            let nBytes = (nFrames + 7) / 8
            var onsetBytes = [UInt8](repeating: 0, count: nBytes)
            for (frame, on) in f.onset.enumerated() where on {
                onsetBytes[frame >> 3] |= UInt8(1 << (frame & 7))
            }
            blob.append(contentsOf: onsetBytes)
        }

        // Encode meta to JSON (sidecar uses snake_case for n_frames).
        let metaJSON: String
        if let metaData = try? JSONSerialization.data(withJSONObject: metaList) {
            metaJSON = String(data: metaData, encoding: .utf8) ?? "[]"
        } else {
            metaJSON = "[]"
        }
        return (blob, metaJSON)
    }

    private func u32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    // MARK: - Cache lookup / store

    /// Returns the cached row decoded into a `StemSeparationResult`,
    /// or nil if no row (or wrong model / protocol version).
    private func cacheLookup(cacheKey: String, model expectedModel: String) throws -> StemSeparationResult? {
        var stmt: OpaquePointer?
        let sql = """
            SELECT model, protocol_version, duration_seconds, title, artist,
                   created_at, features_blob, stems_meta
              FROM stem_features WHERE cache_key = ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("lookup prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let modelStr = String(cString: sqlite3_column_text(stmt, 0))
        let pv = Int(sqlite3_column_int(stmt, 1))
        guard modelStr == expectedModel, pv == Self.protocolVersion else {
            return nil
        }
        let dur = sqlite3_column_double(stmt, 2)
        let blobLen = Int(sqlite3_column_bytes(stmt, 6))
        let storedBlob = Data(bytes: sqlite3_column_blob(stmt, 6)!, count: blobLen)
        let metaJSON = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"

        // The Python sidecar gzips before SQLite write; my first
        // Phase 2 Swift writes did not. Transparently handle both:
        // detect gzip magic 1f8b → gunzip; otherwise treat as raw
        // HVSF (the format my pre-fix Swift backend wrote).
        let blob: Data
        if GzipCompression.isGzipped(storedBlob) {
            do {
                blob = try GzipCompression.decompress(storedBlob)
            } catch {
                throw StemSidecarError.sidecarError(
                    message: "cache row \(cacheKey) is gzipped but inflate failed: \(error)",
                    trace: nil
                )
            }
        } else {
            blob = storedBlob
        }

        // Decode by routing through StemSeparationResult.fromCloudPayload
        // — same unpacker code path the CloudKit downloader uses.
        return try StemSeparationResult.fromCloudPayload(
            model: modelStr,
            sampleRate: Self.sampleRate,
            frameRate: Self.frameRate,
            durationSeconds: dur,
            stemsMetaJSON: metaJSON,
            featuresBlob: blob
        )
    }

    private func cacheStore(
        cacheKey: String, model: String, durationSeconds: Double,
        title: String?, artist: String?,
        blob: Data, stemsMetaJSON: String
    ) throws {
        let createdAt = Int(Date().timeIntervalSince1970)
        try cacheStoreRaw(
            cacheKey: cacheKey, model: model, protocolVersion: Self.protocolVersion,
            durationSeconds: durationSeconds,
            title: title, artist: artist,
            createdAt: createdAt, blob: blob, stemsMetaJSON: stemsMetaJSON
        )
    }

    private func cacheStoreRaw(
        cacheKey: String, model: String, protocolVersion: Int,
        durationSeconds: Double,
        title: String?, artist: String?,
        createdAt: Int, blob: Data, stemsMetaJSON: String?
    ) throws {
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO stem_features
              (cache_key, model, protocol_version, duration_seconds,
               title, artist, created_at, features_blob, stems_meta)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StemSidecarError.sidecarError(message: sqlError("store prepare"), trace: nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(protocolVersion))
        sqlite3_bind_double(stmt, 4, durationSeconds)
        if let title { sqlite3_bind_text(stmt, 5, title, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
        if let artist { sqlite3_bind_text(stmt, 6, artist, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_int64(stmt, 7, Int64(createdAt))
        // Gzip before write so the row is bit-compatible with what
        // the Python sidecar would produce. compresslevel=6 matches
        // sidecar.py's `gzip.compress(..., compresslevel=6)`. Caller
        // passes the raw HVSF blob — we wrap it here so every code
        // path that hits cacheStoreRaw stays in one place.
        let blobToStore: Data
        do {
            blobToStore = try GzipCompression.compress(blob, level: 6)
        } catch {
            throw StemSidecarError.sidecarError(
                message: "gzip failed on cache write \(cacheKey): \(error)",
                trace: nil
            )
        }
        _ = blobToStore.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 8, raw.baseAddress, Int32(blobToStore.count), SQLITE_TRANSIENT)
        }
        if let m = stemsMetaJSON { sqlite3_bind_text(stmt, 9, m, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StemSidecarError.sidecarError(message: sqlError("store exec"), trace: nil)
        }
    }

    // MARK: - Misc

    private func ensureStarted() async throws {
        if model == nil || db == nil { try await start() }
    }

    private func openCache() throws {
        let dir = configuration.cachePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if sqlite3_open(configuration.cachePath.path, &db) != SQLITE_OK {
            throw StemSidecarError.sidecarError(message: sqlError("open"), trace: nil)
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS stem_features (
                cache_key TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                protocol_version INTEGER NOT NULL,
                duration_seconds REAL,
                title TEXT,
                artist TEXT,
                created_at INTEGER NOT NULL,
                features_blob BLOB NOT NULL,
                stems_meta TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_artist_title ON stem_features(artist, title);
            """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            throw StemSidecarError.sidecarError(message: sqlError("schema"), trace: nil)
        }
        _ = sqlite3_exec(db, "ALTER TABLE stem_features ADD COLUMN stems_meta TEXT", nil, nil, nil)
    }

    private func sqlError(_ ctx: String) -> String {
        let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        return "\(ctx): \(msg)"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self
)
