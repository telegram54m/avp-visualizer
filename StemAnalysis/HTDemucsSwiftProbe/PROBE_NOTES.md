# Phase 0 probe — coverage findings

Date: 2026-05-30
Spec: `~/.claude/projects/.../memory/swift-sidecar-port-spec.md`

## Headline

**mlx-swift coverage of HTDemucs primitives: GO.** No blocking gaps. The
spec's concern about "LSTM at the bottleneck / cross-domain attention"
turned out to be **overstated for HTDemucs specifically** — see
"Risk-register correction" below.

## Primitive coverage table

Read against `demucs_mlx`'s HTDemucs implementation (`mlx_htdemucs.py`,
`mlx_hdemucs.py`, `mlx_demucs.py`, `mlx_transformer.py`,
`spec_mlx.py`). mlx-swift inspected at `main` (clone in
`/tmp/mlx-swift-probe`).

| Primitive (mlx Python) | mlx-swift | Status |
|---|---|---|
| `nn.Conv1d` | `Conv1d` | ✅ |
| `nn.Conv2d` | `Conv2d` | ✅ |
| `nn.ConvTranspose1d` | `ConvTransposed1d` | ✅ |
| `nn.ConvTranspose2d` | `ConvTransposed2d` | ✅ |
| `nn.LayerNorm` | `LayerNorm` | ✅ |
| `nn.GroupNorm(pytorch_compatible=True)` | `GroupNorm(pytorchCompatible: true)` | ✅ |
| `nn.MultiHeadAttention` | `MultiHeadAttention` | ✅ |
| `nn.Linear` | `Linear` | ✅ |
| `nn.Embedding` | `Embedding` | ✅ |
| `nn.Identity` | `Identity` | ✅ |
| `nn.Dropout` (no-op in inference) | `Dropout` | ✅ |
| `nn.gelu`, `nn.sigmoid`, `mx.softmax` | `gelu`, `sigmoid`, `softmax` | ✅ |
| `mx.matmul`, `mx.einsum` | `matmul`, `einsum` | ✅ |
| `mx.abs`, `.real`, `.imag` (complex) | `abs`, `realPart()`, `imaginaryPart()` | ✅ |
| Complex64 dtype + arithmetic | `DType.complex64` + ops | ✅ |
| `mx.transpose`, `.reshape`, `mx.broadcast_to` | `transposed`, `reshaped`, `broadcast(...)` | ✅ |
| `mx.concatenate`, `mx.stack`, `mx.split` | `concatenated`, `stacked`, `split` | ✅ |
| `mx.arange`, `mx.zeros`, `mx.ones`, `mx.eye`, `mx.zeros_like` | all present | ✅ |
| `mx.where`, `mx.mean`/`std`/`var`/`sum` | `where(_:_:_:)`, reductions | ✅ |
| `MLX.FFT.rfft` / `irfft` | `MLXFFT.rfft` / `MLXFFT.irfft` | ✅ |
| `mx.load(.safetensors)` | `loadArrays(url:)` | ✅ |
| `mx.pad(mode="reflect")` | `PadMode` only has `.constant` and `.edge` | **WORKAROUND** (see below) |
| `mx.vmap` (used only in Wiener path) | available | ✅ (and not exercised — see below) |

### Reflect padding workaround

`mlx-swift`'s `PadMode` enum is `.constant | .edge` only. Reflect must
be open-coded as `slice + reverse + concat`. Trivial — **the demucs
Python source already does this manually**: see
`mlx_hdemucs.py:50-56`. We just port the same 6 lines.

### Wiener filter (`wiener_mlx.py`)

Not exercised. HTDemucs default config is `cac=True` (Complex As
Channels), which short-circuits to a real+imag reshape and skips
`_wiener()` entirely. We can omit the Wiener port from Phase 0 (and
likely from the final shipping port).

## Risk-register correction

The parent spec's Phase 0 risk register flagged two "uncertain"
mlx-swift exposures:

