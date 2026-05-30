//
//  RMSFrames.swift — librosa.feature.rms equivalent. Frame-wise RMS
//  with center=True padding.
//
//  librosa rms(y, frame_length, hop_length, center=True):
//    1. Pad signal by frame_length//2 on each side (reflect).
//    2. For each frame i, RMS = sqrt(mean(y[i*hop : i*hop + frame_length]²)).
//

import Accelerate
import Foundation

public enum RMSFrames {
    /// frameLength: window size. hopLength: step. center: reflect-pad input.
    public static func compute(
        signal: [Float],
        frameLength: Int,
        hopLength: Int,
        center: Bool = true
    ) -> [Float] {
        let working: [Float]
        if center {
            working = STFT.reflectPad(signal, pad: frameLength / 2)
        } else {
            working = signal
        }
        let n = working.count
        guard n >= frameLength else { return [] }
        let nFrames = 1 + (n - frameLength) / hopLength

        var out = [Float](repeating: 0, count: nFrames)
        var squared = [Float](repeating: 0, count: frameLength)
        let invN = 1.0 / Float(frameLength)

        working.withUnsafeBufferPointer { wPtr in
            for f in 0 ..< nFrames {
                let start = f * hopLength
                // squared = working[start..<start+frameLength]^2
                vDSP_vsq(wPtr.baseAddress! + start, 1,
                         &squared, 1, vDSP_Length(frameLength))
                var meanSq: Float = 0
                vDSP_meanv(squared, 1, &meanSq, vDSP_Length(frameLength))
                out[f] = sqrtf(meanSq)
                _ = invN  // silence warning; meanv already divides
            }
        }
        return out
    }
}
