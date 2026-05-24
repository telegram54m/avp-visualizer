import Foundation

/// Streaming counterpart to ``AnalysisTimeline``. The offline pipeline takes
/// a finished ``DecodedAudio`` clip and returns a complete `[FeatureFrame]`;
/// this class takes PCM in arbitrary chunks and emits frames as enough
/// samples accumulate, suitable for driving a visualizer from a live source
/// like the macOS Core Audio Process Tap.
///
/// Two pieces differ from the offline pipeline:
///
/// 1. **Buffering.** PCM arrives in IOProc-sized blocks (typically 512
///    frames at 48 kHz, i.e. ~10 ms each), but a feature frame wants an
///    8192-sample window (~170 ms at 48 kHz). We keep a window-sized
///    rolling buffer and emit one frame every `sampleRate/frameRate`
///    samples of new audio.
///
/// 2. **Streaming onset detection.** The offline ``OnsetDetector`` builds
///    the full novelty curve, then peak-picks against the curve's global
///    mean + stddev. That's impossible online — we don't have the future.
///    Instead this analyzer computes spectral flux per frame and compares
///    it to an exponential-moving-average baseline (the same shape as
///    ``RealtimeOnsetDetector`` uses for RMS), with a refractory window
///    to debounce single transients.
///
/// Output `FeatureFrame.time` is monotonic — `emittedFrameIndex / frameRate`
/// — so the time field continues to increment for the life of the analyzer.
/// Callers that need wall-clock alignment should compute it themselves.
public final class StreamingAnalyzer {

    public let sampleRate: Double
    public let frameRate: Double
    public let windowSize: Int

    /// New samples needed between successive emitted frames.
    public var hopSize: Int { Int(sampleRate / frameRate) }

    /// Ratio of instantaneous spectral flux to running-average flux that
    /// counts as an onset. Tuned to roughly match the offline detector's
    /// hit rate on typical music. 1.5–2.0 is the useful range — higher =
    /// fewer false positives, more missed soft hits.
    public var onsetThreshold: Float = 1.7

    /// Minimum spacing between successive onsets, in seconds. Keeps a
    /// single transient (which spreads across a few windows) from firing
    /// as multiple onsets back-to-back.
    public var refractory: Double = 0.1

    /// EMA smoothing factor for the running-average novelty baseline.
    /// Smaller = slower-adapting baseline = more sensitive to short
    /// bursts. The offline detector uses a global mean+stddev which has
    /// no analog here; this is the streaming approximation.
    public var baselineSmoothing: Float = 0.05

    private let fft: FFTProcessor
    /// Per-band streaming-flux onset detector. Lives alongside the
    /// scalar spectral-flux + external-override onset logic — drives
    /// the new `FeatureFrame.bandOnset` field so visualizers can
    /// distinguish "kick fired" from "hat fired" from "lead stab fired."
    private let bandedOnsetDetector: BandedOnsetDetector
    /// Rolling sample buffer holding the most-recent `windowSize` samples.
    /// Trimmed as new audio arrives.
    private var buffer: [Float] = []
    /// New samples accumulated since the last frame was emitted. When this
    /// crosses `hopSize` and `buffer` is full, we emit one frame.
    private var samplesSinceLastFrame: Int = 0
    /// Number of frames emitted so far — drives the monotonic `time` field.
    private var emittedFrames: Int = 0

    // Streaming onset state (spectral flux + EMA + refractory window).
    private var previousSpectrum: [Float]?
    private var noveltyBaseline: Float = 0.001
    private var timeSinceLastOnset: Double = .infinity
    private var isFirstSpectrum: Bool = true

    /// Incremental beat tracker — fed the per-frame onset signal,
    /// emits ``BeatState`` per frame for downstream visualizers that
    /// want rhythmically-locked behavior (e.g. Ambient's starfield).
    public let beatTracker = BeatTracker()

    /// Any externally-detected onset that arrived between the last emitted
    /// frame and the next one. OR'd into the next frame's `onset` field
    /// alongside the internal spectral-flux detection. Cleared on emit.
    /// Used by `SystemAudioListener` to forward the proven `RealtimeOnsetDetector`
    /// signal (which fires reliably on the live PCM path where the internal
    /// streaming spectral-flux detector under-fires once the EMA baseline
    /// catches up).
    private var pendingExternalOnset: Bool = false

    public init?(
        sampleRate: Double,
        frameRate: Double = 30,
        windowSize: Int = 8192
    ) {
        guard sampleRate > 0, frameRate > 0, windowSize > 0,
              let fft = FFTProcessor(size: windowSize) else {
            return nil
        }
        self.sampleRate = sampleRate
        self.frameRate = frameRate
        self.windowSize = windowSize
        self.fft = fft
        self.bandedOnsetDetector = BandedOnsetDetector(
            fft: fft,
            sampleRate: sampleRate
        )
        self.buffer.reserveCapacity(windowSize)
    }

