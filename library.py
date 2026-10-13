"""Eavesdroppy meeting library: SQLite source of truth (decision D1).

Python is the ONLY writer. The Swift droplet opens library.db read-only through the SQLite C API, and
mcp_server.py opens it with ?mode=ro. Stdlib only (no numpy/soundfile) so the MCP server can import it.

File: <container>/library.db. WAL, foreign_keys=ON, busy_timeout=5000. Schema version = PRAGMA user_version
(see MIGRATIONS; open_db() applies pending migrations in order, each in its own transaction).

Schema v4 (v3 + meetings.pending_folder; v3 = v2 + action_items.external_url; v2 = v1 + speakers.suggested_person_id; all times ISO 8601 with UTC offset, e.g. 2026-10-12T14:30:00-04:00; seconds are float offsets
from the recording start):

  meetings(id, title, start, duration, source 'record'|'import', folder UNIQUE, audio_path, raw_dir,
           template, attendees JSON list, user_notes, notes_md, summary_status, bleed, created, updated)
      folder      Drive mirror folder (absolute path), the importer's idempotency key
      pending_folder (v4) the Drive folder a run is about to rename into place, recorded before the rename so a retry
                  after a kill can reuse it; NULL once `folder` is set. Readers ignore it.
      audio_path  <folder>/<folder name>.m4a, NULL once expired (D20)
      raw_dir     local raw FLAC dir (<container>/raw/<session>), NULL once expired
      notes_md    the notes section only (starts at "## Summary"); citations already rendered as [MM:SS]
      summary_status 'ok' | 'failed' | 'pending' | 'none'
      bleed       1 if the echo detector flagged mic/system bleed (voiceprints must not learn from it)
  speakers(id, meeting_id, track 'mic'|'system'|'room', cluster, label, person_id -> people, score, kind, embedding,
           suggested_person_id -> people)
      label is what the UI and the Drive files show ("Me", "Priya", "Speaker 2"); kind is free text
      from speakers.py (e.g. 'me', 'known', 'new', 'room').
      suggested_person_id (v2) the person a kind='suggest' voiceprint match (0.60-0.75 cosine) points at, NULL
      otherwise and for rows from before v2. It is a hint only: person_id stays NULL and the label stays "Speaker n"
      until the user confirms (rename-speaker --person-id). A reader may show "Is this <people.name>?"; ignore it
      once person_id is set. Deleting the person nulls it.
  turns(id, meeting_id, idx 0-based, speaker_id -> speakers, start, end, text)   UNIQUE(meeting_id, idx)
  action_items(id, meeting_id, owner, task, due, done, turn_idx, exported_to, external_id, external_url)
      external_url (v3) the exported item's link (Linear issue URL), NULL for rows exported before v3 and for Reminders
  people(...)   owned by speakers.py; created here with the identical DDL only so the FK target exists.
  search        FTS5 table (own copy of the text), maintained by triggers. One row per turn
                (rowid = turns.id, column body) and one per meeting (rowid = -meetings.id, columns
                title/notes/user_notes). UNINDEXED: kind 't'|'m', meeting_id, turn_idx.
                Query it only through list_meetings(); snippets mark hits with « and ».

Deleting a meeting cascades to speakers/turns/action_items and the triggers keep `search` in sync.
"""
import json, os, re, sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

SEP = "\n---\n"  # header/body separator in transcript.md (same as process_meeting.SEP)
NO_SPEECH = "_No speech detected._"
CLOUD_STORAGE = Path.home() / "Library" / "CloudStorage"
SNIP_OPEN, SNIP_CLOSE = "«", "»"


class LibraryError(Exception):
    pass


# ---------- schema ----------

PEOPLE_DDL = ("CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT, email TEXT, "
              "is_me INTEGER DEFAULT 0, voiceprint BLOB, n INTEGER, updated TEXT)")

