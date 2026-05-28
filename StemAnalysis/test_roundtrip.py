#!/usr/bin/env python3
"""Isolate where the bug is — model output or save/load round-trip.
Generate a known long sine wave, save via demucs_mlx.save_audio,
reload, check for distortion."""

import numpy as np
import mlx.core as mx
import mlx_audio_io as aio
from demucs_mlx.audio import save_audio
from pathlib import Path

sr = 44100
dur = 202.28
t = np.arange(int(sr * dur), dtype=np.float32) / sr
# Simulate the demucs stem shape: (channels, samples), 2-channel
sig = np.zeros((2, len(t)), dtype=np.float32)
sig[0] = 0.3 * np.sin(2 * np.pi * 440 * t)  # 440 Hz left
sig[1] = 0.3 * np.sin(2 * np.pi * 220 * t)  # 220 Hz right

print(f"input: shape={sig.shape}, duration={len(t)/sr:.2f}s")

out_path = Path(__file__).parent / "_roundtrip_test.wav"
# Save via demucs_mlx.save_audio (channels-first input)
save_audio(mx.array(sig), str(out_path), sr)
print(f"wrote {out_path.name}")

# Reload via aio.load (channels-last output)
reloaded, _ = aio.load(str(out_path))
reloaded_np = np.asarray(reloaded).astype(np.float32)
print(f"reloaded: shape={reloaded_np.shape}")

# Check spectral peaks
def peak_hz(x, sr):
    chunk = x[:int(4*sr)]
    spec = np.abs(np.fft.rfft(chunk * np.hanning(len(chunk))))
    freqs = np.fft.rfftfreq(len(chunk), 1.0/sr)
    return freqs[np.argmax(spec)]

print(f"  left peak (first 4s): {peak_hz(reloaded_np[:, 0], sr):.1f} Hz (expected 440)")
print(f"  right peak (first 4s): {peak_hz(reloaded_np[:, 1], sr):.1f} Hz (expected 220)")
print(f"  left peak (last 4s, 198-202): {peak_hz(reloaded_np[-int(4*sr):, 0], sr):.1f} Hz (expected 440)")

# Check sample-level alignment for first 20 samples
print(f"\n  input first 20 samples (left): {sig[0][:20]}")
print(f"  reload first 20 samples (left): {reloaded_np[:20, 0]}")
print(f"\n  input last 20 samples (left): {sig[0][-20:]}")
print(f"  reload last 20 samples (left): {reloaded_np[-20:, 0]}")
