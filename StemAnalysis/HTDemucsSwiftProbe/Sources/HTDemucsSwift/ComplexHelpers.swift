//
//  ComplexHelpers.swift — bridge between (real, imag) MLXArray pairs
//  and the complex64 dtype that mlx-swift's FFT consumes.
//
//  mlx-swift exposes `Complex<Float>` scalars and supports complex
//  dtypes (DType.complex64), but the primary API doesn't ship a
//  "make complex array from real + imag" function. We synthesize one
//  by stacking the parts along a new last axis and reinterpreting
//  the float32 buffer as complex64. The byte layout matches:
//  complex64 = (Float32 real, Float32 imag) interleaved, which is
//  exactly what `stacked([real, imag], axis: -1)` produces in memory
//  when the result is contiguous.
//

import Foundation
import MLX
import ComplexModule

/// Compose `real + i*imag` into a complex64 MLXArray with the same
/// shape as the inputs.
func realImagToComplex(real: MLXArray, imag: MLXArray) -> MLXArray {
    precondition(real.shape == imag.shape, "shape mismatch")
    // Stack along a new last axis -> [..., 2] float32.
    let interleaved = MLX.stacked([real, imag], axis: -1).contiguous()
    // Reinterpret the underlying float32 buffer as complex64. We use
    // mlx-swift's array initializer from raw bytes: copy bytes out,
    // build a new complex MLXArray with the same shape (minus the
    // trailing dim of 2).
    let outShape = real.shape
    let count = outShape.reduce(1, *)
    // Pull bytes.
    let floats: [Float] = interleaved.asArray(Float.self)
    var complexes = [Complex<Float>](repeating: .zero, count: count)
    for i in 0 ..< count {
        complexes[i] = Complex(floats[2 * i], floats[2 * i + 1])
    }
    // Build a complex64 MLXArray from the buffer.
    let arr = MLXArray(complexes, outShape)
    return arr
}
