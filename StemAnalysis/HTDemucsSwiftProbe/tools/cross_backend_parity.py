#!/usr/bin/env python
"""cross_backend_parity.py — Phase 2 cross-backend cache parity check.

Runs the Python sidecar's exact separation + feature derivation +
binary packing on the Phase 0 fixture WAV, then compares the produced
HVSF blob byte-for-byte against what the Swift backend's smoke test
wrote to its scratch SQLite.

Acceptance: blobs match exactly OR per-stem features match to float
precision (within 1e-3). Any larger divergence means the Swift backend
has drifted from sidecar.py and Phase 3 soak shouldn't trust either.

Run from StemAnalysis/.venv:
  cd StemAnalysis && .venv/bin/python \\
      HTDemucsSwiftProbe/tools/cross_backend_parity.py
"""
from __future__ import annotations

import os
import sys
import sqlite3
import struct
from pathlib import Path
from typing import Any

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE = REPO_ROOT / "artifacts" / "parity" / "input.wav"
def _resolve_swift_scratch() -> Path:
    """The smoke-test executable writes to
    `FileManager.default.temporaryDirectory`, which on macOS is the
    per-user dir reported by `getconf DARWIN_USER_TEMP_DIR`
    (`/var/folders/.../T/`). Resolve it the same way Foundation does
    so we find the actual file, regardless of `$TMPDIR` shell state."""
    import subprocess
    try:
        out = subprocess.check_output(
            ["getconf", "DARWIN_USER_TEMP_DIR"], text=True
        ).strip()
        if out:
            return Path(out) / "stem_smoke_test.sqlite"
    except Exception:
        pass
    return Path("/tmp/stem_smoke_test.sqlite")


SWIFT_SCRATCH = _resolve_swift_scratch()

# Import sidecar.py — it lives one dir up alongside the .venv.
SIDECAR_DIR = REPO_ROOT.parent
sys.path.insert(0, str(SIDECAR_DIR))


def unpack_hvsf(blob: bytes) -> dict[str, dict]:
    """Inverse of sidecar.py:_pack_features_binary. Returns
    {stem_name: {n_frames, chromagram, loudness, onset}}."""
    if blob[:4] != b"HVSF":
        raise ValueError(f"bad magic: {blob[:4]!r}")
    version = blob[4]
    chroma_bins = blob[5]
    if version != 2 or chroma_bins != 12:
        raise ValueError(f"unsupported version/bins: v{version} bins={chroma_bins}")
    pos = 8  # 4 magic + 1 version + 1 chroma + 2 reserved
    out: dict[str, dict] = {}
    while pos < len(blob):
        name_len = struct.unpack_from("<I", blob, pos)[0]; pos += 4
        name = blob[pos : pos + name_len].decode("utf-8"); pos += name_len
        n_frames = struct.unpack_from("<I", blob, pos)[0]; pos += 4
        chroma_bytes = n_frames * 12 * 4
        chroma = np.frombuffer(blob[pos : pos + chroma_bytes], dtype=np.float32).reshape(n_frames, 12)
        pos += chroma_bytes
        rms_bytes = n_frames * 4
        rms = np.frombuffer(blob[pos : pos + rms_bytes], dtype=np.float32).copy()
        pos += rms_bytes
        onset_bytes = (n_frames + 7) // 8
        onset_packed = blob[pos : pos + onset_bytes]
        pos += onset_bytes
        onset = np.zeros(n_frames, dtype=bool)
        for f in range(n_frames):
            if (onset_packed[f >> 3] >> (f & 7)) & 1:
                onset[f] = True
        out[name] = {
            "n_frames": n_frames,
            "chromagram": chroma,
            "loudness": rms,
            "onset": onset,
        }
    return out


