//
//  Layers.swift — building-block layers shared across HEncDec + DConv
//  + Transformer.
//
//  Mirrors demucs_mlx.mlx_layers and the htdemucs-relevant bits of
//  demucs_mlx.mlx_demucs / .mlx_hdemucs. Each class is a thin Swift
//  port of the Python reference; parameter names match the safetensors
//  export from tools/export_weights.py so the weight loader can walk
//  the tree by reflected property names.
//
//  Convention: NCL/NCHW for the layer inputs/outputs, NLC/NHWC inside
//  the underlying mlx-swift Conv*. The transpose wrappers hide it.
//

import Foundation
import MLX
import MLXNN

// MARK: - pad1d (reflect-mode workaround)

/// Pad on the last dimension. Same semantics as
/// `demucs_mlx.mlx_hdemucs.pad1d` — handles `mode="reflect"`
/// manually via slice+reverse+concat because mlx-swift's `PadMode`
/// only exposes `.constant` and `.edge`.
func pad1d(
    _ x: MLXArray,
    paddings: (Int, Int),
    mode: String = "constant",
    value: Float = 0.0
) -> MLXArray {
    var x = x
    let length = x.shape.last!
    var (padLeft, padRight) = paddings

    if mode == "reflect" {
        let maxPad = max(padLeft, padRight)
        if length <= maxPad {
            // Input too short to reflect — first constant-pad to make it
            // long enough, then reflect-pad the remainder.
            let extraPad = maxPad - length + 1
            let extraPadRight = min(padRight, extraPad)
            let extraPadLeft = extraPad - extraPadRight
            padLeft -= extraPadLeft
            padRight -= extraPadRight
            if extraPadLeft > 0 || extraPadRight > 0 {
                var widths = Array(repeating: IntOrPair(0), count: x.ndim - 1)
                widths.append(IntOrPair((extraPadLeft, extraPadRight)))
                x = padded(
                    x, widths: widths, mode: .constant,
                    value: MLXArray(value)
                )
            }
        }

        // Build left/right reflection slices over the last axis.
        if padLeft > 0 {
            let leftSlice = x[.ellipsis, 1 ..< padLeft + 1]
            let leftRef = leftSlice[.ellipsis, .stride(by: -1)]
            x = concatenated([leftRef, x], axis: -1)
        }
        if padRight > 0 {
            let lastLen = x.shape.last!
            let rightSlice = x[
                .ellipsis,
                (lastLen - padRight - 1) ..< (lastLen - 1)
            ]
            let rightRef = rightSlice[.ellipsis, .stride(by: -1)]
            x = concatenated([x, rightRef], axis: -1)
        }
    } else {
        var widths = Array(repeating: IntOrPair(0), count: x.ndim - 1)
        widths.append(IntOrPair((padLeft, padRight)))
        let pm: PadMode = (mode == "edge") ? .edge : .constant
        x = padded(x, widths: widths, mode: pm, value: MLXArray(value))
    }
    return x
}

/// Trim x's last dim down to reference length (or to match reference's
/// last dim if reference is an array). Center-aligned.
func centerTrim(_ x: MLXArray, length: Int) -> MLXArray {
    let delta = x.shape.last! - length
    precondition(delta >= 0, "tensor smaller than reference")
    if delta == 0 { return x }
    let start = delta / 2
    let end = x.shape.last! - (delta - start)
    return x[.ellipsis, start ..< end]
}

func centerTrim(_ x: MLXArray, like reference: MLXArray) -> MLXArray {
    return centerTrim(x, length: reference.shape.last!)
}

// MARK: - GLU

/// Gated Linear Unit on the channel axis. Splits the input in half
/// along the specified axis, returns `a * sigmoid(b)`.
final class GLU: Module, UnaryLayer {
    let axis: Int

    init(axis: Int = 1) {
        self.axis = axis
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let parts = MLX.split(x, parts: 2, axis: axis)
        return parts[0] * MLX.sigmoid(parts[1])
    }
}

// MARK: - LayerScale

/// Learned per-channel scalar gain. `channelLast=true` multiplies
/// broadcasted on the last axis; `false` multiplies on axis -2
/// (matches `mlx_demucs.LayerScale`).
final class LayerScale: Module {
    let channelLast: Bool
    @ParameterInfo(key: "scale") var scale: MLXArray

    init(channels: Int, initValue: Float = 0.0, channelLast: Bool = false) {
        self.channelLast = channelLast
        self._scale.wrappedValue = MLXArray.zeros([channels]) + initValue
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if channelLast {
            return x * scale
        }
        // shape (C,) -> broadcast on axis -2 (channels dim) of [B, C, T]
        return x * scale.expandedDimensions(axis: -1)
    }
}

// MARK: - ScaledEmbedding

/// Like nn.Embedding but with output scaled by `scale`. We DO NOT
/// reproduce the `smooth=True` cumsum initialization here because
/// the safetensors export carries the post-init weights (we only do
/// inference). The constructor stores `scale` so callAsFunction can
/// multiply.
final class ScaledEmbedding: Module {
    let scale: Float
    @ModuleInfo var embedding: Embedding

