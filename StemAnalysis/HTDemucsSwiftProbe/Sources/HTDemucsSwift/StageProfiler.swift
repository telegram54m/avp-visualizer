//
//  StageProfiler.swift — opt-in per-stage timer for the HTDemucs
//  forward pass. Holds its own clock so the model code can stay
//  pure-functional.
//
//  Callers pass a profiler instance to `HTDemucs.forward(_:profiler:)`.
//  Each `mark(name, arr)` call forces an `eval(arr)` (so the wall
//  time captured reflects actually-finished GPU work for that stage),
//  records the delta, and restarts the clock. After the forward
//  returns, call `report()` to print the breakdown.
//

import Foundation
import MLX

public final class StageProfiler {
    public private(set) var stages: [(name: String, seconds: Double)] = []
    private var clock: Date = Date()

    public init() {}

    public func start() {
        stages.removeAll()
        clock = Date()
    }

    public func mark(_ name: String, _ arr: MLXArray) {
        eval(arr)
        let dt = Date().timeIntervalSince(clock)
        stages.append((name, dt))
        clock = Date()
    }

    public func report() {
        let total = stages.reduce(0.0, { $0 + $1.seconds })
        print("  Stage breakdown (total: \(String(format: "%.4f", total))s):")
        for (name, sec) in stages {
            let pct = total > 0 ? 100 * sec / total : 0
            print(String(format: "    %-20@  %.4fs  (%5.1f%%)",
                         name as NSString, sec, pct))
        }
    }
}