SCHEMA_V1 = [
    PEOPLE_DDL,
    """CREATE TABLE meetings (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        start TEXT NOT NULL,
        duration REAL NOT NULL DEFAULT 0,
        source TEXT NOT NULL DEFAULT 'record' CHECK (source IN ('record', 'import')),
        folder TEXT UNIQUE,
        audio_path TEXT,
        raw_dir TEXT,
        template TEXT NOT NULL DEFAULT 'general',
        attendees TEXT NOT NULL DEFAULT '[]',
        user_notes TEXT NOT NULL DEFAULT '',
        notes_md TEXT NOT NULL DEFAULT '',
        summary_status TEXT NOT NULL DEFAULT 'none',
        bleed INTEGER NOT NULL DEFAULT 0,
        created TEXT NOT NULL,
        updated TEXT NOT NULL)""",
    "CREATE INDEX meetings_start ON meetings(start)",
    """CREATE TABLE speakers (
        id INTEGER PRIMARY KEY,
        meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        track TEXT, cluster TEXT, label TEXT NOT NULL,
        person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
        score REAL, kind TEXT, embedding BLOB)""",
    "CREATE INDEX speakers_meeting ON speakers(meeting_id)",
    "CREATE INDEX speakers_person ON speakers(person_id)",
    """CREATE TABLE turns (
        id INTEGER PRIMARY KEY,
        meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL,
        speaker_id INTEGER REFERENCES speakers(id) ON DELETE SET NULL,
        start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL,
        UNIQUE (meeting_id, idx))""",
    """CREATE TABLE action_items (
        id INTEGER PRIMARY KEY,
        meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        owner TEXT NOT NULL DEFAULT '', task TEXT NOT NULL, due TEXT NOT NULL DEFAULT '',
        done INTEGER NOT NULL DEFAULT 0, turn_idx INTEGER,
        exported_to TEXT, external_id TEXT)""",
    "CREATE INDEX action_items_meeting ON action_items(meeting_id)",
    """CREATE VIRTUAL TABLE search USING fts5(
        body, title, notes, user_notes,
        kind UNINDEXED, meeting_id UNINDEXED, turn_idx UNINDEXED,
        tokenize = 'unicode61 remove_diacritics 2')""",
    """CREATE TRIGGER turns_ai AFTER INSERT ON turns BEGIN
        INSERT INTO search(rowid, body, kind, meeting_id, turn_idx)
        VALUES (new.id, new.text, 't', new.meeting_id, new.idx); END""",
    """CREATE TRIGGER turns_au AFTER UPDATE OF text ON turns BEGIN
        UPDATE search SET body = new.text WHERE rowid = old.id; END""",
    "CREATE TRIGGER turns_ad AFTER DELETE ON turns BEGIN DELETE FROM search WHERE rowid = old.id; END",
    """CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
        INSERT INTO search(rowid, title, notes, user_notes, kind, meeting_id)
        VALUES (-new.id, new.title, new.notes_md, new.user_notes, 'm', new.id); END""",
    """CREATE TRIGGER meetings_au AFTER UPDATE OF title, notes_md, user_notes ON meetings BEGIN
        UPDATE search SET title = new.title, notes = new.notes_md, user_notes = new.user_notes
        WHERE rowid = -old.id; END""",
    "CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN DELETE FROM search WHERE rowid = -old.id; END",
]

# Forward migrations: MIGRATIONS[n] upgrades user_version n -> n+1. Append only; never edit a shipped one.
MIGRATIONS = [SCHEMA_V1,
              ["ALTER TABLE speakers ADD COLUMN suggested_person_id INTEGER REFERENCES people(id) ON DELETE SET NULL"],
              ["ALTER TABLE action_items ADD COLUMN external_url TEXT"],
              ["ALTER TABLE meetings ADD COLUMN pending_folder TEXT"]]


def schema_version(db):
    return db.execute("PRAGMA user_version").fetchone()[0]


def _migrate(db):
    v = schema_version(db)
    if v > len(MIGRATIONS):
        raise LibraryError(f"library.db schema v{v} is newer than this code (v{len(MIGRATIONS)})")
    for n in range(v, len(MIGRATIONS)):
        db.execute("BEGIN IMMEDIATE")
        try:
            for stmt in MIGRATIONS[n]:
                db.execute(stmt)
            db.execute(f"PRAGMA user_version = {n + 1}")
            db.execute("COMMIT")
        except BaseException:
            db.execute("ROLLBACK")
            raise


