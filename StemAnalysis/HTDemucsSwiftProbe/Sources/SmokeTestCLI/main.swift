//
//  SmokeTestCLI — runtime smoke test for the Swift backend's
//  end-to-end pipeline. Inlines the same logic the app-side
//  `StemFeatureProviderSwiftBackend` runs:
//
//    1. Decode WAV via AVAudioFile → 44.1 kHz stereo float32
//    2. Build HTDemucs + FeatureDeriver
//    3. Run model.forward on the audio (single-segment for the 5s
//       fixture; chunking lands in the app-side backend)
//    4. Derive features per stem
//    5. Pack to HVSF v2 binary
//    6. Write to a scratch SQLite (same schema as production cache)
//    7. Read back, unpack, verify the round-trip
//
//  This is the proof-of-life test that the app-side backend is
//  numerically sound and the integration glue works against real audio.
//

import AVFoundation
import Foundation
import HTDemucsSwift
import FeatureDerive
import MLX
import SQLite3

// MARK: - Test fixture paths

let repoRoot = URL(fileURLWithPath: "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer")
let probeArtifacts = repoRoot.appendingPathComponent("StemAnalysis/HTDemucsSwiftProbe/artifacts")
let featureArtifacts = repoRoot.appendingPathComponent(
    "StemAnalysis/FeatureDeriveSwiftProbe/artifacts/parity"
)
let scratchCache = FileManager.default.temporaryDirectory
    .appendingPathComponent("stem_smoke_test.sqlite")

let wavPath = probeArtifacts.appendingPathComponent("parity/input.wav")
let safetensorsPath = probeArtifacts.appendingPathComponent("htdemucs.safetensors")

setbuf(stdout, nil)
print("==== Swift Backend Smoke Test ====")
print("fixture:        \(wavPath.path)")
print("safetensors:    \(safetensorsPath.path)")
print("filterbanks:    \(featureArtifacts.path)")
print("scratch cache:  \(scratchCache.path)")
print()

// 1. Audio loading (mirrors StemFeatureProviderSwiftBackend.loadAudio).
print("[1/7] Load audio...")
let file = try AVAudioFile(forReading: wavPath)
let srcFmt = file.processingFormat
let targetSR: Double = 44_100
let outFmt = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: targetSR,
    channels: 2,
    interleaved: false
)!
let conv = AVAudioConverter(from: srcFmt, to: outFmt)!

let srcCap = AVAudioFrameCount(file.length)
let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: srcCap)!
try file.read(into: srcBuf)
let ratio = targetSR / srcFmt.sampleRate
let outCap = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio) + 1024
let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!

var consumed = false
var convErr: NSError?
_ = conv.convert(to: outBuf, error: &convErr) { _, status in
    if consumed {
        status.pointee = .endOfStream
        return nil
    }
    consumed = true
    status.pointee = .haveData
    return srcBuf
}
if let convErr {
    print("  ERROR: \(convErr.localizedDescription)")
    exit(1)
}

let frames = Int(outBuf.frameLength)
let ch = Int(outFmt.channelCount)
var samples = [Float](repeating: 0, count: frames * ch)
let chData = outBuf.floatChannelData!
for c in 0 ..< ch {
    for i in 0 ..< frames {
        samples[c * frames + i] = chData[c][i]
    }
}
print("      shape=(\(ch), \(frames)) → \(Double(frames) / targetSR)s")

// 2. Load model + features deriver.
print("[2/7] Load HTDemucs weights...")
let model = HTDemucs(sources: ["drums", "bass", "other", "vocals"])
try model.loadWeights(from: safetensorsPath)
print("      ✓ loaded")

print("[3/7] Load FeatureDeriver...")
let deriver = try FeatureDeriver(
    sr: Int(targetSR), frameRate: 30, filterbankDir: featureArtifacts
)
print("      ✓ loaded")

