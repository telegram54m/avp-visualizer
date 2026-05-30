//
//  Parity.swift — the Phase 0 GO/NO-GO gate.
//
//  Loads the reference fixture (input.f32 + out_{drums,bass,other,
//  vocals}.f32 produced by tools/make_parity_fixture.py), runs the
//  Swift HTDemucs over input, and reports per-stem RMS diff vs the
//  PyTorch reference. Pass if every stem is within tolerance.
//

import Foundation
import MLX

public struct ParityResult {
    public let sources: [String]
    public let perStemRmsDiff: [Float]
    public let perStemMaxAbsDiff: [Float]
    public let perStemReferenceRms: [Float]
    public let tolerance: Float
    public let passed: Bool
}

public enum ParityError: Error {
    case fixtureMissing(String)
    case shapeMismatch(expected: [Int], got: [Int])
    case modelLoadFailed(String)
}

public extension HTDemucs {
    /// Run a single segment forward + compare against the reference
    /// fixture in `artifacts/parity/`. Returns a structured result.
    func runParity(
        fixtureDir: URL,
        tolerance: Float = 1e-3
    ) throws -> ParityResult {
        // 1. Load input.f32 → MLXArray [1, 2, T].
        let inputURL = fixtureDir.appendingPathComponent("input.f32")
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ParityError.fixtureMissing(inputURL.path)
        }
        let inData = try Data(contentsOf: inputURL)
        let nFloats = inData.count / MemoryLayout<Float>.stride
        let channels = audioChannels
        let samples = nFloats / channels
        let inFloats: [Float] = inData.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: p.baseAddress, count: nFloats))
        }
        // Reshape: file is [C, T] interleaved by channel (C-major
        // = first channel's T samples, then second channel's T).
        // Build [1, C, T].
        let mix = MLXArray(inFloats, [1, channels, samples])

        // 2. Forward pass — timed. eval() is what forces the lazy MLX
        // graph to actually execute; without it `self(mix)` returns
        // immediately and the "model time" measurement would be meaningless.
        //
        // We run it once as a warm-up (Metal kernels JIT-compile on
        // first invocation), then time the next 3 and report the best.
        // That matches how the Python benchmark
        // (tools/time_python_sidecar.py) reports its numbers, so the
        // Swift vs Python comparison is apples-to-apples.
        let audioSeconds = Double(samples) / 44100.0
        print("  ⏱ warming up...")
        let warmStart = Date()
        let warmup = self(mix)
        eval(warmup)
        let warmupSeconds = Date().timeIntervalSince(warmStart)
        print(String(
            format: "    cold first call: %.3fs (%.2fx realtime)",
            warmupSeconds, audioSeconds / warmupSeconds
        ))

        var times: [TimeInterval] = []
        var output: MLXArray = warmup
        for i in 0 ..< 3 {
            let t0 = Date()
            output = self(mix)
            eval(output)
            let dt = Date().timeIntervalSince(t0)
            times.append(dt)
            print(String(
                format: "    run %d: %.3fs (%.2fx realtime)",
                i + 1, dt, audioSeconds / dt
            ))
        }

        // Optional stage profile pass (HTDEMUCS_PROFILE=1).
        if ProcessInfo.processInfo.environment["HTDEMUCS_PROFILE"] != nil {
            print("  Stage profile (single forward, includes mid-graph eval overhead):")
            let profiler = StageProfiler()
            output = self.forward(mix, profiler: profiler)
            eval(output)
            profiler.report()
        }
        let bestTime = times.min()!
        let xRealtime = audioSeconds / bestTime
        print(String(
            format: "  ⏱ Swift HTDemucs (best of 3 warm): %.3fs → %.2fx realtime",
            bestTime, xRealtime
        ))
        let outShape = output.shape
        precondition(outShape[0] == 1)
        precondition(outShape[1] == sources.count)
        precondition(outShape[2] == channels)
        precondition(outShape[3] == samples,
                     "output T \(outShape[3]) != input T \(samples)")
        // Pull the model output into a contiguous Float buffer in
        // (S, C, T) order.
        let modelFloats: [Float] = output[0].asArray(Float.self)
        // model[0] shape [S, C, T]; we'll index per-stem.

        // 3. For each stem, load reference and compare.
        var perStemRms: [Float] = []
        var perStemMaxAbs: [Float] = []
        var perStemRefRms: [Float] = []
        let stemElems = channels * samples
        for (idx, source) in sources.enumerated() {
            let refURL = fixtureDir.appendingPathComponent("out_\(source).f32")
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw ParityError.fixtureMissing(refURL.path)
            }
            let refData = try Data(contentsOf: refURL)
            precondition(refData.count == stemElems * MemoryLayout<Float>.stride,
                         "ref \(source) byte count mismatch")
            let refFloats: [Float] = refData.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                return Array(UnsafeBufferPointer(start: p.baseAddress, count: stemElems))
            }
            let base = idx * stemElems
            var sumSq: Double = 0
            var refSumSq: Double = 0
            var maxAbs: Float = 0
            for i in 0 ..< stemElems {
                let d = modelFloats[base + i] - refFloats[i]
                sumSq += Double(d) * Double(d)
                refSumSq += Double(refFloats[i]) * Double(refFloats[i])
                let a = abs(d)
                if a > maxAbs { maxAbs = a }
            }
            let rms = Float(sqrt(sumSq / Double(stemElems)))
            let refRms = Float(sqrt(refSumSq / Double(stemElems)))
            perStemRms.append(rms)
            perStemMaxAbs.append(maxAbs)
            perStemRefRms.append(refRms)
        }

        let passed = perStemRms.allSatisfy { $0 < tolerance }
        return ParityResult(
            sources: sources,
            perStemRmsDiff: perStemRms,
            perStemMaxAbsDiff: perStemMaxAbs,
            perStemReferenceRms: perStemRefRms,
            tolerance: tolerance,
            passed: passed
        )
    }
}
