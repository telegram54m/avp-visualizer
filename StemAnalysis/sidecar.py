#!/usr/bin/env python3
"""
Long-lived stem-separation + feature-extraction sidecar.

Loaded by the Swift app once at startup; lives for the app session.
Communicates over stdin/stdout via newline-delimited JSON ("ndjson"):

  ---  Swift writes a request to stdin (one JSON object per line):  ---
      {"action": "ping", "request_id": 1}
      {"action": "separate", "request_id": 2, "path": "/abs/path/song.m4a"}
      {"action": "quit"}

  ---  Sidecar writes responses to stdout (one JSON object per line): ---
      First line on launch:
          {"status": "ready", "model": "htdemucs", "frame_rate": 30, ...}
      Per request:
          {"status": "ok", "request_id": N, "result": {...}}
      Per error:
          {"status": "error", "request_id": N, "error": "...", "trace": "..."}

Stderr is reserved for log lines that Swift can mirror to os_log if
useful — these are NOT part of the protocol.

Performance baseline (M1 Pro, htdemucs warm): ~6× realtime on a
3-4 minute song → 30-60s per song after model is loaded.
"""

from __future__ import annotations

import base64
import gzip
import json
import os
import queue
import sqlite3
import struct
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any

import numpy as np


# Lower process priority so the sidecar's heavy MLX inference (~60s of
# burned CPU + GPU for a fresh htdemucs run) loses scheduling
# contention against audio threads. The Swift side ALSO sets
# Process.qualityOfService = .utility — this nice() is redundant on
# modern macOS where QoS dominates, but cheap insurance.
try:
    os.nice(10)
except (OSError, AttributeError):
    pass


# ---------------------------------------------------------------------------
# Concurrency primitives — see "Stdin reader thread" near main() for the
# threading model. tl;dr: a daemon thread reads stdin so the main thread
# can be busy in `action_separate` for ~60s while still observing an
# `abandon` request. _emit_lock serializes stdout writes between the
# main thread (progress events, final result) and the reader thread
# (abandon ack).
# ---------------------------------------------------------------------------
_line_queue: queue.Queue[str] = queue.Queue()
_cancel_event = threading.Event()
_emit_lock = threading.Lock()


class _CancelledError(Exception):
    """Raised from within `_separate_throttled` when `_cancel_event`
    fires between chunks. Caught in `action_separate` so we return a
    tagged-abandoned result instead of propagating an error."""


# ---------------------------------------------------------------------------
# Protocol version — bumped when the on-wire schema or features change in a
# way that invalidates cached blobs. The cache row's `protocol_version`
# column is checked on lookup; rows with mismatched versions are ignored
# (and replaced if re-computed). Bump when:
#   • feature derivation changes (e.g., chroma bin allocation)
#   • a new feature is added or removed
#   • frame_rate changes
#   • on-disk / wire encoding of the feature payload changes
# Do NOT bump for purely additive optional fields the Swift side can
# safely ignore (e.g., new debug fields in `timing`).
#
# v2 (2026-05-26): switched feature payload from nested JSON arrays to a
# packed binary blob (see _pack_features_binary). Eliminates the
# ~700ms JSON ser/deser tax on cache hits and shrinks per-song storage
# by ~3-4×. JSON-array results from v1 are no longer produced.
#
# v3 (2026-05-26 same day): chunked separation now accumulates raw stem
# audio across chunks and derives librosa features ONCE per stem on the
# concatenated full audio. v2 derived per-chunk and concatenated frame
# arrays, but librosa's default center=True padded each 8-sec chunk by
# n_fft/2 on each side — emitting ~241 frames per chunk instead of 240,
# accumulating a ~1.5-sec time-base skew over a 3-min song that
# manifested as drums firing visually ahead of the audio. v3 stem rows
# have correct frame counts matching song_duration * 30.
# ---------------------------------------------------------------------------
PROTOCOL_VERSION = 3

# Binary blob layout (v2):
#
#   Header (8 bytes):
#     0..3   "HVSF" magic           uint8[4]
#     4      version                uint8   (=2)
#     5      chroma_bins            uint8   (=12)
#     6..7   reserved (0)           uint8[2]
#
#   Per-stem section, repeated. The number of stems is implied by the
#   `stems_meta` list in the JSON envelope (sidecar emits them in a
#   stable order matching the htdemucs source list).
#     0..3       name_length        uint32 LE
#     4..        name (UTF-8)       uint8[name_length]
#                n_frames           uint32 LE
#                chromagram         float32 LE [n_frames * chroma_bins], row-major
#                loudness           float32 LE [n_frames]
#                onset              uint8[ceil(n_frames / 8)], LSB-first within byte
#
# Each Float32 array is laid out contiguously little-endian; Swift can
# `withUnsafeBytes` into [Float] directly on Apple silicon since the
# host byte order matches.
_HVSF_MAGIC = b"HVSF"
_HVSF_BIN_VERSION = 2
_HVSF_CHROMA_BINS = 12


# ---------------------------------------------------------------------------
# Logging helpers — everything goes to stderr to keep stdout clean for
# protocol JSON. Swift can pipe stderr to os_log for visibility.
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    sys.stderr.write(f"[sidecar] {msg}\n")
    sys.stderr.flush()


