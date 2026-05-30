//
//  StemFeatureProvider.swift
//
//  Swift client for the demucs-mlx Python sidecar. Spawns the
//  long-lived sidecar.py process at start(), serializes
//  newline-delimited JSON requests over stdin, and decodes responses
//  on stdout into typed `StemSeparationResult`.
//
//  Concurrency model: ONE in-flight separation at a time. Requests
//  are queued via an actor so multiple callers can `await` concurrently
//  but the model only processes one song at a time (which is the
//  ground truth — htdemucs is not parallelizable across songs without
//  loading multiple model copies, and we don't want the RAM blow-up).
//
//  This file is intentionally self-contained and Foundation-only —
//  no RealityKit / Combine deps — so it can be lifted into either an
//  app target or another package without dragging dependencies.
//

import Foundation

// MARK: - Public types

/// Per-stem derived features. All arrays are length `nFrames` and aligned
/// to a 30 fps timeline (`frameRate` from the parent result).
public struct StemFeatures: Sendable, Codable {
    /// `[nFrames][12]` — max-bin normalized chromagram. Each row sums
    /// to some value <= 12; the dominant pitch in each row is 1.0.
    public let chromagram: [[Float]]
    /// `[nFrames]` — per-frame RMS loudness, roughly 0..1.
    public let loudness: [Float]
    /// `[nFrames]` — peak-picked onsets (true on frames where librosa
    /// detected an onset event).
    public let onset: [Bool]
    /// Convenience — equals `chromagram.count` / `loudness.count` / `onset.count`.
    public let nFrames: Int

    enum CodingKeys: String, CodingKey {
        case chromagram, loudness, onset
        case nFrames = "n_frames"
    }
}

/// Complete result of a separation request. Keyed by canonical stem
/// name: "drums", "bass", "other", "vocals" for the default htdemucs.
///
/// Wire format (PROTOCOL_VERSION 2): the JSON envelope carries
/// `stems_meta` (a small array of `{name, n_frames}` records) and
/// `features_b64` (a base64-encoded packed binary blob containing all
/// stems' chromagram / loudness / onset timelines). The custom
/// `init(from:)` here decodes the JSON envelope, base64-decodes the
/// blob, and walks the binary layout to populate `stems`. Eliminates
/// the ~700ms JSON-array (de)serialization tax on cache hits.
public struct StemSeparationResult: Sendable, Codable {
    public let model: String
    public let sampleRate: Int
    public let frameRate: Int
    public let stems: [String: StemFeatures]
    public let timing: Timing
    /// True when the sidecar returned this result from its SQLite cache
    /// instead of running fresh separation. False on uncached / forced
    /// computations. Useful for telemetry + for showing the user that
    /// stems landed instantly vs after a wait.
    public let fromCache: Bool
    /// Duration of the source audio in seconds, as observed by the
    /// sidecar. Returned both on fresh + cached results.
    public let durationSeconds: Double?

    /// Raw packed-binary feature blob from the original wire envelope,
    /// retained so the result can be re-uploaded to the CloudKit
    /// public DB (#5) without re-packing on the Swift side. Nil when
    /// the result was constructed via the public init (e.g., from a
    /// cloud payload — we don't currently echo cloud-derived results
    /// back to the cloud since they're already there).
    internal let rawFeaturesBlob: Data?
    /// Raw stems-meta JSON from the original wire envelope. Paired
    /// with `rawFeaturesBlob` for cloud re-upload — the JSON encodes
    /// the per-stem byte layout in the blob's exact iteration order
    /// (which Python dicts preserve but Swift dicts don't).
    internal let rawStemsMetaJSON: String?

    public struct Timing: Sendable, Codable {
        public let separationSeconds: Double
        public let featureSeconds: Double

        enum CodingKeys: String, CodingKey {
            case separationSeconds = "separation_seconds"
            case featureSeconds = "feature_seconds"
        }
    }

    /// Tiny wire-only struct describing one stem's location inside
    /// the packed binary blob. The Swift unpacker iterates this in
    /// order; the per-stem byte layout in the blob follows the same
    /// order.
    private struct StemMeta: Codable {
        let name: String
        let nFrames: Int
        enum CodingKeys: String, CodingKey {
            case name
            case nFrames = "n_frames"
        }
    }

