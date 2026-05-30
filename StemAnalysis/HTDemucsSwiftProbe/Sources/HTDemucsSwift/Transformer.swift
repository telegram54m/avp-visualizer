//
//  Transformer.swift — CrossTransformerEncoder bottleneck.
//
//  htdemucs config: dim=512, hidden_scale=4 (→ hidden=2048),
//  num_heads=8, num_layers=5, cross_first=False (→ classic_parity=0),
//  norm_first=True, norm_in=True, norm_out=True, layer_scale=True,
//  emb="sin", t_gelu=True. group_norm=0, sparse_attn=False.
//

import Foundation
import MLX
import MLXNN

// MARK: - Sinusoidal positional embeddings

/// 1-D sin embedding (used for the time-domain branch).
/// Output shape: [length, 1, dim].
func createSinEmbedding(length: Int, dim: Int, maxPeriod: Float = 10000.0) -> MLXArray {
    precondition(dim % 2 == 0, "dim must be even")
    let halfDim = dim / 2
    let pos = MLXArray(0 ..< Int32(length)).asType(Float.self).reshaped(length, 1, 1)
    let adim = MLXArray(0 ..< Int32(halfDim)).asType(Float.self).reshaped(1, 1, halfDim)
    let phase = pos / MLX.pow(MLXArray(maxPeriod), adim / Float(halfDim - 1))
    return MLX.concatenated([MLX.cos(phase), MLX.sin(phase)], axis: -1)
}

/// 2-D sin embedding (used for the freq-domain branch).
/// Output shape: [1, dim, height, width] after broadcast handling
/// by caller. Internally returns shape [1, dim, height, width].
func create2DSinEmbedding(dModel: Int, height: Int, width: Int, maxPeriod: Float = 10000.0)
    -> MLXArray
{
    precondition(dModel % 4 == 0, "d_model must be divisible by 4")
    let half = dModel / 2
    // div_term: exp(arange(0, half, 2) * -ln(max_period) / half)
    let aHalf = MLXArray(stride(from: 0, to: half, by: 2).map { Float($0) })
    let divTerm = MLX.exp(aHalf * (-log(maxPeriod) / Float(half)))

    let posW = MLXArray(0 ..< Int32(width)).asType(Float.self).reshaped(width, 1)
    let posH = MLXArray(0 ..< Int32(height)).asType(Float.self).reshaped(height, 1)

    // Width embeddings: [D/4, H, W]
    var sinW = MLX.sin(posW * divTerm).transposed(1, 0).reshaped(-1, 1, width)
    sinW = MLX.broadcast(sinW, to: [sinW.shape[0], height, width])
    var cosW = MLX.cos(posW * divTerm).transposed(1, 0).reshaped(-1, 1, width)
    cosW = MLX.broadcast(cosW, to: [cosW.shape[0], height, width])
    // Interleave via stack+reshape: [D/4, 2, H, W] -> [D/2, H, W]
    let peW = MLX.stacked([sinW, cosW], axis: 1).reshaped(-1, height, width)

    // Height embeddings: [D/4, H, W]
    var sinH = MLX.sin(posH * divTerm).transposed(1, 0).reshaped(-1, height, 1)
    sinH = MLX.broadcast(sinH, to: [sinH.shape[0], height, width])
    var cosH = MLX.cos(posH * divTerm).transposed(1, 0).reshaped(-1, height, 1)
    cosH = MLX.broadcast(cosH, to: [cosH.shape[0], height, width])
    let peH = MLX.stacked([sinH, cosH], axis: 1).reshaped(-1, height, width)

    // Concatenate width and height embeddings along channel: [D, H, W]
    let pe = MLX.concatenated([peW, peH], axis: 0)
    return pe.expandedDimensions(axis: 0)  // [1, D, H, W]
}

// MARK: - TransformerEncoderLayer (self-attention)

final class TransformerEncoderLayer: Module {
    @ModuleInfo var attn: MultiHeadAttention
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo(key: "norm_out") var normOut: MyGroupNormBTC
    @ModuleInfo(key: "gamma_1") var gamma1: LayerScale
    @ModuleInfo(key: "gamma_2") var gamma2: LayerScale