def emit(payload: dict[str, Any]) -> None:
    """Write one ndjson line to stdout and flush. The flush is critical —
    Swift's Process reading via FileHandle blocks until newline-terminated
    data arrives, and without flushing Python buffers stdout when it's
    not a tty.

    Thread-safe: the stdin reader thread (which emits `abandon` acks)
    and the main thread (which emits progress + final results) BOTH
    call this, and we don't want their bytes interleaved mid-line.
    """
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with _emit_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# Feature extraction (per stem, 30 fps timeline matching FeatureFrame rate)
# ---------------------------------------------------------------------------

FRAME_RATE = 30  # frames per second — matches AudioAnalysis FeatureFrame cadence


def derive_features(stem_np: np.ndarray, sr: int) -> dict[str, Any]:
    """Compute chromagram[12], loudness, onset for a stem at 30 fps.

    Input shape: (samples, channels) float32. Mixed to mono for analysis
    via channel mean (separation models output stereo even for sources
    that are mono-centered).

    Output: dict with parallel arrays of length n_frames.
      • chromagram: list[list[float]] — [n_frames][12], max-bin normalized
      • loudness:   list[float]       — RMS per frame, 0..~1
      • onset:      list[bool]        — peak-picked spectral-flux onsets
    """
    import librosa

    if stem_np.ndim == 2:
        mono = stem_np.mean(axis=-1)
    else:
        mono = stem_np
    mono = np.ascontiguousarray(mono.astype(np.float32))

    # Hop size = sr / FRAME_RATE → emits one feature frame every 1/30 sec.
    hop = sr // FRAME_RATE

    # Chromagram via STFT magnitudes binned to 12 pitch classes. n_fft 2048
    # is the librosa default; gives ~46ms window which is a reasonable
    # tradeoff between time and freq resolution for melodic content.
    chroma = librosa.feature.chroma_stft(
        y=mono, sr=sr, n_fft=2048, hop_length=hop
    ).T  # → (n_frames, 12)

    # Frame-aligned RMS loudness — square-window envelope at the same hop.
    rms = librosa.feature.rms(
        y=mono, frame_length=hop * 2, hop_length=hop, center=True
    )[0]  # → (n_frames,)

    # Onset envelope + peak-picked discrete onset frames. We use librosa's
    # default onset_detect which uses spectral flux + a moving-mean
    # threshold. Returns frame indices; convert to a boolean per frame.
    onset_frames = librosa.onset.onset_detect(
        y=mono, sr=sr, hop_length=hop, units="frames"
    )
    n_frames = chroma.shape[0]
    onset_bool = np.zeros(n_frames, dtype=bool)
    valid = onset_frames[(onset_frames >= 0) & (onset_frames < n_frames)]
    onset_bool[valid] = True

    # Truncate to the minimum length (librosa's three outputs occasionally
    # differ by 1 frame at the tail due to centering choices).
    n = min(chroma.shape[0], rms.shape[0], onset_bool.shape[0])
    chroma = chroma[:n]
    rms = rms[:n]
    onset_bool = onset_bool[:n]

    # Max-bin normalize each chromagram frame so the dominant pitch is
    # always at 1.0 — same convention DodecahedronVisualizer uses for the
    # full-mix chromagram. Avoid divide-by-zero on silent frames.
    chroma_max = np.maximum(chroma.max(axis=1, keepdims=True), 1e-6)
    chroma_normalized = chroma / chroma_max

    # Return numpy arrays (not lists) so the binary packer doesn't have
    # to re-allocate. Caller treats these as opaque per-stem dicts and
    # eventually feeds them to `_pack_features_binary` which expects
    # numpy-typed values. (Pre-v2 callers used .tolist() here.)
    return {
        "chromagram": chroma_normalized.astype(np.float32),
        "loudness": rms.astype(np.float32),
        "onset": onset_bool,
        "n_frames": int(n),
    }


# ---------------------------------------------------------------------------
# Binary feature packing (v2 wire + storage format)
# ---------------------------------------------------------------------------

def _pack_features_binary(out_stems: dict[str, Any]) -> tuple[bytes, list[dict[str, Any]]]:
    """Pack the per-stem features into one contiguous binary blob.

    Returns `(blob_bytes, stems_meta)`:
      • `blob_bytes`: the full packed binary per the layout near the
        PROTOCOL_VERSION comment.
      • `stems_meta`: ordered list of `{name, n_frames}` dicts so the
        Swift side knows how to slice the blob without re-parsing it.

    Order of stems in the blob matches the order of `out_stems.items()`.
    htdemucs's source list is stable across runs (drums/bass/other/vocals
    for default htdemucs), so this gives a predictable byte layout.
    """
    chunks: list[bytes] = [
        _HVSF_MAGIC,
        struct.pack("<BBBB", _HVSF_BIN_VERSION, _HVSF_CHROMA_BINS, 0, 0),
    ]
    stems_meta: list[dict[str, Any]] = []
    for name, feat in out_stems.items():
        name_bytes = name.encode("utf-8")
        n_frames = int(feat["n_frames"])
        # Coerce — if the source was lists (e.g. accumulated chunk-by-
        # chunk by _separate_throttled), convert once here.
        chroma = np.asarray(feat["chromagram"], dtype=np.float32)
        if chroma.ndim == 1:
            chroma = chroma.reshape(n_frames, _HVSF_CHROMA_BINS)
        chroma = np.ascontiguousarray(
            chroma[:n_frames, :_HVSF_CHROMA_BINS], dtype=np.float32)
        loud = np.ascontiguousarray(
            np.asarray(feat["loudness"], dtype=np.float32)[:n_frames])
        onset_bool = np.asarray(feat["onset"], dtype=bool)[:n_frames]
        # LSB-first within each byte so frame N is bit (N % 8) of byte
        # (N // 8) — matches what Swift's unpacker will read.
        onset_packed = np.packbits(onset_bool, bitorder="little")

        chunks.append(struct.pack("<I", len(name_bytes)))
        chunks.append(name_bytes)
        chunks.append(struct.pack("<I", n_frames))
        chunks.append(chroma.tobytes(order="C"))
        chunks.append(loud.tobytes(order="C"))
        chunks.append(onset_packed.tobytes(order="C"))

        stems_meta.append({"name": name, "n_frames": n_frames})

    return b"".join(chunks), stems_meta


