#!/usr/bin/env python
"""dump_librosa_reference.py — Phase 1 parity fixture.

Runs librosa's chroma_stft + rms + onset_detect on a fixture stem and
dumps frame-by-frame outputs as raw f32 buffers + a manifest. Also
exports librosa's chroma filterbank (12 x n_fft/2+1) so Swift can load
and apply it directly instead of reimplementing the Shepard-tone
gaussian-tuning filter construction (which has subtle parameters that
would be brittle to port from scratch).

Reuses HTDemucsSwiftProbe's parity fixture (drums stem of the standard
5-second test input). Run from StemAnalysis/.venv:
  cd StemAnalysis && .venv/bin/python \\
      FeatureDeriveSwiftProbe/tools/dump_librosa_reference.py
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
P0_PARITY = REPO_ROOT.parent / "HTDemucsSwiftProbe" / "artifacts" / "parity"
ARTIFACTS = REPO_ROOT / "artifacts"
PARITY_DIR = ARTIFACTS / "parity"

SR = 44100
FRAME_RATE = 30
N_FFT = 2048

STEM_NAMES = ["drums", "bass", "other", "vocals"]


def f32(arr: np.ndarray) -> bytes:
    return np.ascontiguousarray(arr.astype(np.float32)).tobytes()


def main() -> int:
    os.makedirs(PARITY_DIR, exist_ok=True)

    print(f"[1/4] Loading fixture stems from {P0_PARITY}...")
    # Each out_*.f32 is shape (2, 220500) = (channels, samples) from Phase 0.
    samples = 220500
    stems: dict[str, np.ndarray] = {}
    for name in STEM_NAMES:
        path = P0_PARITY / f"out_{name}.f32"
        if not path.exists():
            print(f"      ERROR: {path} missing — run HTDemucsSwiftProbe first.")
            return 1
        arr = np.frombuffer(path.read_bytes(), dtype=np.float32)
        arr = arr.reshape(2, samples)
        stems[name] = arr
    print(f"      4 stems @ {samples} samples each")

    print("[2/4] Running librosa derive_features...")
    import librosa

    hop = SR // FRAME_RATE  # 1470 for sr=44100, FRAME_RATE=30

    manifest: dict = {
        "sr": SR,
        "frame_rate": FRAME_RATE,
        "hop": hop,
        "n_fft": N_FFT,
        "stems": {},
    }

    for name, stem in stems.items():
        # Mix to mono per the sidecar convention (mean across channels).
        mono = stem.mean(axis=0).astype(np.float32)

        # tuning=0 disables librosa's per-call tuning estimation so the
        # reference filterbank matches the one we export to disk. The
        # production sidecar accepts whatever librosa's estimator picks;
        # parity-locking it here makes the Swift port testable.
        chroma = librosa.feature.chroma_stft(
            y=mono, sr=SR, n_fft=N_FFT, hop_length=hop, tuning=0
        ).T  # (n_frames, 12)

        rms = librosa.feature.rms(
            y=mono, frame_length=hop * 2, hop_length=hop, center=True
        )[0]  # (n_frames,)

        onset_frames = librosa.onset.onset_detect(
            y=mono, sr=SR, hop_length=hop, units="frames"
        )

        n_frames = chroma.shape[0]
        onset_bool = np.zeros(n_frames, dtype=bool)
        valid = onset_frames[(onset_frames >= 0) & (onset_frames < n_frames)]
        onset_bool[valid] = True

        # Truncate to the minimum length (sidecar.py does this).
        n = min(chroma.shape[0], rms.shape[0], onset_bool.shape[0])
        chroma = chroma[:n]
        rms = rms[:n]
        onset_bool = onset_bool[:n]

        # Max-bin normalize (sidecar convention).
        chroma_max = np.maximum(chroma.max(axis=1, keepdims=True), 1e-6)
        chroma_norm = chroma / chroma_max

        # Save raw mono input + features so Swift can read them.
        (PARITY_DIR / f"{name}_mono.f32").write_bytes(f32(mono))
        (PARITY_DIR / f"{name}_chroma.f32").write_bytes(f32(chroma_norm))
        (PARITY_DIR / f"{name}_rms.f32").write_bytes(f32(rms))
        # Onsets: pack as 0/1 floats so the same loader works.
        (PARITY_DIR / f"{name}_onset.f32").write_bytes(
            f32(onset_bool.astype(np.float32))
        )

        manifest["stems"][name] = {
            "n_samples": int(mono.shape[0]),
            "n_frames": int(n),
            "n_onsets": int(onset_bool.sum()),
            "rms_mean": float(rms.mean()),
            "rms_max": float(rms.max()),
            "chroma_mean": float(chroma_norm.mean()),
            "chroma_min": float(chroma_norm.min()),
            "chroma_max": float(chroma_norm.max()),
        }
        print(
            f"      {name:6s}  n_frames={n}  n_onsets={onset_bool.sum():3d}  "
            f"rms_max={rms.max():.4f}"
        )

    print("[3/4] Exporting librosa filterbanks + onset intermediates...")
    # Chroma filterbank (12, n_fft/2 + 1). Depends only on sr + n_fft +
    # tuning (default = 0). Saved once.
    fb = librosa.filters.chroma(sr=SR, n_fft=N_FFT)
    (PARITY_DIR / "chroma_filterbank.f32").write_bytes(f32(fb))
    manifest["chroma_filterbank_shape"] = list(fb.shape)
    print(f"      chroma filterbank shape={fb.shape}")

    # Mel filterbank (128, n_fft/2 + 1). librosa.onset.onset_strength
    # uses the mel spectrogram by default. n_mels=128 is the librosa
    # default.
    mel_fb = librosa.filters.mel(sr=SR, n_fft=N_FFT, n_mels=128)
    (PARITY_DIR / "mel_filterbank.f32").write_bytes(f32(mel_fb))
    manifest["mel_filterbank_shape"] = list(mel_fb.shape)
    print(f"      mel filterbank shape={mel_fb.shape}")

    # Also dump intermediate onset envelope and mel-spectrogram for the
    # drums stem so the Swift port can bisect its onset path.
    drums = stems["drums"].mean(axis=0).astype(np.float32)
    mel_spec = librosa.feature.melspectrogram(
        y=drums, sr=SR, n_fft=N_FFT, hop_length=hop, n_mels=128
    )
    log_mel = librosa.power_to_db(mel_spec, ref=np.max)
    onset_env = librosa.onset.onset_strength(
        y=drums, sr=SR, hop_length=hop
    )
    (PARITY_DIR / "drums_mel_spec.f32").write_bytes(f32(mel_spec))
    (PARITY_DIR / "drums_log_mel.f32").write_bytes(f32(log_mel))
    (PARITY_DIR / "drums_onset_env.f32").write_bytes(f32(onset_env))
    manifest["drums_mel_spec_shape"] = list(mel_spec.shape)
    manifest["drums_onset_env_shape"] = list(onset_env.shape)
    print(f"      drums mel_spec={mel_spec.shape}, onset_env={onset_env.shape}")

    print("[4/4] Writing manifest...")
    with open(PARITY_DIR / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"      {PARITY_DIR / 'manifest.json'}")

    print()
    print("✓ done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
