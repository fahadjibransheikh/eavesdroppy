#!/usr/bin/env python3
"""Golden run of the full pipeline: process_meeting.py against Processor.swift on the same scratch copy of a raw session.

  .venv/bin/python tools/golden/process_golden.py <scratch_dir> [raw_session_dir]      prepare, run both, compare
  .venv/bin/python tools/golden/process_golden.py <scratch_dir> --compare-only
  .venv/bin/python tools/golden/process_golden.py <scratch_dir> --enrolled <enroll_golden_dir>   start both sides with an enrolled Me
  .venv/bin/python tools/golden/process_golden.py <scratch_dir> --synth     the same with a synthetic mic that echoes the call (removal succeeds)

Notes generation is stubbed by tools/golden/fake_notes_reply.md on both sides (EAVESDROPPY_CLAUDE_BIN for Python, a fixed
NotesProvider in the Swift test). The raw session is read only; everything is written under <scratch_dir>:
  echo/ (remove_echo oracle and the Swift numbers)  py/{container,out}  sw/{container,out}  py.log  sw.log  report.txt
Needs the personal build (FluidAudio, LocalVQE) and `swift` on PATH."""
import difflib, json, os, shutil, sqlite3, subprocess, sys
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
RAW = Path.home() / "Library/Application Support/Droppy/Droplets/eavesdroppy/Container/raw/20261013-123545-736-0001"
NAME = "20261013-123545-736-0001"


def prepare(scratch, raw, synth=False, enrolled=None):
    for side in ("py", "sw"):
        s = scratch / side / "container/sessions" / NAME
        shutil.rmtree(scratch / side, ignore_errors=True)
        s.mkdir(parents=True)
        for t in ("mic", "system"):
            if (raw / f"{t}.flac").exists():
                x, sr = sf.read(raw / f"{t}.flac", dtype="float32", always_2d=True)
                sf.write(s / f"{t}.wav", x, sr, subtype="FLOAT")
        shutil.copy2(raw / "meta.json", s / "meta.json")
        if synth:  # mic = the call audio from 20 s later (near end) + the call audio echoed at 70 ms: removal succeeds
            sysx, sr = sf.read(s / "system.wav", dtype="float32", always_2d=True)
            near, k = np.roll(sysx, -20 * sr, axis=0), int(0.07 * sr)
            echoed = np.concatenate([np.zeros((k, sysx.shape[1]), np.float32), sysx])[: len(sysx)]
            sf.write(s / "mic.wav", (0.7 * near + 0.4 * echoed).astype(np.float32), sr, subtype="FLOAT")
            m = json.loads((s / "meta.json").read_text())
            m["track_offsets"] = {"mic": 0.0, "system": 0.0}
            (s / "meta.json").write_text(json.dumps(m))
    if enrolled:  # each side starts from its own enrollment of the same sample (tools/golden/enroll_golden.sh)
        for side, src in (("py", "py-container"), ("sw", "sw-container")):
            shutil.copy2(Path(enrolled) / src / "library.db", scratch / side / "container/library.db")
    fake = scratch / "fake-claude.sh"
    fake.write_text(f'#!/bin/sh\ncat >/dev/null\ncat "{ROOT}/tools/golden/fake_notes_reply.md"\n')
    fake.chmod(0o755)


def run_python(scratch):
    side = scratch / "py"
    env = {**os.environ, "EAVESDROPPY_CLAUDE_BIN": str(scratch / "fake-claude.sh")}
    with open(scratch / "py.log", "w") as log:
        r = subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "process_meeting.py"), str(side / "container/sessions" / NAME),
                            "--container", str(side / "container"), "--out-root", str(side / "out"), "--user-name", "Fahad"],
                           env=env, stdout=subprocess.PIPE, stderr=log, text=True)
    (scratch / "py.json").write_text(r.stdout)
    assert r.returncode == 0, f"python failed, see {scratch / 'py.log'}"