    init(numEmbeddings: Int, embeddingDim: Int, scale: Float = 10.0) {
        self.scale = scale
        self.embedding = Embedding(embeddingCount: numEmbeddings, dimensions: embeddingDim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return embedding(x) * scale
    }
}

// MARK: - NCL / NCHW conv subclasses
//
// mlx-swift's Conv1d expects NLC; Conv2d expects NHWC. The Python
// reference uses NCL/NCHW. We SUBCLASS (not wrap) so that the
// reflected parameter paths stay flat: a Conv1dNCL named `foo`
// produces `foo.weight` / `foo.bias` keys, matching the safetensors
// export exactly. Wrapping with `@ModuleInfo var conv: Conv1d` would
// have produced `foo.conv.weight` which doesn't match.

final class Conv1dNCL: Conv1d {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xNLC = x.transposed(0, 2, 1)
        let yNLC = super.callAsFunction(xNLC)
        return yNLC.transposed(0, 2, 1)
    }
}

final class ConvTranspose1dNCL: ConvTransposed1d {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xNLC = x.transposed(0, 2, 1)
        let yNLC = super.callAsFunction(xNLC)
        return yNLC.transposed(0, 2, 1)
    }
}

final class Conv2dNCHW: Conv2d {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xNHWC = x.transposed(0, 2, 3, 1)
        let yNHWC = super.callAsFunction(xNHWC)
        return yNHWC.transposed(0, 3, 1, 2)
    }
}

final class ConvTranspose2dNCHW: ConvTransposed2d {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xNHWC = x.transposed(0, 2, 3, 1)
        let yNHWC = super.callAsFunction(xNHWC)
        return yNHWC.transposed(0, 3, 1, 2)
    }
}

// MARK: - GroupNorm subclasses for NCL / NCHW
//
// mlx-swift's GroupNorm(pytorchCompatible: true) assumes channels-last
// (NLC / NHWC). The PyTorch-trained htdemucs weights were saved
// expecting PyTorch GroupNorm on NCHW. Transposing channels-to-last,
// calling super, and transposing back gives the same numerical
// result. Subclassing keeps weight/bias visible at `name.weight` /
// `name.bias`.

final class GroupNormNCL: GroupNorm {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        // NCL -> NLC: (B, C, L) -> (B, L, C)
        let xNLC = x.transposed(0, 2, 1)
        let yNLC = super.callAsFunction(xNLC)
        return yNLC.transposed(0, 2, 1)
    }
}

final class GroupNormNCHW: GroupNorm {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        // NCHW -> NHWC: (B, C, H, W) -> (B, H, W, C)
        let xNHWC = x.transposed(0, 2, 3, 1)
        let yNHWC = super.callAsFunction(xNHWC)
        return yNHWC.transposed(0, 3, 1, 2)
    }
}

// MARK: - MyGroupNorm (transformer norm_out)
//
// Matches demucs.transformer.MyGroupNorm: takes (B, T, C), transposes
// to (B, C, T) under the hood, runs PyTorch nn.GroupNorm
// (channels-first), then transposes back.
//
// For G=1 (the htdemucs case), PyTorch's nn.GroupNorm reshapes to
// (B, 1, C*T) and normalizes over the last axis — so mean/std are
// computed over ALL (T, C) elements per batch sample. After the
// affine multiply by `weight[None, :, None]` + `bias[None, :, None]`
// in (B, C, T) layout, transpose back.
//
// This is mathematically distinct from LayerNorm — LayerNorm would
// normalize over the last (C) axis per (B, T) pair.

final class MyGroupNormBTC: Module {
    let numGroups: Int
    let dimensions: Int
    let eps: Float
    public let weight: MLXArray?
    public let bias: MLXArray?

    init(numGroups: Int, dimensions: Int, eps: Float = 1e-5) {
        precondition(dimensions % numGroups == 0)
        self.numGroups = numGroups
        self.dimensions = dimensions
        self.eps = eps
        self.weight = MLXArray.ones([dimensions])
        self.bias = MLXArray.zeros([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // For the G=1 case (the only case used by htdemucs's norm_out),
        // route through the fused Metal kernel — closes most of the
        // ~50ms cross-transformer cost vs the previous reshape-heavy
        // implementation. See FusedKernels.swift.
        if numGroups == 1 {
            return FusedKernels.fusedMyGroupNormBTC(
                x, weight: weight!, bias: bias!, eps: eps
            )
        }
        // Fallback (general case, not exercised by htdemucs).
        let B = x.shape[0]
        let T = x.shape[1]
        let C = x.shape[2]
        precondition(C == dimensions)
        let G = numGroups
        let groupSize = C / G
        var xCF = x.transposed(0, 2, 1)
        xCF = xCF.reshaped(B, G, groupSize, T)
        xCF = xCF.reshaped(B, G, groupSize * T)
        let mean = MLX.mean(xCF, axis: -1, keepDims: true)
        let variance = MLX.variance(xCF, axis: -1, keepDims: true)
        xCF = (xCF - mean) * MLX.rsqrt(variance + eps)
        xCF = xCF.reshaped(B, G, groupSize, T).reshaped(B, C, T)
        if let weight = weight, let bias = bias {
            xCF = xCF * weight.reshaped(1, C, 1) + bias.reshaped(1, C, 1)
        }
        return xCF.transposed(0, 2, 1)
    }
}
