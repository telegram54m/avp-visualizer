//
//  FeatureProbeCLI — Phase 1 parity test.
//
//  Loads the librosa reference fixtures, runs the Swift derive_features
//  on each stem, dumps the Swift outputs back to disk for the Python
//  comparator (tools/compare_features.py) to evaluate against the
//  acceptance criteria from swift-sidecar-port-spec Phase 1.
//

import FeatureDerive
import Foundation

setbuf(stdout, nil)

let cwd = FileManager.default.currentDirectoryPath
let probeRoot = URL(fileURLWithPath: cwd)
let parityDir = probeRoot.appendingPathComponent("artifacts/parity")
let swiftOutDir = probeRoot.appendingPathComponent("artifacts/parity/swift")
try? FileManager.default.createDirectory(
    at: swiftOutDir, withIntermediateDirectories: true
)

print("FeatureDeriveSwiftProbe — Phase 1 parity")
print("  parity fixtures: \(parityDir.path)")
print("  swift outputs:   \(swiftOutDir.path)")
print()

guard FileManager.default.fileExists(atPath: parityDir.path) else {
    print("ERROR: parity dir missing — run tools/dump_librosa_reference.py")
    exit(1)
}

// Construct the deriver once, reuse across stems.
let deriver = try FeatureDeriver(filterbankDir: parityDir)

let stems = ["drums", "bass", "other", "vocals"]
for stem in stems {
    let monoPath = parityDir.appendingPathComponent("\(stem)_mono.f32")
    guard let monoData = try? Data(contentsOf: monoPath) else {
        print("  \(stem): SKIP (mono file missing)")
        continue
    }
    let nSamples = monoData.count / MemoryLayout<Float>.stride
    let mono: [Float] = monoData.withUnsafeBytes { raw in
        Array(UnsafeBufferPointer(
            start: raw.bindMemory(to: Float.self).baseAddress!,
            count: nSamples
        ))
    }

    let start = Date()
    let f = deriver.derive(mono: mono)
    let dt = Date().timeIntervalSince(start)

    // Write Swift outputs to disk for compare_features.py.
    let chromaURL = swiftOutDir.appendingPathComponent("\(stem)_chroma.f32")
    let rmsURL = swiftOutDir.appendingPathComponent("\(stem)_rms.f32")
    let onsetURL = swiftOutDir.appendingPathComponent("\(stem)_onset.f32")
    try f.chromagram.withUnsafeBufferPointer { ptr in
        try Data(buffer: ptr).write(to: chromaURL)
    }
    try f.loudness.withUnsafeBufferPointer { ptr in
        try Data(buffer: ptr).write(to: rmsURL)
    }
    let onsetF: [Float] = f.onset.map { $0 ? 1.0 : 0.0 }
    try onsetF.withUnsafeBufferPointer { ptr in
        try Data(buffer: ptr).write(to: onsetURL)
    }

    let nOnsets = f.onset.filter { $0 }.count
    print(String(
        format: "  %-6@  n_frames=%3d  n_onsets=%3d  rms_max=%.4f   (%.3fs)",
        stem as NSString, f.nFrames, nOnsets,
        f.loudness.max() ?? 0, dt
    ))
}

print()
print("Swift derive done.")
print("Next: .venv/bin/python FeatureDeriveSwiftProbe/tools/compare_features.py")
