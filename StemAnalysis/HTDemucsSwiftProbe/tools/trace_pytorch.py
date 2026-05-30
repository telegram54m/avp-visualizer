#!/usr/bin/env python
"""
trace_pytorch.py — run htdemucs on the parity fixture and dump
intermediate activations.

Outputs raw float32 buffers + a JSON manifest of shapes, so the Swift
side can load each one and compare. We hook the encoder/decoder/
transformer outputs via forward hooks, then run the model once.

Output to artifacts/parity/trace_pytorch/:
  manifest.json
  spec.f32     mag.f32     mag_normed.f32  xt_normed.f32
  enc_0.f32 enc_1.f32 enc_2.f32 enc_3.f32
  tenc_0.f32 tenc_1.f32 tenc_2.f32 tenc_3.f32
  xtransformer_x.f32  xtransformer_xt.f32
  dec_0.f32 dec_1.f32 dec_2.f32 dec_3.f32
  tdec_0.f32 tdec_1.f32 tdec_2.f32 tdec_3.f32
  ispec.f32  final.f32
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
PARITY_DIR = REPO_ROOT / "artifacts" / "parity"
TRACE_DIR = PARITY_DIR / "trace_pytorch"


def save_tensor(t, name: str, manifest: dict):
    """Save a torch tensor as raw float32 + record shape."""
    arr = t.detach().cpu().numpy().astype(np.float32)
    path = TRACE_DIR / f"{name}.f32"
    path.write_bytes(np.ascontiguousarray(arr).tobytes())
    manifest[name] = {
        "shape": list(arr.shape),
        "dtype": str(arr.dtype),
        "first5": [float(v) for v in arr.flatten()[:5]],
        "last5": [float(v) for v in arr.flatten()[-5:]],
        "mean": float(arr.mean()),
        "std": float(arr.std()),
        "min": float(arr.min()),
        "max": float(arr.max()),
    }


def save_complex(t, name: str, manifest: dict):
    """Save a complex torch tensor — interleave real/imag, shape gains last dim 2."""
    arr_c = t.detach().cpu().numpy()
    real = np.real(arr_c).astype(np.float32)
    imag = np.imag(arr_c).astype(np.float32)
    interleaved = np.stack([real, imag], axis=-1).astype(np.float32)
    path = TRACE_DIR / f"{name}.f32"
    path.write_bytes(np.ascontiguousarray(interleaved).tobytes())
    manifest[name] = {
        "shape": list(interleaved.shape),
        "dtype": "complex64_interleaved",
        "first5_real": [float(v) for v in real.flatten()[:5]],
        "first5_imag": [float(v) for v in imag.flatten()[:5]],
        "mean_abs": float(np.mean(np.abs(arr_c))),
        "std_abs": float(np.std(np.abs(arr_c))),
    }


def main() -> int:
    os.makedirs(TRACE_DIR, exist_ok=True)

    print("[1/3] Loading model + fixture...")
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import BagOfModels

    bag = get_model("htdemucs")
    if isinstance(bag, BagOfModels):
        model = bag.models[0]
    else:
        model = bag
    model.cpu().eval()

    # Load fixture input.
    sig = np.frombuffer(
        (PARITY_DIR / "input.f32").read_bytes(), dtype=np.float32
    ).reshape(2, -1).copy()
    print(f"      input shape={sig.shape}")
    x = torch.from_numpy(sig).unsqueeze(0)  # (1, 2, T)

    manifest: dict = {}

    print("[2/3] Running instrumented forward...")
    # The HTDemucs model expects the input padded to the training length.
    # We replicate the call from HTDemucs.forward so we can interleave
    # save_tensor calls without monkey-patching the whole class.
    import math
    training_length = int(model.segment * model.samplerate)
    if x.shape[-1] < training_length:
        prepad = x.shape[-1]
        x = torch.nn.functional.pad(x, (0, training_length - prepad))
    else:
        prepad = None

    save_tensor(x, "mix_input", manifest)

    with torch.no_grad():
        # --- _spec ---
        hl = model.hop_length
        le = int(math.ceil(x.shape[-1] / hl))
        pad = hl // 2 * 3
        from demucs.spec import spectro, ispectro
        from demucs.hdemucs import pad1d
        z = model._spec(x)
        save_complex(z, "spec", manifest)

        # --- magnitude ---
        mag = model._magnitude(z)
        save_tensor(mag, "mag", manifest)

        # --- normalize spectral ---
        B, C, Fq, T = mag.shape
        mean = mag.mean(dim=(1, 2, 3), keepdim=True)
        std = mag.std(dim=(1, 2, 3), keepdim=True)
        x_spec = (mag - mean) / (1e-5 + std)
        save_tensor(x_spec, "mag_normed", manifest)

        # --- normalize time ---
        xt = x
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)
        save_tensor(xt, "xt_normed", manifest)

        # --- encoders ---
        saved = []
        saved_t = []
        lengths = []
        lengths_t = []
        x_cur = x_spec
        xt_cur = xt
        for idx, encode in enumerate(model.encoder):
            lengths.append(x_cur.shape[-1])
            inject = None
            if idx < len(model.tencoder):
                lengths_t.append(xt_cur.shape[-1])
                tenc = model.tencoder[idx]
                xt_cur = tenc(xt_cur)
                save_tensor(xt_cur, f"tenc_{idx}", manifest)
                if not tenc.empty:
                    saved_t.append(xt_cur)
                else:
                    inject = xt_cur
            x_cur = encode(x_cur, inject)
            if idx == 0 and model.freq_emb is not None:
                frs = torch.arange(x_cur.shape[-2], device=x_cur.device)
                emb = model.freq_emb(frs).t()[None, :, :, None].expand_as(x_cur)
                x_cur = x_cur + model.freq_emb_scale * emb
            save_tensor(x_cur, f"enc_{idx}", manifest)
            saved.append(x_cur)

        # --- cross transformer ---
        if model.crosstransformer:
            if model.bottom_channels:
                b, c, f, t = x_cur.shape
                x_cur = x_cur.reshape(b, c, f * t)
                x_cur = model.channel_upsampler(x_cur)
                x_cur = x_cur.reshape(b, model.bottom_channels, f, t)
                xt_cur = model.channel_upsampler_t(xt_cur)
            save_tensor(x_cur, "xtransformer_x_in", manifest)
            save_tensor(xt_cur, "xtransformer_xt_in", manifest)
            # Inline the transformer with traces (avoid monkey-patching).
            ct = model.crosstransformer
            from demucs.transformer import create_sin_embedding, create_2d_sin_embedding
            B_, C_, Fr_, T1_ = x_cur.shape
            pos_emb_2d = create_2d_sin_embedding(C_, Fr_, T1_, ct.max_period).to(x_cur.dtype)
            save_tensor(pos_emb_2d, "tform_pos2d_raw", manifest)
            pos_emb_2d = pos_emb_2d.reshape(1, C_, Fr_, T1_).expand(B_, -1, -1, -1)
            pos_emb_2d = pos_emb_2d.permute(0, 3, 2, 1).reshape(B_, T1_ * Fr_, C_)
            save_tensor(pos_emb_2d, "tform_pos2d_flat", manifest)
            xs = x_cur.permute(0, 3, 2, 1).reshape(B_, T1_ * Fr_, C_)
            save_tensor(xs, "tform_x_pre_norm", manifest)
            xs = ct.norm_in(xs)
            save_tensor(xs, "tform_x_post_norm", manifest)
            xs = xs + ct.weight_pos_embed * pos_emb_2d
            save_tensor(xs, "tform_x_post_pos", manifest)

            B2_, C2_, T2_ = xt_cur.shape
            xts = xt_cur.permute(0, 2, 1)
            pos_emb_1d = create_sin_embedding(T2_, C2_, max_period=ct.max_period).to(xt_cur.dtype)
            save_tensor(pos_emb_1d, "tform_pos1d_raw", manifest)
            pos_emb_1d = pos_emb_1d.permute(1, 0, 2)
            xts = ct.norm_in_t(xts)
            xts = xts + ct.weight_pos_embed * pos_emb_1d

            for idx in range(ct.num_layers):
                if idx % 2 == ct.classic_parity:
                    xs = ct.layers[idx](xs)
                    xts = ct.layers_t[idx](xts)
                else:
                    old_x = xs
                    xs = ct.layers[idx](xs, xts)
                    xts = ct.layers_t[idx](xts, old_x)
                save_tensor(xs, f"tform_layer_{idx}_x", manifest)
                save_tensor(xts, f"tform_layer_{idx}_xt", manifest)

            x_cur = xs.reshape(B_, T1_, Fr_, C_).permute(0, 3, 2, 1)
            xt_cur = xts.permute(0, 2, 1)
            save_tensor(x_cur, "xtransformer_x", manifest)
            save_tensor(xt_cur, "xtransformer_xt", manifest)
            if model.bottom_channels:
                x_cur = x_cur.reshape(b, model.bottom_channels, f * t)
                x_cur = model.channel_downsampler(x_cur)
                x_cur = x_cur.reshape(b, c, f, t)
                xt_cur = model.channel_downsampler_t(xt_cur)

        # --- decoders ---
        offset = model.depth - len(model.tdecoder)
        for idx, decode in enumerate(model.decoder):
            skip = saved.pop(-1)
            x_cur, pre = decode(x_cur, skip, lengths.pop(-1))
            save_tensor(x_cur, f"dec_{idx}", manifest)
            if idx >= offset:
                tdec = model.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt_cur, _ = tdec(pre, None, length_t)
                else:
                    skip_t = saved_t.pop(-1)
                    xt_cur, _ = tdec(xt_cur, skip_t, length_t)
                save_tensor(xt_cur, f"tdec_{idx}", manifest)

        # --- final reshape, unnormalize, mask, ispec ---
        S = len(model.sources)
        x_cur = x_cur.reshape(B, S, -1, Fq, T)
        x_cur = x_cur * std[:, None] + mean[:, None]
        save_tensor(x_cur, "x_pre_mask", manifest)

        zout = model._mask(z, x_cur)
        save_complex(zout, "zout", manifest)

        x_out = model._ispec(zout, training_length)
        save_tensor(x_out, "ispec", manifest)

        actual_length = xt_cur.shape[-1]
        xt_cur = xt_cur.reshape(B, S, -1, actual_length)
        xt_cur = xt_cur * stdt[:, None] + meant[:, None]
        save_tensor(xt_cur, "xt_unnorm", manifest)

        # center_trim x to xt
        from demucs.utils import center_trim
        x_out = center_trim(x_out, xt_cur)
        x_out = xt_cur + x_out
        save_tensor(x_out, "final_pre_trim", manifest)

        x_out = x_out[..., :training_length]
        if prepad is not None:
            x_out = x_out[..., :prepad]
        save_tensor(x_out, "final", manifest)

    print("[3/3] Writing manifest...")
    with open(TRACE_DIR / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"      {TRACE_DIR}")
    print()
    print("✓ done.")
    print(f"  {len(manifest)} trace points written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
