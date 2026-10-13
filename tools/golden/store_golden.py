"""Golden fixtures for the Swift library store (eavesdroppy/Sources/Eavesdroppy/Port/Store*.swift).

Runs the Python oracle (process_meeting.py's library subcommands, notes.retrieve) on scratch copies of a seed database and
dumps every resulting table, rendered file and envelope as JSON. The Swift tests (StoreGoldenTests) replay the same cases on
their own copy and compare.

  .venv/bin/python tools/golden/store_golden.py                    # rewrite Tests/EavesdroppyTests/Fixtures/store/
  .venv/bin/python tools/golden/store_golden.py --real LIBRARY.DB --out DIR
        # a case set built on a copy of a real library.db (never committed: it holds private meetings). Folder, audio and
        # raw paths are NULLed in the copy, so nothing real can be renamed or deleted. Run the Swift side with
        # STORE_GOLDEN_DIR=DIR swift test --filter realLibrary

Time is pinned (library._now, speakers._now) so `created`/`updated` compare exactly. Paths are written as {ROOT} / {HOME}.
"""
import argparse, contextlib, io, json, os, random, shutil, sqlite3, struct, sys, tempfile, unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
import numpy as np  # noqa: E402
import library as lib  # noqa: E402
import notes  # noqa: E402
import process_meeting as pm  # noqa: E402
import speakers as sp  # noqa: E402

NOW = "2026-10-13T12:00:00+00:00"
lib._now = lambda: NOW
sp._now = lambda: NOW
HOME = str(Path.home())
MISSING_DRIVE = HOME + "/Library/CloudStorage/ZZ-NoSuchMount-Eavesdroppy/Meetings"
FIXTURES = REPO / "eavesdroppy" / "Tests" / "EavesdroppyTests" / "Fixtures" / "store"

# ---------- seed database ----------

def emb(seed):
    return np.random.default_rng(seed).normal(size=256).astype(np.float32)


def blob(seed):
    return sp._blob(emb(seed))


