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

    public struct Timing: Sendable, Codable {
        public let separationSeconds: Double
        public let featureSeconds: Double

        enum CodingKeys: String, CodingKey {
            case separationSeconds = "separation_seconds"
            case featureSeconds = "feature_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, stems, timing
        case sampleRate = "sample_rate"
        case frameRate = "frame_rate"
        case fromCache = "from_cache"
        case durationSeconds = "duration_seconds"
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

    public init(configuration: Configuration = .localDevDefaults()) {
        self.configuration = configuration
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
    public func separate(
        filePath: String,
        cacheKey: String? = nil,
        forceRefresh: Bool = false,
        model: String? = nil,
        title: String? = nil,
        artist: String? = nil
    ) async throws -> StemSeparationResult {
        var payload: [String: Any] = ["path": filePath]
        if let model { payload["model"] = model }
        if let cacheKey, !cacheKey.isEmpty { payload["cache_key"] = cacheKey }
        if forceRefresh { payload["force_refresh"] = true }
        if let title { payload["title"] = title }
        if let artist { payload["artist"] = artist }
        return try await sendRequest(action: "separate", payload: payload)
    }

    /// Report cache size + entry count. Cheap — single SQL aggregate.
    public func cacheStats() async throws -> StemCacheStats {
        return try await sendRequest(action: "cache_stats", payload: [:])
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

    /// Each line is a response envelope. Decode it, look up the
    /// pending continuation by request_id, hand it the inner `result`
    /// Data (or an error if status != "ok").
    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            return
        }
        guard let reqID = envelope.requestId, let cont = pendingRequests.removeValue(forKey: reqID) else {
            return  // unsolicited line — ignore (no banner expected here)
        }
        if envelope.status == "ok" {
            // Re-decode the parent object to pluck out the `result` field's
            // raw Data so the caller's R: Decodable can run against it.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resultObj = json["result"],
               let resultData = try? JSONSerialization.data(withJSONObject: resultObj) {
                cont.resume(returning: resultData)
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

// MARK: - Decoder helper

private let _jsonDecoder: JSONDecoder = {
    let d = JSONDecoder()
    return d
}()

private func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try _jsonDecoder.decode(T.self, from: data)
    } catch {
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        throw StemSidecarError.decodingFailed(
            underlying: "\(error.localizedDescription) — snippet: \(snippet)")
    }
}
