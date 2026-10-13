#!/usr/bin/env python3
"""import-drive: library.import_existing_drive_meetings against StoreImport.importExisting on the same mirror folders.
  .venv/bin/python tools/golden/import_golden.py <scratch_dir> <mirror_folder> [<mirror_folder> ...]   build the variants, run Python
  (then) EAVESDROPPY_IMPORT_GOLDEN_DIR=<scratch_dir> swift test --filter ImportGolden                  run Swift
  .venv/bin/python tools/golden/import_golden.py <scratch_dir> --compare                               compare the two databases
Each <mirror_folder> is a meeting folder made by process_meeting (notes.md, transcript.md, m4a). Variants: as is, notes.md only,
transcript.md only, a no-speech meeting, a wrapped turn, an unparsable header."""
import json, re, shutil, sqlite3, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))


def build(scratch, folders):
    mirror = scratch / "mirror"
    shutil.rmtree(mirror, ignore_errors=True)
    mirror.mkdir(parents=True)
    for i, f in enumerate(map(Path, folders)):
        shutil.copytree(f, mirror / f"{i}a full")
        shutil.copytree(f, mirror / f"{i}b notes only"); (mirror / f"{i}b notes only/transcript.md").unlink()
        shutil.copytree(f, mirror / f"{i}c transcript only"); (mirror / f"{i}c transcript only/notes.md").unlink()
        shutil.copytree(f, mirror / f"{i}d wrapped")
        t = (mirror / f"{i}d wrapped/transcript.md").read_text()
        (mirror / f"{i}d wrapped/transcript.md").write_text(re.sub(r"(\*\*\[[0-9:]+\] [^*]+:\*\* \S+ \S+ \S+)", r"\1\n", t, count=1))
    nospeech = mirror / "9 no speech"
    nospeech.mkdir()
    (nospeech / "transcript.md").write_text("# Quiet\n\n- **Date:** 2026-01-02 09:30 (UTC-05:00)\n- **Duration:** 01:05\n- **Attendees:** —\n\n---\n_No speech detected._\n")
    bad = mirror / "9 unparsable"; bad.mkdir()
    (bad / "transcript.md").write_text("no header here\n---\nhello\n")
    (mirror / ".hidden").mkdir(); (mirror / "empty").mkdir()


def run_python(scratch):
    import library
    db_path = scratch / "py.db"
    db_path.unlink(missing_ok=True)
    db = library.open_db(db_path)
    r = library.import_existing_drive_meetings(db, scratch / "mirror")
    again = library.import_existing_drive_meetings(db, scratch / "mirror")
    (scratch / "py.json").write_text(json.dumps({"imported": len(r["imported"]), "skipped": r["skipped"], "failed": r["failed"],
                                                 "again_imported": len(again["imported"]), "again_skipped": again["skipped"]}))
    print("python:", json.loads((scratch / "py.json").read_text()))


def dump(path):
    db = sqlite3.connect(str(path)); db.row_factory = sqlite3.Row
    out = []
    for m in db.execute("SELECT * FROM meetings ORDER BY folder"):
        d = {k: m[k] for k in m.keys() if k not in ("id", "created", "updated")}
        d["speakers"] = [dict(r) for r in db.execute("SELECT track, cluster, label, person_id, score, kind FROM speakers WHERE meeting_id = ? ORDER BY id", (m["id"],))]
        d["turns"] = [dict(r) for r in db.execute("SELECT t.idx, t.start, t.end, t.text, s.label FROM turns t LEFT JOIN speakers s ON s.id = t.speaker_id WHERE t.meeting_id = ? ORDER BY idx", (m["id"],))]
        d["actions"] = [{k: v for k, v in dict(r).items() if k not in ("id", "meeting_id")} for r in db.execute("SELECT * FROM action_items WHERE meeting_id = ? ORDER BY id", (m["id"],))]
        out.append(d)
    return out


def compare(scratch):
    py, sw = dump(scratch / "py.db"), dump(scratch / "sw.db")
    print(f"meetings: py={len(py)} sw={len(sw)}")
    bad = 0
    for a, b in zip(py, sw):
        if a != b:
            bad += 1
            print("DIFF", a["folder"])
            for k in a:
                if a[k] != b.get(k): print(f"  {k}: py={a[k]!r:.300} sw={b.get(k)!r:.300}")
    print("swift result:", (scratch / "sw.json").read_text() if (scratch / "sw.json").exists() else "-")
    print("IDENTICAL" if not bad and len(py) == len(sw) else f"{bad} differing meetings")


if __name__ == "__main__":
    scratch = Path(sys.argv[1]); scratch.mkdir(parents=True, exist_ok=True)
    if sys.argv[2:3] == ["--compare"]:
        compare(scratch)
    else:
        build(scratch, sys.argv[2:]); run_python(scratch)
