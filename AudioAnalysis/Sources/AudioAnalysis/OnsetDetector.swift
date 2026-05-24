import Foundation

/// The result of onset detection over a clip.
public struct OnsetResult: Sendable {

    /// Times, in seconds, at which onsets were detected.
    public let onsetTimes: [Double]

    /// The raw novelty curve — spectral flux per frame — for inspection.
    public let noveltyCurve: [Float]

    /// Duration of one novelty-curve frame, in seconds.
    public let frameDuration: Double

    /// Onsets per second across the analyzed span.
    public var onsetRate: Double {
        let span = Double(noveltyCurve.count) * frameDuration
        return span > 0 ? Double(onsetTimes.count) / span : 0
    }
}

/// Detects note and percussion onsets using spectral flux.
public enum OnsetDetector {

    /// Finds onsets in a clip.
    ///
    /// - Parameters:
    ///   - audio: the decoded clip.
    ///   - fftSize: FFT window size. Small by default — onsets need fine time
    ///     resolution, not fine frequency resolution.
    ///   - hopSize: how far the window advances each frame.
    ///   - minimumGap: minimum time between onsets, in seconds, so a single
    ///     hit spanning several frames isn't counted more than once.
    public static func detect(
        in audio: DecodedAudio,
        fftSize: Int = 2048,
        hopSize: Int = 512,
        minimumGap: Double = 0.1
    ) -> OnsetResult {
        let frameDuration = Double(hopSize) / audio.sampleRate
        guard let fft = FFTProcessor(size: fftSize),
              audio.samples.count >= fftSize else {
            return OnsetResult(onsetTimes: [], noveltyCurve: [], frameDuration: frameDuration)
        }

        // 1. Novelty curve: half-wave-rectified spectral flux. Only rising
        //    energy counts — a decaying note is not a new onset.
        var novelty: [Float] = []
        var previousSpectrum: [Float]?
        var start = 0
        while start + fftSize <= audio.samples.count {
            let window = Array(audio.samples[start..<(start + fftSize)])
            let spectrum = fft.magnitudeSpectrum(of: window)

            var flux: Float = 0
            if let previous = previousSpectrum {
                for bin in spectrum.indices {
                    let rise = spectrum[bin] - previous[bin]
                    if rise > 0 { flux += rise }
                }
            } else {
                flux = spectrum.reduce(0, +)  // first frame: a rise from silence
            }
            novelty.append(flux)
            previousSpectrum = spectrum
            start += hopSize
        }

        guard !novelty.isEmpty else {
            return OnsetResult(onsetTimes: [], noveltyCurve: novelty, frameDuration: frameDuration)
        }

        // 2. Adaptive threshold: the curve's mean plus one standard deviation.
        let count = Float(novelty.count)
        let mean = novelty.reduce(0, +) / count
        let variance = novelty.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let threshold = mean + variance.squareRoot()

        // 3. Peak-pick: a local maximum above threshold, debounced by minimumGap.
        var onsetTimes: [Double] = []
        var lastOnsetTime = -Double.infinity
        for i in novelty.indices {
            let value = novelty[i]
            guard value > threshold else { continue }
            let previous = i > 0 ? novelty[i - 1] : 0
            let next = i < novelty.count - 1 ? novelty[i + 1] : 0
            guard value >= previous, value >= next else { continue }

            let time = Double(i) * frameDuration
            guard time - lastOnsetTime >= minimumGap else { continue }
            onsetTimes.append(time)
            lastOnsetTime = time
        }

        return OnsetResult(
            onsetTimes: onsetTimes,
            noveltyCurve: novelty,
            frameDuration: frameDuration
        )
    }
}
