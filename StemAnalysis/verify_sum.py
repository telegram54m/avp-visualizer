#!/usr/bin/env python3
"""Sum the 4 stems back together and write the result. If the sum
sounds identical to the original, the WAVs are correct and the
"sped up" perception is the stems-in-isolation effect (drums alone
feel brighter/snappier than drums in a full mix). If the sum is
sped up too, there's a real model output bug to chase."""

import sys
from pathlib import Path
import numpy as np
import mlx_audio_io as aio
import mlx.core as mx

stem_dir = Path(__file__).parent / "out_stems"
out_path = stem_dir / "_sum_of_stems.wav"

stems = []
sr = None
for name in ("drums", "bass", "other", "vocals"):
    paths = list(stem_dir.glob(f"* - {name}.wav"))
    if not paths:
        sys.exit(f"missing stem: {name}")
    info = aio.info(str(paths[0]))
    if sr is None:
        sr = info.sample_rate
        print(f"sr={sr}, frames={info.frames}, dur={info.duration:.2f}s")
    audio, _ = aio.load(str(paths[0]))  # shape (channels, samples), mx.array
    stems.append(np.asarray(audio).astype(np.float32))
    print(f"  loaded {name}: shape={stems[-1].shape}, peak={np.max(np.abs(stems[-1])):.3f}")

summed = np.sum(stems, axis=0)  # (channels, samples)
peak = np.max(np.abs(summed))
print(f"summed peak={peak:.3f}")
if peak > 1.0:
    summed = summed / peak * 0.98
    print(f"  rescaled to peak 0.98 to avoid clip")

# Write via mlx_audio_io directly (channels_last layout, which is
# what we have: shape (samples, 2)).
aio.save(str(out_path), mx.array(summed), int(sr))
print(f"wrote {out_path}, shape={summed.shape}, dtype={summed.dtype}")