def seed_db(path):
    Path(path).unlink(missing_ok=True)
    db = lib.open_db(path)
    me = sp.add_person(db, "Me", emb(1), is_me=True)
    priya = sp.add_person(db, "Priya", emb(2))
    sam = sp.add_person(db, "Sam")  # no voiceprint yet (n = 0)
    db.execute("UPDATE people SET n = 3 WHERE id = ?", (me,))
    db.execute("UPDATE people SET n = 2 WHERE id = ?", (priya,))
    R = "{ROOT}"

    def spk(track, label, kind, person=None, e=None, cluster="0"):
        return {"track": track, "cluster": cluster, "label": label, "kind": kind, "person_id": person, "score": 0.9,
                "embedding": None if e is None else blob(e)}
    m1 = lib.add_meeting(
        db, {"title": "Weekly sync", "start": "2026-10-01T09:00:00-04:00", "duration": 3725.5, "attendees": ["Me", "Priya"],
             "folder": f"{R}/out/2026-10-01 0900 – Weekly sync", "audio_path": f"{R}/out/2026-10-01 0900 – Weekly sync/2026-10-01 0900 – Weekly sync.m4a",
             "raw_dir": f"{R}/container/raw/s1", "user_notes": "my typed notes about the roadmap",
             "notes_md": "## Summary\n\nSpeaker 2 agreed with the budget [00:12]. Speaker 21 disagreed, and Speaker 2 would not budge.\n\n"
                         "## Action items\n\n- [ ] Speaker 2 — Send the budget — Friday\n- [ ] Priya — Book the room — none\n"},
        [spk("mic", "Me", "me", me, 11), spk("system", "Speaker 2", "new", None, 12, "1"), spk("system", "Speaker 21", "new", None, 13, "2"),
         spk("system", "Priya", "auto", priya, 14, "3")],
        [{"speaker": 0, "start": 0.0, "end": 12.4, "text": "Let's start with the budget for next quarter."},
         {"speaker": 1, "start": 12.4, "end": 30.0, "text": "The roadmap depends on the budget approval."},
         {"speaker": 3, "start": 31.2, "end": 60.0, "text": "I can send the numbers by Friday, café résumé attached."},
         {"speaker": 2, "start": 61.0, "end": 90.0, "text": "I disagree about the schedule: it is too tight."},
         {"speaker": 0, "start": 3700.9, "end": 3710.0, "text": "Wrap up. Speaker 2 will send the budget."},
         {"speaker": 3, "start": 3710.0, "end": 3725.5, "text": "Thanks everyone."}],
        [{"owner": "Speaker 2", "task": "Send the budget", "due": "Friday", "turn_idx": 4},
         {"owner": "Priya", "task": "Book the room", "done": 1, "exported_to": "reminders", "external_id": "R-1"}])
    m2 = lib.add_meeting(
        db, {"title": "1:1 with Sam", "start": "2026-10-05T15:30:00+05:30", "duration": 610, "attendees": ["Me", "Sam"], "bleed": 1,
             "folder": f"{R}/out/2026-10-05 1530 – 1-1 with Sam", "audio_path": f"{R}/out/2026-10-05 1530 – 1-1 with Sam/2026-10-05 1530 – 1-1 with Sam.m4a",
             "raw_dir": f"{R}/container/raw/s2", "notes_md": "## Summary\n\nP. said the roadmap is blocked. P. and Me agree on a fix.\n"},
        [spk("mic", "Me", "me", me, 21), spk("system", "P.", "auto", priya, 22, "1")],
        [{"speaker": 0, "start": 1.0, "end": 8.0, "text": "Is the roadmap blocked?"},
         {"speaker": 1, "start": 8.0, "end": 20.0, "text": "Yes, legal has not signed the contract."}],
        [{"owner": "P.", "task": "Chase legal", "due": "Monday", "exported_to": "linear", "external_id": "ENG-9", "external_url": "https://linear.app/x/ENG-9"}])
    m3 = lib.add_meeting(
        db, {"title": "Empty meeting", "start": "2026-09-30T23:59:59-07:00", "duration": 0, "attendees": [],
             "audio_path": f"{R}/out/ghost/ghost.m4a", "raw_dir": f"{R}/container/raw/ghost"}, [], [], [])
    m4 = lib.add_meeting(
        db, {"title": "Standup", "start": "2026-10-01T09:00:00-04:00", "duration": 125, "attendees": ["Me", "Them"],
             "user_notes": "pre-existing typed notes", "notes_md": "## Summary\n\nAll good.\n"}, [],
        [{"speaker": "Me", "start": 0, "end": 5, "text": "Nothing blocked on my side."},
         {"speaker": "Them", "start": 5, "end": 9, "text": "Same here, ship it."}], [])
    m5 = lib.add_meeting(
        db, {"title": "Outside paths", "start": "2026-10-07T10:00:00+00:00", "duration": 60,
             "folder": f"{R}/elsewhere/dir", "audio_path": f"{R}/elsewhere/keep.m4a", "raw_dir": f"{R}/container/raw/s5",
             "notes_md": "## Summary\n\nPaths outside the output folder and the container must survive.\n"}, [], [], [])
    for mid, created in ((m1, "2020-01-01T00:00:00+00:00"), (m2, "2099-01-01T00:00:00+00:00"), (m3, "2020-01-01T00:00:00+00:00"),
                         (m4, "2099-01-01T00:00:00+00:00"), (m5, "2020-01-01T00:00:00+00:00")):
        db.execute("UPDATE meetings SET created = ? WHERE id = ?", (created, mid))
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()


