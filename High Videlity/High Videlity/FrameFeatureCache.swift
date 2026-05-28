//
//  FrameFeatureCache.swift
//  High Videlity
//
//  Persistent cache for the [FeatureFrame] timeline that
//  AnalysisTimeline.analyze produces. Skips the 30-second full-song
//  re-analysis on every play of a file we've already analyzed.
//
//  Storage:
//   • Path: ~/Library/Caches/HighVidelity/frames/<sha256-hex>.bin.gz
//   • Format: gzipped packed binary (see HVFF layout below).
//   • Key: SHA-256 of the first 1 MB of the file (matches the hash-key
//     LibraryBatchCacher uses for stem caching — one stable identity
//     across both feature pipelines for the same file).
//
//  Wire/storage format v2 (HVFF):
//    Header (16 bytes):
//      0..3   "HVFF" magic                  uint8[4]
//      4      version                       uint8   (=2)
//      5      chroma_bins                   uint8   (=12)
//      6      band_count                    uint8   (=4)
//      7      reserved                      uint8   (=0)
//      8..11  n_frames                      uint32 LE
//      12..15 reserved                      uint32 LE (=0)
//
//    Per-frame record, repeated n_frames times (133 bytes each):
//      time                f64 LE          (8)
//      color.hue           f64 LE          (8)
//      color.saturation    f64 LE          (8)
//      color.brightness    f64 LE          (8)
//      timbreBrightness    f32 LE          (4)
//      loudness            f32 LE          (4)
//      harmonicComplexity  f32 LE          (4)
//      chromagram[12]      u8              (12)   ← v1 was f32 [48]
//      beat.bpm            f32 LE          (4)
//      beat.phase          f32 LE          (4)
//      beat.confidence     f32 LE          (4)
//      bandLoudness[4]     f32 LE          (16)
//      bandChromagram[4][12] u8            (48)   ← v1 was f32 [192]
//      bools_packed        u8              (1)
//                                            bit 0: onset
//                                            bit 1: beat.beatTrigger
//                                            bits 2..5: bandOnset[0..3]
//                                            bits 6..7: reserved
//
//  v2 (2026-05-26): quantize chromagram + bandChromagram to uint8
//  (0..255 mapping to 0..1). Chromagram values are max-bin normalized
//  in [0, 1] and every consumer either uses argmax (ranking is exact)
//  or sums into TonalColor (quantization noise averages out). Decode
//  cost is one integer→float divide per value, negligible vs the
//  ~10-20ms gzip savings on the smaller blob. Result: per-frame
//  size 313→133 bytes, ~57% smaller raw, ~50% smaller compressed.
//
//  Total per-frame size = 133 bytes. For a 5-minute song at 30 fps
//  (9000 frames): ~1.2 MB raw, ~900 KB compressed. NaN / ±Inf in the
//  non-quantized fields round-trip natively as float32 / float64 — no
//  special encoding needed. Quantized fields can't represent NaN; we
//  clamp incoming values to [0, 1] on encode (NaN → 0).
//
//  Replacing the previous gzipped-JSON format invalidates old cache
//  entries. We use a different file extension (.bin.gz instead of
//  .json.gz) so legacy .json.gz files are simply orphaned — they'll be
//  evicted by macOS cache pressure rather than failing to parse.
//

import AudioAnalysis
import CryptoKit
import Foundation
import OSLog

private let cacheLog = Logger(subsystem: "com.jessegriffith.HighVidelity", category: "frame-cache")

enum FrameFeatureCache {

    private static let magic: [UInt8] = [0x48, 0x56, 0x46, 0x46]  // "HVFF"
    private static let version: UInt8 = 2
    private static let chromaBins: UInt8 = 12
    private static let bandCount: UInt8 = 4
    private static let bytesPerFrame: Int = 133

    /// Inverse of 255, hoisted so the hot decode loop multiplies
    /// instead of dividing. The compiler probably constant-folds the
    /// divide anyway, but explicit is better than implicit.
    private static let invByteScale: Float = 1.0 / 255.0

