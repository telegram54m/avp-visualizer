#!/usr/bin/env python
"""compare_traces.py — diff Swift trace vs PyTorch reference."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
TRACE_DIR = REPO_ROOT / "artifacts" / "parity"
PY_DIR = TRACE_DIR / "trace_pytorch"
SW_DIR = TRACE_DIR / "trace_swift"

ORDER = [
    "mix_input", "spec", "mag", "mag_normed", "xt_normed",
    "tenc_0", "enc_0", "tenc_1", "enc_1",
    "tenc_2", "enc_2", "tenc_3", "enc_3",
    "xtransformer_x_in", "xtransformer_xt_in",
    "tform_pos2d_raw", "tform_pos2d_flat",
    "tform_x_pre_norm", "tform_x_post_norm", "tform_x_post_pos",
    "tform_pos1d_raw",
    "tform_layer_0_x", "tform_layer_0_xt",
    "tform_layer_1_x", "tform_layer_1_xt",
    "tform_layer_2_x", "tform_layer_2_xt",
    "tform_layer_3_x", "tform_layer_3_xt",
    "tform_layer_4_x", "tform_layer_4_xt",
    "xtransformer_x", "xtransformer_xt",
    "dec_0", "tdec_0", "dec_1", "tdec_1",
    "dec_2", "tdec_2", "dec_3", "tdec_3",
    "x_pre_mask", "ispec", "xt_unnorm", "final_pre_trim", "final",
]


def load_f32(d: Path, name: str, shape: list[int]) -> np.ndarray:
    raw = (d / f"{name}.f32").read_bytes()
    arr = np.frombuffer(raw, dtype=np.float32)
    return arr.reshape(shape)


def main() -> int:
    py_manifest = json.load(open(PY_DIR / "manifest.json"))
    sw_manifest = json.load(open(SW_DIR / "manifest.json"))

    print(f"{'name':22s}  {'shape':28s}  {'rms_diff':>12s}  {'max_abs':>10s}  {'ref_rms':>10s}  {'diff/ref':>9s}")
    print("-" * 110)

    for name in ORDER:
        if name not in py_manifest or name not in sw_manifest:
            print(f"{name:22s}  MISSING (py={name in py_manifest} sw={name in sw_manifest})")
            continue
        py_shape = py_manifest[name]["shape"]
        sw_shape = sw_manifest[name]["shape"]
        if py_shape != sw_shape:
            print(f"{name:22s}  SHAPE MISMATCH  py={py_shape}  sw={sw_shape}")
            continue
        try:
            py = load_f32(PY_DIR, name, py_shape).astype(np.float64)
            sw = load_f32(SW_DIR, name, sw_shape).astype(np.float64)
        except Exception as e:
            print(f"{name:22s}  load error: {e}")
            continue
        diff = sw - py
        rms_diff = float(np.sqrt(np.mean(diff * diff)))
        max_abs = float(np.max(np.abs(diff)))
        ref_rms = float(np.sqrt(np.mean(py * py)))
        ratio = rms_diff / ref_rms if ref_rms > 0 else float("nan")
        marker = " "
        if ratio > 0.01:
            marker = "*"
        if ratio > 0.5:
            marker = "**"
        print(f"{name:22s}  {str(py_shape):28s}  {rms_diff:12.5e}  {max_abs:10.4e}  {ref_rms:10.4e}  {ratio:>8.3e}{marker}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
