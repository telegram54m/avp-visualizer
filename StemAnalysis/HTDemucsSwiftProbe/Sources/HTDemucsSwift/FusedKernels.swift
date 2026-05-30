//
//  FusedKernels.swift — custom Metal kernels for fused GroupNorm+GELU
//  and GroupNorm+GLU. Direct port from demucs-mlx's metal_kernels.py
//  (Apache-2.0 — Apple Inc / demucs-mlx authors).
//
//  Closes the ~19% perf gap between my unfused Swift implementation
//  and Python's demucs-mlx, which uses these same kernels. The kernel
//  source is byte-for-byte the same as the Python reference; only the
//  host-side wrapper differs.
//
//  Each kernel handles one (batch, group) pair per threadgroup. Uses
//  simdgroup reductions for mean/variance. Falls back to unfused MLX
//  ops for groups too large for a single threadgroup (the same
//  _HYBRID_THRESHOLD = 32768 from demucs-mlx).
//

import Foundation
import MLX
import MLXNN

enum FusedKernels {
    /// Above this elems-per-group, fall back to pure MLX ops — the
    /// single-threadgroup Metal kernel underutilizes the GPU at large
    /// group sizes. Same threshold demucs-mlx uses.
    static let hybridThreshold = 32_768

    // MARK: - Erf approximation (shared between kernels)

    private static let erfApproxHeader = #"""
    // Abramowitz & Stegun approximation of erf, max error ~1.5e-7
    inline float erf_approx(float x) {
        float sign = (x >= 0.0f) ? 1.0f : -1.0f;
        float a = metal::abs(x);
        float t = 1.0f / (1.0f + 0.3275911f * a);
        float t2 = t * t;
        float t3 = t2 * t;
        float t4 = t3 * t;
        float t5 = t4 * t;
        float poly = 0.254829592f * t
                   - 0.284496736f * t2
                   + 1.421413741f * t3
                   - 1.453152027f * t4
                   + 1.061405429f * t5;
        float result = 1.0f - poly * metal::exp(-a * a);
        return sign * result;
    }
    """#

    // MARK: - Fused GroupNorm + GELU

    private static let gnGeluSource = #"""
    uint bg = threadgroup_position_in_grid.x;
    uint tid = thread_index_in_threadgroup;
    uint tg_size = threads_per_threadgroup.x;
    uint sid = thread_index_in_simdgroup;
    uint wid = simdgroup_index_in_threadgroup;
    uint num_simdgroups = tg_size / 32;

    uint num_groups = params[0];
    uint channels_per_group = params[1];
    uint spatial_size = params[2];
    uint total_channels = params[3];

    uint batch_idx = bg / num_groups;
    uint group_idx = bg % num_groups;

    uint elems_per_group = channels_per_group * spatial_size;

    uint base = batch_idx * total_channels * spatial_size
              + group_idx * channels_per_group * spatial_size;

    float local_sum = 0.0f;
    for (uint i = tid; i < elems_per_group; i += tg_size) {
        local_sum += (float)x[base + i];
    }
    local_sum = simd_sum(local_sum);

