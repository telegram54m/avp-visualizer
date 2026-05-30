//
//  HEncDec.swift — HEncLayer + HDecLayer, htdemucs flavor.
//
//  htdemucs config (depth=4, norm_starts=4, kernel_size=8, stride=4,
//  context=1, context_enc=0, dconv_mode=3, freq_emb=0.2) makes a
//  bunch of branches unreachable:
//    - norm: always False on the HEnc/HDecLayer itself (no norm1/
//      norm2 params on the encoder/decoder layer body)
//    - rewrite: always True (params present)
//    - dconv: 1 for encoders, 2 for decoders (params present)
//    - last_freq: never True (freqs stays > kernel_size at every depth)
//    - empty: never True (no last_freq)
//    - MultiWrap: never instantiated (multi_freqs=None)
//
//  So this port only implements the "norm=False, rewrite=True,
//  dconv=True/(mode), empty=False, freq=true|false" paths — the
//  fast paths that production htdemucs actually exercises.
//

import Foundation
import MLX
import MLXNN

// MARK: - HEncLayer

final class HEncLayer: Module {
    let freq: Bool
    let kernelSize: Int
    let stride: Int
    let pad: Int
    let dconvEnabled: Bool

    // Conv (Conv2dNCHW when freq=true, Conv1dNCL when freq=false).
    // We type-erase to Module so one field handles both; this matches
    // the safetensors path `encoder.X.conv.weight` either way (both
    // subclasses expose .weight directly).
    @ModuleInfo var conv: Module
    @ModuleInfo var rewrite: Module
    @ModuleInfo var dconv: DConv?

    init(
        chin: Int,
        chout: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        freq: Bool = true,
        dconv: Bool = true,
        context: Int = 0,
        pad: Bool = true,
        dconvDepth: Int = 2,
        dconvCompress: Float = 8
    ) {
        self.freq = freq
        self.kernelSize = kernelSize
        self.stride = stride
        let padding = pad ? kernelSize / 4 : 0
        self.pad = padding
        self.dconvEnabled = dconv

        if freq {
            self._conv.wrappedValue = Conv2dNCHW(
                inputChannels: chin, outputChannels: chout,
                kernelSize: IntOrPair((kernelSize, 1)),
                stride: IntOrPair((stride, 1)),
                padding: IntOrPair((padding, 0))
            )
            // rewrite kernel = 1 + 2*context_enc; for htdemucs context_enc=0 → 1.
            self._rewrite.wrappedValue = Conv2dNCHW(
                inputChannels: chout, outputChannels: 2 * chout,
                kernelSize: IntOrPair((1 + 2 * context, 1)),
                stride: IntOrPair(1),
                padding: IntOrPair((context, 0))
            )
        } else {
            self._conv.wrappedValue = Conv1dNCL(
                inputChannels: chin, outputChannels: chout,
                kernelSize: kernelSize, stride: stride, padding: padding
            )
            self._rewrite.wrappedValue = Conv1dNCL(
                inputChannels: chout, outputChannels: 2 * chout,
                kernelSize: 1 + 2 * context, stride: 1, padding: context
            )
        }
        if dconv {
            self._dconv.wrappedValue = DConv(
                channels: chout, compress: dconvCompress, depth: dconvDepth
            )
        }
        super.init()
    }

    /// Forward. `inject` is the time-encoder's same-depth output added
    /// into the freq-encoder. Empty/last_freq branches not implemented.
    func callAsFunction(_ x: MLXArray, inject: MLXArray? = nil) -> MLXArray {
        var x = x
        // The "not freq, 4-D" case occurs only when last_freq is true,
        // which doesn't happen in htdemucs. We assert here so a
        // future port catches the case.
        if !freq && x.ndim == 4 {
            preconditionFailure("HEncLayer last_freq path not implemented")
        }
        // Pad to multiple of stride on the last axis (time-path only).
        if !freq {
            let le = x.shape.last!
            if le % stride != 0 {
                x = pad1d(x, paddings: (0, stride - (le % stride)))
            }
        }
        // Conv.
        var y: MLXArray
        if freq {
            y = (conv as! Conv2dNCHW)(x)
        } else {
            y = (conv as! Conv1dNCL)(x)
        }

        // Inject from the parallel encoder.
        if let inject = inject {
            var inj = inject
            if inj.ndim == 3 && y.ndim == 4 {
                inj = inj.expandedDimensions(axis: 2)  // [B, C, 1, T]
            }
            y = y + inj
        }

        // norm1 + gelu — for htdemucs the norm is False so just gelu.
        y = MLXNN.gelu(y)

        // dconv (collapses freq into batch when in 4-D freq path).
        if let dc = dconv {
            if freq {
                let B = y.shape[0]
                let C = y.shape[1]
                let Fr = y.shape[2]
                let T = y.shape[3]
                let reshaped = y.transposed(0, 2, 1, 3).reshaped(-1, C, T)
                let out = dc(reshaped)
                y = out.reshaped(B, Fr, C, T).transposed(0, 2, 1, 3)
            } else {
                y = dc(y)
            }
        }

        // rewrite -> norm2 -> GLU. norm2 omitted (norm=False).
        let r: MLXArray
        if freq {
            r = (rewrite as! Conv2dNCHW)(y)
        } else {
            r = (rewrite as! Conv1dNCL)(y)
        }
        // GLU on channel axis (axis=1 in both NCL and NCHW layouts).
        let parts = MLX.split(r, parts: 2, axis: 1)
        return parts[0] * MLX.sigmoid(parts[1])
    }
}