    /// Public init for internal construction (the CloudKit
    /// public-cache path will build results directly from a downloaded
    /// blob without going through JSON).
    public init(
        model: String,
        sampleRate: Int,
        frameRate: Int,
        stems: [String: StemFeatures],
        timing: Timing,
        fromCache: Bool,
        durationSeconds: Double?
    ) {
        self.model = model
        self.sampleRate = sampleRate
        self.frameRate = frameRate
        self.stems = stems
        self.timing = timing
        self.fromCache = fromCache
        self.durationSeconds = durationSeconds
        self.rawFeaturesBlob = nil
        self.rawStemsMetaJSON = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.sampleRate = try c.decode(Int.self, forKey: .sampleRate)
        self.frameRate = try c.decode(Int.self, forKey: .frameRate)
        self.timing = try c.decode(Timing.self, forKey: .timing)
        self.fromCache = (try? c.decode(Bool.self, forKey: .fromCache)) ?? false
        self.durationSeconds = try? c.decode(Double.self, forKey: .durationSeconds)

        let meta = try c.decode([StemMeta].self, forKey: .stemsMeta)
        let b64 = try c.decode(String.self, forKey: .featuresB64)
        guard let blob = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .featuresB64, in: c,
                debugDescription: "features_b64 not valid base64")
        }
        self.stems = try StemSeparationResult.unpackBinaryStems(blob, meta: meta)
        self.rawFeaturesBlob = blob
        // Re-encode meta back into JSON for stable round-tripping. Cheap
        // — meta is a list of {name, n_frames} dicts; encoding 4 entries
        // is microseconds.
        if let metaData = try? JSONEncoder().encode(meta),
           let metaString = String(data: metaData, encoding: .utf8) {
            self.rawStemsMetaJSON = metaString
        } else {
            self.rawStemsMetaJSON = nil
        }
    }

    /// Encode is provided for Codable completeness but produces a
    /// shape the sidecar wouldn't accept back (we only ever decode,
    /// never re-encode). Re-encoding `stems` here as `stems_meta` +
    /// base64-encoded binary would mean implementing the packer
    /// twice — skipped until there's an actual round-trip need.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(timing, forKey: .timing)
        try c.encode(fromCache, forKey: .fromCache)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case model, timing
        case sampleRate = "sample_rate"
        case frameRate = "frame_rate"
        case fromCache = "from_cache"
        case durationSeconds = "duration_seconds"
        case stemsMeta = "stems_meta"
        case featuresB64 = "features_b64"
    }

    // MARK: - Cloud-cache adapter

    /// Construct a StemSeparationResult from a CloudKit public-DB
    /// download. The cloud record stores `featuresBlob` (raw packed
    /// binary, gzipped by CloudKit at the asset layer — already
    /// un-gzipped by the time it lands in `featuresBlob` here) and
    /// `stemsMetaJSON` (the same little array we send over the wire).
    /// This bridges those into a fully-decoded result, mirroring what
    /// the JSON path produces from the sidecar.
    public static func fromCloudPayload(
        model: String,
        sampleRate: Int,
        frameRate: Int,
        durationSeconds: Double?,
        stemsMetaJSON: String,
        featuresBlob: Data
    ) throws -> StemSeparationResult {
        guard let metaData = stemsMetaJSON.data(using: .utf8) else {
            throw StemSidecarError.protocolViolation("stemsMetaJSON not UTF-8")
        }
        let meta = try JSONDecoder().decode([StemMeta].self, from: metaData)
        let stems = try unpackBinaryStems(featuresBlob, meta: meta)
        // Retain the raw blob + meta so the caller can persist this
        // result into the local SQLite cache via
        // `StemFeatureProvider.putCachedFeatures` (avoids re-fetching
        // from CloudKit on every subsequent play).
        return StemSeparationResult(
            model: model,
            sampleRate: sampleRate,
            frameRate: frameRate,
            stems: stems,
            timing: Timing(separationSeconds: 0, featureSeconds: 0),
            fromCache: true,
            durationSeconds: durationSeconds,
            rawFeaturesBlob: featuresBlob,
            rawStemsMetaJSON: stemsMetaJSON
        )
    }

    /// Internal init that lets cloud / cache pathways construct a
    /// result with the raw wire-format payload retained alongside the
    /// decoded stems. Public callers should use the simpler
    /// `init(model:sampleRate:...)` above.
    internal init(
        model: String,
        sampleRate: Int,
        frameRate: Int,
        stems: [String: StemFeatures],
        timing: Timing,
        fromCache: Bool,
        durationSeconds: Double?,
        rawFeaturesBlob: Data?,
        rawStemsMetaJSON: String?
    ) {
        self.model = model
        self.sampleRate = sampleRate
        self.frameRate = frameRate
        self.stems = stems
        self.timing = timing
        self.fromCache = fromCache
        self.durationSeconds = durationSeconds
        self.rawFeaturesBlob = rawFeaturesBlob
        self.rawStemsMetaJSON = rawStemsMetaJSON
    }

    // MARK: - Binary unpacker (v2 wire/storage format)

    /// Walk the packed binary blob and reconstruct the per-stem
    /// feature timelines. Layout matches the sidecar's
    /// `_pack_features_binary`:
    ///
    ///   Header (8 bytes): "HVSF" magic | u8 version | u8 chroma_bins | 2B reserved
    ///   Per stem (repeated in `meta` order):
    ///     u32 LE name_length, name bytes (UTF-8),
    ///     u32 LE n_frames,
    ///     float32 LE [n_frames * chroma_bins] chromagram (row-major),
    ///     float32 LE [n_frames] loudness,
    ///     u8[ceil(n_frames/8)] onset (LSB-first within each byte).
    private static func unpackBinaryStems(
        _ blob: Data, meta: [StemMeta]
    ) throws -> [String: StemFeatures] {
        guard blob.count >= 8 else {
            throw StemSidecarError.protocolViolation("binary blob too short for header")
        }
        // Magic "HVSF"
        let magic: [UInt8] = [0x48, 0x56, 0x53, 0x46]
        for i in 0..<4 where blob[blob.startIndex + i] != magic[i] {
            throw StemSidecarError.protocolViolation("binary blob missing HVSF magic")
        }
        let version = blob[blob.startIndex + 4]
        let chromaBins = Int(blob[blob.startIndex + 5])
        guard version == 2 else {
            throw StemSidecarError.protocolViolation(
                "unsupported binary version \(version) (expected 2)")
        }
        guard chromaBins == 12 else {
            throw StemSidecarError.protocolViolation(
                "unexpected chromaBins \(chromaBins) (expected 12)")
        }

        var offset = blob.startIndex + 8
        var stems: [String: StemFeatures] = [:]
        stems.reserveCapacity(meta.count)

        for m in meta {
            // name length + bytes
            guard offset + 4 <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated at stem name length")
            }
            let nameLen = Int(readU32LE(blob, at: offset))
            offset += 4
            guard offset + nameLen <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated at stem name bytes")
            }
            // We skip the in-blob name — `meta[i].name` is the source
            // of truth for the keying. Verifying byte-equality here
            // would be belt-and-braces; not worth the cost.
            offset += nameLen
            guard offset + 4 <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated at n_frames")
            }
            let nFrames = Int(readU32LE(blob, at: offset))
            offset += 4
            guard nFrames == m.nFrames else {
                throw StemSidecarError.protocolViolation(
                    "n_frames mismatch for stem \(m.name): meta=\(m.nFrames) blob=\(nFrames)")
            }

            // chromagram: nFrames * chromaBins float32, row-major
            let chromaCount = nFrames * chromaBins
            let chromaBytes = chromaCount * MemoryLayout<Float>.size
            guard offset + chromaBytes <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated chromagram for \(m.name)")
            }
            var chromaFlat = [Float](repeating: 0, count: chromaCount)
            chromaFlat.withUnsafeMutableBytes { dst in
                blob.copyBytes(to: dst, from: offset..<offset + chromaBytes)
            }
            offset += chromaBytes
            var chromagram = [[Float]]()
            chromagram.reserveCapacity(nFrames)
            for f in 0..<nFrames {
                let start = f * chromaBins
                chromagram.append(Array(chromaFlat[start..<start + chromaBins]))
            }

            // loudness: nFrames float32
            let loudBytes = nFrames * MemoryLayout<Float>.size
            guard offset + loudBytes <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated loudness for \(m.name)")
            }
            var loudness = [Float](repeating: 0, count: nFrames)
            loudness.withUnsafeMutableBytes { dst in
                blob.copyBytes(to: dst, from: offset..<offset + loudBytes)
            }
            offset += loudBytes

            // onset: ceil(nFrames / 8) bytes, LSB-first within byte
            let onsetBytes = (nFrames + 7) / 8
            guard offset + onsetBytes <= blob.endIndex else {
                throw StemSidecarError.protocolViolation("truncated onset for \(m.name)")
            }
            var onset = [Bool](repeating: false, count: nFrames)
            for f in 0..<nFrames {
                let byte = blob[offset + (f >> 3)]
                onset[f] = ((byte >> (f & 7)) & 0x01) == 0x01
            }
            offset += onsetBytes

            stems[m.name] = StemFeatures(
                chromagram: chromagram,
                loudness: loudness,
                onset: onset,
                nFrames: nFrames
            )
        }
        return stems
    }

    private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