FILES = {  # created under ROOT before every case (text files hold their content; the rest are placeholders)
    "out/2026-10-01 0900 – Weekly sync/notes.md": "stale notes\n",
    "out/2026-10-01 0900 – Weekly sync/transcript.md": "stale transcript\n",
    "out/2026-10-01 0900 – Weekly sync/2026-10-01 0900 – Weekly sync.m4a": "AUDIO1",
    "out/2026-10-01 0900 – Weekly sync/extra.txt": "left behind by the user\n",
    "out/2026-10-05 1530 – 1-1 with Sam/2026-10-05 1530 – 1-1 with Sam.m4a": "AUDIO2",
    "container/raw/s1/mic.flac": "x", "container/raw/s1/system.flac": "x", "container/raw/s2/mic.flac": "x",
    "container/raw/s5/mic.flac": "x", "elsewhere/dir/note.txt": "mine\n", "elsewhere/keep.m4a": "KEEP",
}


def old_db(path, n):
    """A library.db at schema version n (1-3) with a little data, written by raw SQL as the older code would have."""
    Path(path).unlink(missing_ok=True)
    c = sqlite3.connect(path)
    for m in lib.MIGRATIONS[:n]:
        for s in m:
            c.execute(s)
    c.execute("INSERT INTO people(id, name, is_me, voiceprint, n, updated) VALUES (1, 'Me', 1, ?, 1, ?)", (blob(1), NOW))
    c.execute("INSERT INTO meetings(id, title, start, duration, folder, notes_md, created, updated) VALUES"
              " (1, 'Old meeting', '2026-08-01T10:00:00+00:00', 90, '{ROOT}/out/old', '## Summary\n\nSpeaker 2 spoke first.', ?, ?)", (NOW, NOW))
    c.execute("INSERT INTO speakers(id, meeting_id, track, label, person_id, kind) VALUES (1, 1, 'system', 'Speaker 2', NULL, 'new')")
    c.execute("INSERT INTO turns(meeting_id, idx, speaker_id, start, end, text) VALUES (1, 0, 1, 0, 5, 'hello old library')")
    c.execute("INSERT INTO action_items(meeting_id, owner, task) VALUES (1, 'Speaker 2', 'Migrate me')")
    c.execute(f"PRAGMA user_version = {n}")
    c.commit()
    c.close()


def newer_db(path):
    Path(path).unlink(missing_ok=True)
    c = sqlite3.connect(path)
    c.execute("PRAGMA user_version = 99")
    c.execute("CREATE TABLE t(x)")
    c.commit()
    c.close()


# ---------- cases ----------

def S(*args, stdin=None):
    return {"args": list(args), "stdin": stdin}