// MARK: - HDecLayer

final class HDecLayer: Module {
    let freq: Bool
    let chin: Int
    let pad: Int
    let stride: Int
    let last: Bool
    let dconvEnabled: Bool

    @ModuleInfo(key: "conv_tr") var convTr: Module
    @ModuleInfo var rewrite: Module
    @ModuleInfo var dconv: DConv?

    init(
        chin: Int,
        chout: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        freq: Bool = true,
        dconv: Bool = true,
        context: Int = 1,
        pad: Bool = true,
        last: Bool = false,
        dconvDepth: Int = 2,
        dconvCompress: Float = 8
    ) {
        self.freq = freq
        self.chin = chin
        self.stride = stride
        self.last = last
        self.dconvEnabled = dconv
        let padding = pad ? kernelSize / 4 : 0
        self.pad = padding

        if freq {
            self._convTr.wrappedValue = ConvTranspose2dNCHW(
                inputChannels: chin, outputChannels: chout,
                kernelSize: IntOrPair((kernelSize, 1)),
                stride: IntOrPair((stride, 1))
            )
            // For htdemucs context=1, rewrite kernel = (1, 1+2*1) = (1, 3) when
            // context_freq=true (the default). All branches in htdemucs use
            // context_freq=true (multi_freqs=None, so context_freq=true).
            self._rewrite.wrappedValue = Conv2dNCHW(
                inputChannels: chin, outputChannels: 2 * chin,
                kernelSize: IntOrPair((1 + 2 * context, 1 + 2 * context)),
                stride: IntOrPair(1),
                padding: IntOrPair((context, context))
            )
        } else {
            self._convTr.wrappedValue = ConvTranspose1dNCL(
                inputChannels: chin, outputChannels: chout,
                kernelSize: kernelSize, stride: stride
            )
            self._rewrite.wrappedValue = Conv1dNCL(
                inputChannels: chin, outputChannels: 2 * chin,
                kernelSize: 1 + 2 * context, stride: 1, padding: context
            )
        }
        if dconv {
            self._dconv.wrappedValue = DConv(
                channels: chin, compress: dconvCompress, depth: dconvDepth
            )
        }
        super.init()
    }

    /// Returns (z, pre) — `z` is the layer output to pass forward;
    /// `pre` is the rewrite/dconv output before conv_tr, which feeds
    /// into the time-decoder's parallel injection.
    func callAsFunction(_ x: MLXArray, skip: MLXArray?, length: Int) -> (MLXArray, MLXArray) {
        var x = x

        if freq && x.ndim == 3 {
            let B = x.shape[0]
            let T = x.shape[2]
            x = x.reshaped(B, chin, -1, T)
        }

        var y: MLXArray
        // Empty path not implemented (last_freq=false in htdemucs).
        x = x + skip!
        // rewrite -> norm1 (omitted, norm=false) -> GLU.
        let r: MLXArray
        if freq {
            r = (rewrite as! Conv2dNCHW)(x)
        } else {
            r = (rewrite as! Conv1dNCL)(x)
        }
        let parts = MLX.split(r, parts: 2, axis: 1)
        y = parts[0] * MLX.sigmoid(parts[1])

        // dconv.
        if let dc = dconv {
            if freq {
                let B = y.shape[0]
                let C = y.shape[1]
                let Fr = y.shape[2]
                let T = y.shape[3]
                let reshaped = y.transposed(0, 2, 1, 3).reshaped(-1, C, T)
                let out = dc(reshaped)
                y = out.reshaped(B, Fr, C, T).transposed(0, 2, 1, 3)
            } else {
                y = dc(y)
            }
        }

        // conv_tr -> norm2 (omitted) -> trim -> gelu (unless last).
        var z: MLXArray
        if freq {
            z = (convTr as! ConvTranspose2dNCHW)(y)
        } else {
            z = (convTr as! ConvTranspose1dNCL)(y)
        }

        if freq {
            if pad > 0 {
                // Trim freq dim symmetrically.
                let Fr = z.shape[2]
                z = z[0..., 0..., pad ..< (Fr - pad), 0...]
            }
        } else {
            z = z[.ellipsis, pad ..< (pad + length)]
        }

        if !last {
            z = MLXNN.gelu(z)
        }
        return (z, y)
    }
}