/// One row in the stem-features cache, as returned by
/// `cacheAudit()`. Lean shape — metadata + payload-shape signature
/// only; no feature timelines. Used by [[StemCacheAuditor]] to find
/// rows whose metadata disagrees with the underlying stem data
/// (alias-bug corruption from prior Shazam misidentifications).
public struct StemCacheRow: Sendable, Codable {
    public let cacheKey: String
    public let model: String
    public let protocolVersion: Int
    public let durationSeconds: Double?
    public let title: String?
    public let artist: String?
    public let createdAt: Int
    public let fileSizeBytes: Int
    public let nFrames: Int

    enum CodingKeys: String, CodingKey {
        case cacheKey = "cache_key"
        case model
        case protocolVersion = "protocol_version"
        case durationSeconds = "duration_seconds"
        case title, artist
        case createdAt = "created_at"
        case fileSizeBytes = "file_size_bytes"
        case nFrames = "n_frames"
    }
}

/// Reported by `cacheStats()` — diagnostic counts for the persistent
/// stem-features cache.
public struct StemCacheStats: Sendable, Codable {
    public let entries: Int
    public let sizeBytes: Int
    public let cachePath: String
    public let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case entries
        case sizeBytes = "size_bytes"
        case cachePath = "cache_path"
        case protocolVersion = "protocol_version"
    }
}

/// Surface for errors from the sidecar bridge.
public enum StemSidecarError: Error, CustomStringConvertible, Sendable {
    case notStarted
    case sidecarExited(code: Int32, stderr: String)
    case protocolViolation(String)
    case sidecarError(message: String, trace: String?)
    case decodingFailed(underlying: String)
    case timedOut
    /// Sidecar returned an abandoned-result envelope — the in-flight
    /// separate() was preempted by an `abandon()` call. Thrown from
    /// `separate(...)` so the caller can distinguish "user changed
    /// their mind" from real failures.
    case abandoned(reason: String)