> - LSTM at the bottleneck — **uncertain** in mlx-swift; check.
> - Local Attention layers (htdemucs has DConv variants with cross-domain attention) — **uncertain**.

Both turned out to be non-issues for HTDemucs:

1. **LSTM is in mlx-swift** (`open class LSTM: Module` in
   `Source/MLXNN/Recurrent.swift`), but **HTDemucs doesn't construct
   any LSTM**. `BLSTM`/`LocalState` only appear inside `DConv` when
   `lstm=True`/`attn=True` are passed — and HTDemucs's `dconv_kw`
   passes only `depth`, `compress`, `init`, `gelu_act`. So in the
   HTDemucs forward graph these layers are never built. (The "DConv
   variants with cross-domain attention" referred to in the spec are
   really the `LocalState` head used by `HDemucs`, not the
   `CrossTransformerEncoder` in `HTDemucs`.)

2. **The "cross-domain attention" in HTDemucs is the
   `CrossTransformerEncoder`** (two parallel transformer stacks with
   alternating self-attn and cross-attn between the spectral branch
   and the time branch). It uses the standard `nn.MultiHeadAttention`
   primitive on both sides — no custom layer. mlx-swift exposes
   `MultiHeadAttention` directly.

Net: the actual Phase 0 risk is **weight-name mapping and numerical
parity**, not missing primitives.

## Phase 0 plan (revised)

The original spec's "1 day of work" for Phase 0 is realistic
**conditional on** the safetensors weight-name mapping being
straightforward. The plan now is:

1. **(Done — this doc)** Inventory mlx primitives + mlx-swift coverage.
2. **(Done)** Scaffold Swift package skeleton.
3. **Export weights .th → .safetensors.** Use a small Python script
   that loads the htdemucs `.th` checkpoint via `demucs.api`, walks
   the state-dict, and writes `safetensors` with names that mirror the
   Swift module hierarchy. This is the riskiest part — the
   `demucs_mlx` Python wrapper does its own parameter renaming via
   `MLXStateDictMixin` (`mlx_utils.py`) that we'll need to either
   replicate in Swift or re-apply before export.
4. **Port `HTDemucs.__call__`.** Mechanically translate
   `mlx_htdemucs.py` + dependencies to Swift, replacing `FusedGroupNormGELU`/
   `FusedGroupNormGLU` with unfused `GroupNorm + gelu` /
   `GroupNorm + glu` (perf optimization, not required for parity).
5. **Port STFT/iSTFT** (`spec_mlx.py` depends on the third-party
   `mlx_spectro` package). Hand-roll the framed STFT + overlap-add
   iSTFT on top of `MLXFFT.rfft`/`irfft` with Hann window,
   `periodic=true`, `center=true`. ~150 LOC.
6. **Parity test.** Run both Python sidecar and Swift probe on the
   same input wav; diff per-stem RMS. Acceptance: < 1e-3.

## Custom Metal kernels — deferred

`demucs_mlx` ships custom Metal kernels (`FusedGroupNormGELU`,
`FusedGroupNormGLU`) in `metal_kernels.py` as fused-norm-activation
optimizations. mlx-swift supports custom Metal kernels too, but the
Phase 0 probe will use **unfused** versions (`GroupNorm` then
`gelu`/`glu` as separate ops). That costs us some throughput vs the
Python reference but doesn't affect parity. Re-fusing is a perf
exercise for Phase 2 if numbers come in below the Python sidecar's
~6× realtime on M1 Pro.

## Files in this probe package

```
HTDemucsSwiftProbe/
├── Package.swift                # SPM, depends on mlx-swift
├── PROBE_NOTES.md               # this file
├── Sources/
│   ├── HTDemucsSwift/           # library — model + STFT + weight loader
│   └── ProbeCLI/                # executable — runs the parity test
└── tools/
    └── export_weights.py        # Python: .th → .safetensors w/ Swift-friendly names
```