    init(dModel: Int, nHead: Int, dimFeedforward: Int) {
        self._attn.wrappedValue = MultiHeadAttention(
            dimensions: dModel, numHeads: nHead, bias: true)
        self._linear1.wrappedValue = Linear(dModel, dimFeedforward)
        self._linear2.wrappedValue = Linear(dimFeedforward, dModel)
        self._norm1.wrappedValue = LayerNorm(dimensions: dModel)
        self._norm2.wrappedValue = LayerNorm(dimensions: dModel)
        self._normOut.wrappedValue = MyGroupNormBTC(numGroups: 1, dimensions: dModel)
        self._gamma1.wrappedValue = LayerScale(channels: dModel, initValue: 1e-4, channelLast: true)
        self._gamma2.wrappedValue = LayerScale(channels: dModel, initValue: 1e-4, channelLast: true)
        super.init()
    }

    /// norm_first=True path. attn_mask not used (sparse=false in htdemucs).
    ///
    /// MLX.compile experiment (2026-05-30): wrapping this in
    /// MLX.compile(inputs:[self]) didn't help — the heavy ops (SDPA,
    /// LayerNorm, large GEMM Linear) are already monolithic Metal
    /// kernel calls and the compile dispatch overhead ate the savings.
    /// shapeless=true also crashed on AddMM's output_shapes call.
    /// Left as plain code for clarity.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        let xNormed = norm1(x)
        let y1 = attn(xNormed, keys: xNormed, values: xNormed)
        x = x + gamma1(y1)
        let y2 = linear2(MLXNN.gelu(linear1(norm2(x))))
        x = x + gamma2(y2)
        return normOut(x)
    }
}

// MARK: - CrossTransformerEncoderLayer

final class CrossTransformerEncoderLayer: Module {
    @ModuleInfo(key: "cross_attn") var crossAttn: MultiHeadAttention
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo var norm3: LayerNorm
    @ModuleInfo(key: "norm_out") var normOut: MyGroupNormBTC
    @ModuleInfo(key: "gamma_1") var gamma1: LayerScale
    @ModuleInfo(key: "gamma_2") var gamma2: LayerScale

    init(dModel: Int, nHead: Int, dimFeedforward: Int) {
        self._crossAttn.wrappedValue = MultiHeadAttention(
            dimensions: dModel, numHeads: nHead, bias: true)
        self._linear1.wrappedValue = Linear(dModel, dimFeedforward)
        self._linear2.wrappedValue = Linear(dimFeedforward, dModel)
        self._norm1.wrappedValue = LayerNorm(dimensions: dModel)
        self._norm2.wrappedValue = LayerNorm(dimensions: dModel)
        self._norm3.wrappedValue = LayerNorm(dimensions: dModel)
        self._normOut.wrappedValue = MyGroupNormBTC(numGroups: 1, dimensions: dModel)
        self._gamma1.wrappedValue = LayerScale(channels: dModel, initValue: 1e-4, channelLast: true)
        self._gamma2.wrappedValue = LayerScale(channels: dModel, initValue: 1e-4, channelLast: true)
        super.init()
    }

    /// q is the "self" branch (the one we're updating); k is the
    /// other branch (cross-attended over). norm_first=True path.
    func callAsFunction(_ q: MLXArray, k: MLXArray) -> MLXArray {
        let kNormed = norm2(k)
        let attnOut = crossAttn(norm1(q), keys: kNormed, values: kNormed)
        var x = q + gamma1(attnOut)
        let ffOut = linear2(MLXNN.gelu(linear1(norm3(x))))
        x = x + gamma2(ffOut)
        return normOut(x)
    }
}

// MARK: - CrossTransformerEncoder

final class CrossTransformerEncoder: Module {
    let numLayers: Int
    let classicParity: Int   // 0 for cross_first=false
    let weightPosEmbed: Float
    let maxPeriod: Float

    @ModuleInfo(key: "norm_in") var normIn: LayerNorm
    @ModuleInfo(key: "norm_in_t") var normInT: LayerNorm

    // Mixed-type lists: even indices are TransformerEncoderLayer (self),
    // odd indices are CrossTransformerEncoderLayer (cross). We type-erase
    // to Module and downcast at runtime to keep one homogenous array.
    @ModuleInfo var layers: [Module]
    @ModuleInfo(key: "layers_t") var layersT: [Module]

