//
//  WeightLoader.swift — load safetensors weights into HTDemucs.
//
//  Uses mlx-swift's NestedDictionary.unflattened to convert the flat
//  dotted-key safetensors dict into the nested structure that
//  Module.update(parameters:) expects.
//

import Foundation
import MLX
import MLXNN

public enum WeightLoaderError: Error {
    case fileNotFound(String)
    case unexpectedKeys([String])
    case missingKeys([String])
}

public struct WeightLoadReport {
    public let totalParams: Int
    public let loadedParams: Int
    public let unexpectedKeys: [String]
    public let missingKeys: [String]
    public let scaledTotal: Int  // sum of scalar counts in loaded tensors
}

public extension HTDemucs {
    /// Load weights from a safetensors file produced by
    /// `tools/export_weights.py`. Returns a report describing which
    /// keys loaded, which were unexpected, and which the model
    /// expected but didn't find. Use `strict=true` to throw on any
    /// discrepancy.
    @discardableResult
    func loadWeights(from url: URL, strict: Bool = false) throws -> WeightLoadReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WeightLoaderError.fileNotFound(url.path)
        }
        let arrays = try loadArrays(url: url)

        // Build the nested structure mlx-swift expects.
        let nested = NestedDictionary<String, MLXArray>.unflattened(
            arrays.map { ($0.key, $0.value) }
        )

        // Discover expected keys by walking the model's current
        // parameter dict.
        let expectedParams = parameters().flattened()
        let expectedKeys = Set(expectedParams.map { $0.0 })
        let providedKeys = Set(arrays.keys)
        let unexpected = providedKeys.subtracting(expectedKeys).sorted()
        let missing = expectedKeys.subtracting(providedKeys).sorted()

        // Apply parameters (verify: .none → ignore missing/extras silently).
        update(parameters: nested)

        var scaledTotal = 0
        for (_, a) in arrays { scaledTotal += a.shape.reduce(1, *) }

        let report = WeightLoadReport(
            totalParams: arrays.count,
            loadedParams: arrays.count - unexpected.count,
            unexpectedKeys: unexpected,
            missingKeys: missing,
            scaledTotal: scaledTotal
        )

        if strict, (!unexpected.isEmpty || !missing.isEmpty) {
            if !missing.isEmpty {
                throw WeightLoaderError.missingKeys(missing)
            }
            throw WeightLoaderError.unexpectedKeys(unexpected)
        }
        return report
    }
}
