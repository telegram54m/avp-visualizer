import Foundation

/// One of four broad frequency bands aligned to roles in a typical mix:
///   • `sub` (20–120 Hz) — kick fundamentals, sub bass, the "body-hit"
///     register. Below where chromagram pitch detection is reliable.
///   • `lowMid` (120–500 Hz) — bass guitar/synth fundamentals, chord
///     roots in lower octaves, the punch part of kicks. Most "bass"
///     instrument energy concentrates here.
///   • `highMid` (500–4000 Hz) — lead vocals, lead synths, snare body,
///     melodic content. Most of a song's harmonic and melodic identity
///     lives in this band.
///   • `brilliance` (4000–16000 Hz) — hi-hats, shakers, cymbals,
///     sibilance, the "air" of a mix. Carries rhythmic-percussion
///     information distinct from kicks and snares.
///
/// The split is deliberately coarse — four bands is enough to drive
/// "sub vs. bass vs. lead vs. hats" routing in a visualizer without
/// needing source separation. The boundaries are rough mixer-style
/// guesses, not calibrated psychoacoustic boundaries.
public enum FrequencyBand: Int, CaseIterable, Sendable {
    case sub = 0
    case lowMid = 1
    case highMid = 2
    case brilliance = 3

    /// Lower frequency bound (inclusive) in Hz.
    public var minFrequency: Double {
        switch self {
        case .sub: 20
        case .lowMid: 120
        case .highMid: 500
        case .brilliance: 4000
        }
    }

    /// Upper frequency bound (exclusive) in Hz.
    public var maxFrequency: Double {
        switch self {
        case .sub: 120
        case .lowMid: 500
        case .highMid: 4000
        case .brilliance: 16000
        }
    }

    public var name: String {
        switch self {
        case .sub: "sub"
        case .lowMid: "lowMid"
        case .highMid: "highMid"
        case .brilliance: "brilliance"
        }
    }
}

/// Splits an FFT magnitude spectrum into per-band loudness + chromagram.
///
/// Same input format as `Chromagram.init(spectrum:fft:sampleRate:)` —
/// pass it the spectrum produced by `FFTProcessor.magnitudeSpectrum(of:)`
/// for the current window. Both arrays it produces are always length 4
/// (one entry per `FrequencyBand`); the chromagram entries are each
/// length 12.
///
/// The per-band loudness is the *mean magnitude per bin* in that band's
/// frequency range — normalizing by bin count keeps the value
/// independent of how wide the band is in Hz (sub spans 100 Hz,
/// brilliance spans 12,000 Hz; raw sums would make brilliance always
/// dominate). It's not RMS in the strict sense — it's a scale-matched
/// proxy that EMA-smoothes cleanly and tracks the perceived energy in
/// the band well enough for visualizer reactivity.
///
/// The per-band chromagram uses the same fold-octaves-together math as
/// the full-spectrum `Chromagram`, but only bins inside the band
/// contribute. Sub and brilliance chromagrams will be mostly empty —
/// sub bins fall below the chroma `minFrequency` floor (65 Hz),
/// brilliance bins above its `maxFrequency` ceiling (2000 Hz). Both
/// are retained as length-12 zero arrays for API uniformity.
public struct BandedSpectrum: Sendable {

    /// Per-band loudness — mean magnitude per bin within the band.
    /// Length 4, indexed by `FrequencyBand.rawValue`.
    public let loudness: [Float]

    /// Per-band pitch-class energies. Length 4 (one per band); each
    /// inner array has length 12 (one per pitch class). Indexed by
    /// `FrequencyBand.rawValue` then `PitchClass.rawValue`.
    public let chromagram: [[Float]]

    /// Same chromagram cutoffs as `Chromagram.init` defaults — bins
    /// outside this window contribute nothing to ANY band's chromagram,
    /// even though they DO contribute to that band's loudness. Means
    /// per-band chromagrams are uniformly chroma-relevant only.
    public static let chromaMinFrequency: Double = 65.0
    public static let chromaMaxFrequency: Double = 2000.0

    public init(
        spectrum: [Float],
        fft: FFTProcessor,
        sampleRate: Double
    ) {
        var bandSums = [Float](repeating: 0, count: FrequencyBand.allCases.count)
        var bandBinCounts = [Int](repeating: 0, count: FrequencyBand.allCases.count)
        var bandChromas = Array(
            repeating: [Float](repeating: 0, count: 12),
            count: FrequencyBand.allCases.count
        )

        for bin in spectrum.indices {
            let frequency = fft.frequency(forBin: bin, sampleRate: sampleRate)
            // Skip bins outside the union of all band ranges. (Cheap
            // early-out — anything below sub.min or above brilliance.max
            // contributes nothing.)
            guard frequency >= FrequencyBand.sub.minFrequency,
                  frequency < FrequencyBand.brilliance.maxFrequency
            else { continue }

            // Each bin lands in exactly one band — ranges are disjoint
            // ([min, max)).
            let bandIndex: Int
            if frequency < FrequencyBand.lowMid.minFrequency {
                bandIndex = FrequencyBand.sub.rawValue
            } else if frequency < FrequencyBand.highMid.minFrequency {
                bandIndex = FrequencyBand.lowMid.rawValue
            } else if frequency < FrequencyBand.brilliance.minFrequency {
                bandIndex = FrequencyBand.highMid.rawValue
            } else {
                bandIndex = FrequencyBand.brilliance.rawValue
            }

            let mag = spectrum[bin]
            bandSums[bandIndex] += mag
            bandBinCounts[bandIndex] += 1

            if frequency >= Self.chromaMinFrequency,
               frequency <= Self.chromaMaxFrequency {
                let pc = PitchClass.of(frequency: frequency).rawValue
                bandChromas[bandIndex][pc] += mag
            }
        }

        var loud = [Float](repeating: 0, count: FrequencyBand.allCases.count)
        for i in loud.indices {
            loud[i] = bandBinCounts[i] > 0
                ? bandSums[i] / Float(bandBinCounts[i])
                : 0
        }
        self.loudness = loud
        self.chromagram = bandChromas
    }

