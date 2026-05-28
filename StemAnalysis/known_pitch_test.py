#!/usr/bin/env python3
"""Generate a synthetic stereo signal with a known 440 Hz sine (left)
and 220 Hz sine (right), save as WAV, run separation, then check
whether each stem preserves the pitch."""

import numpy as np
import mlx.core as mx
import mlx_audio_io as aio
from demucs_mlx import Separator
from pathlib import Path

sr = 44100
dur = 8.0
t = np.linspace(0, dur, int(sr * dur), endpoint=False, dtype=np.float32)
# Channels-last shape for mlx-audio-io: (samples, 2)
sig = np.zeros((len(t), 2), dtype=np.float32)
sig[:, 0] = 0.3 * np.sin(2 * np.pi * 440 * t)   # A4
sig[:, 1] = 0.3 * np.sin(2 * np.pi * 220 * t)   # A3

out_dir = Path(__file__).parent
input_path = out_dir / "_pitch_test_in.wav"
aio.save(str(input_path), mx.array(sig), sr)
print(f"wrote {input_path}: left=440Hz, right=220Hz, {dur}s @ {sr}Hz")

sep = Separator(model="htdemucs", progress=False)
print("running separator...")
_, stems = sep.separate_audio_file(input_path, return_mx=True)

def peak_freq(audio_np, sr, ch):
    chunk = audio_np[:int(4*sr), ch]
    window = np.hanning(len(chunk))
    spec = np.abs(np.fft.rfft(chunk * window))
    freqs = np.fft.rfftfreq(len(chunk), 1.0/sr)
    return freqs[np.argmax(spec)]

print()
print(f"Input expected: L=440Hz, R=220Hz")
for name, stem in stems.items():
    stem_np = np.asarray(stem).astype(np.float32)
    # mlx output is (channels, samples) — transpose to match input layout
    if stem_np.shape[0] < stem_np.shape[1]:
        stem_np = stem_np.T  # (samples, channels)
    left_pk = peak_freq(stem_np, sep.samplerate, 0)
    right_pk = peak_freq(stem_np, sep.samplerate, 1)
    rms_l = float(np.sqrt(np.mean(stem_np[:, 0]**2)))
    rms_r = float(np.sqrt(np.mean(stem_np[:, 1]**2)))
    print(f"  {name:<7} L: {left_pk:7.1f}Hz (rms {rms_l:.4f})  R: {right_pk:7.1f}Hz (rms {rms_r:.4f})")

print()
print("If L peak = 440Hz, R peak = 220Hz on any stem → model rate is correct.")
print("If L peak = 880Hz, R peak = 440Hz → 2× pitch shift (the chipmunk bug).")
