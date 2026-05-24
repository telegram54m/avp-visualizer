import Foundation

/// The distribution of musical energy across the twelve pitch classes.
///
/// A chromagram folds every octave of the frequency spectrum together, so
/// it answers "which note names are sounding" regardless of octave. It is
/// the input to key detection.
public struct Chromagram: Sendable {

    /// Energy per pitch class, indexed by `PitchClass.rawValue`. Always 12 values.
    public let values: [Float]

    /// Looks up the energy of a single pitch class.
    public subscript(_ pitchClass: PitchClass) -> Float {
        values[pitchClass.rawValue]
    }

    /// The pitch class carrying the most energy.
    public var dominant: PitchClass {
        let index = values.indices.max(by: { values[$0] < values[$1] }) ?? 0
        return PitchClass(rawValue: index)!
    }

    /// Creates a chromagram directly from 12 pitch-class energy values.
    public init(values: [Float]) {
        precondition(values.count == 12, "A chromagram has exactly 12 values")
        self.values = values
    }

    /// Builds one averaged chromagram for an entire clip.
    ///
    /// A single FFT window covers only a fraction of a second — far too short
    /// to be representative of a song. This slides an FFT window across the
    /// whole clip and sums the per-window chromagrams, producing a stable
    /// pitch-class fingerprint for the full clip.
    ///
    /// - Parameters:
    ///   - audio: the decoded clip to analyze.
    ///   - fftSize: FFT window size. Must be a power of two.
    ///   - hopSize: how far the window advances each step. Defaults to half
    ///     the FFT size (50% overlap).
    ///   - minFrequency: bins below this are ignored. Raise it (or lower
    ///     `maxFrequency`) to isolate a register — e.g. the bass.
    ///   - maxFrequency: bins above this are ignored.
    public static func aggregate(
        over audio: DecodedAudio,
        fftSize: Int = 8192,
        hopSize: Int? = nil,
        minFrequency: Double = 65.0,
        maxFrequency: Double = 2000.0
    ) -> Chromagram {
        let hop = hopSize ?? (fftSize / 2)
        guard let fft = FFTProcessor(size: fftSize),
              audio.samples.count >= fftSize else {
            return Chromagram(values: [Float](repeating: 0, count: 12))
        }

        var summed = [Float](repeating: 0, count: 12)
        var start = 0
        while start + fftSize <= audio.samples.count {
            let window = Array(audio.samples[start..<(start + fftSize)])
            let chroma = Chromagram(
                spectrum: fft.magnitudeSpectrum(of: window),
                fft: fft,
                sampleRate: audio.sampleRate,
                minFrequency: minFrequency,
                maxFrequency: maxFrequency
            )
            for i in 0..<12 {
                summed[i] += chroma.values[i]
            }
            start += hop
        }
        return Chromagram(values: summed)
    }

    /// Builds a chromagram from an FFT magnitude spectrum.
    ///
    /// - Parameters:
    ///   - spectrum: magnitudes from `FFTProcessor.magnitudeSpectrum(of:)`.
    ///   - fft: the processor that produced the spectrum (used to map bins to Hz).
    ///   - sampleRate: sample rate of the original audio.
    ///   - minFrequency: bins below this are ignored (default ~C2). Very low
    ///     frequencies are too coarse to assign a pitch class reliably.
    ///   - maxFrequency: bins above this are ignored (default ~B6). High
    ///     harmonics add noise rather than pitch information.
    public init(
        spectrum: [Float],
        fft: FFTProcessor,
        sampleRate: Double,
        minFrequency: Double = 65.0,
        maxFrequency: Double = 2000.0
    ) {
        var bins = [Float](repeating: 0, count: 12)
        for bin in spectrum.indices {
            let frequency = fft.frequency(forBin: bin, sampleRate: sampleRate)
            guard frequency >= minFrequency, frequency <= maxFrequency else { continue }
            bins[PitchClass.of(frequency: frequency).rawValue] += spectrum[bin]
        }
        self.values = bins
    }
}