CASES = [
    {"name": "rename_meeting", "steps": [S("rename-meeting", "1", "Weekly sync: Q4 / planning *final*"), S("rename-meeting", "2", "Sam sync")]},
    {"name": "rename_meeting_errors", "steps": [S("rename-meeting", "999", "x"), S("rename-meeting", "1", "   "), S("rename-meeting", "1", ""),
                                                  S("rename-meeting", "abc", "x"), S("rename-meeting", "1")]},
    {"name": "rename_meeting_collisions_and_unicode", "steps": [
        S("rename-meeting", "4", "Weekly sync"), S("rename-meeting", "4", "Weekly sync"), S("rename-meeting", "1", "Weekly sync "),
        S("rename-meeting", "1", "  A very long title " + "word " * 30 + "end  "), S("rename-meeting", "3", "Ünïcode ☕\tand spaces\nnewline")]},
    {"name": "mirror_all", "steps": [S("rename-meeting", str(i), t) for i, t in ((1, "Weekly sync"), (2, "1:1 with Sam"), (3, "Empty meeting"), (4, "Standup"))]},
    {"name": "mirror_stale_folder", "setup_sql": ["UPDATE meetings SET folder = '{ROOT}/out/gone-' || id, pending_folder = '{ROOT}/out/pending' WHERE id IN (2, 4)"],
     "steps": [S("rename-meeting", "2", "1:1 with Sam"), S("rename-meeting", "4", "Standup")]},
    {"name": "mirror_drive_missing", "out_root": "missing-drive", "steps": [S("rename-meeting", "1", "Renamed while Drive is away"), S("set-user-notes", "2", stdin="typed")]},
    {"name": "rename_speaker_relabel", "steps": [S("rename-speaker", "2", "Dana"), S("rename-speaker", "3", "Dana")]},
    {"name": "rename_speaker_person_link", "steps": [
        S("rename-speaker", "4", "Priya S", "--person-id", "2"), S("rename-speaker", "3", "Priya S", "--person-id", "2"),
        S("rename-speaker", "1", "Fahad", "--person-id", "1")]},
    {"name": "rename_speaker_new_person", "steps": [
        S("rename-speaker", "3", "Morgan", "--new-person"), S("rename-speaker", "5", "Fahad B", "--new-person"),
        S("rename-speaker", "5", "Fahad B", "--person-id", "3"), S("rename-speaker", "2", "Sam", "--person-id", "3"),
        S("rename-speaker", "6", "Priya", "--new-person")]},
    {"name": "rename_speaker_existing_names", "steps": [
        S("rename-speaker", "2", "Priya"), S("rename-speaker", "2", "Priya", "--new-person"), S("rename-speaker", "6", "Me", "--person-id", "1"),
        S("rename-speaker", "4", "Priya", "--person-id=2")]},
    {"name": "rename_speaker_errors", "steps": [
        S("rename-speaker", "999", "x"), S("rename-speaker", "999", ""), S("rename-speaker", "2", "  "), S("rename-speaker", "2", "x", "--person-id", "2", "--new-person"),
        S("rename-speaker", "2", "x", "--person-id", "999"), S("rename-speaker", "2")]},
    {"name": "set_user_notes", "steps": [
        S("set-user-notes", "1", stdin="Typed: budget review\nline two\n"), S("set-user-notes", "1", stdin="  \n"), S("set-user-notes", "1", stdin=""),
        S("set-user-notes", "1"), S("set-user-notes", "1", "--clear"), S("set-user-notes", "999", stdin="x"), S("set-user-notes", "2", stdin="  keep my spaces  ")]},
    {"name": "delete", "steps": [S("delete", "1"), S("delete", "3"), S("delete", "999")]},
    {"name": "delete_outside_roots", "steps": [S("delete", "5"), S("delete", "4")]},
    {"name": "set_action_done", "steps": [S("set-action-done", "1"), S("set-action-done", "2", "--undone"), S("set-action-done", "999"), S("set-action-done", "1", "--undone")]},
    {"name": "set_action_exported", "steps": [S("set-action-exported", "1", "linear", "ENG-12"), S("set-action-exported", "2", "reminders", "R-2"),
                                               S("set-action-exported", "999", "linear", "ENG-1")]},
    {"name": "expire_audio", "steps": [S("expire-audio", "30"), S("expire-audio", "30")]},
    {"name": "expire_nothing", "steps": [S("expire-audio", "100000"), S("expire-audio", "0"), S("expire-audio", "-5")]},
    {"name": "migrate_fresh", "base": None, "steps": [S("delete", "999")]},
    {"name": "migrate_from_v1", "base": "v1.db", "steps": [S("delete", "999")]},
    {"name": "migrate_from_v2", "base": "v2.db", "steps": [S("delete", "999")]},
    {"name": "migrate_from_v3", "base": "v3.db", "steps": [S("delete", "999")]},
    {"name": "migrate_then_edit_v1", "base": "v1.db", "steps": [S("rename-speaker", "1", "Dana"), S("set-action-exported", "1", "linear", "ENG-3")]},
    {"name": "schema_newer", "base": "newer.db", "steps": [S("delete", "1")]},
    {"name": "container_missing", "container": "missing", "steps": [S("delete", "1")]},
    {"name": "ask_retrieve", "ask": [
        {"question": "what was said about the budget", "scope": None},
        {"question": "the and of to", "scope": None},
        {"question": "", "scope": None},
        {"question": "zzzzqqq nonexistent", "scope": None},
        {"question": "\"foo\" OR NEAR( AND * title:x -y", "scope": None},
        {"question": "roadmap Speaker contract", "scope": None},
        {"question": "Cafe resume", "scope": None},
        {"question": "roadmap", "scope": {"meeting_id": 2}},
        {"question": "roadmap budget", "scope": {"person_id": 2}},
        {"question": "anything", "scope": {"person_id": 999}},
        {"question": "typed notes", "scope": None},
        {"question": "blocked", "scope": {"meeting_id": 999}}]},
]

