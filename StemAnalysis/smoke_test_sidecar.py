#!/usr/bin/env python3
"""Spawn sidecar.py as a subprocess and drive it through one full
session: read the ready line, ping, separate one file, validate the
returned feature shapes, quit cleanly. This verifies the ndjson IPC
+ feature pipeline before any Swift code touches the sidecar.

Usage:
    .venv/bin/python smoke_test_sidecar.py /path/to/song.wav
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio_path", help="Audio file to separate")
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    sidecar = script_dir / "sidecar.py"
    python = script_dir / ".venv" / "bin" / "python"

    print(f"spawning: {python} {sidecar}")
    proc = subprocess.Popen(
        [str(python), str(sidecar)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=1,  # line-buffered
        text=True,
    )

    def send(req: dict) -> dict:
        line = json.dumps(req)
        print(f"  ⇨ {line}")
        proc.stdin.write(line + "\n")
        proc.stdin.flush()
        # Read responses until we get one matching our request_id, OR
        # until we get a status:error / ready / quit ack
        while True:
            out = proc.stdout.readline()
            if not out:
                stderr = proc.stderr.read()
                raise RuntimeError(f"sidecar EOF; stderr:\n{stderr}")
            try:
                resp = json.loads(out)
            except json.JSONDecodeError:
                print(f"  ! non-JSON on stdout: {out!r}")
                continue
            return resp

    # 1. Read the unsolicited "ready" line
    ready = json.loads(proc.stdout.readline())
    print(f"  ⇦ {ready}")
    assert ready.get("status") == "ready", ready

    # 2. Ping (verifies request_id round-trip, no model load needed)
    pong = send({"action": "ping", "request_id": 1})
    print(f"  ⇦ {pong}")
    assert pong.get("status") == "ok" and pong.get("request_id") == 1, pong

    # 3. Separate with cache_key — first call should miss + compute,
    # second call should hit (sub-50ms). force_refresh=True bypasses
    # cache on demand.
    cache_key = f"smoke-test-{Path(args.audio_path).stem}"

    print(f"\n--- separate (force_refresh, fresh) ---")
    t0 = time.monotonic()
    sep = send({"action": "separate", "request_id": 2,
                "path": str(Path(args.audio_path).resolve()),
                "cache_key": cache_key,
                "force_refresh": True})
    elapsed = time.monotonic() - t0
    print(f"  separation request total time: {elapsed:.1f}s")
    assert sep.get("status") == "ok", sep
    result = sep["result"]
    print(f"  from_cache: {result.get('from_cache')}  (expected False)")
    assert result.get("from_cache") is False

    print(f"\n--- separate (cache hit) ---")
    t1 = time.monotonic()
    sep2 = send({"action": "separate", "request_id": 3,
                 "path": str(Path(args.audio_path).resolve()),
                 "cache_key": cache_key})
    elapsed2 = time.monotonic() - t1
    print(f"  cache lookup total time: {elapsed2*1000:.0f}ms")
    assert sep2.get("status") == "ok", sep2
    result2 = sep2["result"]
    print(f"  from_cache: {result2.get('from_cache')}  (expected True)")
    assert result2.get("from_cache") is True
    # Same features (length-wise) from cache and fresh — sanity check
    assert result["stems"]["drums"]["n_frames"] == result2["stems"]["drums"]["n_frames"]

    print(f"\n--- cache_stats ---")
    stats = send({"action": "cache_stats", "request_id": 4})
    print(f"  {stats['result']}")

    # 4. Validate the feature shapes
    print(f"\n  sample_rate: {result['sample_rate']}")
    print(f"  frame_rate:  {result['frame_rate']}")
    print(f"  timing:      {result['timing']}")
    stems = result["stems"]
    print(f"  stems: {list(stems.keys())}")
    for name, feats in stems.items():
        n_frames = feats["n_frames"]
        chroma = feats["chromagram"]
        loud = feats["loudness"]
        onset = feats["onset"]
        n_onsets = sum(onset)
        print(f"    {name:<8} n_frames={n_frames:>5}  "
              f"chroma=({len(chroma)}, {len(chroma[0]) if chroma else 0})  "
              f"loudness={len(loud)}  onsets={n_onsets}")
        assert len(chroma) == n_frames
        assert len(chroma[0]) == 12 if chroma else True
        assert len(loud) == n_frames
        assert len(onset) == n_frames

    # 5. Quit cleanly
    bye = send({"action": "quit"})
    print(f"  ⇦ {bye}")
    rc = proc.wait(timeout=2)
    print(f"\n  exit code: {rc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
