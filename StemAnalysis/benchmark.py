#!/usr/bin/env python3
"""
Phase 0 benchmark for demucs-mlx on this machine.

Measures: model-load time, separation wall-clock time, peak RAM, and
per-stem peak loudness so we can sanity-check the separation produced
something musically reasonable before investing in Swift integration.

Usage:
    .venv/bin/python benchmark.py /path/to/song.m4a
"""

from __future__ import annotations

import argparse
import gc
import os
import resource
import sys
import time
from pathlib import Path

import numpy as np


def peak_rss_mb() -> float:
    """Resident-set-size peak in MB. On macOS ru_maxrss is bytes."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def fmt_secs(s: float) -> str:
    return f"{s:.2f}s" if s < 60 else f"{int(s // 60)}m{s % 60:04.1f}s"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio_path", help="Input audio file (m4a, mp3, wav, flac)")
    ap.add_argument(
        "--model",
        default="htdemucs",
        help="Demucs model name (htdemucs, htdemucs_ft, mdx_extra, etc.)",
    )
    ap.add_argument(
        "--out",
        default="out_stems",
        help="Directory under StemAnalysis/ to write stem WAVs",
    )
    args = ap.parse_args()

    audio_path = Path(args.audio_path).expanduser().resolve()
    if not audio_path.exists():
        print(f"FATAL: audio file not found: {audio_path}", file=sys.stderr)
        return 1

    script_dir = Path(__file__).resolve().parent
    out_dir = (script_dir / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 72)
    print(f"Input:  {audio_path}")
    print(f"Output: {out_dir}")
    print(f"Model:  {args.model}")
    print("=" * 72)

    # ----- 1. Probe duration so we can compute realtime multiplier --------
    import mlx_audio_io as aio
    audio_info = aio.info(str(audio_path))
    duration_s = audio_info.duration
    print(f"Source: {audio_info.sample_rate} Hz, {audio_info.channels} ch, "
          f"{fmt_secs(duration_s)}")

    # ----- 2. Load the model (timed separately from inference) ------------
    from demucs_mlx import Separator

    t0 = time.monotonic()
    sep = Separator(model=args.model, progress=False)
    load_t = time.monotonic() - t0
    print(f"Model '{args.model}' loaded in {fmt_secs(load_t)}")
    print(f"RAM after model load: {peak_rss_mb():.1f} MB")

    # ----- 3. Run separation (the number we actually care about) ----------
    t0 = time.monotonic()
    original, stems_dict = sep.separate_audio_file(audio_path, return_mx=True)
    sep_t = time.monotonic() - t0
    realtime_mult = duration_s / sep_t
    print()
    print(f"SEPARATION: {fmt_secs(sep_t)} for {fmt_secs(duration_s)} "
          f"of audio → {realtime_mult:.1f}× realtime")
    print(f"RAM peak: {peak_rss_mb():.1f} MB")

    # ----- 4. Per-stem stats + write WAVs ---------------------------------
    # NOTE: NOT using `demucs_mlx.save_audio` — that path goes through
    # `mlx_audio_io.save` which has a confirmed bug on long inputs
    # (~200s+): the saved file contains the audio at 2× speed in the
    # first half + 1× speed in the second half (the user's "song plays
    # in double time, twice"). Round-trip-verified on a pure 440Hz
    # sine wave at 202s — bug appears around the file-write step, not
    # the model output. soundfile handles long writes correctly.
    import soundfile as sf

    print()
    print("Per-stem analysis (stems dict keys = source names):")
    print(f"  {'stem':<10} {'peak':>8} {'rms':>8} {'wav file'}")
    for stem_name, stem in stems_dict.items():
        # stem is an mx.array shaped (channels, samples).
        # soundfile expects (samples, channels) — transpose.
        stem_np = np.asarray(stem).astype(np.float32)
        if stem_np.shape[0] < stem_np.shape[1]:
            stem_np = stem_np.T  # (samples, channels)
        peak = float(np.max(np.abs(stem_np)))
        rms = float(np.sqrt(np.mean(stem_np ** 2)))
        out_path = out_dir / f"{audio_path.stem} - {stem_name}.wav"
        # Rescale to prevent clipping (demucs_mlx.save_audio did this
        # internally via _prevent_clip_mlx)
        if peak > 1.0:
            stem_np = stem_np / peak * 0.98
        sf.write(str(out_path), stem_np, sep.samplerate, subtype="PCM_16")
        print(f"  {stem_name:<10} {peak:>8.4f} {rms:>8.4f} {out_path.name}")

    # ----- 5. Throughput summary line for easy copy --------------------
    print()
    print("=" * 72)
    print(f"PHASE 0 RESULT: {realtime_mult:.1f}× realtime, "
          f"{peak_rss_mb():.0f}MB peak RAM, "
          f"{fmt_secs(load_t)} model-load, "
          f"{fmt_secs(sep_t)} inference")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
