#!/usr/bin/env python3
"""Try different Separator configurations to isolate the
doubled/sped-up chunk-reassembly bug. The 8s synthetic test came
through clean, so the bug is in chunk handling for longer audio."""

import sys
import time
from pathlib import Path
import numpy as np
import mlx_audio_io as aio
from demucs_mlx import Separator, save_audio

src = "/Users/jessegriffith/dev/Claude/Projects/AVP Visualizer/StemAnalysis/sinatra_decoded.wav"
out_dir = Path(__file__).parent / "out_split_tests"
out_dir.mkdir(exist_ok=True)

# Process just the first 60 seconds to keep test cycles fast — but
# still long enough to exceed the default segment length (which is
# usually 7.8s for htdemucs) so chunking is required.
audio, sr = aio.load(src, duration=60.0)
audio_np = np.asarray(audio).astype(np.float32)
print(f"test input: {audio_np.shape} @ {sr}Hz = {audio_np.shape[0]/sr:.1f}s")

# Write a 60s slice as our input
test_in = out_dir / "_sinatra_60s.wav"
import mlx.core as mx
aio.save(str(test_in), mx.array(audio_np), int(sr))

configs = [
    dict(model="htdemucs", split=True,  shifts=1, overlap=0.25, segment=None),  # default
    dict(model="htdemucs", split=False, shifts=1, overlap=0.25),                  # one shot
    dict(model="htdemucs", split=True,  shifts=0, overlap=0.25, segment=None),  # no shifts
    dict(model="htdemucs", split=True,  shifts=1, overlap=0.0,  segment=None),  # no overlap
]

for cfg in configs:
    label = "_".join(f"{k}{v}" for k, v in cfg.items() if k != "model")
    print(f"\n=== config: {cfg} ===")
    try:
        sep = Separator(progress=False, **cfg)
        t0 = time.monotonic()
        _, stems = sep.separate_audio_file(test_in, return_mx=True)
        print(f"  done in {time.monotonic()-t0:.1f}s")
        # Sum and check duration vs input
        sum_arr = np.zeros_like(audio_np)
        for stem in stems.values():
            stem_np = np.asarray(stem).astype(np.float32)
            if stem_np.shape[0] < stem_np.shape[1]:
                stem_np = stem_np.T
            n = min(sum_arr.shape[0], stem_np.shape[0])
            sum_arr[:n] += stem_np[:n]
        out_path = out_dir / f"sum_{label}.wav"
        aio.save(str(out_path), mx.array(sum_arr), int(sr))
        # Quick spectral check on left channel at t=20s (vocals coming in)
        s0 = int(20 * sr)
        s1 = s0 + int(2 * sr)
        chunk_orig = audio_np[s0:s1, 0]
        chunk_sum = sum_arr[s0:s1, 0]
        # Cross-correlate the two and find peak lag
        a = (chunk_orig - chunk_orig.mean()) / (chunk_orig.std() + 1e-9)
        b = (chunk_sum  - chunk_sum.mean())  / (chunk_sum.std()  + 1e-9)
        corr = np.correlate(a, b, mode='full')
        peak = np.argmax(corr) - (len(a) - 1)
        peak_val = corr[np.argmax(corr)] / len(a)
        print(f"  cross-corr peak: lag={peak} samples ({peak/sr*1000:+.1f}ms), val={peak_val:.3f}")
        print(f"  sum saved to {out_path.name}")
    except Exception as e:
        print(f"  FAILED: {type(e).__name__}: {e}")