    public var description: String {
        switch self {
        case .notStarted:
            return "sidecar not started — call start() first"
        case .sidecarExited(let code, let stderr):
            return "sidecar exited with code \(code). stderr:\n\(stderr)"
        case .protocolViolation(let msg):
            return "sidecar protocol violation: \(msg)"
        case .sidecarError(let msg, let trace):
            return "sidecar reported error: \(msg)\n\(trace ?? "")"
        case .decodingFailed(let msg):
            return "couldn't decode sidecar response: \(msg)"
        case .timedOut:
            return "sidecar request timed out"
        case .abandoned(let reason):
            return "separation abandoned: \(reason)"
        }
    }
}

// MARK: - Wire protocol

/// Sidecar's "ready" banner emitted once at startup.
private struct ReadyBanner: Codable {
    let status: String
    let model: String
    let frameRate: Int
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case status, model
        case frameRate = "frame_rate"
        case protocolVersion = "protocol_version"
    }
}

/// Generic response envelope — the `result` field varies per action,
/// so we decode the envelope first and then re-decode the inner result
/// against the appropriate type for the action that was sent.
private struct ResponseEnvelope: Codable {
    let status: String
    let requestId: Int?
    let error: String?
    let trace: String?

    enum CodingKeys: String, CodingKey {
        case status, error, trace
        case requestId = "request_id"
    }
}

// MARK: - The provider

