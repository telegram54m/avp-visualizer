#!/usr/bin/env python
"""
make_parity_fixture.py — build a small deterministic input + the
Python reference's 4-stem output for the Swift parity test.

The input is 5 seconds of two-channel pseudo-music generated from
seeded random + a couple of sine tones, so the test is fully
reproducible without shipping a copyrighted audio clip.

Output (in artifacts/parity/):
  input.f32   - raw float32, shape [2, 220500], little-endian
  meta.json   - shape/sample_rate/etc
  out_drums.f32  out_bass.f32  out_other.f32  out_vocals.f32
                - reference stems from demucs.api.apply_model, same
                  raw float32 format, shape [2, 220500]

Swift loads input.f32 → runs HTDemucs → reads out_*.f32 → computes
per-stem RMS diff and reports.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = REPO_ROOT / "artifacts" / "parity"


def make_input(seconds: float = 5.0, sr: int = 44100, seed: int = 1234) -> np.ndarray:
    """A reproducible stereo signal that exercises both branches."""
    rng = np.random.default_rng(seed)
    n = int(seconds * sr)
    t = np.arange(n) / sr
    # Mix of sines (drums-ish low pulse, bass tone, harmonic) + filtered noise.
    left = (
        0.30 * np.sin(2 * np.pi * 110.0 * t)
        + 0.20 * np.sin(2 * np.pi * 220.0 * t)
        + 0.15 * np.sin(2 * np.pi * 55.0 * t) * (np.sin(2 * np.pi * 2.0 * t) > 0)
        + 0.08 * rng.standard_normal(n)
    )
    right = (
        0.25 * np.sin(2 * np.pi * 120.0 * t)
        + 0.20 * np.sin(2 * np.pi * 240.0 * t)
        + 0.15 * np.sin(2 * np.pi * 60.0 * t) * (np.sin(2 * np.pi * 2.0 * t) > 0)
        + 0.08 * rng.standard_normal(n)
    )
    sig = np.stack([left, right], axis=0).astype(np.float32)
    # Light normalize to a sensible level.
    peak = np.max(np.abs(sig))
    if peak > 0:
        sig = sig * (0.5 / peak)
    return sig


def main() -> int:
    os.makedirs(ARTIFACTS, exist_ok=True)
    print(f"[1/3] Generating reproducible 5s stereo input...")
    sig = make_input()
    print(f"      shape={sig.shape} dtype={sig.dtype} peak={np.max(np.abs(sig)):.3f}")
    (ARTIFACTS / "input.f32").write_bytes(sig.tobytes())

    print(f"[2/3] Running PyTorch demucs reference (htdemucs, raw model fwd)...")
    # IMPORTANT: parity is against the bare HTDemucs.forward(x), NOT
    # apply_model() — the latter pre/post-normalizes and shift-augments,
    # which would force the Swift port to replicate those wrappers too.
    # The Swift HTDemucs models only the inner forward.
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import BagOfModels

    bag = get_model("htdemucs")
    model = bag.models[0] if isinstance(bag, BagOfModels) else bag
    model.cpu().eval()

    x = torch.from_numpy(sig).unsqueeze(0)
    with torch.no_grad():
        out = model(x)
    # out shape: (batch, sources, channels, samples)
    out_np = out[0].cpu().numpy().astype(np.float32)
    print(f"      stems shape={out_np.shape}")
    sources = model.sources

    print(f"[3/3] Writing reference stems...")
    for i, name in enumerate(sources):
        path = ARTIFACTS / f"out_{name}.f32"
        path.write_bytes(out_np[i].tobytes())
        rms = float(np.sqrt(np.mean(out_np[i] ** 2)))
        print(f"      {path.name}  rms={rms:.6f}")

    meta = {
        "sample_rate": 44100,
        "duration_sec": 5.0,
        "channels": 2,
        "samples": int(sig.shape[1]),
        "dtype": "float32",
        "byte_order": "little-endian",
        "sources": list(sources),
        "stem_shape": list(out_np.shape[1:]),  # per-stem [C, T]
        "input_seed": 1234,
        "reference_model": "htdemucs",
    }
    with open(ARTIFACTS / "meta.json", "w") as f:
        json.dump(meta, f, indent=2)
    print(f"      meta.json written")

    print()
    print("✓ done.")
    print(f"  fixture dir: {ARTIFACTS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
