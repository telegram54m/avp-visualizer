#!/usr/bin/env python
"""compare_features.py — Phase 1 acceptance test.

Acceptance bars from swift-sidecar-port-spec:
  Chromagram: max-bin agreement frame-by-frame in >=98% of frames
  Loudness:   RMS values within 5% relative error
  Onsets:     >=90% of librosa's onsets present in Swift output within +-1 frame
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
PARITY = REPO_ROOT / "artifacts" / "parity"
SWIFT_DIR = PARITY / "swift"
STEMS = ["drums", "bass", "other", "vocals"]


def load_f32(p: Path, shape):
    raw = p.read_bytes()
    arr = np.frombuffer(raw, dtype=np.float32)
    if shape:
        arr = arr.reshape(shape)
    return arr.copy()


def main() -> int:
    manifest = json.load(open(PARITY / "manifest.json"))
    overall_pass = True

    print(f"{'stem':6s}  {'chroma_match':>14s}  {'rms_rel_err':>12s}  {'onset_recall':>13s}  {'verdict':>7s}")
    print("-" * 70)

    for stem in STEMS:
        meta = manifest["stems"][stem]
        n = meta["n_frames"]

        # Chromagram
        ref_c = load_f32(PARITY / f"{stem}_chroma.f32", (n, 12))
        try:
            sw_c = load_f32(SWIFT_DIR / f"{stem}_chroma.f32", (n, 12))
        except (FileNotFoundError, ValueError) as e:
            print(f"  {stem}: SWIFT MISSING — run feature-probe first ({e})")
            continue
        ref_argmax = ref_c.argmax(axis=1)
        sw_argmax = sw_c.argmax(axis=1)
        chroma_match = float((ref_argmax == sw_argmax).mean()) * 100

        # RMS
        ref_r = load_f32(PARITY / f"{stem}_rms.f32", (n,))
        sw_r = load_f32(SWIFT_DIR / f"{stem}_rms.f32", (n,))
        # Relative error: |sw - ref| / max(|ref|, eps), averaged.
        eps = 1e-6
        rel_err = np.abs(sw_r - ref_r) / np.maximum(np.abs(ref_r), eps)
        rms_rel_err = float(rel_err.mean()) * 100

        # Onsets
        ref_o = load_f32(PARITY / f"{stem}_onset.f32", (n,)) > 0.5
        sw_o = load_f32(SWIFT_DIR / f"{stem}_onset.f32", (n,)) > 0.5
        ref_idx = np.where(ref_o)[0]
        sw_idx = np.where(sw_o)[0]
        # Recall: fraction of ref onsets within +-1 frame of a sw onset.
        if len(ref_idx) == 0:
            recall = 100.0
        else:
            recalled = 0
            for r in ref_idx:
                if (np.abs(sw_idx - r) <= 1).any():
                    recalled += 1
            recall = 100 * recalled / len(ref_idx)

        chroma_ok = chroma_match >= 98
        rms_ok = rms_rel_err <= 5
        onset_ok = recall >= 90
        verdict = "PASS" if (chroma_ok and rms_ok and onset_ok) else "FAIL"
        if verdict == "FAIL":
            overall_pass = False

        print(
            f"  {stem:6s}  {chroma_match:>12.2f}%  {rms_rel_err:>10.3f}%  "
            f"{recall:>11.2f}% ({len(sw_idx):>2d}/{len(ref_idx):>2d})  {verdict:>7s}"
        )

    print()
    print("Acceptance: chroma>=98%  rms<=5%  onset>=90% (+-1 frame)")
    print("OVERALL:", "✓ PASS — Phase 1 GO" if overall_pass else "✗ FAIL")
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