# ---------- harness ----------

def materialize(root, base, base_dir, setup_sql=()):
    for d in ("out", "container"):
        (root / d).mkdir(exist_ok=True)
    for rel, text in FILES.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    if base:
        dst = root / "container" / "library.db"
        shutil.copyfile(Path(base_dir) / base, dst)
        c = sqlite3.connect(dst)
        for s in setup_sql:
            c.execute(s)
        for col in ("folder", "audio_path", "raw_dir", "pending_folder"):
            if col in {r[1] for r in c.execute("PRAGMA table_info(meetings)")}:
                c.execute(f"UPDATE meetings SET {col} = replace({col}, '{{ROOT}}', ?)", (str(root),))
        c.commit()
        c.close()


def scrub(o, root):
    if isinstance(o, str):
        return o.replace(str(root), "{ROOT}").replace(HOME, "{HOME}")
    if isinstance(o, list):
        return [scrub(x, root) for x in o]
    if isinstance(o, dict):
        return {k: scrub(v, root) for k, v in o.items()}
    return o


def cell(table, col, v):
    if isinstance(v, bytes):
        if (table, col) == ("people", "voiceprint"):  # compared with a tolerance: numpy's float32 maths is not bit-reproducible elsewhere
            return [round(x, 8) for x in struct.unpack(f"<{len(v) // 4}f", v)]
        return f"blob:{len(v)}:{v[:8].hex()}"  # embeddings are only ever read
    return v


def dump_db(path, root):
    if not Path(path).exists():
        return None
    c = sqlite3.connect(path)
    out = {"user_version": c.execute("PRAGMA user_version").fetchone()[0],
           "schema": [list(r) for r in c.execute("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
                                                 " ORDER BY type, name")]}
    for t, order in (("people", "id"), ("meetings", "id"), ("speakers", "id"), ("turns", "id"), ("action_items", "id"),
                     ("search", "rowid")):
        if not c.execute("SELECT 1 FROM sqlite_master WHERE name = ?", (t,)).fetchone():
            continue
        cur = c.execute(f"SELECT * FROM {t} ORDER BY {order}")
        names = [d[0] for d in cur.description]
        out[t] = [{n: cell(t, n, v) for n, v in zip(names, r)} for r in cur]
    c.close()
    return scrub(out, root)


