#!/usr/bin/env python
"""tuning_impact.py — isolated measurement of the chromagram drift
caused PURELY by tuning=0 vs tuning=None.

For each Phase 0/1 reference stem (out_drums/bass/other/vocals.f32):
  1. Run librosa.feature.chroma_stft(tuning=0)
  2. Run librosa.feature.chroma_stft(tuning=None)  # default = estimate
  3. Diff the two chromagrams + report what librosa estimated.

If the diff is small → option (a) (ship fixed tuning) is safe.
If big → need option (b) (per-song stored tuning) or (c) (Swift port).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
PARITY = REPO_ROOT / "artifacts" / "parity"
# Real music: 4-minute Sinatra recording sitting in the StemAnalysis dir.
# Much more representative of the chromagram-pitch-sensitivity question
# than the synthetic Phase 0 fixture (which is near-silent random noise
# in most stems).
REAL_SONG_WAV = REPO_ROOT.parent / "sinatra_decoded.wav"

SR = 44100
FRAME_RATE = 30
N_FFT = 2048

# Phase 0 stems are channel-major float32: shape (2, 220500)
STEM_FILES = {
    "drums":  PARITY / "out_drums.f32",
    "bass":   PARITY / "out_bass.f32",
    "other":  PARITY / "out_other.f32",
    "vocals": PARITY / "out_vocals.f32",
}


def main() -> int:
    import librosa

    hop = SR // FRAME_RATE

    # Also test on something more "musical" — use the FULL mix (input.f32),
    # not just isolated low-energy stems. Synthetic noise fixtures
    # exaggerate worst-case behavior.
    print(f"{'stem':10s}  {'librosa tuning est':>18s}  {'max-bin Δ%':>11s}  {'chroma rms diff':>16s}  {'chroma ref rms':>15s}")
    print("-" * 80)

    overall_max_bin_changes: list[float] = []

    for name, path in STEM_FILES.items():
        if not path.exists():
            print(f"  {name}: SKIP ({path.name} missing)")
            continue
        # Load + downmix to mono (sidecar's derive_features does the same).
        raw = np.frombuffer(path.read_bytes(), dtype=np.float32).reshape(2, -1)
        mono = raw.mean(axis=0).astype(np.float32)

        # Both chromagrams at the same hop / n_fft.
        c_fixed = librosa.feature.chroma_stft(
            y=mono, sr=SR, n_fft=N_FFT, hop_length=hop, tuning=0
        )
        c_dyn = librosa.feature.chroma_stft(
            y=mono, sr=SR, n_fft=N_FFT, hop_length=hop
        )

        # What did librosa actually estimate?
        S = np.abs(librosa.stft(mono, n_fft=N_FFT, hop_length=hop)) ** 2
        est = librosa.estimate_tuning(S=S, sr=SR)

        # max-bin agreement frame-by-frame (the metric most visualizers care about)
        argmax_fixed = c_fixed.argmax(axis=0)
        argmax_dyn = c_dyn.argmax(axis=0)
        max_bin_changes = float((argmax_fixed != argmax_dyn).mean()) * 100

        # raw chroma diff
        diff = c_dyn - c_fixed
        rms_diff = float(np.sqrt(np.mean(diff ** 2)))
        ref_rms = float(np.sqrt(np.mean(c_dyn ** 2)))

        overall_max_bin_changes.append(max_bin_changes)
        print(f"  {name:8s}  {est:+18.4f}    {max_bin_changes:>9.2f}%   "
              f"{rms_diff:>14.4e}    {ref_rms:>13.4e}")

    print()
    # Run on the actual mix too — more realistic than stems alone.
    mix_path = PARITY / "input.f32"
    if mix_path.exists():
        raw = np.frombuffer(mix_path.read_bytes(), dtype=np.float32).reshape(2, -1)
        mono = raw.mean(axis=0).astype(np.float32)
        c_fixed = librosa.feature.chroma_stft(y=mono, sr=SR, n_fft=N_FFT, hop_length=hop, tuning=0)
        c_dyn = librosa.feature.chroma_stft(y=mono, sr=SR, n_fft=N_FFT, hop_length=hop)
        S = np.abs(librosa.stft(mono, n_fft=N_FFT, hop_length=hop)) ** 2
        est = librosa.estimate_tuning(S=S, sr=SR)
        argmax_fixed = c_fixed.argmax(axis=0)
        argmax_dyn = c_dyn.argmax(axis=0)
        max_bin_changes = float((argmax_fixed != argmax_dyn).mean()) * 100
        diff = c_dyn - c_fixed
        rms_diff = float(np.sqrt(np.mean(diff ** 2)))
        ref_rms = float(np.sqrt(np.mean(c_dyn ** 2)))
        print(f"  {'FULL MIX':8s}  {est:+18.4f}    {max_bin_changes:>9.2f}%   "
              f"{rms_diff:>14.4e}    {ref_rms:>13.4e}")

    # =======================================================
    # Real song: Sinatra ~4 min, gets separated by Python sidecar then
    # each stem chromagram measured under tuning=0 vs tuning=None.
    # This is the actually-relevant test for the production decision.
    # =======================================================
    if REAL_SONG_WAV.exists():
        print()
        print("=== REAL SONG (Sinatra, ~4 min) ===")
        import soundfile as sf
        audio_2d, file_sr = sf.read(str(REAL_SONG_WAV), dtype="float32", always_2d=True)
        if file_sr != SR:
            import librosa as _lib
            audio_2d = _lib.resample(audio_2d.T, orig_sr=file_sr, target_sr=SR).T
        audio = audio_2d.T  # (channels, samples)
        dur = audio.shape[1] / SR
        print(f"Loaded {REAL_SONG_WAV.name}  dur={dur:.1f}s")
        print()

        # Full mix tuning baseline.
        mono_mix = audio.mean(axis=0).astype(np.float32)
        c_fixed_mix = librosa.feature.chroma_stft(y=mono_mix, sr=SR, n_fft=N_FFT, hop_length=hop, tuning=0)
        c_dyn_mix = librosa.feature.chroma_stft(y=mono_mix, sr=SR, n_fft=N_FFT, hop_length=hop)
        S_mix = np.abs(librosa.stft(mono_mix, n_fft=N_FFT, hop_length=hop)) ** 2
        est_mix = librosa.estimate_tuning(S=S_mix, sr=SR)
        am_f = c_fixed_mix.argmax(axis=0); am_d = c_dyn_mix.argmax(axis=0)
        mix_delta = float((am_f != am_d).mean()) * 100
        print(f"  FULL MIX (Sinatra)   tuning_est={est_mix:+.4f}   max-bin Δ={mix_delta:5.2f}%")

        # Now separate via Python sidecar to get real stems, then measure
        # chromagram drift on each stem.
        import sys
        sys.path.insert(0, str(REPO_ROOT.parent))
        import sidecar
        import mlx.core as mx
        sep = sidecar._ensure_separator("htdemucs")
        audio_mx = mx.array(audio)
        print(f"  Running Python sidecar separation...")
        _, stems_dict = sep.separate_tensor(audio_mx)
        print(f"  Stems: {list(stems_dict.keys())}")
        print()

        real_changes: list[float] = []
        for name in ["drums", "bass", "other", "vocals"]:
            stem_audio = stems_dict[name]  # (channels, samples)
            mono = np.asarray(stem_audio).mean(axis=0).astype(np.float32)
            rms_stem = float(np.sqrt(np.mean(mono ** 2)))
            c_fixed = librosa.feature.chroma_stft(y=mono, sr=SR, n_fft=N_FFT, hop_length=hop, tuning=0)
            c_dyn = librosa.feature.chroma_stft(y=mono, sr=SR, n_fft=N_FFT, hop_length=hop)
            S = np.abs(librosa.stft(mono, n_fft=N_FFT, hop_length=hop)) ** 2
            est = librosa.estimate_tuning(S=S, sr=SR)
            am_f = c_fixed.argmax(axis=0); am_d = c_dyn.argmax(axis=0)
            delta = float((am_f != am_d).mean()) * 100
            real_changes.append(delta)
            print(f"  {name:8s}  rms={rms_stem:.4f}  tuning_est={est:+.4f}   max-bin Δ={delta:5.2f}%")

        avg_real = sum(real_changes) / len(real_changes)
        print()
        print(f"REAL-SONG per-stem average: {avg_real:.2f}%")

    print()
    print("Acceptance for option (a) — ship fixed tuning=0:")
    print("  • max-bin Δ < 5% across stems → visualizers will barely notice")
    print("  • max-bin Δ 5-15% → marginal — judge with real visualizer A/B")
    print("  • max-bin Δ > 15% → noticeable shifts, escalate to option (b) or (c)")

    avg_change = sum(overall_max_bin_changes) / max(1, len(overall_max_bin_changes))
    print(f"\nObserved per-stem average: {avg_change:.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