    init(
        dim: Int,
        hiddenScale: Float = 4.0,
        numHeads: Int = 8,
        numLayers: Int = 5,
        crossFirst: Bool = false,
        maxPeriod: Float = 10000.0,
        weightPosEmbed: Float = 1.0
    ) {
        precondition(dim % numHeads == 0)
        self.numLayers = numLayers
        self.classicParity = crossFirst ? 1 : 0
        self.maxPeriod = maxPeriod
        self.weightPosEmbed = weightPosEmbed
        let hiddenDim = Int(Float(dim) * hiddenScale)

        self._normIn.wrappedValue = LayerNorm(dimensions: dim)
        self._normInT.wrappedValue = LayerNorm(dimensions: dim)

        var layers: [Module] = []
        var layersT: [Module] = []
        for idx in 0 ..< numLayers {
            let isSelf = (idx % 2 == (crossFirst ? 1 : 0))
            if isSelf {
                layers.append(TransformerEncoderLayer(
                    dModel: dim, nHead: numHeads, dimFeedforward: hiddenDim
                ))
                layersT.append(TransformerEncoderLayer(
                    dModel: dim, nHead: numHeads, dimFeedforward: hiddenDim
                ))
            } else {
                layers.append(CrossTransformerEncoderLayer(
                    dModel: dim, nHead: numHeads, dimFeedforward: hiddenDim
                ))
                layersT.append(CrossTransformerEncoderLayer(
                    dModel: dim, nHead: numHeads, dimFeedforward: hiddenDim
                ))
            }
        }
        self._layers.wrappedValue = layers
        self._layersT.wrappedValue = layersT
        super.init()
    }

    /// x: spectral branch [B, C, Fr, T1]. xt: time branch [B, C, T2].
    /// When `trace` is non-nil, dumps intermediates with the given prefix.
    func callAsFunction(
        _ x: MLXArray, _ xt: MLXArray,
        trace: TraceCollector? = nil
    ) -> (MLXArray, MLXArray) {
        let B = x.shape[0]
        let C = x.shape[1]
        let Fr = x.shape[2]
        let T1 = x.shape[3]

        // 2-D positional embedding for the spectral branch.
        var posEmb2D = create2DSinEmbedding(
            dModel: C, height: Fr, width: T1, maxPeriod: maxPeriod
        )  // [1, C, Fr, T1]
        trace?.saveReal(posEmb2D, name: "tform_pos2d_raw")
        posEmb2D = MLX.broadcast(posEmb2D, to: [B, C, Fr, T1])
        // (B, C, Fr, T1) -> (B, T1, Fr, C) -> (B, T1*Fr, C)
        posEmb2D = posEmb2D.transposed(0, 3, 2, 1).reshaped(B, T1 * Fr, C)
        trace?.saveReal(posEmb2D, name: "tform_pos2d_flat")

        // Spectral: (B, C, Fr, T1) -> (B, T1, Fr, C) -> (B, T1*Fr, C)
        var xFlat = x.transposed(0, 3, 2, 1).reshaped(B, T1 * Fr, C)
        trace?.saveReal(xFlat, name: "tform_x_pre_norm")
        xFlat = normIn(xFlat)
        trace?.saveReal(xFlat, name: "tform_x_post_norm")
        xFlat = xFlat + weightPosEmbed * posEmb2D
        trace?.saveReal(xFlat, name: "tform_x_post_pos")

        // Time branch.
        let T2 = xt.shape[2]
        var xtFlat = xt.transposed(0, 2, 1)  // (B, T2, C)
        var posEmb = createSinEmbedding(length: T2, dim: C, maxPeriod: maxPeriod)  // [T2, 1, C]
        trace?.saveReal(posEmb, name: "tform_pos1d_raw")
        posEmb = posEmb.transposed(1, 0, 2)  // [1, T2, C]
        xtFlat = normInT(xtFlat)
        xtFlat = xtFlat + weightPosEmbed * posEmb

        var xs = xFlat
        var xts = xtFlat
        for idx in 0 ..< numLayers {
            let isSelf = (idx % 2 == classicParity)
            if isSelf {
                let l = layers[idx] as! TransformerEncoderLayer
                let lt = layersT[idx] as! TransformerEncoderLayer
                xs = l(xs)
                xts = lt(xts)
            } else {
                let l = layers[idx] as! CrossTransformerEncoderLayer
                let lt = layersT[idx] as! CrossTransformerEncoderLayer
                let oldX = xs
                xs = l(xs, k: xts)
                xts = lt(xts, k: oldX)
            }
            trace?.saveReal(xs, name: "tform_layer_\(idx)_x")
            trace?.saveReal(xts, name: "tform_layer_\(idx)_xt")
        }

        // Restore shapes.
        let xOut = xs.reshaped(B, T1, Fr, C).transposed(0, 3, 2, 1)
        let xtOut = xts.transposed(0, 2, 1)
        return (xOut, xtOut)
    }
}