def open_db(path):
    """Open (creating/migrating) the library for writing. Autocommit mode; writers use `with tx(db)`."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path), isolation_level=None, timeout=5)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA busy_timeout = 5000")
    _migrate(db)
    return db


def connect_readonly(path):
    """Read-only connection (mcp_server). Raises sqlite3.OperationalError if the file does not exist."""
    db = sqlite3.connect(f"file:{Path(path).as_posix().replace('?', '%3f').replace('#', '%23')}?mode=ro",
                         uri=True, timeout=5)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout = 5000")
    return db


class tx:
    """`with tx(db):` = BEGIN IMMEDIATE ... COMMIT (ROLLBACK on error)."""
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.execute("BEGIN IMMEDIATE")
        return self.db

    def __exit__(self, et, ev, tb):
        self.db.execute("ROLLBACK" if et else "COMMIT")


# ---------- formatting (copied from process_meeting so the Drive files stay identical) ----------

def fmt_ts(sec):
    sec = int(max(sec, 0))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def sanitize_title(title):
    t = re.sub(r'[/:\\?*"<>|\r\n]', "-", title or "")
    t = re.sub(r"\s+", " ", t).strip()[:80].strip()
    return t or "Meeting"


def folder_name(title, start_dt):
    return f"{start_dt:%Y-%m-%d %H%M} – {sanitize_title(title)}"


def render_header(title, start_dt, duration, attendees):
    return "\n".join([f"# {title}", "",
                      f"- **Date:** {start_dt:%Y-%m-%d %H:%M} (UTC{start_dt.isoformat()[-6:]})",
                      f"- **Duration:** {fmt_ts(duration)}",
                      f"- **Attendees:** {', '.join(attendees) if attendees else '—'}"])


def neutralize_fences(s):
    """Untrusted text (transcript, calendar title, attendees, speaker names) goes inside <tag>...</tag> fences in
    prompts. Defuse every closing tag in it, whatever the tag, case or spacing (`</transcript >`, `</ TRANSCRIPT>`),
    so it cannot end its own fence."""
    return re.sub(r"<[\s\u200b-\u200d\ufeff]*/", r"<\\/", s or "")


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _norm_start(start):
    """datetime or ISO string -> ISO string with a UTC offset (naive = local time)."""
    dt = datetime.fromisoformat(start) if isinstance(start, str) else start
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt.isoformat(timespec="seconds")


def format_turns(turns):
    """Prompt/UI text: `[T12 03:41] Name: text`, one per line. turns need idx, speaker, start, text."""
    return "\n".join(f"[T{t['idx']} {fmt_ts(t['start'])}] {t['speaker']}: {t['text']}" for t in turns)


# ---------- writes ----------

def add_meeting(db, meeting, speakers=(), turns=(), action_items=()):
    """Insert a meeting with its speakers, turns and action items in ONE transaction. Returns the meeting id.

    meeting: title, start (ISO str or datetime) required; optional duration, source, folder, audio_path, raw_dir,
      template, attendees (list), user_notes, notes_md, summary_status, bleed.
    speakers: [{track, cluster, label, person_id, suggested_person_id, score, kind, embedding}] (label required).
    turns: [{speaker, start, end, text}] in order; `idx` is assigned 0..n-1. `speaker` is an int index into
      `speakers`, or a label string (matched to the first speaker with that label; an unknown label creates a
      speaker row, so the legacy "Me"/"Them"/"Room" turns from build_turns() work without a speakers list).
    action_items: [{owner, task, due, done, turn_idx}]."""
    m = dict(meeting)
    if not m.get("title") or not m.get("start"):
        raise LibraryError("meeting needs title and start")
    now = _now()
    spk = [dict(s) for s in speakers]
    with tx(db):
        cur = db.execute(
            "INSERT INTO meetings(title, start, duration, source, folder, audio_path, raw_dir, template, attendees,"
            " user_notes, notes_md, summary_status, bleed, created, updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (m["title"], _norm_start(m["start"]), float(m.get("duration") or 0), m.get("source", "record"),
             m.get("folder"), m.get("audio_path"), m.get("raw_dir"), m.get("template") or "general",
             json.dumps(list(m.get("attendees") or [])), m.get("user_notes") or "", m.get("notes_md") or "",
             m.get("summary_status") or ("ok" if m.get("notes_md") else "none"), int(bool(m.get("bleed"))), now, now))
        mid = cur.lastrowid
        ids = []

        def insert_speaker(s):
            c = db.execute("INSERT INTO speakers(meeting_id, track, cluster, label, person_id, suggested_person_id, score, kind,"
                           " embedding) VALUES (?,?,?,?,?,?,?,?,?)",
                           (mid, s.get("track"), s.get("cluster"), s["label"], s.get("person_id"),
                            s.get("suggested_person_id"), s.get("score"), s.get("kind"), s.get("embedding")))
            ids.append(c.lastrowid)
            return len(ids) - 1

        for s in spk:
            insert_speaker(s)
        by_label = {}
        for i, s in enumerate(spk):
            by_label.setdefault(s["label"], i)
        for idx, t in enumerate(turns):
            who = t.get("speaker")
            if isinstance(who, int):
                if not 0 <= who < len(ids):
                    raise LibraryError(f"turn {idx}: speaker index {who} out of range")
                sid = ids[who]
            elif who is None:
                sid = None
            else:
                if who not in by_label:
                    by_label[who] = insert_speaker({"label": str(who)})
                sid = ids[by_label[who]]
            db.execute("INSERT INTO turns(meeting_id, idx, speaker_id, start, end, text) VALUES (?,?,?,?,?,?)",
                       (mid, idx, sid, float(t["start"]), float(t.get("end", t["start"])), t["text"]))
        for a in action_items:
            _insert_action(db, mid, a)
    return mid


def _insert_action(db, mid, a):
    db.execute("INSERT INTO action_items(meeting_id, owner, task, due, done, turn_idx, exported_to, external_id, external_url)"
               " VALUES (?,?,?,?,?,?,?,?,?)",
               (mid, a.get("owner") or "", a["task"], a.get("due") or "", int(bool(a.get("done"))), a.get("turn_idx"),
                a.get("exported_to"), a.get("external_id"), a.get("external_url")))


def _touch(db, mid, **cols):
    sets = "".join(f"{k} = ?, " for k in cols)
    n = db.execute(f"UPDATE meetings SET {sets}updated = ? WHERE id = ?", (*cols.values(), _now(), mid)).rowcount
    if not n:
        raise LibraryError(f"no meeting {mid}")


def rename_meeting(db, meeting_id, title):
    """Change the title only. The Drive folder follows on the next sync_mirror()."""
    title = (title or "").strip()
    if not title:
        raise LibraryError("empty title")
    with tx(db):
        _touch(db, meeting_id, title=title)


def set_user_notes(db, meeting_id, text):
    with tx(db):
        _touch(db, meeting_id, user_notes=text or "")


def set_notes(db, meeting_id, notes_md, actions=None, status="ok", template=None):
    """Store generated notes. actions=None leaves action items alone; a list REPLACES them, keeping done /
    exported state for items whose (owner, task) is unchanged (so regenerating does not un-tick anything)."""
    with tx(db):
        cols = {"notes_md": notes_md or "", "summary_status": status}
        if template:
            cols["template"] = template
        _touch(db, meeting_id, **cols)
        if actions is not None:
            old = {(r["owner"].lower(), r["task"].lower()): r for r in
                   db.execute("SELECT * FROM action_items WHERE meeting_id = ?", (meeting_id,))}
            db.execute("DELETE FROM action_items WHERE meeting_id = ?", (meeting_id,))
            for a in actions:
                prev = old.get((a.get("owner", "").lower(), a["task"].lower()))
                if prev:
                    a = {**a, "done": prev["done"], "exported_to": prev["exported_to"], "external_id": prev["external_id"],
                         "external_url": prev["external_url"]}
                _insert_action(db, meeting_id, a)


def set_audio(db, meeting_id, audio_path=None, raw_dir=None, folder=None):
    with tx(db):
        cols = {k: v for k, v in (("audio_path", audio_path), ("raw_dir", raw_dir), ("folder", folder)) if v is not None}
        if folder is not None:
            cols["pending_folder"] = None  # the folder is in place
        if cols:
            _touch(db, meeting_id, **cols)


def set_pending_folder(db, meeting_id, path):
    """Record the Drive folder about to be renamed into place (processing only; see pending_folder)."""
    with tx(db):
        _touch(db, meeting_id, pending_folder=str(path))


def rename_speaker(db, speaker_id, name, person_id=None):
    """Relabel a speaker (so every one of its turns shows the new name). With person_id, also link the
    speaker to that person and relabel every other speaker linked to the same person, library-wide. The old label
    is also replaced by the new name in those meetings' notes_md and action owners (_relabel_text). Returns the sorted ids of meetings whose rendered files changed (re-run sync_mirror on each)."""
    name = (name or "").strip()
    if not name:
        raise LibraryError("empty name")
    with tx(db):
        row = db.execute("SELECT meeting_id, label FROM speakers WHERE id = ?", (speaker_id,)).fetchone()
        if not row:
            raise LibraryError(f"no speaker {speaker_id}")
        affected, renamed = {row["meeting_id"]}, [(row["meeting_id"], row["label"])]
        db.execute("UPDATE speakers SET label = ?, person_id = COALESCE(?, person_id) WHERE id = ?",
                   (name, person_id, speaker_id))
        if person_id is not None:
            for r in db.execute("SELECT id, meeting_id, label FROM speakers WHERE person_id = ? AND label != ?", (person_id, name)).fetchall():
                db.execute("UPDATE speakers SET label = ? WHERE id = ?", (name, r["id"]))
                affected.add(r["meeting_id"])
                renamed.append((r["meeting_id"], r["label"]))
        for mid, old in renamed:
            _relabel_text(db, mid, old, name)
        for mid in affected:
            _touch(db, mid)
    return sorted(affected)