/// Long-lived bridge to the demucs-mlx Python sidecar.
///
/// Lifecycle:
///   • `start()` spawns the Python process and waits for its "ready"
///     banner. Throws on missing binaries or non-zero exit.
///   • `ping()` / `separate(filePath:)` send requests and await
///     responses. They're queued by the actor — one in flight at a time.
///   • `stop()` sends a quit request and waits for clean exit. Safe to
///     call from a deinit-like context.
///
/// Path conventions: this provider needs absolute paths to both the
/// Python interpreter and the sidecar script — see
/// `Configuration.localDevDefaults()` for the values used during
/// Phase 1 prototyping. For shipping we'll bundle the sidecar + a
/// venv inside the .app and compute paths relative to Bundle.main.
///
/// **Platform note:** the real implementation lives under
/// `#if os(macOS)` because it depends on `Process` (macOS-only) to
/// spawn the Python sidecar. The `#else` branch below defines a
/// stub actor with the same public API surface; every action throws
/// or no-ops. AppModel's stem-separation pipeline degrades gracefully
/// — `MusicAppNowPlaying().query()` already returns
/// `.musicAppNotRunning` on iOS, so `kickoffStemSeparation` early-
/// returns before ever calling into this stub.
#if os(macOS)
public actor StemFeatureProvider {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public let pythonExecutable: URL
        public let sidecarScript: URL
        public let model: String

        public init(pythonExecutable: URL, sidecarScript: URL, model: String = "htdemucs") {
            self.pythonExecutable = pythonExecutable
            self.sidecarScript = sidecarScript
            self.model = model
        }

        /// Hard-coded paths used during Phase 1 development against the
        /// local repo. These will fail on any other machine — when we
        /// productionize, replace with a `Bundle.main.url(forResource:)`
        /// lookup that finds the bundled sidecar inside .app/Contents/Resources.
        public static func localDevDefaults() -> Configuration {
            let repoRoot = "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer/StemAnalysis"
            return Configuration(
                pythonExecutable: URL(fileURLWithPath: "\(repoRoot)/.venv/bin/python"),
                sidecarScript: URL(fileURLWithPath: "\(repoRoot)/sidecar.py")
            )
        }
    }

    // MARK: State

    private let configuration: Configuration

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextRequestID: Int = 1

    /// Continuations for in-flight requests, keyed by request_id. Each
    /// continuation completes with the raw "result" Data so the caller's
    /// typed decoder can run against it.
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]

    /// Stdout-reader task; reads ndjson lines and dispatches them to
    /// the corresponding pending continuation.
    private var readerTask: Task<Void, Never>?

    /// Captured stderr — surfaced into the .sidecarExited error.
    private var capturedStderr: String = ""

    /// Optional callback invoked on each progress envelope emitted by
    /// the sidecar during a throttled separation. Argument is the
    /// fraction completed in `[0, 1]`. Called on a detached task so a
    /// slow consumer can't stall the actor's response routing.
    ///
    /// Set from outside the actor with `await provider.setOnProgress { ... }`.
    private var onProgress: (@Sendable (Double) -> Void)?

    public init(configuration: Configuration = .localDevDefaults()) {
        self.configuration = configuration
    }

    /// Register a callback invoked on each progress event from the
    /// sidecar (during throttled separations only — the fast path
    /// emits nothing intermediate). Pass nil to clear.
    public func setOnProgress(_ callback: (@Sendable (Double) -> Void)?) {
        self.onProgress = callback
    }

    /// Snapshot the current onProgress callback so a transient caller
    /// (e.g. the library batch cacher) can save it, install its own,
    /// do its work, and restore the original. Returning nil if no
    /// handler is currently set.
    public func currentOnProgress() -> (@Sendable (Double) -> Void)? {
        return self.onProgress
    }

    // MARK: Lifecycle

    /// Spawn the sidecar and wait for its `{"status":"ready"}` banner.
    /// Throws if the process exits before the banner arrives (usually
    /// means missing Python deps — check stderr in the error).
    public func start() async throws {
        guard process == nil else { return }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let proc = Process()
        proc.executableURL = configuration.pythonExecutable
        proc.arguments = [configuration.sidecarScript.path]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        // Lower-priority QoS so the sidecar's heavy compute work
        // (htdemucs inference burns ~60s of CPU + Metal on M1 Pro
        // during a fresh separation) doesn't compete with audio
        // threads. Music.app's audio render runs at QoS userInteractive
        // / userInitiated; demoting the sidecar to .utility tells
        // macOS to throttle it first when there's contention. Without
        // this, the user reported audio popping + animation hitching
        // when a fresh (uncached) song triggered separation.
        proc.qualityOfService = .utility
        // Unbuffer Python stdout so writes appear immediately —
        // belt-and-braces in case the Python side forgets to flush.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        try proc.run()
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Drain stderr in the background — capture into a buffer so we
        // can include it in any later error message.
        let stderrHandle = stderr.fileHandleForReading
        Task.detached { [weak self] in
            while let chunk = try? stderrHandle.read(upToCount: 4096), !chunk.isEmpty {
                if let str = String(data: chunk, encoding: .utf8) {
                    await self?.appendStderr(str)
                }
            }
        }

        // Read the ready banner synchronously (the first stdout line
        // must be it). We don't start the long-running reader task
        // until after the banner so banner-read errors are clean.
        let bannerLine = try await readLine(from: stdout.fileHandleForReading)
        guard let bannerData = bannerLine.data(using: .utf8) else {
            throw StemSidecarError.protocolViolation("ready banner not UTF-8")
        }
        let banner = try decodeOrThrow(ReadyBanner.self, from: bannerData)
        guard banner.status == "ready" else {
            throw StemSidecarError.protocolViolation(
                "expected ready banner, got status=\(banner.status)")
        }

        // Start the long-running reader. From here on every line on
        // stdout is a response envelope.
        startReaderTask()
    }

    /// Send the quit action and wait for the process to exit. Idempotent.
    public func stop() async {
        guard let proc = process else { return }

        // Best-effort: write "quit" and close stdin so the sidecar's
        // for-loop exits naturally.
        _ = try? writeLine("{\"action\":\"quit\"}")
        stdinPipe?.fileHandleForWriting.closeFile()

        // Wait up to 2 seconds for graceful exit, then terminate.
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            proc.terminate()
        }
        readerTask?.cancel()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: Public requests

    public func ping() async throws {
        struct PingResult: Codable { let pong: Bool }
        let result: PingResult = try await sendRequest(action: "ping", payload: [:])
        guard result.pong else {
            throw StemSidecarError.protocolViolation("ping result not pong")
        }
    }

    /// Separate an audio file and return per-stem feature timelines.
    ///
    /// First call against a given `cacheKey`: ~5-60 seconds wall-clock
    /// (model runs + features extract). Subsequent calls with the same
    /// key are sub-500ms cache hits (the bulk of which is JSON
    /// (de)serialization of the ~1.5 MB feature payload).
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the audio file on disk.
    ///   - cacheKey: Opaque string identifying this song for cache
    ///     lookup/store. The Shazam ID is the obvious choice when
    ///     available; a stable hash of (title, artist, album) works as
    ///     a fallback. Pass `nil` or empty to skip cache entirely.
    ///   - forceRefresh: When true, bypass the cache lookup and re-run
    ///     separation. The fresh result still gets written back to the
    ///     cache, overwriting any prior row for this key.
    ///   - model: Model name override; default htdemucs.
    ///   - title / artist: Optional metadata stored alongside the
    ///     cache row for diagnostics (cache_stats can be extended to
    ///     list entries by artist later).
    ///   - throttleMS: When non-zero, the sidecar processes audio in
    ///     short chunks and `time.sleep()`s this many ms between each
    ///     chunk so audio threads aren't starved. ~500ms is a good
    ///     value during active playback; 0 (default) runs at maximum
    ///     speed. Cache hits ignore this since they don't run inference.
    public func separate(
        filePath: String,
        cacheKey: String? = nil,
        forceRefresh: Bool = false,
        model: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        throttleMS: Int = 0
    ) async throws -> StemSeparationResult {
        var payload: [String: Any] = ["path": filePath]
        if let model { payload["model"] = model }
        if let cacheKey, !cacheKey.isEmpty { payload["cache_key"] = cacheKey }
        if forceRefresh { payload["force_refresh"] = true }
        if let title { payload["title"] = title }
        if let artist { payload["artist"] = artist }
        if throttleMS > 0 { payload["throttle_ms"] = throttleMS }
        return try await sendRequest(action: "separate", payload: payload)
    }

    /// Report cache size + entry count. Cheap — single SQL aggregate.
    public func cacheStats() async throws -> StemCacheStats {
        return try await sendRequest(action: "cache_stats", payload: [:])
    }

    /// Wipe every row from the local SQLite stem-features cache.
    /// CloudKit public-DB rows are untouched. Used when the user
    /// wants to reclaim disk space — invoke via a debug menu / lldb
    /// (no built-in UI surface yet, but the plumbing's here for one).
    /// Returns the number of rows deleted.
    @discardableResult
    public func clearAllCachedFeatures() async throws -> Int {
        struct ClearResult: Decodable {
            let cleared: Bool
            let rowsDeleted: Int

            enum CodingKeys: String, CodingKey {
                case cleared
                case rowsDeleted = "rows_deleted"
            }
        }
        let result: ClearResult = try await sendRequest(action: "cache_clear_all", payload: [:])
        if !result.cleared {
            throw StemSidecarError.sidecarError(
                message: "cache_clear_all returned cleared=false", trace: nil)
        }
        return result.rowsDeleted
    }

    /// Make `aliasKey` point at the same cached row that `primaryKey`
    /// already holds. Used when:
    ///   • stems were computed under `musicapp-pid-<id>` and Shazam
    ///     later identifies the song — adding the `shazam-<id>` alias
    ///     lets future plays (any library, any device once
    ///     [[cloudkit-cache-sync]]'d) hit by Shazam ID.
    ///   • the reverse — we first see Shazam ID at kickoff time and
    ///     want a pid alias for offline-only future plays.
    ///
    /// Returns the sidecar's `{aliased, reason?}` payload so callers
    /// can log the no-op cases ("primary not found", "alias already
    /// exists"). Cheap — single SQLite insert worst case.
    public struct AliasResult: Sendable, Codable {
        public let aliased: Bool
        public let reason: String?
    }

    public func alias(primaryKey: String, aliasKey: String) async throws -> AliasResult {
        let payload: [String: Any] = [
            "primary_key": primaryKey,
            "alias_key": aliasKey
        ]
        return try await sendRequest(action: "cache_alias", payload: payload)
    }

    /// Look up an existing cache row by (title, artist) — case-
    /// insensitive exact match on both fields. Returns the most
    /// recently created matching cache_key, or nil. Used when a song
    /// is identified by Shazam (so we have a clean title+artist) but
    /// no shazam-keyed row exists yet — typically because the song
    /// was previously cached under `hash-<sha256>` by
    /// LibraryBatchCacher's fallback path when its own Shazam
    /// identification didn't yield an ID for the file. Callers
    /// usually pair this with `alias(...)` to mint a shazam-keyed
    /// row pointing at the found content for instant lookups next
    /// time.
    public func findCacheKey(title: String, artist: String, model: String = "htdemucs") async throws -> String? {
        struct LookupEnvelope: Decodable {
            let found: Bool
            let cache_key: String?
        }
        let env: LookupEnvelope = try await sendRequest(
            action: "cache_find_by_metadata",
            payload: ["title": title, "artist": artist, "model": model]
        )
        return env.found ? env.cache_key : nil
    }

    /// Local-only cache lookup. Returns the cached result if present
    /// + protocol-compatible, nil otherwise. Used by AppModel to
    /// decide whether to skip the Demucs run in favor of the CloudKit
    /// public-DB shared cache before paying full compute cost.
    public func cachedFeatures(forKey key: String, model: String = "htdemucs") async throws -> StemSeparationResult? {
        struct LookupOnlyEnvelope: Decodable {
            let hit: Bool
            let envelope: StemSeparationResult?
        }
        let env: LookupOnlyEnvelope = try await sendRequest(
            action: "cache_lookup_only",
            payload: ["cache_key": key, "model": model]
        )
        return env.hit ? env.envelope : nil
    }

    /// Insert pre-computed binary features into the local SQLite
    /// cache. Used after a successful fetch from the CloudKit public
    /// DB so the result persists offline. `featuresBlob` is the raw
    /// (un-gzipped) packed binary; we'll base64 it for the JSON wire,
    /// and the sidecar gzips it for SQLite storage.
    public func putCachedFeatures(
        forKey key: String,
        featuresBlob: Data,
        stemsMeta: [(name: String, nFrames: Int)],
        model: String = "htdemucs",
        durationSeconds: Double? = nil,
        title: String? = nil,
        artist: String? = nil
    ) async throws {
        struct StoreResponse: Decodable {
            let stored: Bool
            let reason: String?
        }
        let metaArray: [[String: Any]] = stemsMeta.map { ["name": $0.name, "n_frames": $0.nFrames] }
        var payload: [String: Any] = [
            "cache_key": key,
            "features_b64": featuresBlob.base64EncodedString(),
            "stems_meta": metaArray,
            "model": model
        ]
        if let durationSeconds { payload["duration_seconds"] = durationSeconds }
        if let title { payload["title"] = title }
        if let artist { payload["artist"] = artist }
        let resp: StoreResponse = try await sendRequest(action: "cache_put_binary", payload: payload)
        if !resp.stored {
            throw StemSidecarError.sidecarError(
                message: "cache_put_binary failed: \(resp.reason ?? "(no reason)")",
                trace: nil)
        }
    }

    /// Enumerate every row in the local SQLite stem-features cache.
    /// Cheap — payload blobs are NOT returned; only the (cache_key,
    /// metadata, payload-shape signature) tuple per row, ordered
    /// newest-first. Used by [[StemCacheAuditor]] to find rows whose
    /// metadata disagrees with the underlying stem bytes.
    public func cacheAudit() async throws -> [StemCacheRow] {
        struct AuditResult: Decodable { let rows: [StemCacheRow] }
        let result: AuditResult = try await sendRequest(action: "cache_audit", payload: [:])
        return result.rows
    }

    /// Delete a single row by cache_key. Used by the "Verify stem
    /// cache" maintenance UI after the user confirms removal of a
    /// corrupted alias row. Returns true when a row was actually
    /// deleted; false when no row existed for the key (idempotent —
    /// not an error).
    @discardableResult
    public func deleteCacheRow(forKey key: String) async throws -> Bool {
        struct DeleteResult: Decodable {
            let deleted: Bool
            let rowsDeleted: Int
            enum CodingKeys: String, CodingKey {
                case deleted
                case rowsDeleted = "rows_deleted"
            }
        }
        let result: DeleteResult = try await sendRequest(
            action: "cache_delete", payload: ["cache_key": key])
        return result.deleted
    }

    /// Signal the sidecar to abandon any in-flight throttled separation
    /// at the next chunk boundary. Fire-and-forget — we don't await
    /// the ack here because the *real* effect is on the currently-
    /// awaited `separate()` call, which will throw
    /// `StemSidecarError.abandoned` when the abandoned-result envelope
    /// arrives. Caller of `separate()` catches that and reacts.
    ///
    /// No-op if there's no separation in flight (the cancel flag gets
    /// set but immediately cleared at the start of the next separate
    /// action). Only the THROTTLED path checks the flag — fast-path
    /// separation can't be interrupted.
    public func abandon() async throws {
        guard process != nil else { throw StemSidecarError.notStarted }
        // No request_id: we don't await the sidecar's abandon ack.
        // The sidecar's reader thread sets its cancel event the
        // instant the line is parsed, well before any queue draining.
        try writeLine("{\"action\":\"abandon\"}")
    }

    // MARK: Internals — request/response plumbing

    private func sendRequest<R: Decodable>(action: String, payload: [String: Any]) async throws -> R {
        guard process != nil else { throw StemSidecarError.notStarted }
        let requestID = nextRequestID
        nextRequestID += 1

        // Build the request JSON: {"action": "...", "request_id": N, ...payload}
        var dict: [String: Any] = ["action": action, "request_id": requestID]
        for (k, v) in payload { dict[k] = v }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        guard let line = String(data: data, encoding: .utf8) else {
            throw StemSidecarError.protocolViolation("couldn't build request JSON")
        }

        // Wait for the response Data on this request_id, then decode R.
        let resultData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pendingRequests[requestID] = cont
            do {
                try writeLine(line)
            } catch {
                pendingRequests[requestID] = nil
                cont.resume(throwing: error)
            }
        }
        return try decodeOrThrow(R.self, from: resultData)
    }

    private func writeLine(_ s: String) throws {
        guard let pipe = stdinPipe else { throw StemSidecarError.notStarted }
        var data = Data(s.utf8)
        data.append(0x0A) // \n
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: Internals — stdout reader

    private func startReaderTask() {
        guard let pipe = stdoutPipe else { return }
        let handle = pipe.fileHandleForReading
        readerTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.handleLine(line)
                }
            } catch {
                await self?.failAllPending(with: error)
            }
            await self?.failAllPending(with: StemSidecarError.sidecarExited(
                code: -1, stderr: (await self?.capturedStderr) ?? ""))
        }
    }

    /// Each line is a response envelope. Three envelope kinds:
    ///   • `status: "ok"` (TERMINAL) — fulfill the pending continuation
    ///     with the inner `result` Data. Special case: if the result
    ///     has `abandoned: true`, throw `.abandoned` instead.
    ///   • `status: "progress"` (NON-TERMINAL) — informational; invoke
    ///     onProgress callback if set, leave the continuation pending.
    ///   • `status: "error"` (TERMINAL) — throw `.sidecarError`.
    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            return
        }

        // Progress is non-terminal — handle BEFORE the pendingRequests
        // lookup so we don't remove the continuation.
        if envelope.status == "progress" {
            guard let reqID = envelope.requestId,
                  pendingRequests[reqID] != nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultObj = json["result"] as? [String: Any],
                  let fraction = (resultObj["fraction"] as? NSNumber)?.doubleValue
            else { return }
            // Snapshot the callback so the closure can run off-actor
            // without keeping the actor locked while the consumer
            // does (potentially slow) UI work.
            if let cb = onProgress {
                Task.detached { cb(fraction) }
            }
            return
        }

        guard let reqID = envelope.requestId, let cont = pendingRequests.removeValue(forKey: reqID) else {
            return  // unsolicited line — ignore (no banner expected here)
        }
        if envelope.status == "ok" {
            // Re-decode the parent object to pluck out the `result` field's
            // raw Data so the caller's R: Decodable can run against it.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resultObj = json["result"] {
                // Abandoned-result short-circuit: the sidecar returned
                // status:ok with {abandoned: true} after a throttled
                // separation hit a cancel-event. Surface as a typed
                // error so callers can distinguish "user changed
                // their mind" from real failures.
                if let resultDict = resultObj as? [String: Any],
                   let abandoned = resultDict["abandoned"] as? Bool, abandoned {
                    let reason = (resultDict["reason"] as? String) ?? "abandoned"
                    cont.resume(throwing: StemSidecarError.abandoned(reason: reason))
                    return
                }
                if let resultData = try? JSONSerialization.data(withJSONObject: resultObj) {
                    cont.resume(returning: resultData)
                } else {
                    cont.resume(throwing: StemSidecarError.protocolViolation("ok response result not serializable"))
                }
            } else {
                cont.resume(throwing: StemSidecarError.protocolViolation("ok response missing result"))
            }
        } else {
            cont.resume(throwing: StemSidecarError.sidecarError(
                message: envelope.error ?? "(unknown)",
                trace: envelope.trace))
        }
    }

    private func failAllPending(with error: Error) {
        for (_, cont) in pendingRequests { cont.resume(throwing: error) }
        pendingRequests.removeAll()
    }

    // MARK: Internals — utilities

    /// Read a single newline-terminated line from a FileHandle. Used
    /// for the startup banner, before the async reader task is up.
    private func readLine(from handle: FileHandle) async throws -> String {
        var collected = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            if chunk.isEmpty {
                throw StemSidecarError.sidecarExited(code: -1, stderr: capturedStderr)
            }
            if chunk.first == 0x0A {
                guard let s = String(data: collected, encoding: .utf8) else {
                    throw StemSidecarError.protocolViolation("non-UTF8 line")
                }
                return s
            }
            collected.append(chunk)
        }
    }

    private func appendStderr(_ s: String) {
        capturedStderr.append(s)
    }
}

