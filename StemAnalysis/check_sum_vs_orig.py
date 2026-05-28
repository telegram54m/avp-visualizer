#!/usr/bin/env python3
"""Compare sum-of-stems against the original at multiple timestamps.
If pitch is shifted, the sum's spectrum will be translated up in
frequency. If time is shifted, cross-correlation peak will be off
zero lag. Both should match within decoder noise if the model is
working correctly."""

import numpy as np
import mlx_audio_io as aio
from pathlib import Path

orig_path = "/Users/jessegriffith/Downloads/03 The Way You Look Tonight.m4a"
sum_path  = Path(__file__).parent / "out_stems" / "_sum_of_stems.wav"

orig_audio, sr = aio.load(orig_path)
sum_audio, _   = aio.load(str(sum_path))
orig_np = np.asarray(orig_audio).astype(np.float32)
sum_np  = np.asarray(sum_audio).astype(np.float32)

print(f"original: {orig_np.shape} @ {sr} Hz")
print(f"sum:      {sum_np.shape} @ {sr} Hz")

# 1. Cross-correlation on a small window to detect time shift.
def time_lag_seconds(a, b, sr, start_s=30, dur_s=2):
    s0 = int(start_s * sr)
    s1 = int((start_s + dur_s) * sr)
    a_chunk = a[s0:s1, 0]
    b_chunk = b[s0:s1, 0]
    # Normalize so peak isn't biased by amplitude
    a_chunk = (a_chunk - a_chunk.mean()) / (a_chunk.std() + 1e-9)
    b_chunk = (b_chunk - b_chunk.mean()) / (b_chunk.std() + 1e-9)
    # numpy correlate, mode 'full' gives length 2N-1
    corr = np.correlate(a_chunk, b_chunk, mode='full')
    peak = np.argmax(corr) - (len(a_chunk) - 1)
    return peak, peak / sr, corr[np.argmax(corr)] / len(a_chunk)

print("\nTime-lag detection (cross-correlation peak should be at 0 samples):")
for s in [10, 30, 60, 100, 150]:
    lag_s, lag_sec, peak_val = time_lag_seconds(orig_np, sum_np, sr, s)
    print(f"  @ {s}s: peak lag = {lag_s:+d} samples ({lag_sec*1000:+.2f} ms)  corr={peak_val:.3f}")

# 2. Spectral comparison: dominant freq bin per window.
def dominant_freqs(audio, sr, start_s, dur_s, n_peaks=3):
    s0 = int(start_s * sr)
    s1 = int((start_s + dur_s) * sr)
    chunk = audio[s0:s1, 0]
    window = np.hanning(len(chunk))
    spectrum = np.abs(np.fft.rfft(chunk * window))
    freqs = np.fft.rfftfreq(len(chunk), 1.0 / sr)
    # Limit to 20-2000 Hz musical fundamental range
    mask = (freqs >= 20) & (freqs <= 2000)
    spec_masked = spectrum[mask]
    freqs_masked = freqs[mask]
    top = np.argsort(spec_masked)[-n_peaks:][::-1]
    return [(freqs_masked[i], spec_masked[i]) for i in top]

print("\nTop-3 spectral peaks (20-2000 Hz) — should match between original and sum:")
for s in [30, 60, 100, 150]:
    op = dominant_freqs(orig_np, sr, s, 2)
    sp = dominant_freqs(sum_np, sr, s, 2)
    op_str = ' '.join(f"{f:5.0f}Hz" for f, _ in op)
    sp_str = ' '.join(f"{f:5.0f}Hz" for f, _ in sp)
    print(f"  @ {s}s: orig=[{op_str}]  sum=[{sp_str}]")

# 3. Per-stem rate sanity: confirm vocals stem at expected vocal freq.
print("\nVocals-stem peak frequencies (should be in vocal range 100-500 Hz for Sinatra):")
voc_path = Path(__file__).parent / "out_stems" / "03 The Way You Look Tonight - vocals.wav"
voc_audio, _ = aio.load(str(voc_path))
voc_np = np.asarray(voc_audio).astype(np.float32)
for s in [30, 40, 60, 80, 100, 120]:
    if s * sr >= voc_np.shape[0]:
        break
    p = dominant_freqs(voc_np, sr, s, 2)
    p_str = ' '.join(f"{f:5.0f}Hz" for f, _ in p)
    print(f"  @ {s}s: [{p_str}]")
