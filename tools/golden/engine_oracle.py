#!/usr/bin/env python3
"""Runs the CLI path (as process_meeting.py runs it) on a recorded session, for EngineEquivalenceTests.
  .venv/bin/python tools/golden/engine_oracle.py <raw_session_dir> <out_dir>
Reads <raw_session_dir>/{mic,system}.flac (never writes there). Writes into out_dir:
  <track>16k.wav            16 kHz mono 16-bit, as process() hands it to fluidaudiocli
  oracle.json               per track: words, duration_seconds, diarization segments + embeddings, seconds taken
  lvqe-{mic,ref,out}.wav    one 10 s chunk through echo._localvqe (float WAVs), for the EchoRemover check"""
import json, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import numpy as np
import soundfile as sf
import echo, process_meeting as pm, speakers

session, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
model_dir = pm.link_droppy_model(out / "model-link")
hot = pm.build_hotwords([], pm.load_droppy_vocab())
result = {"hotwords": hot, "model_dir": str(model_dir) if model_dir else None, "tracks": {}}
with tempfile.TemporaryDirectory() as d:
    for key in ("mic", "system"):
        src = session / f"{key}.flac"
        if not src.exists():
            continue
        tr = pm.prepare_track(key, src, Path(d))
        wav = out / f"{key}16k.wav"
        pm.to_16k_wav(tr["mono"], wav)
        t0 = time.time()
        res = pm.transcribe(wav, hot, model_dir, ())
        t1 = time.time()
        diar = speakers.diarize(wav)
        t2 = time.time()
        result["tracks"][key] = {
            "peak": tr["peak"], "duration": tr["dur"], "sr": tr["sr"],
            "words": res["words"], "duration_seconds": res["duration_seconds"],
            "segments": [[s, e, c] for s, e, c in diar["segments"]],
            "embeddings": {c: [float(x) for x in v] for c, v in diar["embeddings"].items()},
            "transcribe_s": round(t1 - t0, 2), "diarize_s": round(t2 - t1, 2),
        }
if "mic" in result["tracks"] and "system" in result["tracks"]:
    # a third, two-voice track (mic + call summed) so the diarization comparison is not just "one cluster vs one"
    a, b = echo.load16k(out / "mic16k.wav"), echo.load16k(out / "system16k.wav")
    n = min(len(a), len(b))
    sf.write(out / "mix16k.wav", np.clip(a[:n] + b[:n], -1, 1), echo.SR, subtype="PCM_16")
    t0 = time.time()
    res = pm.transcribe(out / "mix16k.wav", hot, model_dir, ())
    t1 = time.time()
    diar = speakers.diarize(out / "mix16k.wav")
    result["tracks"]["mix"] = {
        "peak": 1.0, "duration": n / echo.SR, "sr": echo.SR, "words": res["words"], "duration_seconds": res["duration_seconds"],
        "segments": [[s, e, c] for s, e, c in diar["segments"]],
        "embeddings": {c: [float(x) for x in v] for c, v in diar["embeddings"].items()},
        "transcribe_s": round(t1 - t0, 2), "diarize_s": round(time.time() - t1, 2)}
import subprocess
LINES = [("Daniel", "Good morning everyone. Let us start with the wholesale desk and what we ship on Friday."),
         ("Samantha", "Thanks. The returns flow is nearly done, but I still need a review of the pricing rules before the launch."),
         ("Eddy", "I can take that review. Send me the notes and I will go through them this afternoon with the team."),
         ("Daniel", "Great. Then the open question is the mobile app scope, and whether we build it ourselves or hire an agency."),
         ("Samantha", "I would hire. The estimate is rough, but two months of focused work is more than we can spare right now.")]
with tempfile.TemporaryDirectory() as d:  # a three-voice conversation from synthetic voices
    parts = []
    for i, (voice, text) in enumerate(LINES):
        aiff, w = Path(d) / f"{i}.aiff", Path(d) / f"{i}.wav"
        r = subprocess.run(["/usr/bin/say", "-v", voice, "-o", str(aiff), text], capture_output=True)
        if r.returncode:
            parts = []
            break
        pm.to_16k_wav(aiff, w)
        parts += [echo.load16k(w), np.zeros(int(0.6 * echo.SR), np.float32)]
    if parts:
        sf.write(out / "say16k.wav", np.concatenate(parts), echo.SR, subtype="PCM_16")
        t0 = time.time()
        res = pm.transcribe(out / "say16k.wav", hot, model_dir, ())
        t1 = time.time()
        diar = speakers.diarize(out / "say16k.wav")
        result["tracks"]["say"] = {
            "peak": 1.0, "duration": sum(len(x) for x in parts) / echo.SR, "sr": echo.SR, "words": res["words"],
            "duration_seconds": res["duration_seconds"], "segments": [[s, e, c] for s, e, c in diar["segments"]],
            "embeddings": {c: [float(x) for x in v] for c, v in diar["embeddings"].items()},
            "transcribe_s": round(t1 - t0, 2), "diarize_s": round(time.time() - t1, 2)}
if "mic" in result["tracks"] and "system" in result["tracks"] and echo.LVQE.exists():
    mic, sysm = echo.load16k(out / "mic16k.wav"), echo.load16k(out / "system16k.wav")
    a, b = 20 * echo.SR, 30 * echo.SR   # 10 s chunk, same alignment for both: no lag shift, the point is the binary call
    m, r = mic[a:b], sysm[a:b]
    y = echo._localvqe(m, r)
    for name, x in (("mic", m), ("ref", r), ("out", y)):
        sf.write(out / f"lvqe-{name}.wav", x, echo.SR, subtype="FLOAT")
(out / "oracle.json").write_text(json.dumps(result))
print(f"oracle: {out / 'oracle.json'}")