def echo_oracle(scratch):
    """echo.remove_echo on the 16 kHz tracks of the session (as process_meeting hands them over): numbers + cleaned audio.
    Also on a synthetic mix of the same tracks (echo-synth/: near end = the call audio from 20 s later, plus the call audio
    echoed at 70 ms, 0.4x), because the real session fails the self-check, so it never exercises the success path."""
    sys.path.insert(0, str(ROOT))
    import tempfile
    import echo, process_meeting as pm
    d = scratch / "echo"
    d.mkdir(exist_ok=True)
    meta = json.loads((RAW / "meta.json").read_text())
    off = meta["track_offsets"]["system"] - meta["track_offsets"]["mic"]
    with tempfile.TemporaryDirectory() as t:
        for k in ("mic", "system"):
            tr = pm.prepare_track(k, scratch / "py/container/sessions" / NAME / f"{k}.wav", Path(t))
            pm.to_16k_wav(tr["mono"], d / f"{k}16k.wav")
    r = echo.remove_echo(d / "mic16k.wav", d / "system16k.wav", d / "cleaned-py.wav", system_offset_s=off)
    det = echo.detect_bleed(d / "mic16k.wav", d / "system16k.wav", system_offset_s=off)
    (d / "echo-py.json").write_text(json.dumps({"offset": off, "remove": r, "detect": {k: det[k] for k in ("bleed", "share", "lag_ms", "scores")}}))
    print("python remove_echo:", {k: r[k] for k in ("failed", "reason", "self_check", "lag_ms", "chunk_lags_ms")})
    d2 = scratch / "echo-synth"
    d2.mkdir(exist_ok=True)
    sysm = echo.load16k(d / "system16k.wav")
    near = np.roll(sysm, -20 * 16000)
    echoed = np.concatenate([np.zeros(int(0.07 * 16000), np.float32), sysm])[: len(sysm)]
    sf.write(d2 / "mic16k.wav", (0.7 * near + 0.4 * echoed).astype(np.float32), 16000, subtype="PCM_16")
    shutil.copy2(d / "system16k.wav", d2 / "system16k.wav")
    r2 = echo.remove_echo(d2 / "mic16k.wav", d2 / "system16k.wav", d2 / "cleaned-py.wav", system_offset_s=0.0)
    det2 = echo.detect_bleed(d2 / "mic16k.wav", d2 / "system16k.wav")
    (d2 / "echo-py.json").write_text(json.dumps({"offset": 0.0, "remove": r2, "detect": {k: det2[k] for k in ("bleed", "share", "lag_ms", "scores")}}))
    print("python remove_echo (synthetic):", {k: r2[k] for k in ("failed", "reason", "self_check", "lag_ms", "chunk_lags_ms")})


def run_swift(scratch):
    env = {**os.environ, "EAVESDROPPY_PERSONAL": "1", "EAVESDROPPY_PROCESS_GOLDEN_DIR": str(scratch)}
    r = subprocess.run(["swift", "test", "--filter", "ProcessorGolden"], cwd=ROOT / "eavesdroppy", env=env, capture_output=True, text=True)
    (scratch / "swift-test.log").write_text(r.stdout + r.stderr)
    assert r.returncode == 0, f"swift test failed, see {scratch / 'swift-test.log'}"


def dump(side, scratch):
    db = sqlite3.connect(str(side / "container/library.db"))
    db.row_factory = sqlite3.Row
    norm = lambda v: v.replace(str(scratch / side.name), "<SIDE>") if isinstance(v, str) else v
    m = dict(db.execute("SELECT * FROM meetings").fetchone())
    for k in ("created", "updated", "id", "pending_folder"):
        m.pop(k)
    m = {k: norm(v) for k, v in m.items()}
    spk = [{k: (np.frombuffer(v, np.float32) if k == "embedding" and v else v) for k, v in dict(r).items() if k not in ("id", "meeting_id")}
           for r in db.execute("SELECT * FROM speakers ORDER BY id")]
    label = {r["id"]: r["label"] for r in db.execute("SELECT id, label FROM speakers")}
    turns = [{"idx": r["idx"], "speaker": label.get(r["speaker_id"]), "start": r["start"], "end": r["end"], "text": r["text"]}
             for r in db.execute("SELECT * FROM turns ORDER BY idx")]
    actions = [{k: v for k, v in dict(r).items() if k not in ("id", "meeting_id")} for r in db.execute("SELECT * FROM action_items ORDER BY id")]
    people = [{k: v for k, v in dict(r).items() if k != "updated"} for r in db.execute("SELECT * FROM people")]
    folder = Path(m["folder"].replace("<SIDE>", str(scratch / side.name)))
    files = {f.name: f.read_text() for f in folder.iterdir() if f.suffix == ".md"}
    audio = next(folder.glob("*.m4a"))
    ai = subprocess.run(["/usr/bin/afinfo", str(audio)], capture_output=True, text=True).stdout
    info = {k: float(v.split()[0]) for k, v in (l.split(":", 1) for l in ai.splitlines() if ":" in l) if k.strip() in ("estimated duration", "bit rate")}
    return {"meeting": m, "speakers": spk, "turns": turns, "actions": actions, "people": people, "files": files,
            "m4a": {**info, "bytes": audio.stat().st_size},
            "raw": sorted(p.name for p in Path(m["raw_dir"].replace("<SIDE>", str(scratch / side.name))).iterdir())}


