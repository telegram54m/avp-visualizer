#!/usr/bin/env python3
"""Compare spectral content of original vs vocals stem at the same
timestamp. If the stem's peak energy is at a higher frequency than
the original, there's a real pitch shift in the model output. If
they match, the 'chipmunk' perception is something else."""

import numpy as np
import mlx_audio_io as aio
from pathlib import Path

orig_path = "/Users/jessegriffith/Downloads/03 The Way You Look Tonight.m4a"
vocals_path = Path(__file__).parent / "out_stems" / "03 The Way You Look Tonight - vocals.wav"

# Load both
orig_audio, orig_sr = aio.load(orig_path)
voc_audio, voc_sr = aio.load(str(vocals_path))
orig_np = np.asarray(orig_audio).astype(np.float32)
voc_np = np.asarray(voc_audio).astype(np.float32)

print(f"original: shape={orig_np.shape}, sr={orig_sr}, dur={orig_np.shape[0]/orig_sr:.2f}s")
print(f"vocals:   shape={voc_np.shape}, sr={voc_sr}, dur={voc_np.shape[0]/voc_sr:.2f}s")

# Pick a 4-second window where Sinatra is singing a sustained note.
# The intro has the orchestra, vocals enter around 22s. Take 30-34s,
# which should be a clean vocal phrase.
def fft_peak_hz(audio_np, sr, start_s, dur_s):
    s0 = int(start_s * sr)
    s1 = int((start_s + dur_s) * sr)
    chunk = audio_np[s0:s1, 0]  # mono left
    # Hann window + FFT
    window = np.hanning(len(chunk))
    spectrum = np.abs(np.fft.rfft(chunk * window))
    freqs = np.fft.rfftfreq(len(chunk), 1.0 / sr)
    # Restrict to vocal range (80-1500 Hz) to find the fundamental
    mask = (freqs >= 80) & (freqs <= 1500)
    peak_idx_in_mask = np.argmax(spectrum[mask])
    peak_freq = freqs[mask][peak_idx_in_mask]
    peak_amp = spectrum[mask][peak_idx_in_mask]
    return peak_freq, peak_amp

print("\nSpectral peak (80-1500 Hz, fundamental-vocal range):")
for start_s in [30, 40, 60, 80, 100, 120]:
    if start_s + 4 > orig_np.shape[0] / orig_sr:
        break
    of, oa = fft_peak_hz(orig_np, orig_sr, start_s, 4.0)
    vf, va = fft_peak_hz(voc_np, voc_sr, start_s, 4.0)
    ratio = vf / of if of > 0 else float('nan')
    print(f"  @ {start_s}s: original={of:7.1f} Hz | vocals={vf:7.1f} Hz | ratio={ratio:.3f}")

print("\nIf ratio ≈ 1.0 → no pitch shift, perceptual issue.")
print("If ratio ≈ 1.5/2.0 → real shift, possible 1.5× or 2× rate mismatch.")
