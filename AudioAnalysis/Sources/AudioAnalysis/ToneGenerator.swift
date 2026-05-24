import Foundation

/// Generates synthetic audio signals with known, predictable properties.
///
/// We use this to test analysis code: if we feed in a signal whose correct
/// answer we already know, we can verify the analyzer produces that answer.
public enum ToneGenerator {

    /// Generates a pure sine wave of an exact sample count.
    ///
    /// - Parameters:
    ///   - frequency: tone pitch in Hz (e.g. 440 is concert A).
    ///   - sampleCount: exact number of samples to produce.
    ///   - sampleRate: samples per second. 48,000 is standard for digital audio.
    ///   - amplitude: peak height of the wave, from 0.0 (silence) to 1.0 (full scale).
    /// - Returns: PCM samples, each in the range `-amplitude...amplitude`.
    public static func sine(
        frequency: Double,
        sampleCount: Int,
        sampleRate: Double = 48_000,
        amplitude: Double = 1.0
    ) -> [Float] {
        let count = max(0, sampleCount)
        var samples = [Float](repeating: 0, count: count)

        // Each sample advances the wave's angle by this much.
        let angularStep = 2.0 * Double.pi * frequency / sampleRate

        for i in 0..<count {
            samples[i] = Float(amplitude * sin(angularStep * Double(i)))
        }
        return samples
    }

    /// Sums several signals into one, sample by sample.
    ///
    /// Playing three sine waves at once produces a chord. The result may
    /// exceed the -1...1 range; that's fine for analysis (we never play it
    /// back), since the FFT only cares about relative energy.
    ///
    /// - Parameter signals: signals to combine. The result's length matches
    ///   the shortest input.
    public static func mix(_ signals: [[Float]]) -> [Float] {
        guard let shortest = signals.map(\.count).min() else { return [] }
        var result = [Float](repeating: 0, count: shortest)
        for signal in signals {
            for i in 0..<shortest {
                result[i] += signal[i]
            }
        }
        return result
    }

    /// Generates a chord: several sine waves of equal amplitude, summed.
    ///
    /// - Parameters:
    ///   - frequencies: the frequency of each note, in Hz.
    ///   - sampleCount: exact number of samples to produce.
    ///   - sampleRate: samples per second.
    ///   - amplitude: peak amplitude of each individual note.
    public static func tones(
        frequencies: [Double],
        sampleCount: Int,
        sampleRate: Double = 48_000,
        amplitude: Double = 1.0
    ) -> [Float] {
        mix(frequencies.map {
            sine(
                frequency: $0,
                sampleCount: sampleCount,
                sampleRate: sampleRate,
                amplitude: amplitude
            )
        })
    }

    /// Generates a sequence of short tone bursts separated by silence —
    /// a click track. Each burst has a sharp attack, useful for testing
    /// onset detection against known onset positions.
    ///
    /// - Parameters:
    ///   - count: number of bursts.
    ///   - interval: time from the start of one burst to the next, in seconds.
    ///   - burstDuration: length of each burst, in seconds.
    ///   - frequency: tone frequency of the bursts.
    ///   - sampleRate: samples per second.
    public static func pulses(
        count: Int,
        interval: Double,
        burstDuration: Double,
        frequency: Double = 440,
        sampleRate: Double = 48_000
    ) -> [Float] {
        let intervalSamples = Int(interval * sampleRate)
        let burstSamples = Int(burstDuration * sampleRate)
        var signal = [Float](repeating: 0, count: count * intervalSamples)

        let burst = sine(
            frequency: frequency,
            sampleCount: burstSamples,
            sampleRate: sampleRate
        )
        for pulse in 0..<count {
            let offset = pulse * intervalSamples
            for i in 0..<min(burstSamples, signal.count - offset) {
                signal[offset + i] = burst[i]
            }
        }
        return signal
    }

    /// Generates a pure sine wave of a given duration.
    ///
    /// - Parameters:
    ///   - frequency: tone pitch in Hz.
    ///   - duration: length of the signal in seconds.
    ///   - sampleRate: samples per second.
    ///   - amplitude: peak height of the wave, from 0.0 to 1.0.
    /// - Returns: PCM samples, each in the range `-amplitude...amplitude`.
    public static func sine(
        frequency: Double,
        duration: Double,
        sampleRate: Double = 48_000,
        amplitude: Double = 1.0
    ) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        return sine(
            frequency: frequency,
            sampleCount: count,
            sampleRate: sampleRate,
            amplitude: amplitude
        )
    }
}