# ---------------------------------------------------------------------------
# SQLite cache (keyed by caller-provided cache_key, usually Shazam ID)
# ---------------------------------------------------------------------------

_CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS stem_features (
    cache_key TEXT PRIMARY KEY,
    model TEXT NOT NULL,
    protocol_version INTEGER NOT NULL,
    duration_seconds REAL,
    title TEXT,
    artist TEXT,
    created_at INTEGER NOT NULL,
    features_blob BLOB NOT NULL,
    stems_meta TEXT
);
CREATE INDEX IF NOT EXISTS idx_artist_title ON stem_features(artist, title);
"""

# In-place schema migration: v1 omitted the stems_meta column. ALTER
# TABLE to add it; existing rows get NULL. They're v1 protocol anyway,
# so the version check in cache_lookup will skip them on read and the
# next compute will write a fresh v2 row with stems_meta populated.
_CACHE_MIGRATIONS = [
    "ALTER TABLE stem_features ADD COLUMN stems_meta TEXT",
]


def _cache_path() -> Path:
    """Cache location resolution, in priority order:
      1. STEM_CACHE_PATH env var (full file path)
      2. XDG_CACHE_HOME/HighVidelity/stem_features.sqlite
      3. ~/Library/Caches/HighVidelity/stem_features.sqlite  (macOS standard)
      4. <script_dir>/cache/stem_features.sqlite             (dev fallback)
    """
    explicit = os.environ.get("STEM_CACHE_PATH")
    if explicit:
        return Path(explicit)
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return Path(xdg) / "HighVidelity" / "stem_features.sqlite"
    home = Path.home()
    if (home / "Library" / "Caches").is_dir():
        return home / "Library" / "Caches" / "HighVidelity" / "stem_features.sqlite"
    return Path(__file__).resolve().parent / "cache" / "stem_features.sqlite"


_cache_conn: sqlite3.Connection | None = None


def _ensure_cache() -> sqlite3.Connection:
    global _cache_conn
    if _cache_conn is None:
        path = _cache_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        log(f"opening cache at {path}")
        # check_same_thread=False because we may read on the reader's
        # thread and write on the main thread eventually. For now all
        # access is single-threaded; the flag is cheap insurance.
        _cache_conn = sqlite3.connect(str(path), check_same_thread=False)
        _cache_conn.executescript(_CACHE_SCHEMA)
        for stmt in _CACHE_MIGRATIONS:
            try:
                _cache_conn.execute(stmt)
            except sqlite3.OperationalError:
                # Column already exists — fine, idempotent.
                pass
        _cache_conn.commit()
    return _cache_conn


def cache_lookup(cache_key: str, model: str) -> dict[str, Any] | None:
    """Return a result envelope (binary features, base64-encoded) if
    present + valid for this model and protocol version, else None.
    Caller is the only one who knows what cache_key to use — we treat
    it as an opaque string.

    The returned envelope matches the shape produced by `action_separate`
    on a fresh compute: `stems_meta` + `features_b64` + metadata. This
    way the Swift side decodes cache hits and fresh results with the
    exact same code path.
    """
    if not cache_key:
        return None
    conn = _ensure_cache()
    row = conn.execute(
        "SELECT features_blob, model, protocol_version, duration_seconds, "
        "title, artist, created_at, stems_meta FROM stem_features WHERE cache_key = ?",
        (cache_key,),
    ).fetchone()
    if row is None:
        return None
    blob, row_model, row_proto, duration, title, artist, created_at, stems_meta_json = row
    if row_model != model:
        return None  # different model — re-compute on demand
    if row_proto != PROTOCOL_VERSION:
        return None  # incompatible features — re-compute
    if not stems_meta_json:
        # v2-protocol row without stems_meta (shouldn't normally happen
        # — both are written together — but be defensive).
        return None
    try:
        features_blob = gzip.decompress(blob)
        stems_meta = json.loads(stems_meta_json)
    except Exception as e:
        log(f"cache row corrupt for {cache_key!r}: {e}")
        return None
    envelope: dict[str, Any] = {
        "model": row_model,
        "sample_rate": 44100,  # htdemucs is fixed at 44.1k; not stored per-row
        "frame_rate": FRAME_RATE,
        "duration_seconds": duration,
        "stems_meta": stems_meta,
        "features_b64": base64.b64encode(features_blob).decode("ascii"),
        "from_cache": True,
        "cache_created_at": created_at,
    }
    if title is not None:
        envelope["title"] = title
    if artist is not None:
        envelope["artist"] = artist
    return envelope


def cache_write_binary(
    cache_key: str,
    *,
    features_blob: bytes,
    stems_meta: list[dict[str, Any]],
    model: str,
    duration_seconds: float | None = None,
    title: str | None = None,
    artist: str | None = None,
) -> None:
    """Persist the packed-binary features under the given cache_key.
    The blob is gzipped binary (NOT gzipped JSON anymore — see v2
    notes near PROTOCOL_VERSION). Sub-300KB after compression for a
    typical 3-4 min song × 4 stems."""
    if not cache_key:
        return
    conn = _ensure_cache()
    blob = gzip.compress(features_blob, compresslevel=6)
    conn.execute(
        "INSERT OR REPLACE INTO stem_features "
        "(cache_key, model, protocol_version, duration_seconds, title, artist, "
        " created_at, features_blob, stems_meta) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            cache_key,
            model,
            PROTOCOL_VERSION,
            duration_seconds,
            title,
            artist,
            int(time.time()),
            blob,
            json.dumps(stems_meta, separators=(",", ":")),
        ),
    )
    conn.commit()
    log(f"cache stored {cache_key!r} ({len(blob)/1024:.1f} KB compressed, binary)")


def cache_alias(primary_key: str, alias_key: str) -> dict[str, Any]:
    """Make `alias_key` point at the same cached features `primary_key`
    already holds. Useful when we cached a song under
    `musicapp-pid-<id>` first and Shazam later identifies it — adding a
    `shazam-<id>` alias means the next play (any device, any library)
    finds the row by Shazam ID without re-computing.

    Implementation: INSERT OR REPLACE the alias row with a copy of the
    primary row's blob + metadata. Storage cost is ~300KB per duplicate
    (gzip JSON of feature timelines); cheap given typical cache sizes.
    Could be optimized to a separate `aliases` table later if it ever
    matters.

    Returns `{aliased: bool, reason?: str}` so the Swift caller can
    distinguish "primary not found" from "already aliased identically"
    from "newly aliased".
    """
    if not primary_key or not alias_key:
        return {"aliased": False, "reason": "empty key"}
    if primary_key == alias_key:
        return {"aliased": False, "reason": "primary == alias"}
    conn = _ensure_cache()
    row = conn.execute(
        "SELECT model, protocol_version, duration_seconds, title, artist, "
        "created_at, features_blob, stems_meta FROM stem_features WHERE cache_key = ?",
        (primary_key,),
    ).fetchone()
    if row is None:
        return {"aliased": False, "reason": "primary not found"}
    model, proto, duration, title, artist, created_at, blob, stems_meta_json = row
    # Skip the write if the alias already holds an identical row — saves
    # a redundant 300KB SQLite write on every Shazam re-fire for the same
    # song.
    existing = conn.execute(
        "SELECT model, protocol_version FROM stem_features WHERE cache_key = ?",
        (alias_key,),
    ).fetchone()
    if existing is not None and existing[0] == model and existing[1] == proto:
        return {"aliased": False, "reason": "alias already exists"}
    conn.execute(
        "INSERT OR REPLACE INTO stem_features "
        "(cache_key, model, protocol_version, duration_seconds, title, artist, "
        " created_at, features_blob, stems_meta) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (alias_key, model, proto, duration, title, artist, created_at, blob, stems_meta_json),
    )
    conn.commit()
    log(f"cache alias {alias_key!r} → {primary_key!r}")
    return {"aliased": True}


def cache_stats() -> dict[str, Any]:
    conn = _ensure_cache()
    row = conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(LENGTH(features_blob)), 0) FROM stem_features"
    ).fetchone()
    n_rows, total_bytes = row
    return {
        "entries": int(n_rows),
        "size_bytes": int(total_bytes),
        "cache_path": str(_cache_path()),
        "protocol_version": PROTOCOL_VERSION,
    }


# ---------------------------------------------------------------------------
# Action handlers
# ---------------------------------------------------------------------------

# Lazy globals — populated on first use so `ping` works even before the
# model is loaded.
_separator = None


def _ensure_separator(model: str = "htdemucs"):
    global _separator
    if _separator is None or getattr(_separator, "_model_name", None) != model:
        from demucs_mlx import Separator

        log(f"loading model '{model}' …")
        t0 = time.monotonic()
        _separator = Separator(model=model, progress=False)
        _separator._model_name = model  # type: ignore[attr-defined]
        log(f"model loaded in {time.monotonic() - t0:.2f}s")
    return _separator


def action_ping(req: dict[str, Any]) -> dict[str, Any]:
    return {"pong": True}


def _separate_throttled(
    sep,
    path: str,
    throttle_ms: int,
    chunk_sec: float = 8.0,
    *,
    cancel_event: threading.Event | None = None,
    request_id: int | None = None,
) -> tuple[dict[str, Any], float, float, float]:
    """Chunked separation that yields GPU/CPU between chunks.

    Returns `(stems_features, duration_seconds, sep_elapsed, feat_elapsed)`.

    Why chunk instead of letting `separate_audio_file` run end-to-end:
    MLX inference saturates Metal for whatever 30-60s it takes. On M1
    Pro that contends with audio threads enough to glitch playback
    (Music.app audio popping, visualizer animation hitching). MLX has
    no GPU-usage knob, so the only yield mechanism is to break the
    work into small chunks and `time.sleep()` between them.

    For VISUALIZATION purposes (feature timelines, not playback) the
    boundary artifacts from chunk-local separation are negligible —
    chromagram + onset + loudness are computed per-frame locally,
    so chunks don't need cross-overlap to produce coherent features.

    Default chunk_sec=8s means roughly one model `segment` per chunk
    (htdemucs trains on 7.8s windows), so each chunk is a single
    forward pass — clean yield points, ~500ms compute + 500ms sleep.
    """
    import mlx_audio_io as mac
    import mlx.core as mx

    sr = sep.samplerate
    # Load + transpose once. mac.load gives (samples, channels).
    audio_mx, _ = mac.load(path, sr=sr, dtype="float32")
    audio_mx = mx.transpose(audio_mx, (1, 0))  # → (channels, samples)
    n_samples = audio_mx.shape[-1]
    duration_seconds = n_samples / sr
    chunk_samples = int(chunk_sec * sr)
    n_chunks = (n_samples + chunk_samples - 1) // chunk_samples

    log(f"throttled separation: {n_chunks} chunks of {chunk_sec}s, "
        f"sleeping {throttle_ms}ms between")

    stem_names = list(sep._model.sources)
    # v3 (2026-05-26): per-stem AUDIO accumulator. Earlier (v2 and prior)
    # we derived librosa features PER CHUNK and concatenated the
    # resulting frame arrays — but librosa's default `center=True` pads
    # each chunk by n_fft/2 on each side, so each 8-second chunk emits
    # ~241 frames instead of 240. Across ~44 chunks of a 3-minute song
    # that accumulates to a ~1.5-second time-base skew between stem
    # frames and mix frames — measurable as the "drums one measure
    # ahead" misalignment Jesse caught on the Supertramp track.
    #
    # v3 fixes this by collecting raw stem audio (one numpy array per
    # stem accumulating across chunks), then running derive_features
    # ONCE per stem on the concatenated full audio after all chunks
    # are separated. librosa now sees the whole song so its padding is
    # only at the song boundaries, not at every chunk boundary.
    #
    # Memory cost: ~4 stems × song_duration × sample_rate × 4 bytes
    # (mono float32 after mixdown) ≈ 250 MB for a 3-minute song.
    # Comfortable on M1 Pro.
    audio_accum: dict[str, list] = {name: [] for name in stem_names}

    total_sep_elapsed = 0.0

    for i in range(n_chunks):
        # ---- Cancellation check (before doing any work for this chunk)
        # The reader thread sets `cancel_event` as soon as an `abandon`
        # message arrives on stdin, even though the main thread is busy
        # in this loop. Raising here means action_separate catches
        # _CancelledError and the main loop emits an abandoned result.
        if cancel_event is not None and cancel_event.is_set():
            log(f"separation abandoned at chunk {i}/{n_chunks}")
            raise _CancelledError(f"abandoned at chunk {i}/{n_chunks}")

        pos = i * chunk_samples
        end = min(pos + chunk_samples, n_samples)
        chunk_mx = audio_mx[..., pos:end]

        # 1. Separate this chunk
        t0 = time.monotonic()
        _, stems = sep.separate_tensor(chunk_mx, return_mx=True)
        # Force evaluation here so GPU work completes inside the timed
        # window — without it MLX may defer to the next access and our
        # sleep would interleave with still-running kernels.
        for s in stems.values():
            mx.eval(s)
        total_sep_elapsed += time.monotonic() - t0

        # 2. Accumulate stem AUDIO for this chunk (v3). No feature
        #    derivation per chunk anymore — that happens once after
        #    all separation is done, on the concatenated full audio.
        for name in stem_names:
            stem_np = np.asarray(stems[name]).astype(np.float32)
            if stem_np.ndim == 2 and stem_np.shape[0] < stem_np.shape[1]:
                stem_np = stem_np.T  # → (samples, channels)
            audio_accum[name].append(stem_np)

        # 3a. Progress event — non-terminal envelope. The Swift client
        # recognizes `status: "progress"` as informational (doesn't
        # resolve the pending continuation, just invokes the
        # onProgress callback). Reserve the final 10% for the
        # post-separation feature extraction phase below — chunks 0..n-1
        # map to [0, 0.9], leaving 0.9..1.0 for derive_features.
        if request_id is not None:
            emit({
                "status": "progress",
                "request_id": request_id,
                "result": {
                    "fraction": round((i + 1) / n_chunks * 0.9, 4),
                    "chunk": i + 1,
                    "total_chunks": n_chunks,
                },
            })

        # 3b. Yield. Last chunk doesn't need the sleep.
        if throttle_ms > 0 and i < n_chunks - 1:
            time.sleep(throttle_ms / 1000.0)

    # Derive features ONCE per stem on the concatenated full audio.
    # This is the heart of the v3 fix — librosa sees the whole song,
    # so per-chunk padding artifacts can't accumulate.
    t0 = time.monotonic()
    out_stems: dict[str, Any] = {}
    for name in stem_names:
        full_audio = np.concatenate(audio_accum[name], axis=0)
        out_stems[name] = derive_features(full_audio, sr)
    feat_elapsed = time.monotonic() - t0

    # Emit a final progress event so the UI bar lands at 100% even
    # for cache-write tails that follow.
    if request_id is not None:
        emit({
            "status": "progress",
            "request_id": request_id,
            "result": {"fraction": 1.0, "chunk": n_chunks, "total_chunks": n_chunks},
        })

    return out_stems, duration_seconds, total_sep_elapsed, feat_elapsed


def action_separate(req: dict[str, Any]) -> dict[str, Any]:
    path = req["path"]
    model = req.get("model", "htdemucs")
    cache_key = req.get("cache_key", "")  # opaque string, often Shazam ID
    force_refresh = bool(req.get("force_refresh", False))
    throttle_ms = int(req.get("throttle_ms", 0))
    request_id = req.get("request_id")

    # ---- Cache check (fast path) -----------------------------------------
    if cache_key and not force_refresh:
        cached = cache_lookup(cache_key, model)
        if cached is not None:
            log(f"cache HIT for {cache_key!r}")
            cached["timing"] = {
                "separation_seconds": 0.0,
                "feature_seconds": 0.0,
                "cache_lookup_seconds": 0.0,  # caller can fill if desired
            }
            return cached

    # ---- Cache miss → real separation + feature derivation ---------------
    sep = _ensure_separator(model)

    if throttle_ms > 0:
        log(f"separating (throttled, {throttle_ms}ms): {path}")
        # Pass cancel_event + request_id so the throttled loop can
        # bail on abandon AND emit progress envelopes per chunk.
        out_stems, duration_seconds, sep_elapsed, feat_elapsed = \
            _separate_throttled(
                sep, path,
                throttle_ms=throttle_ms,
                cancel_event=_cancel_event,
                request_id=request_id,
            )
        log(f"throttled separation done in {sep_elapsed:.2f}s "
            f"(+{feat_elapsed:.2f}s features)")
    else:
        log(f"separating (fast): {path}")
        t0 = time.monotonic()
        _, stems_dict = sep.separate_audio_file(path, return_mx=True)
        sep_elapsed = time.monotonic() - t0
        log(f"separation done in {sep_elapsed:.2f}s")

        t0 = time.monotonic()
        out_stems = {}
        duration_seconds = 0.0
        for name, stem in stems_dict.items():
            stem_np = np.asarray(stem).astype(np.float32)
            # MLX layout is (channels, samples); rotate to (samples, channels).
            if stem_np.ndim == 2 and stem_np.shape[0] < stem_np.shape[1]:
                stem_np = stem_np.T
            out_stems[name] = derive_features(stem_np, sep.samplerate)
            # All stems share the same length → just remember one.
            if duration_seconds == 0.0:
                duration_seconds = stem_np.shape[0] / sep.samplerate
        feat_elapsed = time.monotonic() - t0
        log(f"features extracted in {feat_elapsed:.2f}s")

    # Pack features into a single binary blob (v2 wire format). Per-stem
    # metadata (name, n_frames) goes alongside in the JSON envelope so
    # the Swift unpacker knows the blob layout without re-parsing it.
    features_blob, stems_meta = _pack_features_binary(out_stems)

    result = {
        "model": model,
        "sample_rate": sep.samplerate,
        "frame_rate": FRAME_RATE,
        "duration_seconds": round(duration_seconds, 3),
        "stems_meta": stems_meta,
        "features_b64": base64.b64encode(features_blob).decode("ascii"),
        "from_cache": False,
        "timing": {
            "separation_seconds": round(sep_elapsed, 3),
            "feature_seconds": round(feat_elapsed, 3),
            "throttle_ms": throttle_ms,
        },
    }

    # ---- Cache write (only on fresh results) -----------------------------
    # SQLite blob now stores the gzipped BINARY directly (not JSON-with-
    # arrays). On cache hits the lookup path gunzips, base64-encodes,
    # and ships the same envelope shape — Swift can't tell fresh from
    # cached at the wire level (modulo `from_cache: true`).
    if cache_key:
        try:
            cache_write_binary(
                cache_key,
                features_blob=features_blob,
                stems_meta=stems_meta,
                model=model,
                duration_seconds=duration_seconds,
                title=req.get("title"),
                artist=req.get("artist"),
            )
        except Exception as e:
            # Don't fail the request just because cache write failed.
            log(f"cache write failed for {cache_key!r}: {e}")

    return result


def action_cache_stats(req: dict[str, Any]) -> dict[str, Any]:
    return cache_stats()


def action_cache_alias(req: dict[str, Any]) -> dict[str, Any]:
    primary = req.get("primary_key", "")
    alias = req.get("alias_key", "")
    return cache_alias(primary, alias)


def action_cache_clear_all(req: dict[str, Any]) -> dict[str, Any]:
    """Wipe ALL rows from the stem-features SQLite cache. Used by the
    Swift side when the user explicitly asks to clear the cache (e.g.,
    a debug menu / settings button). Returns `{cleared, rows_deleted}`.

    Does NOT delete the SQLite file itself — just empties the table.
    Cloud-side rows (CloudKit public DB) are untouched; this is local
    cleanup only."""
    conn = _ensure_cache()
    cur = conn.execute("SELECT COUNT(*) FROM stem_features")
    rows = int(cur.fetchone()[0])
    conn.execute("DELETE FROM stem_features")
    conn.commit()
    # VACUUM reclaims the disk space immediately. Can't run inside a
    # transaction — `commit()` above closed the DELETE's implicit
    # transaction. Failures here are non-fatal; SQLite auto-reuses
    # freed pages on next inserts even without explicit VACUUM.
    try:
        conn.execute("VACUUM")
    except Exception as e:
        log(f"VACUUM failed (non-fatal): {e}")
    log(f"cache cleared: {rows} rows deleted")
    return {"cleared": True, "rows_deleted": rows}


def action_cache_lookup_only(req: dict[str, Any]) -> dict[str, Any]:
    """Read-only cache lookup — returns the envelope if cached and
    valid, or `{hit: false}` otherwise. Used by the Swift side to
    decide whether to skip Demucs in favor of the CloudKit public-DB
    shared cache before paying full compute cost.

    Adds the same `timing: {0, 0, 0}` placeholder as the action_separate
    cache-hit path. Without it the Swift `StemSeparationResult.init(from:)`
    throws on the missing `timing` key (non-optional decode), `try?`
    swallows the error, and the caller sees a phantom cache miss even
    though the row exists. Burnt-in by a Supertramp `Goodbye Stranger`
    repro that had a valid hash-keyed v2 row that lookups kept missing."""
    cache_key = req.get("cache_key", "")
    model = req.get("model", "htdemucs")
    cached = cache_lookup(cache_key, model)
    if cached is None:
        return {"hit": False}
    cached["timing"] = {
        "separation_seconds": 0.0,
        "feature_seconds": 0.0,
        "cache_lookup_seconds": 0.0,
    }
    return {"hit": True, "envelope": cached}


def action_cache_find_by_metadata(req: dict[str, Any]) -> dict[str, Any]:
    """Case-insensitive exact match on (title, artist). Used when AM
    playback identifies a song via Shazam but the cache has no
    shazam-keyed row — the song may still be in cache under a
    different key shape (typically `hash-<sha256>` when an earlier
    `LibraryBatchCacher` scan couldn't Shazam-ID the file at scan
    time, or `musicapp-pid-<id>` for Music.app-tagged rows from
    before the shazam-first migration).

    Returns the most-recently-created matching key so the caller can
    alias it to `shazam-<id>` for instant lookups next time. Falls
    back to {found: false} when no metadata is unique enough.
    Requires both fields non-empty — single-field matching would
    false-positive on common titles (e.g. "Intro").
    """
    title = (req.get("title") or "").strip()
    artist = (req.get("artist") or "").strip()
    model = req.get("model", "htdemucs")
    if not title or not artist:
        return {"found": False}
    conn = _ensure_cache()
    row = conn.execute(
        "SELECT cache_key FROM stem_features "
        "WHERE LOWER(title) = LOWER(?) AND LOWER(artist) = LOWER(?) "
        "AND model = ? "
        "ORDER BY created_at DESC LIMIT 1",
        (title, artist, model),
    ).fetchone()
    if row is None:
        return {"found": False}
    return {"found": True, "cache_key": row[0]}


def action_cache_audit(req: dict[str, Any]) -> dict[str, Any]:
    """Return one row per cache_key with the metadata + payload-shape
    signature the Swift auditor needs to detect corrupted alias rows.

    Per-row fields:
      • cache_key, model, title, artist, duration_seconds, created_at
      • file_size_bytes  — LENGTH(features_blob), i.e. the compressed
        size on disk. A good proxy for "do these rows hold the same
        underlying audio"; combined with n_frames it's a tight
        signature.
      • n_frames  — extracted from stems_meta JSON (max across stems;
        all stems in a row share the song duration so this is also
        just one stem's value). 0 when stems_meta is NULL (v1 rows).
      • protocol_version  — so the Swift side can dim v1 rows in the UI
        (they'll be recomputed on next play; deletion is harmless).

    This is intentionally read-only and cheap; the row body
    (features_blob) is NOT returned — that'd be MBs per row × hundreds
    of rows.
    """
    conn = _ensure_cache()
    rows: list[dict[str, Any]] = []
    for row in conn.execute(
        "SELECT cache_key, model, protocol_version, duration_seconds, "
        "title, artist, created_at, LENGTH(features_blob), stems_meta "
        "FROM stem_features ORDER BY created_at DESC"
    ):
        (
            cache_key, model, proto, duration, title, artist,
            created_at, file_size, stems_meta_json,
        ) = row
        n_frames = 0
        if stems_meta_json:
            try:
                meta = json.loads(stems_meta_json)
                if isinstance(meta, list) and meta:
                    n_frames = max(
                        int(m.get("n_frames", 0)) for m in meta
                        if isinstance(m, dict)
                    )
            except Exception:
                n_frames = 0
        rows.append({
            "cache_key": cache_key,
            "model": model,
            "protocol_version": proto,
            "duration_seconds": duration,
            "title": title,
            "artist": artist,
            "created_at": created_at,
            "file_size_bytes": int(file_size or 0),
            "n_frames": n_frames,
        })
    return {"rows": rows}


def action_cache_delete(req: dict[str, Any]) -> dict[str, Any]:
    """Delete a single row by cache_key. Used by the "Verify stem
    cache" maintenance UI after the user reviews audit findings and
    chooses to remove a corrupted alias row.

    Returns `{deleted: bool, rows_deleted: int}`. `deleted=false` with
    `rows_deleted=0` means no row existed for the key (harmless — the
    UI may have already removed it in a previous run).
    """
    cache_key = req.get("cache_key", "")
    if not cache_key:
        return {"deleted": False, "rows_deleted": 0, "reason": "empty cache_key"}
    conn = _ensure_cache()
    cur = conn.execute(
        "DELETE FROM stem_features WHERE cache_key = ?", (cache_key,)
    )
    conn.commit()
    rows_deleted = cur.rowcount if cur.rowcount is not None else 0
    log(f"cache row deleted: {cache_key!r} ({rows_deleted} rows)")
    return {"deleted": rows_deleted > 0, "rows_deleted": int(rows_deleted)}


def action_cache_put_binary(req: dict[str, Any]) -> dict[str, Any]:
    """Insert pre-computed binary features into the local SQLite cache.
    Used when the Swift side fetches features from the CloudKit public
    DB (the shared cross-user cache) — we want them to persist locally
    too so subsequent offline plays of the same song are instant.

    Required fields: `cache_key`, `features_b64`, `stems_meta` (list),
    `model`. Optional: `duration_seconds`, `title`, `artist`."""
    cache_key = req.get("cache_key", "")
    b64 = req.get("features_b64", "")
    stems_meta = req.get("stems_meta") or []
    model = req.get("model", "htdemucs")
    if not cache_key or not b64:
        return {"stored": False, "reason": "missing cache_key or features_b64"}
    try:
        features_blob = base64.b64decode(b64)
    except Exception as e:
        return {"stored": False, "reason": f"base64 decode failed: {e}"}
    try:
        cache_write_binary(
            cache_key,
            features_blob=features_blob,
            stems_meta=stems_meta,
            model=model,
            duration_seconds=req.get("duration_seconds"),
            title=req.get("title"),
            artist=req.get("artist"),
        )
    except Exception as e:
        return {"stored": False, "reason": f"sqlite write failed: {e}"}
    return {"stored": True}


ACTIONS = {
    "ping": action_ping,
    "separate": action_separate,
    "cache_stats": action_cache_stats,
    "cache_alias": action_cache_alias,
    "cache_lookup_only": action_cache_lookup_only,
    "cache_put_binary": action_cache_put_binary,
    "cache_clear_all": action_cache_clear_all,
    "cache_find_by_metadata": action_cache_find_by_metadata,
    "cache_audit": action_cache_audit,
    "cache_delete": action_cache_delete,
}


# ---------------------------------------------------------------------------
# Stdin reader thread + main loop
# ---------------------------------------------------------------------------
#
# Why a thread?
#   The main thread is busy inside `action_separate` for ~5-60s during
#   a fresh compute. If we read stdin only between actions (the old
#   for-loop design), an `abandon` request sent during a separation
#   sits in the stdin buffer until separation finishes — making
#   abandon useless. By reading stdin on a background daemon thread
#   and pushing to a queue, the main thread keeps draining at its
#   own pace AND any `abandon` request gets observed immediately:
#   the reader thread sees it, sets `_cancel_event`, the throttled
#   separation loop notices between chunks, raises _CancelledError,
#   action_separate catches it, main loop emits an abandoned result.

def _stdin_reader() -> None:
    """Daemon thread: forward stdin lines into _line_queue. Special
    cases `abandon` to set the cancel event AND ack from this thread,
    so the abandon takes effect even while the main thread is busy."""
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue

        # Peek at the action — abandon is too time-sensitive to wait
        # for the main thread to drain the queue.
        try:
            peek = json.loads(line)
        except json.JSONDecodeError:
            _line_queue.put(line)  # let main thread emit the error
            continue

        if peek.get("action") == "abandon":
            _cancel_event.set()
            req_id = peek.get("request_id")
            log(f"abandon signaled from stdin reader (rid={req_id})")
            # Ack the abandon directly; safe because emit() takes the
            # _emit_lock that the main thread also respects.
            emit({
                "status": "ok",
                "request_id": req_id,
                "result": {"abandon_signaled": True},
            })
            continue

        _line_queue.put(line)
    # stdin closed → push sentinel so main loop can exit.
    _line_queue.put("")


def main() -> int:
    threading.Thread(target=_stdin_reader, name="stdin-reader",
                     daemon=True).start()

    emit({
        "status": "ready",
        "model": "htdemucs",
        "frame_rate": FRAME_RATE,
        "protocol_version": PROTOCOL_VERSION,
    })
    log("ready, awaiting requests on stdin")

    while True:
        line = _line_queue.get()
        if not line:
            log("stdin closed, exiting")
            return 0
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"status": "error", "error": f"invalid JSON: {e}"})
            continue

        action = req.get("action")
        req_id = req.get("request_id")

        if action == "quit":
            log("quit requested")
            emit({"status": "ok", "request_id": req_id, "result": {"bye": True}})
            return 0

        # abandon is already fully handled in the reader thread (sets
        # cancel event + acks). If one slips into the queue (because
        # the reader fell back on JSON-decode failure), drop it.
        if action == "abandon":
            continue

        handler = ACTIONS.get(action)
        if handler is None:
            emit({
                "status": "error",
                "request_id": req_id,
                "error": f"unknown action: {action!r}",
            })
            continue

        # Clear cancel event before any non-abandon action — abandon
        # targets the CURRENT request, not future ones, so we start
        # each new separation with a fresh signal slate.
        _cancel_event.clear()

        try:
            result = handler(req)
            emit({"status": "ok", "request_id": req_id, "result": result})
        except _CancelledError as e:
            log(f"action {action} abandoned: {e}")
            emit({
                "status": "ok",
                "request_id": req_id,
                "result": {"abandoned": True, "reason": str(e)},
            })
        except Exception as e:
            emit({
                "status": "error",
                "request_id": req_id,
                "error": f"{type(e).__name__}: {e}",
                "trace": traceback.format_exc(),
            })


if __name__ == "__main__":
    sys.exit(main())