def _relabel_text(db, mid, old, new):
    """The notes quote speakers by label ("Speaker 2 agreed..."), and action owners are labels: follow a rename.
    Whole-word and case-sensitive, so "Speaker 2" leaves "Speaker 21" alone. No Claude call; text that merely
    reads like the old label (a person called "Speaker 2" is not expected) is rewritten too."""
    if not old or old == new:
        return
    pat = re.compile(rf"(?<!\w){re.escape(old)}(?!\w)")
    sub = lambda text: pat.sub(lambda _: new, text or "")
    notes_md = db.execute("SELECT notes_md FROM meetings WHERE id = ?", (mid,)).fetchone()["notes_md"]
    if sub(notes_md) != notes_md:
        db.execute("UPDATE meetings SET notes_md = ? WHERE id = ?", (sub(notes_md), mid))
    for r in db.execute("SELECT id, owner FROM action_items WHERE meeting_id = ?", (mid,)).fetchall():
        if sub(r["owner"]) != r["owner"]:
            db.execute("UPDATE action_items SET owner = ? WHERE id = ?", (sub(r["owner"]), r["id"]))


def set_action_done(db, action_id, done=True):
    with tx(db):
        if not db.execute("UPDATE action_items SET done = ? WHERE id = ?", (int(bool(done)), action_id)).rowcount:
            raise LibraryError(f"no action item {action_id}")


