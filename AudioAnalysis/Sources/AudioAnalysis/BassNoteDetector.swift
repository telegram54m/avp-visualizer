import Foundation

/// An estimate of a clip's bass root: the pitch class plus how dominant it was.
public struct BassEstimate: Sendable {
    public let pitchClass: PitchClass

    /// Fraction of analyzed windows that voted for this pitch class, 0...1.
    /// Low values mean the bass was ambiguous and the hint is less trustworthy.
    public let prominence: Float
}

/// Estimates the most prominent bass note of a clip.
///
/// The tonic of a song is very often the note its bass keeps returning to.
/// This finds, in each short window, the single strongest peak in the bass
/// frequency range, then takes the most frequent pitch class across the clip.
public enum BassNoteDetector {

    /// - Parameters:
    ///   - audio: the decoded clip.
    ///   - fftSize: FFT window size. Large by default — low frequencies need
    ///     fine resolution, since semitones are only a few Hz apart down there.
    ///   - minFrequency: lowest bass frequency to consider.
    ///   - maxFrequency: highest bass frequency to consider.
    /// - Returns: the bass estimate, or `nil` if the clip is too short.
    public static func detect(
        in audio: DecodedAudio,
        fftSize: Int = 32_768,
        minFrequency: Double = 40,
        maxFrequency: Double = 200
    ) -> BassEstimate? {
        guard let fft = FFTProcessor(size: fftSize),
              audio.samples.count >= fftSize else {
            return nil
        }

        let hop = fftSize / 2
        var histogram = [Int](repeating: 0, count: 12)
        var windowsCounted = 0

        var start = 0
        while start + fftSize <= audio.samples.count {
            defer { start += hop }
            let window = Array(audio.samples[start..<(start + fftSize)])
            let spectrum = fft.magnitudeSpectrum(of: window)

            // Find the strongest bin in the bass range, and the range's mean.
            var peakBin = -1
            var peakValue: Float = 0
            var sum: Float = 0
            var count = 0
            for bin in spectrum.indices {
                let frequency = fft.frequency(forBin: bin, sampleRate: audio.sampleRate)
                if frequency < minFrequency { continue }
                if frequency > maxFrequency { break }
                sum += spectrum[bin]
                count += 1
                if spectrum[bin] > peakValue {
                    peakValue = spectrum[bin]
                    peakBin = bin
                }
            }
            guard peakBin >= 0, count > 0 else { continue }

            // Require a real peak — well above the window's bass-range average.
            // This rejects windows that are just broadband noise (e.g. a kick).
            let mean = sum / Float(count)
            guard peakValue > mean * 2 else { continue }

            let frequency = fft.frequency(forBin: peakBin, sampleRate: audio.sampleRate)
            histogram[PitchClass.of(frequency: frequency).rawValue] += 1
            windowsCounted += 1
        }

        guard windowsCounted > 0,
              let bestIndex = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
              histogram[bestIndex] > 0 else {
            return nil
        }

        return BassEstimate(
            pitchClass: PitchClass(rawValue: bestIndex)!,
            prominence: Float(histogram[bestIndex]) / Float(windowsCounted)
        )
    }
}