    /// Returns a `BandedSpectrum` with all-zero loudness and chromagrams.
    /// Convenient default for cases where banded data isn't computed
    /// (e.g. backward-compatible `FeatureFrame` init).
    public static var zero: BandedSpectrum {
        BandedSpectrum(zeroFilled: ())
    }

    private init(zeroFilled: Void) {
        self.loudness = [Float](repeating: 0, count: FrequencyBand.allCases.count)
        self.chromagram = Array(
            repeating: [Float](repeating: 0, count: 12),
            count: FrequencyBand.allCases.count
        )
    }
}

/// Per-band streaming-flux onset detector. Same shape as
/// `StreamingAnalyzer`'s internal onset logic, but split across the
/// four `FrequencyBand`s so the visualizer can distinguish "kick
/// fired" from "hat fired" from "lead chord stab fired."
///
/// Maintains a per-band running-average baseline of half-wave-rectified
/// spectral flux and emits an onset for a band when its instantaneous
/// flux crosses `onsetThreshold × baseline`. Per-band refractory
/// windows prevent a single transient (which spreads across multiple
/// hop windows in any one band) from re-firing.
///
/// Designed for one instance per analyzer; share between offline and
/// online by calling `process(spectrum:)` once per emitted frame.
public final class BandedOnsetDetector {

    /// Ratio threshold (instantaneous flux / running baseline) that
    /// counts as an onset for a band. Same tuning range as the scalar
    /// streaming detector: 1.5–2.0.
    public var onsetThreshold: Float

    /// Minimum spacing between successive onsets within the same band,
    /// in seconds.
    public var refractory: Double

    /// EMA smoothing factor for the per-band baselines.
    public var baselineSmoothing: Float

    private let fft: FFTProcessor
    private let sampleRate: Double

    /// Bin-range cache — first/last bin in each band, computed once at
    /// init from the FFT geometry.
    private let bandBinRanges: [(start: Int, endExclusive: Int)]

    // Per-band streaming state.
    private var previousSpectrum: [Float]?
    private var baselines: [Float]
    private var timeSinceLastOnset: [Double]
    private var isFirst: Bool = true

    public init(
        fft: FFTProcessor,
        sampleRate: Double,
        onsetThreshold: Float = 1.7,
        refractory: Double = 0.08,
        baselineSmoothing: Float = 0.05
    ) {
        self.fft = fft
        self.sampleRate = sampleRate
        self.onsetThreshold = onsetThreshold
        self.refractory = refractory
        self.baselineSmoothing = baselineSmoothing
        let bandCount = FrequencyBand.allCases.count
        self.baselines = [Float](repeating: 0.001, count: bandCount)
        self.timeSinceLastOnset = [Double](repeating: .infinity, count: bandCount)

        // Precompute bin ranges per band — same partition logic as
        // `BandedSpectrum.init`, but done once instead of per-frame.
        let halfSize = fft.size / 2
        var ranges = Array(
            repeating: (start: halfSize, endExclusive: halfSize),
            count: bandCount
        )
        for bandIdx in 0..<bandCount {
            let band = FrequencyBand(rawValue: bandIdx)!
            var start = -1
            var end = -1
            for bin in 0..<halfSize {
                let f = fft.frequency(forBin: bin, sampleRate: sampleRate)
                if f >= band.minFrequency && f < band.maxFrequency {
                    if start < 0 { start = bin }
                    end = bin + 1
                } else if start >= 0 {
                    break
                }
            }
            if start >= 0 {
                ranges[bandIdx] = (start, end)
            }
        }
        self.bandBinRanges = ranges
    }

    /// Process one frame's spectrum + the elapsed time since the
    /// previous frame. Returns a length-4 bool array (one per band).
    public func process(spectrum: [Float], deltaTime: Double) -> [Bool] {
        let bandCount = FrequencyBand.allCases.count
        var onsets = [Bool](repeating: false, count: bandCount)

        for i in 0..<bandCount {
            timeSinceLastOnset[i] += deltaTime
        }

        // Skip the very first spectrum so a cold-start "rise from
        // silence" doesn't fire onsets on every band.
        guard let previous = previousSpectrum else {
            previousSpectrum = spectrum
            isFirst = false
            return onsets
        }

        for bandIdx in 0..<bandCount {
            let (start, endExclusive) = bandBinRanges[bandIdx]
            guard start < endExclusive else { continue }

            var flux: Float = 0
            for bin in start..<endExclusive {
                let rise = spectrum[bin] - previous[bin]
                if rise > 0 { flux += rise }
            }

            let ratio = flux / max(baselines[bandIdx], 0.0001)
            if ratio > onsetThreshold && timeSinceLastOnset[bandIdx] > refractory {
                onsets[bandIdx] = true
                timeSinceLastOnset[bandIdx] = 0
            }
            baselines[bandIdx] = (1 - baselineSmoothing) * baselines[bandIdx]
                               + baselineSmoothing * flux
        }

        previousSpectrum = spectrum
        return onsets
    }

    /// Drop accumulated state so the next call's first spectrum is
    /// treated as a cold start.
    public func reset() {
        previousSpectrum = nil
        for i in baselines.indices { baselines[i] = 0.001 }
        for i in timeSinceLastOnset.indices { timeSinceLastOnset[i] = .infinity }
        isFirst = true
    }
}
