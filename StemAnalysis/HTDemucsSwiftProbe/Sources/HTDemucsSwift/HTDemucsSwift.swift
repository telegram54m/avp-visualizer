//
//  HTDemucsSwift.swift — module entry point.
//
//  The real model code will land in HTDemucs.swift, Layers.swift,
//  Transformer.swift, Spectro.swift, WeightLoader.swift as the Phase 0
//  probe progresses. For now this file just verifies the SPM package
//  resolves and the mlx-swift dependency is reachable.
//

import Foundation
import MLX
import MLXNN
import MLXFFT

public enum HTDemucsSwift {
    /// Returns the version of the probe scaffold — bump as Phase 0 progresses.
    public static let version = "0.0.1-scaffold"

    /// Smoke-check: build a tiny MLXArray and run a trivial op.
    /// Confirms the mlx-swift dependency links cleanly.
    public static func smokeCheck() -> String {
        let x = MLXArray([1.0, 2.0, 3.0, 4.0] as [Float])
        let y = x * 2
        return "mlx-swift OK · x*2 = \(y)"
    }

    /// Open the exported safetensors and print a few stats so we know
    /// the file is well-formed and the loader works before we sink
    /// time into the model port.
    public static func auditSafetensors(at url: URL) throws -> String {
        let arrays = try loadArrays(url: url)
        // Spot-check three known parameter names from the export.
        let spots = [
            "channel_upsampler.weight",
            "crosstransformer.layers.0.attn.query_proj.weight",
            "freq_emb.embedding.weight",
        ]
        var lines: [String] = []
        lines.append("loaded \(arrays.count) tensors from \(url.lastPathComponent)")
        for name in spots {
            if let a = arrays[name] {
                lines.append("  \(name): shape=\(a.shape) dtype=\(a.dtype)")
            } else {
                lines.append("  \(name): MISSING")
            }
        }
        // Total parameter count.
        var total = 0
        for (_, a) in arrays {
            total += a.shape.reduce(1, *)
        }
        lines.append("total scalars: \(total)")
        return lines.joined(separator: "\n")
    }
}
