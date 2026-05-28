import Foundation

/// A snapshot of the visual-relevant audio features at one moment in time.
public struct FeatureFrame: Sendable, Codable {
    public let time: Double
    public let color: TonalColor
    public let timbreBrightness: Float
    public let loudness: Float
    public let harmonicComplexity: Float
    public let onset: Bool
    /// The 12 pitch-class energy weights from the underlying chromagram, in
    /// `PitchClass.rawValue` order (C, C#, D, …, B). Same array that
    /// `TonalColor.init(chromagram:)` collapses into a single hue —
    /// retained here so visualizers that want per-pitch-class behavior
    /// (Aurora's 12 sky streaks, a future Dodecahedron) don't have to
    /// re-run the FFT. Always length 12.
    public let chromagram: [Float]
    /// Per-frame beat-tracker output. See ``BeatState`` for the shape;
    /// `beat.beatTrigger` is the rhythmic counterpart to ``onset`` —
    /// fires on a predicted beat grid (even between actual onsets) once
    /// the tracker has locked. Gate visual behavior on
    /// `beat.confidence > ~0.3`.
    public let beat: BeatState
    /// Per-band loudness — length 4, indexed by `FrequencyBand.rawValue`
    /// (sub / lowMid / highMid / brilliance). Mean magnitude per bin
    /// within each band's frequency range. Lets a visualizer route the
    /// kick to one lane, the bass to another, the lead to a third,
    /// the hats to a fourth — instead of merging them into a single
    /// scalar `loudness`.
    public let bandLoudness: [Float]
    /// Per-band chromagram — 4 × 12. Indexed by `FrequencyBand.rawValue`
    /// then `PitchClass.rawValue`. Sub and brilliance entries are
    /// near-empty (their bins fall outside the chromagram's reliable
    /// pitch range); the harmonic content concentrates in lowMid and
    /// highMid.
    public let bandChromagram: [[Float]]
    /// Per-band onset — length 4. Distinguishes "kick fired" (sub)
    /// from "snare hit" (highMid) from "hat fired" (brilliance), so a
    /// visualizer can react to percussive events per-register.
    public let bandOnset: [Bool]

    public init(
        time: Double,
        color: TonalColor,
        timbreBrightness: Float,
        loudness: Float,
        harmonicComplexity: Float,
        onset: Bool,
        chromagram: [Float],
        beat: BeatState = .unknown,
        bandLoudness: [Float]? = nil,
        bandChromagram: [[Float]]? = nil,
        bandOnset: [Bool]? = nil
    ) {
        precondition(chromagram.count == 12, "chromagram must have 12 values")
        let bandCount = FrequencyBand.allCases.count
        let resolvedBandLoudness = bandLoudness
            ?? [Float](repeating: 0, count: bandCount)
        let resolvedBandChromagram = bandChromagram
            ?? Array(repeating: [Float](repeating: 0, count: 12), count: bandCount)
        let resolvedBandOnset = bandOnset
            ?? [Bool](repeating: false, count: bandCount)
        precondition(resolvedBandLoudness.count == bandCount,
                     "bandLoudness must have \(bandCount) values")
        precondition(resolvedBandChromagram.count == bandCount,
                     "bandChromagram must have \(bandCount) entries")
        precondition(resolvedBandChromagram.allSatisfy { $0.count == 12 },
                     "each bandChromagram entry must have 12 values")
        precondition(resolvedBandOnset.count == bandCount,
                     "bandOnset must have \(bandCount) values")
        self.time = time
        self.color = color
        self.timbreBrightness = timbreBrightness
        self.loudness = loudness
        self.harmonicComplexity = harmonicComplexity
        self.onset = onset
        self.chromagram = chromagram
        self.beat = beat
        self.bandLoudness = resolvedBandLoudness
        self.bandChromagram = resolvedBandChromagram
        self.bandOnset = resolvedBandOnset
    }

