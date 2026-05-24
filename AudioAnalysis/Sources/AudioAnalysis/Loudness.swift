import Foundation

/// Time-domain loudness measurement.
public enum Loudness {

    /// Root-mean-square (RMS) amplitude of a block of samples.
    ///
    /// RMS is a better proxy for *perceived* loudness than peak amplitude,
    /// because it accounts for the energy across the whole block rather than
    /// just the single loudest sample.
    ///
    /// Reference value: a full-scale sine wave (amplitude 1.0) has an RMS of
    /// `1 / sqrt(2)` ≈ 0.7071.
    ///
    /// - Returns: the RMS value, or 0 for an empty input.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sumOfSquares = 0.0
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
        }
        let meanSquare = sumOfSquares / Double(samples.count)
        return Float(meanSquare.squareRoot())
    }
}