def compare(scratch):
    py, sw = dump(scratch / "py", scratch), dump(scratch / "sw", scratch)
    out = []
    say = out.append
    for k in sorted(set(py["meeting"]) | set(sw["meeting"])):
        a, b = py["meeting"].get(k), sw["meeting"].get(k)
        if a != b:
            say(f"meetings.{k}: py={a!r} sw={b!r}" if k not in ("notes_md",) else f"meetings.notes_md differs")
    say(f"speakers: py={len(py['speakers'])} sw={len(sw['speakers'])}")
    for i, (a, b) in enumerate(zip(py["speakers"], sw["speakers"])):
        for k in a:
            if k == "embedding":
                cos = float(a[k] @ b[k] / (np.linalg.norm(a[k]) * np.linalg.norm(b[k]))) if a[k] is not None and b[k] is not None else None
                say(f"  speaker[{i}] {a['label']!r}/{b['label']!r} embedding cosine={cos}")
            elif k == "score":
                if a[k] != b[k]: say(f"  speaker[{i}].score py={a[k]} sw={b[k]} (delta {abs(a[k]-b[k]):.4f})")
            elif a[k] != b[k]:
                say(f"  speaker[{i}].{k}: py={a[k]!r} sw={b[k]!r}")
    say(f"turns: py={len(py['turns'])} sw={len(sw['turns'])}")
    exact = sum(1 for a, b in zip(py["turns"], sw["turns"]) if a == b)
    say(f"  turns identical (speaker,start,end,text exact): {exact}")
    ta, tb = " ".join(t["text"] for t in py["turns"]), " ".join(t["text"] for t in sw["turns"])
    say(f"  transcript text: py {len(ta.split())} words, sw {len(tb.split())} words, difflib ratio={difflib.SequenceMatcher(None, ta.split(), tb.split(), autojunk=False).ratio():.4f}")
    dt = [max(abs(a["start"] - b["start"]), abs(a["end"] - b["end"])) for a, b in zip(py["turns"], sw["turns"])]
    if dt: say(f"  max |start/end| delta over paired turns: {max(dt):.4f} s")
    shown = 0
    for a, b in zip(py["turns"], sw["turns"]):
        if a != b and shown < 6:
            shown += 1
            say(f"  DIFF idx {a['idx']}: py {a['speaker']}[{a['start']:.2f}-{a['end']:.2f}] {a['text'][:100]!r}\n          sw {b['speaker']}[{b['start']:.2f}-{b['end']:.2f}] {b['text'][:100]!r}")
    say(f"actions equal: {py['actions'] == sw['actions']}")
    for a, b in zip(py["people"], sw["people"]):
        va, vb = np.frombuffer(a.pop("voiceprint"), np.float32), np.frombuffer(b.pop("voiceprint"), np.float32)
        say(f"people {a['name']!r}: n py={a['n']} sw={b['n']}  other columns equal: {a == b}  voiceprint cosine={float(va @ vb / (np.linalg.norm(va) * np.linalg.norm(vb))):.7f}")
    say(f"people rows: py={len(py['people'])} sw={len(sw['people'])}")
    for f in sorted(set(py["files"]) | set(sw["files"])):
        a, b = py["files"].get(f), sw["files"].get(f)
        say(f"mirror {f}: {'IDENTICAL' if a == b else 'differs'}" + ("" if a == b else f" (ratio {difflib.SequenceMatcher(None, a or '', b or '').ratio():.4f})"))
    say(f"m4a: py {py['m4a']} sw {sw['m4a']}")
    say(f"raw dir: py {py['raw']} sw {sw['raw']}")
    for side in ("py", "sw"):
        log = (scratch / f"{side}.log").read_text() if (scratch / f"{side}.log").exists() else ""
        say(f"--- {side} log (Echo / warnings lines)")
        for l in log.splitlines():
            if l.startswith(("Echo", "Using", "Custom", "WARNING")): say("  " + l)
    (scratch / "report.txt").write_text("\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    scratch = Path(sys.argv[1]).resolve()
    if "--compare-only" not in sys.argv:
        enrolled = sys.argv[sys.argv.index("--enrolled") + 1] if "--enrolled" in sys.argv else None
        prepare(scratch, Path(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else RAW, "--synth" in sys.argv, enrolled)
        run_python(scratch)
        if "--synth" not in sys.argv: echo_oracle(scratch)
        run_swift(scratch)
    compare(scratch)