    /// Returns a copy of the frame with `time` replaced. Used by
    /// `AppModel.appendLiveFrames` to rewrite streaming-analyzer frame
    /// times onto the playback clock's array-index-based timeline: the
    /// analyzer's internal `emittedFrames / frameRate` resets to 0 on
    /// each toggle-on, so its `time` doesn't match `playbackTime` once
    /// preview frames are already in the buffer. Visualizers that
    /// compute physics from `clock - frame.time` (Slipstream, Crystal's
    /// camera-look-ahead, Architecture's pop-in) get a stale-by-30s
    /// `time` otherwise, immediately evicting freshly-spawned entities.
    public func withTime(_ newTime: Double) -> FeatureFrame {
        FeatureFrame(
            time: newTime,
            color: color,
            timbreBrightness: timbreBrightness,
            loudness: loudness,
            harmonicComplexity: harmonicComplexity,
            onset: onset,
            chromagram: chromagram,
            beat: beat,
            bandLoudness: bandLoudness,
            bandChromagram: bandChromagram,
            bandOnset: bandOnset
        )
    }
}

/// Runs the analysis pipeline frame-by-frame across a clip, producing a
/// time series of feature snapshots suitable for driving a visualization.
public enum AnalysisTimeline {

    /// Analyzes a clip into a sequence of feature frames.
    ///
    /// - Parameters:
    ///   - audio: the decoded clip.
    ///   - frameRate: feature snapshots per second.
    ///   - windowSize: FFT window used for each frame's spectral features.
    public static func analyze(
        _ audio: DecodedAudio,
        frameRate: Double = 30,
        windowSize: Int = 8192
    ) -> [FeatureFrame] {
        guard let fft = FFTProcessor(size: windowSize),
              audio.samples.count >= windowSize else {
            return []
        }

        // Onsets are detected once over the whole clip, then mapped to frames.
        let onsets = OnsetDetector.detect(in: audio)
        var onsetFrames = Set<Int>()
        for time in onsets.onsetTimes {
            onsetFrames.insert(Int((time * frameRate).rounded()))
        }

        // Global tempo estimate over the whole clip — used to seed the
        // beat tracker with a confident lock from frame 0 (the online
        // streaming case has to learn tempo gradually; offline doesn't).
        let beatTracker = BeatTracker()
        if let estimate = TempoDetector.detect(in: audio),
           let firstOnset = onsets.onsetTimes.first {
            // Anchor on the first onset. The tracker will gently re-
            // align as subsequent onsets land near predicted beats.
            beatTracker.setTempo(
                bpm: estimate.bpm,
                anchorTime: firstOnset,
                confidence: estimate.confidence
            )
        }

        let totalFrames = Int(audio.duration * frameRate)
        var frames: [FeatureFrame] = []
        frames.reserveCapacity(totalFrames)

        // Per-band streaming onset detector — runs as a second pass
        // alongside the offline global detector. The global one drives
        // the scalar `onset` field (existing behavior); this one drives
        // the new per-band `bandOnset` field. Same instance across all
        // frames so its EMA baseline can adapt across the clip.
        let bandedOnsetDetector = BandedOnsetDetector(
            fft: fft,
            sampleRate: audio.sampleRate
        )
        let bandDeltaTime = 1.0 / frameRate

        for index in 0..<totalFrames {
            // Center a window on this frame's time, clamped into range.
            let center = Int(Double(index) / frameRate * audio.sampleRate)
            let start = min(max(0, center - windowSize / 2), audio.samples.count - windowSize)
            let window = Array(audio.samples[start..<(start + windowSize)])

            let spectrum = fft.magnitudeSpectrum(of: window)
            let chroma = Chromagram(spectrum: spectrum, fft: fft, sampleRate: audio.sampleRate)
            let tonality = Tonality(of: chroma)
            let color = TonalColor(chromagram: chroma, majorness: tonality.majorness)
            let timbre = Timbre(spectrum: spectrum, fft: fft, sampleRate: audio.sampleRate)
            let banded = BandedSpectrum(
                spectrum: spectrum,
                fft: fft,
                sampleRate: audio.sampleRate
            )
            let bandOnsets = bandedOnsetDetector.process(
                spectrum: spectrum,
                deltaTime: bandDeltaTime
            )

            let frameTime = Double(index) / frameRate
            let onset = onsetFrames.contains(index)
            let beat = beatTracker.update(time: frameTime, hadOnset: onset)

            frames.append(FeatureFrame(
                time: frameTime,
                color: color,
                timbreBrightness: timbre.brightness,
                loudness: Loudness.rms(window),
                harmonicComplexity: HarmonicComplexity(spectrum: spectrum).value,
                onset: onset,
                chromagram: chroma.values,
                beat: beat,
                bandLoudness: banded.loudness,
                bandChromagram: banded.chromagram,
                bandOnset: bandOnsets
            ))
        }
        return frames
    }
}