#else  // !os(macOS) — stub actor for iOS/iPadOS/visionOS/tvOS

/// iOS/iPadOS/visionOS/tvOS stub. The Python sidecar isn't available
/// on these platforms (Foundation.Process is macOS-only, and we don't
/// ship a Python runtime in mobile bundles). Every API on this stub
/// either throws `protocolViolation` or no-ops, so AppModel's stem
/// pipeline degrades gracefully — visualizers fall back to band-split
/// signals on every Shazam match. The macOS implementation is
/// IDENTICAL above and tested; this file just needs to compile on
/// non-Mac platforms so the multiplatform target builds.
public actor StemFeatureProvider {
    public struct Configuration: Sendable {
        public let pythonExecutable: URL
        public let sidecarScript: URL
        public let model: String
        public init(pythonExecutable: URL, sidecarScript: URL, model: String = "htdemucs") {
            self.pythonExecutable = pythonExecutable
            self.sidecarScript = sidecarScript
            self.model = model
        }
        public static func localDevDefaults() -> Configuration {
            // Stub: paths are never resolved on non-macOS.
            Configuration(
                pythonExecutable: URL(fileURLWithPath: "/"),
                sidecarScript: URL(fileURLWithPath: "/")
            )
        }
    }

    public init(configuration: Configuration = .localDevDefaults()) {}

    public func setOnProgress(_ callback: (@Sendable (Double) -> Void)?) {}

    public func currentOnProgress() -> (@Sendable (Double) -> Void)? { nil }

    public func start() async throws {
        throw StemSidecarError.protocolViolation(
            "stem separation is macOS-only (sidecar requires Foundation.Process)")
    }

    public func stop() async {}

    public func ping() async throws {
        throw StemSidecarError.protocolViolation("stem separation is macOS-only")
    }

    public func separate(
        filePath: String,
        cacheKey: String? = nil,
        forceRefresh: Bool = false,
        model: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        throttleMS: Int = 0
    ) async throws -> StemSeparationResult {
        throw StemSidecarError.protocolViolation("stem separation is macOS-only")
    }

    public func cacheStats() async throws -> StemCacheStats {
        throw StemSidecarError.protocolViolation("stem separation is macOS-only")
    }

    @discardableResult
    public func clearAllCachedFeatures() async throws -> Int { 0 }

    public struct AliasResult: Sendable, Codable {
        public let aliased: Bool
        public let reason: String?
    }

    public func alias(primaryKey: String, aliasKey: String) async throws -> AliasResult {
        AliasResult(aliased: false, reason: "stem separation is macOS-only")
    }

    public func cachedFeatures(forKey key: String, model: String = "htdemucs") async throws -> StemSeparationResult? {
        return nil
    }

    public func findCacheKey(title: String, artist: String, model: String = "htdemucs") async throws -> String? {
        return nil
    }

    public func putCachedFeatures(
        forKey key: String,
        featuresBlob: Data,
        stemsMeta: [(name: String, nFrames: Int)],
        model: String = "htdemucs",
        durationSeconds: Double? = nil,
        title: String? = nil,
        artist: String? = nil
    ) async throws {
        // no-op
    }

    public func abandon() async throws {}

    public func cacheAudit() async throws -> [StemCacheRow] { [] }

    @discardableResult
    public func deleteCacheRow(forKey key: String) async throws -> Bool { false }
}

#endif

// MARK: - Decoder helper

/// Free function — under Swift 6 strict concurrency a file-scope
/// `JSONDecoder` constant gets treated as main-actor-isolated, which
/// breaks calls from inside the `StemFeatureProvider` actor. Decoder
/// construction is cheap (<10µs); just spin one up per call.
private func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        throw StemSidecarError.decodingFailed(
            underlying: "\(error.localizedDescription) — snippet: \(snippet)")
    }
}
