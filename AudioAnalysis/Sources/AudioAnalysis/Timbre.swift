import Foundation

/// A description of a sound's tone color — warm and dark versus bright and sharp.
public struct Timbre: Sendable, Equatable {

    /// The spectral centroid in Hz: the energy-weighted average frequency,
    /// i.e. the "center of mass" of the spectrum.
    public let centroidHz: Double

    /// Perceptual brightness, 0...1, derived from the centroid on a log scale.
    /// 0 is warm and dark; 1 is bright and sharp.
    public var brightness: Float {
        Timbre.brightness(forCentroid: centroidHz)
    }

    /// Creates a timbre from a known spectral centroid.
    public init(centroidHz: Double) {
        self.centroidHz = max(0, centroidHz)
    }

    /// Computes the timbre of a single FFT magnitude spectrum.
    public init(spectrum: [Float], fft: FFTProcessor, sampleRate: Double) {
        var weightedSum = 0.0
        var totalMagnitude = 0.0
        for bin in spectrum.indices {
            let magnitude = Double(spectrum[bin])
            let frequency = fft.frequency(forBin: bin, sampleRate: sampleRate)
            weightedSum += frequency * magnitude
            totalMagnitude += magnitude
        }
        self.centroidHz = totalMagnitude > 0 ? weightedSum / totalMagnitude : 0
    }

    /// Averages timbre across a whole clip, weighting each window by its
    /// energy so loud passages count more and silence contributes nothing.
    public static func average(
        over audio: DecodedAudio,
        fftSize: Int = 8192,
        hopSize: Int? = nil
    ) -> Timbre {
        let hop = hopSize ?? (fftSize / 2)
        guard let fft = FFTProcessor(size: fftSize),
              audio.samples.count >= fftSize else {
            return Timbre(centroidHz: 0)
        }

        var weightedCentroidSum = 0.0
        var weightSum = 0.0
        var start = 0
        while start + fftSize <= audio.samples.count {
            let window = Array(audio.samples[start..<(start + fftSize)])
            let spectrum = fft.magnitudeSpectrum(of: window)
            let energy = spectrum.reduce(0.0) { $0 + Double($1) }
            let centroid = Timbre(spectrum: spectrum, fft: fft, sampleRate: audio.sampleRate).centroidHz
            weightedCentroidSum += centroid * energy
            weightSum += energy
            start += hop
        }

        return Timbre(centroidHz: weightSum > 0 ? weightedCentroidSum / weightSum : 0)
    }

    /// Maps a spectral centroid (Hz) to perceptual brightness (0...1) on a
    /// log scale spanning roughly 100 Hz (dark) to 8 kHz (bright).
    static func brightness(forCentroid centroid: Double) -> Float {
        guard centroid > 0 else { return 0 }
        let low = log2(100.0)
        let high = log2(8000.0)
        let t = (log2(centroid) - low) / (high - low)
        return Float(min(1, max(0, t)))
    }
}
