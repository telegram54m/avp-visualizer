#!/usr/bin/env python
"""time_python_sidecar.py — time demucs_mlx htdemucs.separate on the
same input the Swift probe uses, so we can compare apples to apples.

Loads input.f32 (raw float32 buffer, 2 channels × 220500 samples) and
runs the model forward through demucs_mlx with everything warm. Times
just the forward pass, not the cache/JSON/IPC overhead the production
sidecar adds.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
PARITY = REPO_ROOT / "artifacts" / "parity"


def main() -> int:
    print("[1/4] Loading input fixture...")
    sig = np.frombuffer(
        (PARITY / "input.f32").read_bytes(), dtype=np.float32
    ).reshape(2, -1).copy()
    print(f"      shape={sig.shape}, audio_seconds={sig.shape[-1] / 44100:.2f}")

    print("[2/4] Loading htdemucs (PyTorch torch.compile path)...")
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import BagOfModels

    bag = get_model("htdemucs")
    model = bag.models[0] if isinstance(bag, BagOfModels) else bag
    model.cpu().eval()  # PyTorch CPU — same as our parity reference
    x_torch = torch.from_numpy(sig).unsqueeze(0)

    print("[3/4] Loading htdemucs (demucs-mlx Metal path)...")
    from demucs_mlx.mlx_convert import load_mlx_model
    import mlx.core as mx

    mlx_model = load_mlx_model("htdemucs", verbose=False)
    if hasattr(mlx_model, "models"):
        mlx_model = mlx_model.models[0]
    x_mlx = mx.array(sig).reshape(1, 2, -1)

    print("[4/4] Timing...")
    n_runs = 3

    # PyTorch CPU.
    with torch.no_grad():
        # warm-up
        _ = model(x_torch)
        torch_times = []
        for _ in range(n_runs):
            t0 = time.perf_counter()
            _ = model(x_torch)
            torch_times.append(time.perf_counter() - t0)
    torch_best = min(torch_times)
    print(f"  PyTorch CPU:   best={torch_best:.3f}s  → {5.0 / torch_best:.2f}x realtime  (n={n_runs})")

    # MLX Metal (warm-up first).
    _ = mlx_model(x_mlx)
    mx.eval(_)
    mlx_times = []
    for _ in range(n_runs):
        t0 = time.perf_counter()
        y = mlx_model(x_mlx)
        mx.eval(y)
        mlx_times.append(time.perf_counter() - t0)
    mlx_best = min(mlx_times)
    print(f"  demucs-mlx GPU: best={mlx_best:.3f}s  → {5.0 / mlx_best:.2f}x realtime  (n={n_runs})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
