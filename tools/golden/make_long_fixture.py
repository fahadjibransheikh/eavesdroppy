#!/usr/bin/env python3
"""Loops a raw session's tracks into a long scratch session, for the processing gate (wall time, peak memory, responsiveness).
  .venv/bin/python tools/golden/make_long_fixture.py <raw_session_dir> <scratch_dir> <minutes> [--echo]
--echo: the mic becomes the call audio from 20 s later (near end) plus the call audio echoed at 70 ms, so bleed is detected and
echo removal (LocalVQE, the heaviest stage) really runs; the real session loops into "clean" once repeated (Python agrees).
Writes <scratch_dir>/container/sessions/<name>/{mic,system}.wav (float32) + meta.json. The raw session is only read."""
import json, math, shutil, sys
from pathlib import Path
import numpy as np, soundfile as sf

raw, scratch, minutes = Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3])
echo = "--echo" in sys.argv
dst = scratch / "container/sessions" / raw.name
dst.mkdir(parents=True, exist_ok=True)
base = {t: sf.read(raw / f"{t}.flac", dtype="float32", always_2d=True) for t in ("mic", "system")}
if echo:
    sysx, sr = base["system"]
    k = int(0.07 * sr)
    delayed = np.concatenate([np.zeros((k, sysx.shape[1]), np.float32), sysx])[: len(sysx)]
    mixed = (0.7 * np.roll(sysx, -20 * sr, axis=0) + 0.4 * delayed).astype(np.float32)
    base["mic"] = (mixed[:, :1], sr)
    meta0 = json.loads((raw / "meta.json").read_text()); meta0["track_offsets"] = {"mic": 0.0, "system": 0.0}
for t in ("mic", "system"):
    x, sr = base[t]
    n = int(minutes * 60 * sr)
    with sf.SoundFile(dst / f"{t}.wav", "w", sr, x.shape[1], subtype="FLOAT") as out:
        done = 0
        while done < n:  # streamed: an hour of 48 kHz float is ~0.7 GB per track
            block = x[: n - done]
            out.write(block)
            done += len(block)
meta = meta0 if echo else json.loads((raw / "meta.json").read_text())
meta["title"] = f"Long fixture ({minutes:g} min)"
(dst / "meta.json").write_text(json.dumps(meta))
print(dst, f"{minutes:g} min per track")
