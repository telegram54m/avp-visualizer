import Accelerate

/// Computes the frequency content of a block of audio samples using a
/// Fast Fourier Transform (FFT).
///
/// Create one `FFTProcessor` for a fixed FFT size and reuse it — the setup
/// is moderately expensive to build but cheap to run repeatedly.
public final class FFTProcessor {

    /// Number of input samples the FFT consumes per call. Always a power of two.
    public let size: Int

    private let fft: vDSP.FFT<DSPSplitComplex>

    /// A Hann window, applied to the samples before the transform to reduce
    /// "spectral leakage" — energy smearing caused by the abrupt edges of a
    /// finite block of audio.
    private let window: [Float]

    /// Creates a processor for a given FFT size.
    ///
    /// - Parameter size: number of samples per FFT. Must be a power of two
    ///   (e.g. 1024, 2048, 4096). Returns `nil` otherwise.
    public init?(size: Int) {
        guard size >= 2, (size & (size - 1)) == 0 else { return nil }
        guard let fft = vDSP.FFT(
            log2n: vDSP_Length(log2(Double(size))),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        ) else {
            return nil
        }
        self.size = size
        self.fft = fft
        self.window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: size,
            isHalfWindow: false
        )
    }

    /// Returns the magnitude spectrum of a block of samples: how much energy
    /// is present at each frequency bin.
    ///
    /// - Parameter samples: exactly `size` audio samples.
    /// - Returns: `size / 2` magnitude values, one per frequency bin, ordered
    ///   from lowest frequency to highest.
    public func magnitudeSpectrum(of samples: [Float]) -> [Float] {
        precondition(
            samples.count == size,
            "FFTProcessor expects exactly \(size) samples, got \(samples.count)"
        )

        // Taper the edges so the FFT doesn't see a false discontinuity.
        let windowed = vDSP.multiply(samples, window)

        let halfSize = size / 2
        var realIn = [Float](repeating: 0, count: halfSize)
        var imagIn = [Float](repeating: 0, count: halfSize)
        var realOut = [Float](repeating: 0, count: halfSize)
        var imagOut = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realIn.withUnsafeMutableBufferPointer { realInPtr in
        imagIn.withUnsafeMutableBufferPointer { imagInPtr in
        realOut.withUnsafeMutableBufferPointer { realOutPtr in
        imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
            var input = DSPSplitComplex(
                realp: realInPtr.baseAddress!,
                imagp: imagInPtr.baseAddress!
            )
            var output = DSPSplitComplex(
                realp: realOutPtr.baseAddress!,
                imagp: imagOutPtr.baseAddress!
            )

            // Pack the real samples into the split-complex layout vDSP expects.
            windowed.withUnsafeBytes { rawBuffer in
                let interleaved = rawBuffer.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(interleaved.baseAddress!, 2, &input, 1, vDSP_Length(halfSize))
            }

            // Run the transform.
            fft.transform(input: input, output: &output, direction: .forward)

            // Convert each complex bin into a single magnitude (its energy).
            vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(halfSize))
        }}}}

        return magnitudes
    }

    /// The center frequency, in Hz, of a given bin.
    public func frequency(forBin bin: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(size)
    }

    /// Estimates the single loudest frequency in a block of samples.
    ///
    /// This is a crude pitch estimate — it just finds the bin with the most
    /// energy. Good enough to verify the FFT works; real pitch detection comes later.
    public func dominantFrequency(of samples: [Float], sampleRate: Double) -> Double {
        let spectrum = magnitudeSpectrum(of: samples)
        var peakBin = 0
        var peakValue: Float = 0
        for (bin, value) in spectrum.enumerated() where value > peakValue {
            peakValue = value
            peakBin = bin
        }
        return frequency(forBin: peakBin, sampleRate: sampleRate)
    }
}
