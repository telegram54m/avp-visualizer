//
//  FeatureDerive.swift — top-level API matching sidecar.py's
//  `derive_features(stem, sr)`.
//
//  Mirrors the sidecar's three-output structure:
//    chromagram (nFrames × 12), max-bin normalized
//    loudness   (nFrames,)      RMS at frame_length=2*hop, center=True
//    onset      (nFrames,)      bool, from spectral flux + peak-pick
//
//  Caller supplies sr; the sidecar runs everything at sr/30 hop.
//

import Foundation

public struct FeatureFrames {
    public let nFrames: Int
    public let chromagram: [Float]  // [nFrames * 12]
    public let loudness: [Float]    // [nFrames]
    public let onset: [Bool]        // [nFrames]
}

public final class FeatureDeriver {
    public let sr: Int
    public let frameRate: Int
    public let nFft: Int
    public let hop: Int
    public let stft: STFT
    public let chroma: Chromagram
    public let onsetDetector: OnsetDetector

    /// `filterbankDir` must contain `chroma_filterbank.f32` (12×1025)
    /// and `mel_filterbank.f32` (128×1025) exported by the librosa
    /// dump tool.
    public init(sr: Int = 44100, frameRate: Int = 30, nFft: Int = 2048,
                filterbankDir: URL) throws {
        self.sr = sr
        self.frameRate = frameRate
        self.nFft = nFft
        self.hop = sr / frameRate
        self.stft = STFT(nFft: nFft, hop: hop)
        let nBins = nFft / 2 + 1
        self.chroma = try Chromagram(
            filterbankPath: filterbankDir.appendingPathComponent("chroma_filterbank.f32"),
            nBins: nBins
        )
        self.onsetDetector = try OnsetDetector(
            sr: sr, hop: hop, nBins: nBins,
            melFilterbankPath: filterbankDir.appendingPathComponent("mel_filterbank.f32")
        )
    }

    /// Compute features for a mono signal at `sr`.
    public func derive(mono: [Float]) -> FeatureFrames {
        // 1) STFT magnitudes (used by both chromagram and onset).
        let (nFrames, mag) = stft.magnitude(mono)

        // 2) Chromagram.
        let chromaArr = chroma.apply(magnitudeSpectrogram: mag, nFrames: nFrames)

        // 3) RMS — uses the time-domain signal directly, not the STFT.
        let rms = RMSFrames.compute(
            signal: mono,
            frameLength: hop * 2,
            hopLength: hop,
            center: true
        )

        // 4) Onset frames.
        let onset = onsetDetector.detect(magnitude: mag, nFrames: nFrames)

        // 5) Truncate to the minimum length (sidecar.py does this — the
        // three pipelines can disagree by 1 frame at the tail due to
        // centering choices).
        let n = min(nFrames, rms.count, onset.count)
        let chromaTrim = Array(chromaArr.prefix(n * 12))
        let rmsTrim = Array(rms.prefix(n))
        let onsetTrim = Array(onset.prefix(n))

        return FeatureFrames(
            nFrames: n,
            chromagram: chromaTrim,
            loudness: rmsTrim,
            onset: onsetTrim
        )
    }
}