    threadgroup float shared_sums[32];
    if (sid == 0) shared_sums[wid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = shared_sums[0] / (float)elems_per_group;

    float local_var = 0.0f;
    for (uint i = tid; i < elems_per_group; i += tg_size) {
        float diff = (float)x[base + i] - mean;
        local_var += diff * diff;
    }
    local_var = simd_sum(local_var);
    if (sid == 0) shared_sums[wid] = local_var;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float var_v = shared_sums[0] / (float)elems_per_group;
    float inv_std = metal::rsqrt(var_v + eps[0]);

    float rsqrt2 = 0.7071067811865475f;
    for (uint i = tid; i < elems_per_group; i += tg_size) {
        uint c_local = i / spatial_size;
        uint c_global = group_idx * channels_per_group + c_local;
        float val = ((float)x[base + i] - mean) * inv_std;
        val = val * (float)weight[c_global] + (float)bias[c_global];
        val = 0.5f * val * (1.0f + erf_approx(val * rsqrt2));
        out[base + i] = (T)val;
    }
    """#

    // MARK: - Fused GroupNorm + GLU

    private static let gnGluSource = #"""
    uint bg = threadgroup_position_in_grid.x;
    uint tid = thread_index_in_threadgroup;
    uint tg_size = threads_per_threadgroup.x;
    uint sid = thread_index_in_simdgroup;
    uint wid = simdgroup_index_in_threadgroup;
    uint num_simdgroups = tg_size / 32;

    uint num_groups = params[0];
    uint channels_per_group = params[1];
    uint spatial_size = params[2];
    uint total_channels = params[3];
    uint half_channels = params[4];

    uint batch_idx = bg / num_groups;
    uint group_idx = bg % num_groups;

    uint elems_per_group = channels_per_group * spatial_size;

    uint base = batch_idx * total_channels * spatial_size
              + group_idx * channels_per_group * spatial_size;

    float local_sum = 0.0f;
    for (uint i = tid; i < elems_per_group; i += tg_size) {
        local_sum += (float)x[base + i];
    }
    local_sum = simd_sum(local_sum);

    threadgroup float shared_sums[32];
    if (sid == 0) shared_sums[wid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = shared_sums[0] / (float)elems_per_group;

    float local_var = 0.0f;
    for (uint i = tid; i < elems_per_group; i += tg_size) {
        float diff = (float)x[base + i] - mean;
        local_var += diff * diff;
    }
    local_var = simd_sum(local_var);
    if (sid == 0) shared_sums[wid] = local_var;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float var_v = shared_sums[0] / (float)elems_per_group;
    float inv_std = metal::rsqrt(var_v + eps[0]);

    uint half_cpg = channels_per_group / 2;
    uint out_epg = half_cpg * spatial_size;
    uint out_base = batch_idx * half_channels * spatial_size
                  + group_idx * half_cpg * spatial_size;

    for (uint i = tid; i < out_epg; i += tg_size) {
        uint c_local = i / spatial_size;
        uint s = i % spatial_size;

        uint c_a = c_local;
        uint c_a_global = group_idx * channels_per_group + c_a;
        float val_a = ((float)x[base + c_a * spatial_size + s] - mean) * inv_std;
        val_a = val_a * (float)weight[c_a_global] + (float)bias[c_a_global];

        uint c_b = c_local + half_cpg;
        uint c_b_global = group_idx * channels_per_group + c_b;
        float val_b = ((float)x[base + c_b * spatial_size + s] - mean) * inv_std;
        val_b = val_b * (float)weight[c_b_global] + (float)bias[c_b_global];

        float sig_b = 1.0f / (1.0f + metal::exp(-val_b));
        out[out_base + i] = (T)(val_a * sig_b);
    }
    """#

    // MARK: - Lazy kernel handles

    nonisolated(unsafe) private static var _gnGeluKernel: MLXFast.MLXFastKernel?
    nonisolated(unsafe) private static var _gnGluKernel: MLXFast.MLXFastKernel?

    private static func gnGeluKernel() -> MLXFast.MLXFastKernel {
        if let k = _gnGeluKernel { return k }
        let k = MLXFast.metalKernel(
            name: "fused_groupnorm_gelu",
            inputNames: ["x", "weight", "bias", "eps", "params"],
            outputNames: ["out"],
            source: gnGeluSource,
            header: erfApproxHeader
        )
        _gnGeluKernel = k
        return k
    }

    private static func gnGluKernel() -> MLXFast.MLXFastKernel {
        if let k = _gnGluKernel { return k }
        let k = MLXFast.metalKernel(
            name: "fused_groupnorm_glu",
            inputNames: ["x", "weight", "bias", "eps", "params"],
            outputNames: ["out"],
            source: gnGluSource
            // GLU kernel has no erf, no header needed.
        )
        _gnGluKernel = k
        return k
    }

    // MARK: - Public API

    /// GroupNorm + GELU. Input must be (B, C, …) NCL/NCHW.
    static func fusedGroupNormGELU(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        numGroups: Int, eps: Float = 1e-5
    ) -> MLXArray {
        let origShape = x.shape
        let B = origShape[0]
        let C = origShape[1]
        var spatial = 1
        for d in origShape.dropFirst(2) { spatial *= d }
        precondition(C % numGroups == 0,
                     "channels \(C) not divisible by num_groups \(numGroups)")
        let channelsPerGroup = C / numGroups
        let elemsPerGroup = channelsPerGroup * spatial

        // Fall back for groups too large for a single threadgroup.
        if elemsPerGroup > hybridThreshold {
            return unfusedGroupNormGELU(
                x, weight: weight, bias: bias, numGroups: numGroups, eps: eps
            )
        }

        let xContig = x.reshaped(B, C, spatial).contiguous()
        let w = weight.asType(.float32)
        let b = bias.asType(.float32)
        let epsArr = MLXArray([eps])
        let params = MLXArray([Int32(numGroups), Int32(channelsPerGroup),
                               Int32(spatial), Int32(C)])

        let totalGroups = B * numGroups
        let tg = min(1024, max(32, ((elemsPerGroup + 31) / 32) * 32))

        let outputs = gnGeluKernel()(
            [xContig, w, b, epsArr, params],
            template: [("T", x.dtype)],
            grid: (totalGroups * tg, 1, 1),
            threadGroup: (tg, 1, 1),
            outputShapes: [[B, C, spatial]],
            outputDTypes: [x.dtype]
        )
        return outputs[0].reshaped(origShape)
    }

    /// GroupNorm over 2C channels + GLU split. Output has half the
    /// channels of input.
    static func fusedGroupNormGLU(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        numGroups: Int, eps: Float = 1e-5
    ) -> MLXArray {
        let origShape = x.shape
        let B = origShape[0]
        let cFull = origShape[1]
        precondition(cFull % 2 == 0,
                     "GLU input channels \(cFull) must be even")
        let halfC = cFull / 2
        var spatial = 1
        for d in origShape.dropFirst(2) { spatial *= d }
        precondition(cFull % numGroups == 0,
                     "channels \(cFull) not divisible by num_groups \(numGroups)")
        let channelsPerGroup = cFull / numGroups
        let elemsPerGroup = channelsPerGroup * spatial

        if elemsPerGroup > hybridThreshold {
            return unfusedGroupNormGLU(
                x, weight: weight, bias: bias, numGroups: numGroups, eps: eps
            )
        }

        let xContig = x.reshaped(B, cFull, spatial).contiguous()
        let w = weight.asType(.float32)
        let b = bias.asType(.float32)
        let epsArr = MLXArray([eps])
        let params = MLXArray([Int32(numGroups), Int32(channelsPerGroup),
                               Int32(spatial), Int32(cFull), Int32(halfC)])

        let totalGroups = B * numGroups
        let tg = min(1024, max(32, ((elemsPerGroup + 31) / 32) * 32))

        var outShape = origShape
        outShape[1] = halfC

        let outputs = gnGluKernel()(
            [xContig, w, b, epsArr, params],
            template: [("T", x.dtype)],
            grid: (totalGroups * tg, 1, 1),
            threadGroup: (tg, 1, 1),
            outputShapes: [[B, halfC, spatial]],
            outputDTypes: [x.dtype]
        )
        return outputs[0].reshaped(outShape)
    }

    // MARK: - MyGroupNorm (B, T, C) — for transformer norm_out

    private static let myGroupNormBTCSource = #"""
    // One threadgroup per batch sample (gid.x == batch idx).
    // Each thread strides over (T*C) elements, contributing to a
    // simdgroup sum/var reduction. Then writes normalized + affine.
    uint b = threadgroup_position_in_grid.x;
    uint tid = thread_index_in_threadgroup;
    uint tg_size = threads_per_threadgroup.x;
    uint sid = thread_index_in_simdgroup;
    uint wid = simdgroup_index_in_threadgroup;
    uint num_simdgroups = tg_size / 32;

    uint T = params[0];
    uint C = params[1];
    uint TC = T * C;

    uint base = b * TC;

    // Pass 1: mean
    float local_sum = 0.0f;
    for (uint i = tid; i < TC; i += tg_size) {
        local_sum += (float)x[base + i];
    }
    local_sum = simd_sum(local_sum);

    threadgroup float shared_sums[32];
    if (sid == 0) shared_sums[wid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = shared_sums[0] / (float)TC;

    // Pass 2: variance
    float local_var = 0.0f;
    for (uint i = tid; i < TC; i += tg_size) {
        float diff = (float)x[base + i] - mean;
        local_var += diff * diff;
    }
    local_var = simd_sum(local_var);
    if (sid == 0) shared_sums[wid] = local_var;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (wid == 0) {
        float val = (sid < num_simdgroups) ? shared_sums[sid] : 0.0f;
        val = simd_sum(val);
        if (sid == 0) shared_sums[0] = val;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float var_v = shared_sums[0] / (float)TC;
    float inv_std = metal::rsqrt(var_v + eps[0]);

    // Pass 3: normalize + affine. Channel index = i % C.
    for (uint i = tid; i < TC; i += tg_size) {
        uint c = i % C;
        float val = ((float)x[base + i] - mean) * inv_std;
        val = val * (float)weight[c] + (float)bias[c];
        out[base + i] = (T_dt)val;
    }
    """#

    nonisolated(unsafe) private static var _myGroupNormBTCKernel: MLXFast.MLXFastKernel?

    private static func myGroupNormBTCKernel() -> MLXFast.MLXFastKernel {
        if let k = _myGroupNormBTCKernel { return k }
        let k = MLXFast.metalKernel(
            name: "fused_mygroupnorm_btc",
            inputNames: ["x", "weight", "bias", "eps", "params"],
            outputNames: ["out"],
            source: myGroupNormBTCSource
        )
        _myGroupNormBTCKernel = k
        return k
    }

    /// MyGroupNorm (G=1) on (B, T, C) input. Normalizes per-batch
    /// over all T*C elements, then applies per-channel affine
    /// (weight[C], bias[C]).
    ///
    /// Matches `demucs.transformer.MyGroupNorm(1, C)` exactly.
    static func fusedMyGroupNormBTC(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        eps: Float = 1e-5
    ) -> MLXArray {
        precondition(x.ndim == 3, "expected (B, T, C)")
        let B = x.shape[0]
        let T = x.shape[1]
        let C = x.shape[2]
        let TC = T * C

        // Fallback for very large T*C (single threadgroup is suboptimal).
        if TC > hybridThreshold {
            return unfusedMyGroupNormBTC(
                x, weight: weight, bias: bias, eps: eps
            )
        }

        let xContig = x.contiguous()
        let w = weight.asType(.float32)
        let bs = bias.asType(.float32)
        let epsArr = MLXArray([eps])
        let params = MLXArray([Int32(T), Int32(C)])

        let tg = min(1024, max(32, ((TC + 31) / 32) * 32))

        let outputs = myGroupNormBTCKernel()(
            [xContig, w, bs, epsArr, params],
            template: [("T_dt", x.dtype)],
            grid: (B * tg, 1, 1),
            threadGroup: (tg, 1, 1),
            outputShapes: [[B, T, C]],
            outputDTypes: [x.dtype]
        )
        return outputs[0]
    }

    private static func unfusedMyGroupNormBTC(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray, eps: Float
    ) -> MLXArray {
        let B = x.shape[0]
        let T = x.shape[1]
        let C = x.shape[2]
        var xCF = x.transposed(0, 2, 1)
        xCF = xCF.reshaped(B, 1, C * T)
        let mean = MLX.mean(xCF, axis: -1, keepDims: true)
        let variance = MLX.variance(xCF, axis: -1, keepDims: true)
        xCF = (xCF - mean) * MLX.rsqrt(variance + eps)
        xCF = xCF.reshaped(B, C, T)
        xCF = xCF * weight.reshaped(1, C, 1) + bias.reshaped(1, C, 1)
        return xCF.transposed(0, 2, 1)
    }

    // MARK: - Fused overlap-add (iSTFT post-processing)

    /// Computes the k range of overlapping frames for output sample
    /// `st`. Compile-time constants HOP and FRAME are filled in by
    /// the kernel template machinery.
    private static let kBoundsSource = #"""
    int k_max = st / HOP;
    if (k_max >= n_frames) k_max = n_frames - 1;
    int k_min = 0;
    { int target = st - FRAME; if (target >= 0) k_min = (target / HOP) + 1; }
    """#

    private static let olaNormSource = #"""
    int n_frames = params[0];
    int out_len = params[1];
    int st = (int)thread_position_in_grid.x;
    int sb = (int)thread_position_in_grid.y;
    if (st >= out_len) return;

    int k_max = st / HOP;
    if (k_max >= n_frames) k_max = n_frames - 1;
    int k_min = 0;
    { int target = st - FRAME; if (target >= 0) k_min = (target / HOP) + 1; }

    float acc = 0.0f;
    float den = 0.0f;
    int base_offset = sb * n_frames * FRAME;

    #pragma unroll 4
    for (int k = k_max; k >= k_min; --k) {
        int off = st - k * HOP;
        acc += (float)frames[base_offset + k * FRAME + off] * (float)window[off];
        den += (float)window_sq[off];
    }

    // Torch-style masked normalization (no epsilon clamp):
    out[sb * out_len + st] = (den > 1.0e-11f) ? (T)(acc / den) : (T)(0.0f);
    """#

    nonisolated(unsafe) private static var _olaNormKernel: MLXFast.MLXFastKernel?

    private static func olaNormKernel() -> MLXFast.MLXFastKernel {
        if let k = _olaNormKernel { return k }
        let k = MLXFast.metalKernel(
            name: "ola_norm_windowed_div_envelope",
            inputNames: ["frames", "window", "window_sq", "params"],
            outputNames: ["out"],
            source: olaNormSource
        )
        _olaNormKernel = k
        return k
    }

    /// Fused overlap-add with synthesis window + envelope normalization.
    /// Replaces the Python-for-loop in Spectro.iSTFT with one Metal
    /// kernel launch per call.
    ///
    /// frames:    (B, N, FRAME)  — irfft outputs, pre-window-multiply.
    /// window:    (FRAME,)       — analysis/synthesis window (Hann).
    /// windowSq:  (FRAME,)       — window² (precomputed once).
    /// hop, frame: STFT params.
    /// outLen:    (N-1)*hop + frame.
    /// Returns:   (B, outLen).
    static func fusedOverlapAddNormalize(
        frames: MLXArray, window: MLXArray, windowSq: MLXArray,
        hop: Int, frame: Int, outLen: Int
    ) -> MLXArray {
        precondition(frames.ndim == 3, "expected (B, N, FRAME)")
        let B = frames.shape[0]
        let N = frames.shape[1]
        precondition(frames.shape[2] == frame, "frame dim mismatch")

        let f = frames.contiguous()
        let w = window.contiguous()
        let ws = windowSq.contiguous()
        let params = MLXArray([Int32(N), Int32(outLen)])

        let outputs = olaNormKernel()(
            [f, w, ws, params],
            template: [
                ("T", frames.dtype),
                ("HOP", hop),
                ("FRAME", frame),
            ],
            grid: (outLen, B, 1),
            threadGroup: (256, 1, 1),
            outputShapes: [[B, outLen]],
            outputDTypes: [frames.dtype],
            initValue: 0
        )
        return outputs[0]
    }

    // MARK: - Unfused fallbacks (large groups + non-Metal)

    private static func unfusedGroupNormGELU(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        numGroups: Int, eps: Float
    ) -> MLXArray {
        let normed = groupNormCore(
            x, weight: weight, bias: bias, numGroups: numGroups, eps: eps
        )
        return MLXNN.gelu(normed)
    }

    private static func unfusedGroupNormGLU(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        numGroups: Int, eps: Float
    ) -> MLXArray {
        let normed = groupNormCore(
            x, weight: weight, bias: bias, numGroups: numGroups, eps: eps
        )
        // GLU: split on channel axis (axis 1).
        let parts = MLX.split(normed, parts: 2, axis: 1)
        return parts[0] * MLX.sigmoid(parts[1])
    }

    private static func groupNormCore(
        _ x: MLXArray, weight: MLXArray, bias: MLXArray,
        numGroups: Int, eps: Float
    ) -> MLXArray {
        let shape = x.shape
        let B = shape[0]
        let C = shape[1]
        let cpg = C / numGroups
        var newShape = [B, numGroups, cpg]
        for d in shape.dropFirst(2) { newShape.append(d) }
        let xR = x.reshaped(newShape)
        let axes = Array(2 ..< xR.ndim)
        let mean = MLX.mean(xR, axes: axes, keepDims: true)
        let variance = MLX.variance(xR, axes: axes, keepDims: true)
        var xNorm = (xR - mean) * MLX.rsqrt(variance + eps)
        xNorm = xNorm.reshaped(shape)
        var wShape = [1, C]
        for _ in 0 ..< (xNorm.ndim - 2) { wShape.append(1) }
        return xNorm * weight.reshaped(wShape) + bias.reshaped(wShape)
    }
}
