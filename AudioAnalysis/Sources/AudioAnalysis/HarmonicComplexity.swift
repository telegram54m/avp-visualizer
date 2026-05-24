import Foundation

/// A measure of how spectrally dense a sound is — a pure tone versus a
/// many-layered ensemble or a wall of distortion.
public struct HarmonicComplexity: Sendable, Equatable {

    /// Number of significant peaks found in the spectrum.
    public let peakCount: Int

    /// Normalized complexity: 0 for a near-pure tone, approaching 1 for dense,
    /// many-component sounds.
    public var value: Float {
        Float(min(1.0, Double(peakCount) / 40.0))
    }

    /// Creates a complexity measure from a known peak count.
    public init(peakCount: Int) {
        self.peakCount = max(0, peakCount)
    }

    /// Counts significant spectral peaks in an FFT magnitude spectrum.
    ///
    /// A peak is a local maximum that rises above a fraction of the
    /// spectrum's loudest bin — so faint side-lobes and noise are ignored.
    ///
    /// - Parameters:
    ///   - spectrum: an FFT magnitude spectrum.
    ///   - peakThreshold: minimum height, as a fraction of the loudest bin.
    public init(spectrum: [Float], peakThreshold: Float = 0.1) {
        guard spectrum.count > 2, let maxMagnitude = spectrum.max(), maxMagnitude > 0 else {
            self.peakCount = 0
            return
        }
        let cutoff = maxMagnitude * peakThreshold
        var count = 0
        for i in 1..<(spectrum.count - 1) {
            let magnitude = spectrum[i]
            if magnitude > cutoff,
               magnitude >= spectrum[i - 1],
               magnitude > spectrum[i + 1] {
                count += 1
            }
        }
        self.peakCount = count
    }

    /// Averages harmonic complexity across a whole clip.
    public static func average(
        over audio: DecodedAudio,
        fftSize: Int = 8192,
        hopSize: Int? = nil
    ) -> HarmonicComplexity {
        let hop = hopSize ?? (fftSize / 2)
        guard let fft = FFTProcessor(size: fftSize),
              audio.samples.count >= fftSize else {
            return HarmonicComplexity(peakCount: 0)
        }

        var totalPeaks = 0
        var windows = 0
        var start = 0
        while start + fftSize <= audio.samples.count {
            let window = Array(audio.samples[start..<(start + fftSize)])
            let spectrum = fft.magnitudeSpectrum(of: window)
            totalPeaks += HarmonicComplexity(spectrum: spectrum).peakCount
            windows += 1
            start += hop
        }
        return HarmonicComplexity(peakCount: windows > 0 ? totalPeaks / windows : 0)
    }
}