def set_action_exported(db, action_id, exported_to, external_id=None, external_url=None):
    """Record that an item went to 'reminders' / 'linear' (external_id = the target's id, external_url its link)."""
    with tx(db):
        if not db.execute("UPDATE action_items SET exported_to = ?, external_id = ?, external_url = ? WHERE id = ?",
                          (exported_to, external_id, external_url, action_id)).rowcount:
            raise LibraryError(f"no action item {action_id}")


def delete_meeting(db, meeting_id):
    """Delete a meeting and everything under it (FTS follows via triggers). Returns {folder, audio_path,
    raw_dir} so the caller can remove the files, or None if there was no such meeting."""
    with tx(db):
        row = db.execute("SELECT folder, audio_path, raw_dir FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
        if not row:
            return None
        db.execute("DELETE FROM meetings WHERE id = ?", (meeting_id,))
    return dict(row)


def expire_audio(db, days, delete, now=None, exclude=()):
    """D20: for meetings processed (`created`) more than `days` days ago, delete their audio (the m4a and the raw FLAC
    dir) and forget it. Notes and transcript are never touched. days falsy = keep forever.
    Age is counted from `created`, not `start`: an imported old recording (start = the file's date) is not purged
    the moment it is imported. `exclude`: meeting ids never expired (the one being processed right now).
    `delete(path)` removes one path and returns "deleted", "absent" (nothing there) or any other word when the path
    may still exist (failed, refused). Files go first and a column is cleared only for a path that is gone, so a failed
    delete (Drive offline) or a killed run leaves the reference for the next run instead of an orphaned file.
    The database is not locked while deleting. Returns [(path, outcome)]."""
    if not days:
        return []
    cutoff = ((now or datetime.now(timezone.utc)) - timedelta(days=days))
    out = []
    for r in db.execute("SELECT id, created, audio_path, raw_dir FROM meetings"
                        " WHERE audio_path IS NOT NULL OR raw_dir IS NOT NULL").fetchall():
        if r["id"] in exclude or datetime.fromisoformat(r["created"]) >= cutoff:
            continue
        gone = {}
        for col in ("audio_path", "raw_dir"):
            if r[col]:
                res = delete(r[col])
                out.append((r[col], res))
                if res in ("deleted", "absent"):
                    gone[col] = None
        if gone:
            try:
                with tx(db):
                    _touch(db, r["id"], **gone)
            except LibraryError:  # the meeting was deleted meanwhile
                pass
    return out


# ---------- reads ----------

def get_meeting(db, meeting_id):
    """Full meeting dict: meetings columns (attendees as a list) + speakers, turns (with speaker label and
    speaker_id), actions. None if absent."""
    row = db.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
    if not row:
        return None
    m = dict(row)
    m["attendees"] = json.loads(m["attendees"] or "[]")
    m["speakers"] = [dict(r) for r in db.execute(
        "SELECT id, meeting_id, track, cluster, label, person_id, suggested_person_id, score, kind FROM speakers"
        " WHERE meeting_id = ? ORDER BY id", (meeting_id,))]
    m["turns"] = [dict(r) for r in db.execute(
        "SELECT t.idx, t.speaker_id, COALESCE(s.label, '?') AS speaker, t.start, t.end, t.text"
        " FROM turns t LEFT JOIN speakers s ON s.id = t.speaker_id WHERE t.meeting_id = ? ORDER BY t.idx", (meeting_id,))]
    m["actions"] = [dict(r) for r in db.execute("SELECT * FROM action_items WHERE meeting_id = ? ORDER BY id", (meeting_id,))]
    return m


def turns_text(db, meeting_id):
    """The transcript as `[T12 03:41] Name: text` lines, for prompts."""
    m = get_meeting(db, meeting_id)
    return format_turns(m["turns"]) if m else ""


def fts_query(text, op="OR", max_terms=32):
    """User text -> safe FTS5 MATCH string: every \\w+ token quoted with prefix matching ("tok"*), joined by
    `op`. Quoting neutralizes FTS syntax (quotes, colons, asterisks, hyphens, AND/OR/NOT/NEAR). '' if no tokens."""
    toks = re.findall(r"\w+", text or "")[:max_terms]
    return f" {op} ".join(f'"{t}"*' for t in toks)


def list_meetings(db, query=None, limit=50, offset=0):
    """Newest first; with `query`, only meetings with a hit (all words, prefix matched, in a turn, title, notes
    or typed notes), best bm25 first. Each row: id, title, start, duration, source, template, summary_status,
    folder, audio_path, open_actions; with a query also snippet («hit»), hit_turn_idx (None for a title/notes
    hit), hit_ts, rank. Ceiling: the 2000 best hits are ranked, so paging stops there."""
    cols = ("m.id, m.title, m.start, m.duration, m.source, m.template, m.summary_status, m.folder, m.audio_path,"
            " (SELECT COUNT(*) FROM action_items a WHERE a.meeting_id = m.id AND a.done = 0) AS open_actions")
    match = fts_query(query, "AND")
    if not match:
        return [dict(r) for r in db.execute(f"SELECT {cols} FROM meetings m ORDER BY m.start DESC, m.id DESC LIMIT ? OFFSET ?",
                                            (limit, offset))]
    hits = db.execute(
        "SELECT meeting_id, kind, turn_idx, bm25(search, 1.0, 4.0, 2.0, 3.0) AS rank,"
        f" snippet(search, -1, '{SNIP_OPEN}', '{SNIP_CLOSE}', '…', 16) AS snip"
        " FROM search WHERE search MATCH ? ORDER BY rank LIMIT 2000", (match,)).fetchall()
    best = {}
    for h in hits:
        best.setdefault(h["meeting_id"], h)
    out = []
    for mid, h in list(best.items())[offset:offset + limit]:
        r = db.execute(f"SELECT {cols} FROM meetings m WHERE m.id = ?", (mid,)).fetchone()
        d = dict(r)
        d.update(snippet=h["snip"], rank=h["rank"], hit_turn_idx=h["turn_idx"] if h["kind"] == "t" else None)
        t = db.execute("SELECT start FROM turns WHERE meeting_id = ? AND idx = ?", (mid, d["hit_turn_idx"])).fetchone() \
            if d["hit_turn_idx"] is not None else None
        d["hit_ts"] = fmt_ts(t["start"]) if t else None
        out.append(d)
    return out


def list_action_items(db, open_only=True, limit=100, meeting_id=None):
    """Action items with their meeting's title/start, newest meeting first."""
    where, args = [], []
    if open_only:
        where.append("a.done = 0")
    if meeting_id is not None:
        where.append("a.meeting_id = ?")
        args.append(meeting_id)
    sql = ("SELECT a.*, m.title AS meeting_title, m.start AS meeting_start FROM action_items a JOIN meetings m ON m.id = a.meeting_id"
           + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY m.start DESC, a.id LIMIT ?")
    return [dict(r) for r in db.execute(sql, (*args, limit))]


# ---------- mirror rendering ----------

def _start_dt(m):
    return datetime.fromisoformat(m["start"])


def meeting_header(m):
    return render_header(m["title"], _start_dt(m), m.get("duration") or 0, m.get("attendees") or [])


def transcript_body(m):
    turns = m.get("turns") or []
    if not turns:
        return NO_SPEECH
    return "\n\n".join(f"**[{fmt_ts(t['start'])}] {t['speaker']}:** {t['text']}" for t in turns)


def render_transcript_md(m):
    """transcript.md exactly as process_meeting writes it: header, `---`, body."""
    return f"{meeting_header(m)}\n{SEP}\n{transcript_body(m)}\n"


def render_notes_md(m):
    """notes.md exactly as process_meeting.write_notes writes it: header, notes, `## Transcript`, body."""
    notes = (m.get("notes_md") or "").strip() or "## Summary\n\n_Summary not generated yet._"
    return f"{meeting_header(m)}\n\n{notes}\n\n## Transcript\n\n{transcript_body(m)}\n"


def _write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def check_out_root(out_root):
    """Don't mkdir -p into a Drive path whose CloudStorage mount is not there (would create a fake local copy)."""
    try:
        mount = CLOUD_STORAGE / Path(out_root).relative_to(CLOUD_STORAGE).parts[0]
    except (ValueError, IndexError):
        return
    if not mount.is_dir():
        raise LibraryError(f"Drive folder not available: {out_root}")


def write_mirror(m, out_root):
    """Atomically (re)write notes.md and transcript.md in the meeting's Drive folder, creating it if needed.
    If the folder name no longer matches the title (rename) the folder and its .m4a are renamed first; the m4a
    is always <folder name>.m4a (D20). Returns {"folder", "audio_path"} (the caller stores them: sync_mirror)."""
    out_root = Path(out_root)
    check_out_root(out_root)
    out_root.mkdir(parents=True, exist_ok=True)
    want = folder_name(m["title"], _start_dt(m))
    cur = Path(m["folder"]) if m.get("folder") else None
    audio = Path(m["audio_path"]) if m.get("audio_path") else None
    if cur is None or not cur.is_dir():
        final, n = out_root / want, 1
        while final.exists():
            n += 1
            final = out_root / f"{want} ({n})"
        final.mkdir()
        cur = final
    elif cur.name != want and not re.fullmatch(re.escape(want) + r"( \(\d+\))?", cur.name):
        final, n = cur.parent / want, 1
        while final.exists():
            n += 1
            final = cur.parent / f"{want} ({n})"
        os.rename(cur, final)
        if audio is not None and audio.parent == cur:
            audio = final / audio.name
        cur = final
    if audio is not None and audio.parent == cur and audio.exists() and audio.name != f"{cur.name}.m4a":
        new = audio.with_name(f"{cur.name}.m4a")
        os.rename(audio, new)
        audio = new
    _write_atomic(cur / "transcript.md", render_transcript_md(m))
    _write_atomic(cur / "notes.md", render_notes_md(m))
    return {"folder": str(cur), "audio_path": str(audio) if audio else None}


def sync_mirror(db, meeting_id, out_root):
    """Re-render a meeting's Drive files from the DB and record the (possibly renamed) folder/audio path.
    Call after every edit: rename-meeting, rename-speaker, regenerate, import."""
    m = get_meeting(db, meeting_id)
    if not m:
        raise LibraryError(f"no meeting {meeting_id}")
    r = write_mirror(m, out_root)
    set_audio(db, meeting_id, audio_path=r["audio_path"], folder=r["folder"])
    return r


# ---------- importer for folders made by the pre-library pipeline ----------

_DATE = re.compile(r"^- \*\*Date:\*\* (\d{4}-\d\d-\d\d) (\d\d:\d\d) \(UTC([+-]\d\d:\d\d)\)\s*$", re.M)
_DUR = re.compile(r"^- \*\*Duration:\*\* (\d+(?::\d\d){1,2})\s*$", re.M)
_ATT = re.compile(r"^- \*\*Attendees:\*\* (.*)$", re.M)
_TURN = re.compile(r"^\*\*\[(\d+(?::\d\d){1,2})\] (.+?):\*\* ?(.*)$")
_ACTION = re.compile(r"^\s*[-*]\s*\[( |x|X)\]\s*(.+?)\s*$")


def parse_ts(s):
    """'03:41' / '1:03:41' -> seconds."""
    sec = 0
    for p in s.split(":"):
        sec = sec * 60 + int(p)
    return sec


def parse_action_line(line):
    """`- [ ] Owner — task — due` -> {owner, task, due, done}; None if not a checkbox line. Accepts ' - ' / ' – '
    as separators too, 2 fields (owner, task) or 1 (task), and treats — / None / n/a as no due date."""
    mo = _ACTION.match(line)
    if not mo:
        return None
    parts = [p.strip() for p in re.split(r"\s+[—–]\s+|\s+-\s+", mo.group(2))]
    if len(parts) >= 3:
        owner, task, due = parts[0], " — ".join(parts[1:-1]), parts[-1]
    elif len(parts) == 2:
        owner, task, due = parts[0], parts[1], ""
    else:
        owner, task, due = "", parts[0], ""
    if due.lower() in ("—", "–", "-", "none", "n/a", "tbd", "unknown"):
        due = ""
    if not task:
        return None
    return {"owner": owner, "task": task, "due": due, "done": int(mo.group(1) != " ")}


def parse_transcript_md(text):
    """transcript.md text -> (title, start ISO, duration, attendees, turns) in the pipeline's format."""
    header, _, body = text.partition(SEP)
    header = header.strip()
    title = header.splitlines()[0].lstrip("# ").strip() if header else ""
    d = _DATE.search(header)
    if not title or not d:
        raise LibraryError("no title/date in header")
    start = datetime.fromisoformat(f"{d.group(1)}T{d.group(2)}:00{d.group(3)}").isoformat(timespec="seconds")
    dur = _DUR.search(header)
    a = _ATT.search(header)
    attendees = [x.strip() for x in a.group(1).split(",") if x.strip()] if a and a.group(1).strip() != "—" else []
    return title, start, float(parse_ts(dur.group(1))) if dur else 0.0, attendees, _parse_turns(body)


def _parse_turns(body):
    turns = []
    for line in body.splitlines():
        if not line.strip() or line.strip() == NO_SPEECH:
            continue
        mo = _TURN.match(line)
        if mo:
            turns.append({"speaker": mo.group(2), "start": float(parse_ts(mo.group(1))), "text": mo.group(3).strip()})
        elif turns:  # continuation of a wrapped turn
            turns[-1]["text"] += " " + line.strip()
    return turns


_KIND = {"Me": ("mic", "me"), "Them": ("system", "remote"), "Room": ("mic", "room")}


def import_existing_drive_meetings(db, out_root):
    """Import every <out_root>/<folder>/ that has transcript.md (or notes.md) and is not yet in the library.
    Idempotent: keyed on the absolute folder path. Never writes to the Drive folder. The old files become a
    mirror of the DB afterwards (the next sync_mirror overwrites them). Returns
    {"imported": [ids], "skipped": n, "failed": [(folder, reason)]}."""
    out_root = Path(os.path.abspath(out_root))
    res = {"imported": [], "skipped": 0, "failed": []}
    if not out_root.is_dir():
        return res
    known = {r[0] for r in db.execute("SELECT folder FROM meetings WHERE folder IS NOT NULL")}
    for f in sorted(p for p in out_root.iterdir() if p.is_dir() and not p.name.startswith(".")):
        tm, nm = f / "transcript.md", f / "notes.md"
        if str(f) in known:
            res["skipped"] += 1
            continue
        if not tm.is_file() and not nm.is_file():
            continue
        try:
            ntext = nm.read_text() if nm.is_file() else ""
            att = _ATT.search(ntext)
            head, _, nbody = ntext.partition("\n## Transcript")
            notes_md = head[att.end():].strip() if att else ""
            status = "failed" if "Summary failed" in notes_md else ("ok" if notes_md else "none")
            if tm.is_file():
                title, start, dur, attendees, turns = parse_transcript_md(tm.read_text())
            else:  # notes.md only: header from it, turns from after "## Transcript"
                title, start, dur, attendees, _ = parse_transcript_md(head[:att.end() if att else 0] + SEP)
                turns = _parse_turns(nbody)
            for i, t in enumerate(turns):  # end = next turn's start (last = meeting end)
                t["end"] = turns[i + 1]["start"] if i + 1 < len(turns) else max(dur, t["start"])
            labels = list(dict.fromkeys(t["speaker"] for t in turns))
            spk = [{"label": l, "track": _KIND.get(l, (None, "other"))[0], "kind": _KIND.get(l, (None, "other"))[1]} for l in labels]
            for t in turns:
                t["speaker"] = labels.index(t["speaker"])
            audio = next(iter(sorted(f.glob("*.m4a"))), None)
            actions = [a for a in map(parse_action_line, notes_md.splitlines()) if a]
            mid = add_meeting(db, {"title": title, "start": start, "duration": dur, "attendees": attendees,
                                   "source": "import" if "Room" in labels else "record", "folder": str(f),
                                   "audio_path": str(audio) if audio else None, "notes_md": notes_md,
                                   "summary_status": status}, spk, turns, actions)
            res["imported"].append(mid)
        except (OSError, ValueError, LibraryError, sqlite3.Error) as e:
            res["failed"].append((str(f), str(e)))
    return res
