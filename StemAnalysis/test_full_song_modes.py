#!/usr/bin/env python3
"""Run full 3:22 Sinatra with different Separator configs to find
which knob causes the doubled/chipmunked output at long durations.
60s tests passed for default config — so this is duration-dependent."""

import time
from pathlib import Path
import numpy as np
import mlx_audio_io as aio
import mlx.core as mx
from demucs_mlx import Separator

src = "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer/StemAnalysis/sinatra_decoded.wav"
out_dir = Path(__file__).parent / "out_full_tests"
out_dir.mkdir(exist_ok=True)

audio, sr = aio.load(src)
audio_np = np.asarray(audio).astype(np.float32)
print(f"input: {audio_np.shape[0]/sr:.1f}s")

configs = [
    ("default",          dict(split=True,  shifts=1, overlap=0.25, segment=None)),
    ("shifts0",          dict(split=True,  shifts=0, overlap=0.25, segment=None)),
    ("no-overlap",       dict(split=True,  shifts=1, overlap=0.0,  segment=None)),
    ("seg7-shifts0",     dict(split=True,  shifts=0, overlap=0.25, segment=7)),
]

for label, cfg in configs:
    print(f"\n=== {label}: {cfg} ===")
    sep = Separator(model="htdemucs", progress=False, **cfg)
    t0 = time.monotonic()
    _, stems = sep.separate_audio_file(src, return_mx=True)
    elapsed = time.monotonic() - t0
    print(f"  separation: {elapsed:.1f}s")

    sum_arr = np.zeros_like(audio_np)
    for stem in stems.values():
        sn = np.asarray(stem).astype(np.float32)
        if sn.shape[0] < sn.shape[1]:
            sn = sn.T
        n = min(sum_arr.shape[0], sn.shape[0])
        sum_arr[:n] += sn[:n]

    # Correlation at multiple timestamps — if any chunk is doubled,
    # at least one of these will show poor correlation
    print("  cross-corr (orig vs sum):")
    for ts in [20, 60, 100, 150]:
        s0 = int(ts * sr)
        s1 = s0 + int(2 * sr)
        a = audio_np[s0:s1, 0]
        b = sum_arr[s0:s1, 0]
        a = (a - a.mean()) / (a.std() + 1e-9)
        b = (b - b.mean()) / (b.std() + 1e-9)
        corr = np.correlate(a, b, mode='full')
        peak = np.argmax(corr) - (len(a) - 1)
        peak_val = corr[np.argmax(corr)] / len(a)
        print(f"    @ {ts:3d}s: lag={peak:+5d} samples ({peak/sr*1000:+6.1f}ms)  corr={peak_val:+.3f}")

    aio.save(str(out_dir / f"sum_{label}.wav"), mx.array(sum_arr), int(sr))