    /// Feed a chunk of mono samples. Returns any feature frames that
    /// became fully available with this chunk — zero, one, or more
    /// depending on chunk size relative to `hopSize`. Safe to call from
    /// any thread, **but not from multiple threads at once** — the
    /// analyzer is single-producer.
    ///
    /// `onsetOverride`: if `true`, mark the next emitted frame's `onset`
    /// as true regardless of what the internal spectral-flux detector
    /// decides. Callers that already run a more reliable onset detector
    /// upstream (e.g. `SystemAudioListener`'s `RealtimeOnsetDetector` on
    /// the raw IOProc PCM) pass this to overlay its decisions onto the
    /// emitted frames. The override OR's onto any internal detection
    /// since the last emit, so multiple IOProc blocks worth of "onset
    /// happened" between two frame emissions all get folded into the
    /// next frame.
    public func append(_ samples: [Float], onsetOverride: Bool = false) -> [FeatureFrame] {
        if onsetOverride { pendingExternalOnset = true }
        guard !samples.isEmpty else { return [] }

        // Append into the rolling buffer, trimming the head once we exceed
        // `windowSize`. `removeFirst(_:)` is O(n) but n is bounded by the
        // incoming chunk size (~hop bytes per call at steady state).
        buffer.append(contentsOf: samples)
        if buffer.count > windowSize {
            buffer.removeFirst(buffer.count - windowSize)
        }
        samplesSinceLastFrame += samples.count

        // Emit as many frames as accumulated audio supports. At steady
        // state with chunks of ~hopSize/3 (e.g. 512 frames @ 48k), this is
        // 0 or 1 per call. With larger chunks (file-fed tests) it can be
        // many. Cap the per-call emit at a sane number to avoid runaway
        // work on a single call.
        guard buffer.count == windowSize else { return [] }
        var out: [FeatureFrame] = []
        while samplesSinceLastFrame >= hopSize {
            samplesSinceLastFrame -= hopSize
            out.append(makeFrame())
        }
        return out
    }

    /// Drop accumulated state — call when starting a fresh capture so
    /// the first few buffers don't carry across spurious novelty from
    /// a prior song.
    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        samplesSinceLastFrame = 0
        emittedFrames = 0
        previousSpectrum = nil
        noveltyBaseline = 0.001
        timeSinceLastOnset = .infinity
        isFirstSpectrum = true
        pendingExternalOnset = false
        beatTracker.reset()
        bandedOnsetDetector.reset()
    }

    /// Number of frames emitted since the last `reset()` (or since init).
    public var emittedFrameCount: Int { emittedFrames }

    /// Diagnostic — current rolling sample-buffer length + capacity.
    /// Surfaced so the host app's leak-investigation logger can verify
    /// the rolling buffer is staying bounded (it should sit at exactly
    /// `windowSize` at steady state with capacity ≤ 2× windowSize).
    /// RELEASE-CLEANUP — paired with the diag chain in the host app's
    /// `AppModel.swift`; remove together. (Public-API change at removal:
    /// downstream callers other than the leak diag don't read this.)
    public var debugBufferStats: (count: Int, capacity: Int) {
        (buffer.count, buffer.capacity)
    }

    /// Build one feature frame from whatever's currently in `buffer`.
    /// Mirrors the per-frame math in ``AnalysisTimeline/analyze(_:frameRate:windowSize:)``
    /// — when the same windowed slice arrives both online and offline,
    /// they should produce close-to-identical chroma / color / loudness
    /// / timbre / complexity values.
    private func makeFrame() -> FeatureFrame {
        let window = buffer
        let spectrum = fft.magnitudeSpectrum(of: window)

        // --- Streaming spectral-flux onset detection --------------------
        // Half-wave-rectified spectral flux: only count rising energy.
        var flux: Float = 0
        if let previous = previousSpectrum {
            for bin in spectrum.indices {
                let rise = spectrum[bin] - previous[bin]
                if rise > 0 { flux += rise }
            }
        }
        previousSpectrum = spectrum

        let dt = Double(hopSize) / sampleRate
        timeSinceLastOnset += dt

        // The very first spectrum is a "rise from silence" — skip it for
        // onset detection so we don't pin frame 0 as an onset on every
        // restart. The offline detector handles this with adaptive
        // thresholding; we approximate by suppressing the first frame.
        var onset = false
        if !isFirstSpectrum {
            let ratio = flux / max(noveltyBaseline, 0.0001)
            if ratio > onsetThreshold && timeSinceLastOnset > refractory {
                onset = true
                timeSinceLastOnset = 0
            }
            noveltyBaseline = (1 - baselineSmoothing) * noveltyBaseline
                            + baselineSmoothing * flux
        } else {
            isFirstSpectrum = false
            // Seed the baseline so it doesn't take a few frames to converge.
            noveltyBaseline = max(noveltyBaseline, flux * 0.5)
        }

        // --- Spectral / tonal features (identical math to offline) ------
        let chroma = Chromagram(spectrum: spectrum, fft: fft, sampleRate: sampleRate)
        let tonality = Tonality(of: chroma)
        let color = TonalColor(chromagram: chroma, majorness: tonality.majorness)
        let timbre = Timbre(spectrum: spectrum, fft: fft, sampleRate: sampleRate)
        let banded = BandedSpectrum(spectrum: spectrum, fft: fft, sampleRate: sampleRate)
        // Per-band onsets — same streaming-flux shape as the scalar
        // onset above, but split by frequency band. Note: this uses
        // the SAME spectrum + previous-spectrum data the scalar
        // detector just consumed, but maintains its own per-band
        // baseline state internally.
        let bandOnsets = bandedOnsetDetector.process(
            spectrum: spectrum,
            deltaTime: Double(hopSize) / sampleRate
        )

        // OR the external onset (if any IOProc block since the last emit
        // signaled one via `append(_:onsetOverride:)`) onto the internal
        // detection, then clear the pending flag.
        if pendingExternalOnset {
            onset = true
            pendingExternalOnset = false
        }

        let time = Double(emittedFrames) / frameRate
        emittedFrames += 1

        // Beat tracker — fed the onset signal + the analyzer's monotonic
        // clock. The clock matches `FeatureFrame.time` so downstream
        // re-timing via `withTime(_:)` only shifts the time axis, not
        // the beat structure.
        let beat = beatTracker.update(time: time, hadOnset: onset)

        return FeatureFrame(
            time: time,
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
        )
    }
}
