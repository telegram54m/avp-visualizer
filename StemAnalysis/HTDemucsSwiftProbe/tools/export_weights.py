#!/usr/bin/env python
"""
export_weights.py — htdemucs PyTorch .th → MLX-layout .safetensors.

Wraps demucs_mlx.convert_state_dict (which already does the conv weight
transposes and the in_proj_weight → query/key/value split that MLX uses)
and writes the result as safetensors.

Output:
  artifacts/htdemucs.safetensors  — flat tensor map
  artifacts/htdemucs_config.json  — constructor args + parameter inventory

The Swift loader (P0.5) opens both: the .safetensors via
MLX.loadArrays(url:), the JSON to know which constructor parameters to
pass to HTDemucsSwift's initializer.

Run from the StemAnalysis/.venv:
  cd StemAnalysis && .venv/bin/python \\
      HTDemucsSwiftProbe/tools/export_weights.py htdemucs
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = REPO_ROOT / "artifacts"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "model_name",
        nargs="?",
        default="htdemucs",
        choices=["htdemucs", "htdemucs_ft", "htdemucs_6s"],
        help="Demucs model to convert (default: htdemucs)",
    )
    parser.add_argument(
        "--output-dir",
        default=str(ARTIFACTS),
        help=f"Output directory (default: {ARTIFACTS})",
    )
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    print(f"[1/4] Loading PyTorch model '{args.model_name}' ...")
    from demucs.apply import BagOfModels
    from demucs.pretrained import get_model

    torch_model = get_model(args.model_name)
    if isinstance(torch_model, BagOfModels):
        # htdemucs_ft is a bag of 4 fine-tuned models. For Phase 0 parity
        # we want a single model, so export just the first.
        print(f"      Bag of {len(torch_model.models)} models — exporting model[0] only")
        tm = torch_model.models[0]
    else:
        tm = torch_model

    print(f"      class={type(tm).__name__} sources={tm.sources}")

    print("[2/4] Converting state_dict to MLX layout ...")
    from demucs_mlx.mlx_convert import convert_state_dict

    torch_state = tm.state_dict()
    print(f"      {len(torch_state)} torch parameters")

    flat_mlx_state = convert_state_dict(
        torch_state,
        verbose=False,
        flatten=True,
        torch_model=tm,
    )
    print(f"      {len(flat_mlx_state)} mlx-layout parameters")

    # convert_state_dict leaves three kinds of redundant keys behind:
    #   1. .gn. wrapper duplicates (demucs_mlx's MyGroupNorm indirection;
    #      mlx-swift uses nn.GroupNorm directly so we don't need them).
    #   2. self_attn.in_proj_{weight,bias} (already split into
    #      attn.{query,key,value}_proj.{weight,bias}).
    #   3. self_attn.out_proj.* (already renamed to attn.out_proj.*).
    # Drop all three so the safetensors only contains live parameters.
    cleaned: dict = {}
    dropped = {
        "gn": 0,
        "self_attn_in_proj": 0,
        "self_attn_out_proj": 0,
        "cross_attn_in_proj": 0,
    }
    for k, v in flat_mlx_state.items():
        if ".gn." in k:
            dropped["gn"] += 1
            continue
        if ".self_attn.in_proj_" in k:
            dropped["self_attn_in_proj"] += 1
            continue
        if ".self_attn.out_proj." in k:
            dropped["self_attn_out_proj"] += 1
            continue
        if ".cross_attn.in_proj_" in k:
            # convert_state_dict only renames self_attn → attn; for
            # cross_attn it splits in_proj into q/k/v but leaves the
            # original in_proj_* in place. Drop them to avoid clutter.
            dropped["cross_attn_in_proj"] += 1
            continue
        cleaned[k] = v
    for tag, count in dropped.items():
        if count:
            print(f"      dropped {count} {tag} duplicates")

    print("[3/4] Writing safetensors ...")
    try:
        from safetensors.numpy import save_file as save_safetensors
        import numpy as np
    except ImportError:
        print("      ERROR: pip install safetensors numpy", file=sys.stderr)
        return 1

    np_state = {}
    total_params = 0
    for k, v in cleaned.items():
        # v is an mx.array; route via numpy.
        try:
            arr = np.asarray(v)
        except Exception:
            # Some mlx arrays need explicit conversion
            import mlx.core as mx

            mx.eval(v)
            arr = np.array(v)
        np_state[k] = arr
        total_params += arr.size

    safetensors_path = Path(args.output_dir) / f"{args.model_name}.safetensors"
    save_safetensors(np_state, str(safetensors_path))
    size_mb = safetensors_path.stat().st_size / (1024 * 1024)
    print(f"      {safetensors_path}  ({size_mb:.1f} MB, {total_params:,} params)")

    print("[4/4] Writing config JSON ...")
    init_args, init_kwargs = tm._init_args_kwargs
    # Filter to JSON-serializable kwargs (lists/scalars only).
    safe_kwargs = {}
    for k, v in init_kwargs.items():
        try:
            json.dumps(v)
            safe_kwargs[k] = v
        except TypeError:
            safe_kwargs[k] = str(v)

    # Parameter inventory so Swift can validate shape/dtype on load.
    param_inventory = []
    for name in sorted(np_state.keys()):
        arr = np_state[name]
        param_inventory.append(
            {"name": name, "shape": list(arr.shape), "dtype": str(arr.dtype)}
        )

    config = {
        "model_name": args.model_name,
        "model_class": type(tm).__name__,
        "sources": list(tm.sources),
        "audio_channels": int(tm.audio_channels),
        "samplerate": int(tm.samplerate),
        "segment": float(getattr(tm, "segment", 0.0)),
        "init_args": list(init_args),
        "init_kwargs": safe_kwargs,
        "param_count": len(np_state),
        "param_inventory": param_inventory,
        "exported_at": datetime.now().isoformat(),
        "exporter": "HTDemucsSwiftProbe/tools/export_weights.py",
    }
    config_path = Path(args.output_dir) / f"{args.model_name}_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"      {config_path}")

    print()
    print("✓ done.")
    print(f"  safetensors : {safetensors_path}")
    print(f"  config json : {config_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
