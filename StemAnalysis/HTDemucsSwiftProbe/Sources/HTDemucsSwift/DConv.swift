//
//  DConv.swift — depth-wise conv block used inside HEncLayer/HDecLayer.
//
//  Structure: DConv has a `layers` field which is `[[Module]]` — an
//  outer array of "blocks", each block an inner array of 7 sub-modules
//  at positions 0-6 mirroring the PyTorch Sequential layout:
//
//    [0] Conv1d   (channels -> hidden, kernel=3, dilation=2^d)
//    [1] GroupNorm(1, hidden)
//    [2] Identity (gelu placeholder; activation applied inline)
//    [3] Conv1d   (hidden -> 2*channels, kernel=1)
//    [4] GroupNorm(1, 2*channels)
//    [5] Identity (glu placeholder; activation applied inline)
//    [6] LayerScale(channels)
//
//  With `[[Module]]`, mlx-swift's reflection treats layers.X.Y as
//  pure array-of-array indexing — which is exactly what
//  `NestedDictionary.unflattened` produces from the safetensors
//  keys (`dconv.layers.0.0.weight`, `dconv.layers.0.1.weight`, etc.).
//
//  We rely on the parameters() return values for slots 2 and 5
//  being "none" in the safetensors — Identity has zero parameters so
//  the update walk skips those indices.
//

import Foundation
import MLX
import MLXNN

final class DConv: Module {
    let depth: Int
    let channels: Int
    let hidden: Int

    @ModuleInfo var layers: [[Module]]

    init(
        channels: Int,
        compress: Float = 4,
        depth: Int = 2,
        kernel: Int = 3,
        dilate: Bool = true
    ) {
        precondition(kernel % 2 == 1, "kernel must be odd")
        let hidden = Int(Float(channels) / compress)
        self.channels = channels
        self.hidden = hidden
        self.depth = abs(depth)

        var blocks: [[Module]] = []
        for d in 0 ..< abs(depth) {
            let dilation = dilate ? (1 << d) : 1
            let padding = dilation * (kernel / 2)
            let conv1 = Conv1dNCL(
                inputChannels: channels, outputChannels: hidden,
                kernelSize: kernel, padding: padding, dilation: dilation
            )
            let norm1 = GroupNormNCL(
                groupCount: 1, dimensions: hidden, pytorchCompatible: true
            )
            let act = Identity()
            let conv2 = Conv1dNCL(
                inputChannels: hidden, outputChannels: 2 * channels,
                kernelSize: 1
            )
            let norm2 = GroupNormNCL(
                groupCount: 1, dimensions: 2 * channels, pytorchCompatible: true
            )
            let glu = Identity()
            let scale = LayerScale(channels: channels, initValue: 0.0)
            blocks.append([conv1, norm1, act, conv2, norm2, glu, scale])
        }
        self._layers.wrappedValue = blocks
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for block in layers {
            let conv1 = block[0] as! Conv1dNCL
            let norm1 = block[1] as! GroupNormNCL
            let conv2 = block[3] as! Conv1dNCL
            let norm2 = block[4] as! GroupNormNCL
            let scale = block[6] as! LayerScale

            // conv1 → norm1(GroupNorm 1 group) → gelu → conv2 → norm2(GroupNorm 1 group) → glu
            //
            // The two norm+activation pairs are fused via single Metal
            // kernel launches each. demucs-mlx's perf baseline depends on
            // these fused kernels; without them we're ~19% slower. See
            // FusedKernels.swift.
            //
            // Both norm1 and norm2 are pytorchCompatible GroupNorms with
            // numGroups=1 → normalization is effectively per-(batch, all
            // channels combined). norm1's weight is sized to `hidden`
            // channels; norm2's is sized to `2 * channels`.
            var y = conv1(x)
            y = FusedKernels.fusedGroupNormGELU(
                y, weight: norm1.weight!, bias: norm1.bias!,
                numGroups: 1, eps: 1e-5
            )
            y = conv2(y)
            y = FusedKernels.fusedGroupNormGLU(
                y, weight: norm2.weight!, bias: norm2.bias!,
                numGroups: 1, eps: 1e-5
            )
            y = scale(y)
            x = x + y
        }
        return x
    }
}