    /// SHA-256 hex prefix of the first 1 MB of the file — same shape as
    /// LibraryBatchCacher.cacheKeyForFile (minus the `hash-` prefix).
    /// Stable per content, cheap to compute.
    static func hashForFile(_ fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        guard !prefix.isEmpty else { return nil }
        let digest = SHA256.hash(data: prefix)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Look up cached frames for a previously-computed hash. Returns
    /// nil on miss / any read failure. Caller should treat nil as
    /// "compute fresh."
    static func cachedFrames(forHash hash: String) -> [FeatureFrame]? {
        let url = cacheURL(for: hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let gz = try Data(contentsOf: url)
            let raw = try gunzip(gz)
            let frames = try unpack(raw)
            cacheLog.info("HV-FRAMES cache HIT \(hash.prefix(12), privacy: .public) (\(frames.count) frames, \(gz.count / 1024) KB on disk)")
            return frames
        } catch {
            // Most likely cause: FeatureFrame schema changed since
            // this row was written. Delete the corrupt entry so a
            // fresh compute can replace it.
            cacheLog.notice("HV-FRAMES cache read failed for \(hash.prefix(12), privacy: .public): \(String(describing: error), privacy: .public) — discarding entry")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Persist a freshly-computed timeline under a hash. Best effort —
    /// write failures don't propagate; the in-memory result is
    /// returned regardless.
    static func storeFrames(_ frames: [FeatureFrame], forHash hash: String) {
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = cacheURL(for: hash)
        do {
            let raw = pack(frames)
            let gz = try gzip(raw)
            try gz.write(to: url, options: .atomic)
            cacheLog.info("HV-FRAMES cache stored \(hash.prefix(12), privacy: .public) (\(frames.count) frames, \(raw.count / 1024) KB raw, \(gz.count / 1024) KB compressed)")
        } catch {
            cacheLog.notice("HV-FRAMES cache write failed for \(hash.prefix(12), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Paths

    private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HighVidelity/frames", isDirectory: true)
    }

    private static func cacheURL(for hash: String) -> URL {
        cacheDirectory().appendingPathComponent(hash).appendingPathExtension("bin.gz")
    }

    // MARK: - gzip

    private static func gzip(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private static func gunzip(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - Pack

    /// Serialize `[FeatureFrame]` into the packed binary layout
    /// described at the top of the file. All fields little-endian.
    private static func pack(_ frames: [FeatureFrame]) -> Data {
        var out = Data(capacity: 16 + frames.count * bytesPerFrame)
        // Header
        out.append(contentsOf: magic)
        out.append(version)
        out.append(chromaBins)
        out.append(bandCount)
        out.append(0)  // reserved
        appendU32LE(&out, UInt32(frames.count))
        appendU32LE(&out, 0)  // reserved

        for f in frames {
            appendF64LE(&out, f.time)
            appendF64LE(&out, f.color.hue)
            appendF64LE(&out, f.color.saturation)
            appendF64LE(&out, f.color.brightness)
            appendF32LE(&out, f.timbreBrightness)
            appendF32LE(&out, f.loudness)
            appendF32LE(&out, f.harmonicComplexity)
            // chromagram[12] — quantized to uint8. Always exactly 12
            // per FeatureFrame.init precondition. Clamp incoming
            // values to [0, 1] (NaN → 0 via the max() short-circuit).
            for v in f.chromagram { out.append(quantizeToByte(v)) }
            appendF32LE(&out, f.beat.bpm)
            appendF32LE(&out, f.beat.phase)
            appendF32LE(&out, f.beat.confidence)
            // bandLoudness[4]
            for v in f.bandLoudness { appendF32LE(&out, v) }
            // bandChromagram[4][12] — also quantized.
            for row in f.bandChromagram {
                for v in row { out.append(quantizeToByte(v)) }
            }
            // Packed bools: bit 0 = onset, bit 1 = beatTrigger,
            // bits 2..5 = bandOnset[0..3], bits 6..7 reserved.
            var bools: UInt8 = 0
            if f.onset { bools |= 1 << 0 }
            if f.beat.beatTrigger { bools |= 1 << 1 }
            for (i, b) in f.bandOnset.enumerated() where i < 4 {
                if b { bools |= UInt8(1 << (2 + i)) }
            }
            out.append(bools)
        }
        return out
    }

    // MARK: - Unpack

    /// Walk a packed binary blob back into `[FeatureFrame]`. Throws if
    /// the header is wrong, version mismatches, or the byte count
    /// doesn't match `n_frames * bytesPerFrame + 16`. The caller
    /// (cachedFrames) discards the file on any throw.
    private static func unpack(_ data: Data) throws -> [FeatureFrame] {
        guard data.count >= 16 else {
            throw CacheError.truncated("header < 16 bytes")
        }
        let base = data.startIndex
        for i in 0..<4 where data[base + i] != magic[i] {
            throw CacheError.badMagic
        }
        let v = data[base + 4]
        guard v == version else {
            throw CacheError.versionMismatch(found: v, expected: version)
        }
        let chroma = data[base + 5]
        let bands = data[base + 6]
        guard chroma == chromaBins, bands == bandCount else {
            throw CacheError.shapeMismatch(chroma: chroma, bands: bands)
        }
        let nFrames = Int(readU32LE(data, at: base + 8))
        let expectedTotal = 16 + nFrames * bytesPerFrame
        guard data.count == expectedTotal else {
            throw CacheError.truncated("expected \(expectedTotal) bytes for \(nFrames) frames, got \(data.count)")
        }

        var frames: [FeatureFrame] = []
        frames.reserveCapacity(nFrames)
        var offset = base + 16

        for _ in 0..<nFrames {
            let time = readF64LE(data, at: offset); offset += 8
            let hue = readF64LE(data, at: offset); offset += 8
            let sat = readF64LE(data, at: offset); offset += 8
            let bri = readF64LE(data, at: offset); offset += 8
            let timbre = readF32LE(data, at: offset); offset += 4
            let loud = readF32LE(data, at: offset); offset += 4
            let hc = readF32LE(data, at: offset); offset += 4
            // chromagram[12] — quantized uint8 → float via *(1/255).
            var chromagram = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                chromagram[i] = Float(data[offset]) * invByteScale
                offset += 1
            }
            let bpm = readF32LE(data, at: offset); offset += 4
            let phase = readF32LE(data, at: offset); offset += 4
            let conf = readF32LE(data, at: offset); offset += 4
            var bandLoudness = [Float](repeating: 0, count: 4)
            for i in 0..<4 {
                bandLoudness[i] = readF32LE(data, at: offset); offset += 4
            }
            // bandChromagram[4][12] — also quantized uint8.
            var bandChromagram: [[Float]] = []
            bandChromagram.reserveCapacity(4)
            for _ in 0..<4 {
                var row = [Float](repeating: 0, count: 12)
                for k in 0..<12 {
                    row[k] = Float(data[offset]) * invByteScale
                    offset += 1
                }
                bandChromagram.append(row)
            }
            let bools = data[offset]; offset += 1
            let onset = (bools & 0x01) != 0
            let beatTrigger = (bools & 0x02) != 0
            var bandOnset = [Bool](repeating: false, count: 4)
            for i in 0..<4 {
                bandOnset[i] = (bools & UInt8(1 << (2 + i))) != 0
            }

            let beat = BeatState(
                bpm: bpm, phase: phase,
                beatTrigger: beatTrigger, confidence: conf
            )
            let color = TonalColor.fromUnpackedFields(
                hue: hue, saturation: sat, brightness: bri
            )
            frames.append(FeatureFrame(
                time: time,
                color: color,
                timbreBrightness: timbre,
                loudness: loud,
                harmonicComplexity: hc,
                onset: onset,
                chromagram: chromagram,
                beat: beat,
                bandLoudness: bandLoudness,
                bandChromagram: bandChromagram,
                bandOnset: bandOnset
            ))
        }
        return frames
    }

    enum CacheError: Error {
        case truncated(String)
        case badMagic
        case versionMismatch(found: UInt8, expected: UInt8)
        case shapeMismatch(chroma: UInt8, bands: UInt8)
    }

    // MARK: - Quantization helpers

    /// Clamp `value` to [0, 1] and quantize to uint8 (0..255).
    /// NaN-safe — NaN compares false to every number, so `max(0, NaN)`
    /// returns 0 in Swift's max() (NaN propagates through). Actually
    /// `max(Float.nan, 0)` returns 0 — Foundation's max returns the
    /// non-NaN value when one is NaN. We want NaN → 0, which works.
    /// Out-of-range positive → 255; negative → 0.
    private static func quantizeToByte(_ value: Float) -> UInt8 {
        if value.isNaN || value <= 0 { return 0 }
        if value >= 1 { return 255 }
        return UInt8((value * 255).rounded())
    }

    // MARK: - Little-endian primitive helpers

    private static func appendF64LE(_ out: inout Data, _ value: Double) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func appendF32LE(_ out: inout Data, _ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func appendU32LE(_ out: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func readF64LE(_ data: Data, at offset: Int) -> Double {
        var bits: UInt64 = 0
        withUnsafeMutableBytes(of: &bits) { raw in
            data.copyBytes(to: raw, from: offset..<offset + 8)
        }
        return Double(bitPattern: UInt64(littleEndian: bits))
    }

    private static func readF32LE(_ data: Data, at offset: Int) -> Float {
        var bits: UInt32 = 0
        withUnsafeMutableBytes(of: &bits) { raw in
            data.copyBytes(to: raw, from: offset..<offset + 4)
        }
        return Float(bitPattern: UInt32(littleEndian: bits))
    }

    private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

// TonalColor's stored fields are `public let`, and its only public
// initializer takes a chromagram + majorness (computing hue/saturation/
// brightness itself). Cache unpacking needs to reconstruct an exact
// instance from the three doubles we stored. Add a small bridging
// initializer that accepts the fields verbatim.
private extension TonalColor {
    static func fromUnpackedFields(hue: Double, saturation: Double, brightness: Double) -> TonalColor {
        // The synthesized memberwise init isn't public, but we can
        // round-trip via Codable since TonalColor: Codable. JSONEncoder
        // is overkill for three doubles but it's < 50 µs and only runs
        // during cache hits, not per frame in the hot path.
        struct TC: Codable { let hue: Double; let saturation: Double; let brightness: Double }
        let bridge = TC(hue: hue, saturation: saturation, brightness: brightness)
        let data = (try? JSONEncoder().encode(bridge)) ?? Data()
        return (try? JSONDecoder().decode(TonalColor.self, from: data)) ?? TonalColor.zero
    }

    /// Black/neutral fallback used only when the bridge decode fails
    /// (shouldn't happen — the JSON we just encoded is valid).
    static var zero: TonalColor {
        // Reconstruct via the public init using an all-zero chromagram.
        let zeroChroma = Chromagram(values: [Float](repeating: 0, count: 12))
        return TonalColor(chromagram: zeroChroma, majorness: 0)
    }
}