def dump_files(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            p = Path(dp) / n
            rel = unicodedata.normalize("NFC", p.relative_to(root).as_posix())
            if rel.startswith("container/library.db"):
                continue
            out[rel] = "<dir>" if p.is_dir() else (p.read_text() if p.suffix in (".md", ".txt") else f"<{p.stat().st_size} bytes>")
    return dict(sorted(out.items()))


def run_step(step, container, out_root, root):
    argv = list(step["args"]) + ["--container", str(container), "--out-root", str(out_root)]
    out, err = io.StringIO(), io.StringIO()
    old_stdin = sys.stdin
    sys.stdin = None if step["stdin"] is None else io.StringIO(step["stdin"])
    code = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                pm.main(argv)
            except SystemExit as e:
                code = e.code or 0
    finally:
        sys.stdin = old_stdin
    lines = err.getvalue().splitlines()
    res = {"warnings": [l[len("WARNING: "):] for l in lines if l.startswith("WARNING: ")]}
    if code:
        res["error"] = [l for l in lines if l.startswith("ERROR: ")][-1][len("ERROR: "):]
    else:
        res["ok"] = json.loads(out.getvalue().strip().splitlines()[-1])
    return scrub(res, root)


def run_case(case, base_dir, default_base, setup_sql):
    setup_sql = [*setup_sql, *case.get("setup_sql", [])]
    root = Path(tempfile.mkdtemp(prefix="storegolden-")).resolve()
    try:
        base = case.get("base", default_base)
        materialize(root, base, base_dir, setup_sql)
        container = root / "nocontainer" if case.get("container") == "missing" else root / "container"
        out_root = MISSING_DRIVE if case.get("out_root") == "missing-drive" else root / "out"
        if "ask" in case:
            db = lib.connect_readonly(container / "library.db")
            res = []
            for q in case["ask"]:
                scope = q["scope"]
                segs, nts = notes.retrieve(db, q["question"], scope)
                res.append({"segments": segs, "notes": nts})
            db.close()
            return {"ask": scrub(res, root)}
        steps = [run_step(s, container, out_root, root) for s in case["steps"]]
        return {"steps": steps, "db": dump_db(container / "library.db", root), "files": dump_files(root)}
    finally:
        shutil.rmtree(root, ignore_errors=True)


def build(out_dir, cases, base_dir, default_base, setup_sql=()):
    spec = []
    for c in cases:
        spec.append({**c, "setup_sql": [*setup_sql, *c.get("setup_sql", [])], "expect": run_case(c, base_dir, default_base, setup_sql)})
    return {"version": 1, "defaultBase": default_base, "files": FILES, "cases": spec}


def real_cases(real_db):
    c = sqlite3.connect(real_db)
    mid, title = c.execute("SELECT id, title FROM meetings ORDER BY id LIMIT 1").fetchone()
    sid = c.execute("SELECT id FROM speakers WHERE meeting_id = ? ORDER BY id LIMIT 1", (mid,)).fetchone()[0]
    word = (c.execute("SELECT text FROM turns WHERE meeting_id = ? ORDER BY idx LIMIT 1", (mid,)).fetchone() or ["hello"])[0].split()[0]
    c.close()
    return [{"name": "real_rename_meeting", "steps": [S("rename-meeting", str(mid), "Renamed: " + title)]},
            {"name": "real_rename_speaker", "steps": [S("rename-speaker", str(sid), "Zed")]},
            {"name": "real_user_notes", "steps": [S("set-user-notes", str(mid), stdin="typed " + word)]},
            {"name": "real_ask", "ask": [{"question": word, "scope": None}, {"question": "what happened", "scope": {"meeting_id": mid}}]},
            {"name": "real_open_only", "steps": [S("delete", "999999")]}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(FIXTURES))
    ap.add_argument("--real", help="a library.db to copy; writes real.db + golden.json into --out")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.real:
        src, dst = sqlite3.connect(a.real), sqlite3.connect(out / "real.db")
        src.backup(dst)
        dst.close()
        src.close()
        nuke = ["UPDATE meetings SET folder = NULL, audio_path = NULL, raw_dir = NULL"] + \
               (["UPDATE meetings SET pending_folder = NULL"] if "pending_folder" in {r[1] for r in sqlite3.connect(out / "real.db").execute("PRAGMA table_info(meetings)")} else [])
        data = build(out, real_cases(out / "real.db"), out, "real.db", nuke)
    else:
        seed_db(out / "seed.db")
        for n in (1, 2, 3):
            old_db(out / f"v{n}.db", n)
        newer_db(out / "newer.db")
        data = build(out, CASES, out, "seed.db")
    (out / "golden.json").write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"wrote {out / 'golden.json'}: {len(data['cases'])} cases")


if __name__ == "__main__":
    main()
