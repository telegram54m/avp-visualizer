//
//  RFFTProbe.swift — verify mlx-swift's MLXFFT.rfft normalization
//  matches mlx Python's mx.fft.rfft (which matches numpy's default).
//

import Foundation
import MLX
import MLXFFT

public enum RFFTProbe {
    /// Build a constant input of value 1.0, length n, run rfft, return
    /// the DC bin's real part. For an unnormalized rfft, DC = sum = n.
    /// For norm="ortho", DC = sqrt(n). For norm="forward", DC = 1.0.
    public static func probeDC(n: Int) -> Float {
        let x = MLXArray.ones([n])
        let y = MLXFFT.rfft(x, axis: -1)
        let dcReal = y[0].realPart()
        eval(dcReal)
        return dcReal.asArray(Float.self)[0]
    }
}