def main() -> int:
    print(f"[1/4] Load fixture: {FIXTURE}")
    if not FIXTURE.exists():
        print(f"      ERROR: fixture missing — run tools/make_test_wav.py first")
        return 1
    import soundfile as sf
    audio_2d, sr = sf.read(str(FIXTURE), dtype="float32", always_2d=True)
    # audio_2d shape (samples, channels) → demucs wants (channels, samples) → (1, channels, samples)
    audio = audio_2d.T  # (2, 220500)
    print(f"      shape={audio.shape}, sr={sr}, dur={audio.shape[1]/sr:.2f}s")

    print(f"[2/4] Run Python sidecar's separation + features ...")
    import sidecar  # imports the long-running script as a module

    # Ensure the model is loaded (the same code path action_separate hits).
    sep = sidecar._ensure_separator("htdemucs")
    print(f"      model loaded: {type(sep).__name__}")

    # demucs_mlx's Separator.separate_tensor expects an mx.array.
    import torch
    import mlx.core as mx
    audio_mx = mx.array(audio)  # (channels, samples)
    print(f"      input shape: {audio_mx.shape}")

    # demucs_mlx.api.Separator.separate_tensor returns
    # (wav_np, {stem_name: ndarray}). The dict keys are the model's
    # canonical source order (drums/bass/other/vocals for htdemucs).
    _, stems_dict = sep.separate_tensor(audio_mx)
    print(f"      stems: {list(stems_dict.keys())}, "
          f"first shape: {next(iter(stems_dict.values())).shape}")

    # Derive per-stem features using sidecar's exact code path. We must
    # iterate in htdemucs canonical order so the binary blob layout
    # matches what the Swift backend produced.
    out_stems: dict[str, Any] = {}
    sources = ["drums", "bass", "other", "vocals"]
    for name in sources:
        stem_arr = stems_dict[name]  # (channels, samples) per demucs_mlx
        stem_np = np.ascontiguousarray(stem_arr.T)  # (samples, channels)
        out_stems[name] = sidecar.derive_features(stem_np, sr)

    py_blob, py_meta = sidecar._pack_features_binary(out_stems)
    print(f"      python blob: {len(py_blob)} bytes, meta {len(py_meta)} stems")

    print(f"[3/4] Load Swift smoke-test blob: {SWIFT_SCRATCH}")
    if not SWIFT_SCRATCH.exists():
        print(f"      ERROR: scratch db missing — run smoke test:")
        print(f"      $HOME/Library/Developer/Xcode/DerivedData/HTDemucsSwiftProbe-*/Build/Products/Release/swift-backend-smoke")
        return 1
    con = sqlite3.connect(str(SWIFT_SCRATCH))
    row = con.execute(
        "SELECT features_blob FROM stem_features WHERE cache_key='smoke-test-key'"
    ).fetchone()
    con.close()
    if not row:
        print(f"      ERROR: no smoke-test-key row in scratch db")
        return 1
    sw_blob = row[0]
    print(f"      swift blob: {len(sw_blob)} bytes")

    print(f"[4/4] Compare ...")
    if py_blob == sw_blob:
        print("      ✓ BYTE-IDENTICAL — full backend parity")
        return 0

    print(f"      blobs differ: py {len(py_blob)} vs sw {len(sw_blob)}")

    # Diff per-stem features
    py_stems = unpack_hvsf(py_blob)
    sw_stems = unpack_hvsf(sw_blob)

    print()
    print(f"{'stem':10s}  {'n_frames':>8s}  {'chroma rms':>11s}  {'rms err':>10s}  {'onset Δ':>8s}")
    print("-" * 60)
    overall_ok = True
    for name in sources:
        py_s = py_stems[name]
        sw_s = sw_stems[name]
        c_diff = np.sqrt(np.mean((py_s["chromagram"] - sw_s["chromagram"]) ** 2))
        c_ref = np.sqrt(np.mean(py_s["chromagram"] ** 2))
        c_ratio = c_diff / max(c_ref, 1e-12)
        rms_err = np.mean(np.abs(py_s["loudness"] - sw_s["loudness"]) /
                          np.maximum(np.abs(py_s["loudness"]), 1e-6))
        onset_diff = int(np.sum(py_s["onset"] != sw_s["onset"]))
        ok = c_ratio < 0.05 and rms_err < 0.10 and onset_diff <= 2
        if not ok: overall_ok = False
        print(f"{name:10s}  {py_s['n_frames']:>8d}  "
              f"{c_diff:>11.3e}  {rms_err*100:>9.3f}%  {onset_diff:>8d}  "
              f"{'✓' if ok else '✗'}")

    print()
    print("Acceptance: chroma_diff/chroma_rms < 5%, rms_err < 10%, onset Δ ≤ 2 frames")
    print("RESULT:", "✓ PASS (feature-level parity)" if overall_ok else "✗ FAIL")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
