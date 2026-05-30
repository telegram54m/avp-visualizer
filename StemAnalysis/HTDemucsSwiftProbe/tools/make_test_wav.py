#!/usr/bin/env python
"""make_test_wav.py — convert the Phase 0 fixture input.f32 into a
proper WAV file so the Swift smoke test can load it via AVAudioFile.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

REPO_ROOT = Path(__file__).resolve().parents[1]
PARITY = REPO_ROOT / "artifacts" / "parity"


def main() -> int:
    raw = np.frombuffer(
        (PARITY / "input.f32").read_bytes(), dtype=np.float32
    )
    # input.f32 is (channels=2, samples=220500) flat.
    audio = raw.reshape(2, -1).T  # → (samples, channels) for soundfile
    out = PARITY / "input.wav"
    sf.write(str(out), audio, 44100, subtype="FLOAT")
    size_kb = out.stat().st_size / 1024
    print(f"✓ wrote {out}  ({audio.shape[0]} frames, {size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
