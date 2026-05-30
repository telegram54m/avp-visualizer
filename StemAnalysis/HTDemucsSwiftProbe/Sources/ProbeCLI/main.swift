//
//  ProbeCLI — runs the Phase 0 parity test once the model is ported.
//  For now: smoke-tests mlx-swift and audits the exported safetensors.
//

import Foundation
import HTDemucsSwift
import MLX

setbuf(stdout, nil)  // unbuffered output (the parity test is slow & we want progressive prints)
print("HTDemucsSwift probe", HTDemucsSwift.version)
print(HTDemucsSwift.smokeCheck())

// rfft normalization sanity check
for n in [16, 64, 4096] {
    let dc = RFFTProbe.probeDC(n: n)
    print("  rfft(ones[\(n)]).real[0] = \(dc)  (expect \(n) if no-norm, \(Float(n).squareRoot()) if ortho, 1.0 if forward)")
}

// The artifacts dir lives next to Package.swift. Resolve relative to
// CWD (the package root when invoked via run.sh).
let cwd = FileManager.default.currentDirectoryPath
let safetensorsURL = URL(fileURLWithPath: cwd)
    .appendingPathComponent("artifacts/htdemucs.safetensors")

if FileManager.default.fileExists(atPath: safetensorsURL.path) {
    print()
    print("Auditing", safetensorsURL.path)
    do {
        print(try HTDemucsSwift.auditSafetensors(at: safetensorsURL))
    } catch {
        print("ERROR auditing:", error)
    }

    print()
    print("Constructing HTDemucs + loading weights ...")
    let model = HTDemucs()
    do {
        let r = try model.loadWeights(from: safetensorsURL)
        print("  loaded \(r.loadedParams)/\(r.totalParams) safetensors entries (\(r.scaledTotal) scalars)")
        if !r.unexpectedKeys.isEmpty {
            print("  unexpected (\(r.unexpectedKeys.count)):")
            for k in r.unexpectedKeys.prefix(15) { print("    +", k) }
        }
        if !r.missingKeys.isEmpty {
            print("  missing (\(r.missingKeys.count)):")
            for k in r.missingKeys.prefix(15) { print("    -", k) }
        }
        if r.unexpectedKeys.isEmpty && r.missingKeys.isEmpty {
            print("  ✓ all keys matched exactly")
        }
    } catch {
        print("ERROR loading weights:", error)
    }

    // Trace mode: when TRACE=1, dump per-layer activations instead
    // of running the per-stem RMS comparison.
    if ProcessInfo.processInfo.environment["TRACE"] != nil {
        let traceDir = URL(fileURLWithPath: cwd)
            .appendingPathComponent("artifacts/parity/trace_swift")
        print()
        print("Trace mode: writing intermediates to \(traceDir.path)")
        let inputURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent("artifacts/parity/input.f32")
        let inData = try? Data(contentsOf: inputURL)
        if let inData = inData {
            let nFloats = inData.count / MemoryLayout<Float>.stride
            let inFloats: [Float] = inData.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(
                    start: raw.bindMemory(to: Float.self).baseAddress,
                    count: nFloats
                ))
            }
            let mix = MLXArray(inFloats, [1, 2, nFloats / 2])
            let collector = TraceCollector(dir: traceDir)
            _ = model.forwardTraced(mix, into: collector)
            try? collector.writeManifest()
            print("  trace done")
        }
        exit(0)
    }

    // Parity test if the fixture is present.
    let parityDir = URL(fileURLWithPath: cwd)
        .appendingPathComponent("artifacts/parity")
    if FileManager.default.fileExists(atPath: parityDir.path) {
        print()
        print("Running parity test against fixture in \(parityDir.path) ...")
        do {
            let result = try model.runParity(fixtureDir: parityDir, tolerance: 1e-3)
            for (i, s) in result.sources.enumerated() {
                let ratio = result.perStemReferenceRms[i] > 0
                    ? result.perStemRmsDiff[i] / result.perStemReferenceRms[i]
                    : Float.nan
                let line = String(
                    format: "  %-6@ rmsDiff=%.6f  maxAbs=%.6f  refRms=%.6f  diff/ref=%.4e",
                    s as NSString, result.perStemRmsDiff[i], result.perStemMaxAbsDiff[i],
                    result.perStemReferenceRms[i], ratio
                )
                print(line)
            }
            print("  tolerance: rmsDiff < \(result.tolerance) per stem")
            print(result.passed
                ? "  ✓ PARITY PASS — Phase 0 GO"
                : "  ✗ PARITY FAIL")
        } catch {
            print("ERROR running parity:", error)
        }
        // Force exit before any deinit issues with the complex bridge.
        exit(0)
    } else {
        print("(no parity fixture at \(parityDir.path) — run tools/make_parity_fixture.py)")
    }
} else {
    print("(no safetensors at \(safetensorsURL.path) — run tools/export_weights.py first)")
}