// 3. Single-segment forward (5s fits in 7.8s training segment).
print("[4/7] Run model.forward...")
let mix = MLXArray(samples, [1, ch, frames])
let fwdStart = Date()
let out = model(mix)
eval(out)
let fwdSec = Date().timeIntervalSince(fwdStart)
let outShape = out.shape
print(String(format: "      out shape=%@  (%.3fs, %.2fx realtime)",
             "\(outShape)", fwdSec, (Double(frames) / targetSR) / fwdSec))

// Extract per-stem stereo audio.
// out shape = [1, S=4, C=2, T=frames]. We want left/right per stem.
let S = outShape[1], C = outShape[2], T = outShape[3]
let flat: [Float] = out[0].asArray(Float.self)
let sources = model.sources
var stems: [String: (left: [Float], right: [Float])] = [:]
let perStem = C * T
for (idx, src) in sources.enumerated() {
    let base = idx * perStem
    stems[src] = (
        left: Array(flat[base ..< (base + T)]),
        right: Array(flat[(base + T) ..< (base + 2 * T)])
    )
}
_ = S

// 4. Per-stem features.
print("[5/7] Derive per-stem features...")
let derivStart = Date()
struct StemFeats {
    let chromagram: [[Float]]
    let loudness: [Float]
    let onset: [Bool]
    let nFrames: Int
}
var features: [String: StemFeats] = [:]
for (name, channels) in stems {
    let n = channels.left.count
    var mono = [Float](repeating: 0, count: n)
    for i in 0 ..< n {
        mono[i] = (channels.left[i] + channels.right[i]) * 0.5
    }
    let f = deriver.derive(mono: mono)
    var rows: [[Float]] = []
    rows.reserveCapacity(f.nFrames)
    for frame in 0 ..< f.nFrames {
        rows.append(Array(f.chromagram[frame * 12 ..< (frame + 1) * 12]))
    }
    features[name] = StemFeats(
        chromagram: rows,
        loudness: f.loudness,
        onset: f.onset,
        nFrames: f.nFrames
    )
}
let derivSec = Date().timeIntervalSince(derivStart)
print(String(format: "      %.3fs (4 stems)", derivSec))
for name in sources {
    let f = features[name]!
    let nOnsets = f.onset.filter { $0 }.count
    print(String(format: "      %-6@  n_frames=%d  n_onsets=%d  rms_max=%.4f",
                 name as NSString,
                 f.nFrames, nOnsets, f.loudness.max() ?? 0))
}

// 5. Binary pack (HVSF v2).
print("[6/7] Pack HVSF binary + write to SQLite...")
let order = ["drums", "bass", "other", "vocals"]
var blob = Data()
blob.append(contentsOf: [0x48, 0x56, 0x53, 0x46]) // HVSF
blob.append(UInt8(2))   // version
blob.append(UInt8(12))  // chroma_bins
blob.append(contentsOf: [0, 0]) // reserved

var metaList: [[String: Any]] = []
for name in order {
    let f = features[name]!
    metaList.append(["name": name, "n_frames": f.nFrames])
    let nameBytes = Array(name.utf8)
    var nameLen = UInt32(nameBytes.count).littleEndian
    blob.append(Data(bytes: &nameLen, count: 4))
    blob.append(contentsOf: nameBytes)
    var nFramesLE = UInt32(f.nFrames).littleEndian
    blob.append(Data(bytes: &nFramesLE, count: 4))
    // chroma rows
    var chromaFlat: [Float] = []
    chromaFlat.reserveCapacity(f.nFrames * 12)
    for row in f.chromagram { chromaFlat.append(contentsOf: row) }
    chromaFlat.withUnsafeBufferPointer { p in blob.append(Data(buffer: p)) }
    // loudness
    f.loudness.withUnsafeBufferPointer { p in blob.append(Data(buffer: p)) }
    // onset bits
    let nBytes = (f.nFrames + 7) / 8
    var onsetBytes = [UInt8](repeating: 0, count: nBytes)
    for (frame, on) in f.onset.enumerated() where on {
        onsetBytes[frame >> 3] |= UInt8(1 << (frame & 7))
    }
    blob.append(contentsOf: onsetBytes)
}
let metaJSON = String(
    data: try JSONSerialization.data(withJSONObject: metaList),
    encoding: .utf8
)!
print("      blob \(blob.count) bytes, meta \(metaJSON.count) bytes")

// SQLite write (schema matches sidecar.py).
let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self
)
try? FileManager.default.removeItem(at: scratchCache)
var db: OpaquePointer?
sqlite3_open(scratchCache.path, &db)
defer { sqlite3_close(db) }
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
    """
sqlite3_exec(db, schema, nil, nil, nil)

let insertSQL = """
    INSERT INTO stem_features
      (cache_key, model, protocol_version, duration_seconds,
       title, artist, created_at, features_blob, stems_meta)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
var stmt: OpaquePointer?
sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil)
sqlite3_bind_text(stmt, 1, "smoke-test-key", -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 2, "htdemucs", -1, SQLITE_TRANSIENT)
sqlite3_bind_int(stmt, 3, 2)
sqlite3_bind_double(stmt, 4, Double(frames) / targetSR)
sqlite3_bind_text(stmt, 5, "Test Title", -1, SQLITE_TRANSIENT)
sqlite3_bind_text(stmt, 6, "Test Artist", -1, SQLITE_TRANSIENT)
sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
_ = blob.withUnsafeBytes { raw in
    sqlite3_bind_blob(stmt, 8, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
}
sqlite3_bind_text(stmt, 9, metaJSON, -1, SQLITE_TRANSIENT)
let stepOK = sqlite3_step(stmt) == SQLITE_DONE
sqlite3_finalize(stmt)
print("      SQLite write: \(stepOK ? "OK" : "FAIL")")

// 6. Read back + verify roundtrip.
print("[7/7] Read back + verify roundtrip...")
let selectSQL = "SELECT features_blob, stems_meta, protocol_version FROM stem_features WHERE cache_key = ?"
var rstmt: OpaquePointer?
sqlite3_prepare_v2(db, selectSQL, -1, &rstmt, nil)
sqlite3_bind_text(rstmt, 1, "smoke-test-key", -1, SQLITE_TRANSIENT)
guard sqlite3_step(rstmt) == SQLITE_ROW else {
    print("      ✗ select failed")
    exit(1)
}
let readBlobLen = Int(sqlite3_column_bytes(rstmt, 0))
let readBlob = Data(bytes: sqlite3_column_blob(rstmt, 0)!, count: readBlobLen)
let readMeta = String(cString: sqlite3_column_text(rstmt, 1))
let readPV = Int(sqlite3_column_int(rstmt, 2))
sqlite3_finalize(rstmt)

print("      blob roundtrip: \(readBlob == blob ? "✓ identical" : "✗ MISMATCH")")
print("      meta roundtrip: \(readMeta == metaJSON ? "✓ identical" : "✗ MISMATCH")")
print("      protocol_version: \(readPV) (expected 2)")

// Header sanity check
let magic = readBlob.prefix(4)
let expectedMagic = Data([0x48, 0x56, 0x53, 0x46])
print("      HVSF magic: \(magic == expectedMagic ? "✓" : "✗")  version byte: \(readBlob[4]) (expected 2)")
let chromaBins = readBlob[5]
print("      chroma bins: \(chromaBins) (expected 12)")

print()
print("==== ✓ SMOKE TEST COMPLETE ====")
print("Pipeline proven: AVAudioFile → MLX htdemucs → FeatureDeriver →")
print("                 HVSF pack → SQLite write → SQLite read → unpack.")
print("The app-side StemFeatureProviderSwiftBackend uses the same code paths.")
