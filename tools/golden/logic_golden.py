#!/usr/bin/env python3
"""Golden fixtures for the pure-logic Swift port (Port/Turns.swift, Echo.swift, Voiceprints.swift).

Runs the Python oracle (process_meeting.py, echo.py, speakers.py) and writes JSON next to the Swift tests:
    cd <repo root> && .venv/bin/python tools/golden/logic_golden.py [out_dir]
Default out_dir: eavesdroppy/Tests/EavesdroppyTests/Fixtures/logic. Deterministic (seeded); re-running changes nothing.
Dicts that Python orders by insertion are written as [[key, value], ...] so the order survives JSON.
"""
import json
import os
import random
import sqlite3
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import echo  # noqa: E402
import notes  # noqa: E402
import process_meeting as pm  # noqa: E402
import speakers  # noqa: E402

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "eavesdroppy/Tests/EavesdroppyTests/Fixtures/logic"
REAL = Path.home() / "Library/Application Support/Droppy/Droplets/eavesdroppy/Container/raw/20261013-123545-736-0001"


def dump(name, obj):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_text(json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False) + "\n")


def f(x):  # float32 / numpy scalar -> exact python float
    return None if x is None else float(x)


# ================= turns =================
def words_json(ws):
    return [[w["text"], w["start"], w["end"]] for w in ws]


def W(t, s, e):
    return {"text": t, "start": s, "end": e}


def build_case(name, tracks, offsets=None):
    offsets = offsets or {}
    out = pm.build_turns(tracks, offsets)
    return {"name": name, "tracks": [[k, words_json(v)] for k, v in tracks.items()],
            "offsets": [[k, v] for k, v in offsets.items()],
            "expected": [{"speaker": t["speaker"], "start": t["start"], "end": t["end"], "text": t["text"]} for t in out]}


VOCAB = ["the", "a", "Yes", "ok.", "Really?", "go!", "hello,", "Zürich", "naïve", "I'm", "don't", "—", "x", "42", "end.", "Wait...", "so", "and"]


def rand_words(rng, n, gapmax, lenmax=0.9, t0=0.0):
    t, ws = t0, []
    for _ in range(n):
        t += rng.choice([0.0, 0.05, 0.2, 0.5, 0.9, 1.0, 1.0001, 1.5, 4.0, 8.0, 9.5, 25.0]) * rng.random() * gapmax
        d = rng.choice([0.0, 0.1, 0.3, lenmax, 1.5])
        ws.append(W(rng.choice(VOCAB), round(t, 3), round(t + d, 3)))
        t += d * rng.random()
    return ws


def turns_fixture():
    cases = []
    cases.append(build_case("empty", {}))
    cases.append(build_case("empty tracks with offset", {0: [], 1: []}, {0: 1.0}))
    cases.append(build_case("single word", {0: [W("hi", 0, 0.5)]}))
    cases.append(build_case("zero-length words", {0: [W("a", 1, 1), W("b", 1, 1), W("c", 1.5, 1.5)]}))
    cases.append(build_case("two tracks merge/split", {0: [W("hi", 0, 0.5), W("there", 0.5, 1.0), W("ok", 10, 10.5)],
                                                      1: [W("yo", 2, 2.5)]}))
    cases.append(build_case("offset orders speakers", {0: [W("a", 1, 2)], 1: [W("b", 0, 1)]}, {0: 0, 1: 2.0}))
    cases.append(build_case("negative offset", {0: [W("a", 0, 1), W("b", 2.0, 3)], 1: [W("x", 5, 6)]}, {0: -0.5, 1: -10.0}))
    cases.append(build_case("interleaved speakers", {0: [W("a", 0, 1), W("b", 2.5, 3)], 1: [W("x", 1.5, 2)]}))
    cases.append(build_case("turn gap exactly 8 merges", {0: [W("a", 0, 1), W("b", 9.0, 10)]}))
    cases.append(build_case("turn gap 8.5 splits", {0: [W("a", 0, 1), W("b", 9.5, 10)]}))
    cases.append(build_case("utterance gap exactly 1.0 stays one", {0: [W("a", 0, 1), W("b", 2.0, 3)]}))
    cases.append(build_case("utterance gap just over 1.0 splits", {0: [W("a", 0, 1), W("b", 2.0000001, 3)]}))
    cases.append(build_case("sparse 5 s words every 7 s", {0: [W(str(i), i * 7, i * 7 + 5) for i in range(20)]}))
    run = []
    for i in range(80):
        run.append(W(f"w{i}" + ("." if i % 9 == 8 else ""), 0.5 * i, 0.5 * i + 0.5))
    cases.append(build_case("gapless sentences past 20 s", {0: run}))
    cases.append(build_case("no punctuation, forced at 40 s", {0: [W("w", 0.6 * i, 0.6 * i + 0.5) for i in range(108)]}))
    cases.append(build_case("18 s gapless no split", {0: [W("w", 0.6 * i, 0.6 * i + 0.5) for i in range(30)]}))
    cases.append(build_case("unsorted input", {0: [W("c", 4, 5), W("a", 0, 1), W("b", 2, 3)]}))
    cases.append(build_case("same start, two speakers", {0: [W("a", 1, 2)], 1: [W("b", 1, 2)], 2: [W("c", 1, 1.5)]}))
    cases.append(build_case("same start same speaker keeps order", {0: [W("a", 1, 2), W("b", 1, 1.5), W("c", 1, 3)]}))
    cases.append(build_case("overlapping words", {0: [W("a", 0, 3), W("b", 1, 2), W("c", 2.5, 2.6)]}))
    cases.append(build_case("end before start", {0: [W("a", 2, 1), W("b", 2.2, 3)]}))
    cases.append(build_case("merge cap 30 s", {0: [W("s", i * 6, i * 6 + 1) for i in range(12)]}))
    cases.append(build_case("sentence end exactly at 20 s", {0: [W("a", 0, 10), W("b.", 10, 20), W("c", 20, 21)]}))
    cases.append(build_case("question mark and bang split", {0: [W("a?", 0, 10), W("b", 10, 21), W("c!", 21, 22), W("d", 22, 23)]}))
    rng = random.Random(1)
    for i in range(300):
        tracks = {k: rand_words(rng, rng.choice([0, 1, 3, 12, 60]), rng.choice([0.2, 1.0, 3.0])) for k in range(rng.choice([1, 2, 3]))}
        offs = {k: round(rng.uniform(-3, 3), 3) for k in tracks if rng.random() < 0.5}
        cases.append(build_case(f"fuzz {i}", tracks, offs))

    aligns = []

    def A(name, raw, text):
        out = pm.align_words(raw, text)
        aligns.append({"name": name, "raw": [list(r) for r in raw], "text": text,
                       "expected": [[w["text"], w["start"], w["end"]] for w in out]})

    A("empty", [], "")
    A("empty raw, text", [], "hello there")
    A("raw, empty text", [("hello", 0.0, 0.4)], "")
    A("identical", [("we", 0, 0.3), ("use", 0.4, 0.7), ("data", 0.8, 1.2)], "we use data")
    A("replace one", [("we", 0, 0.3), ("use", 0.4, 0.7), ("data", 0.8, 1.2), ("now", 1.3, 1.6)], "we use Detta now")
    A("replace one with two", [("we", 0, 0.3), ("use", 0.4, 0.7), ("data", 0.8, 1.2), ("now", 1.3, 1.6)], "we use Detta app now")
    A("insertion", [("we", 0, 0.3), ("use", 0.4, 0.7), ("now", 1.3, 1.6)], "we use the Detta app now")
    A("insertion at start", [("use", 1.0, 1.4)], "so we use")
    A("deletion", [("a", 0, 1), ("b", 1, 2), ("c", 2, 3)], "a c")
    A("clamp long word", [("a", 0.0, 5.0), ("b", 5.0, 5.2)], "a b")
    A("clamp to next start", [("a", 0.0, 1.0), ("b", 0.5, 0.9)], "a b")
    A("end before start", [("a", 2.0, 1.0), ("b", 3.0, 4.0)], "a b")
    A("punctuation and case ignored", [("region", 0, 1), ("then", 1, 2), ("go", 2, 3), ("slow", 3, 4)], "the region. Then go slow")
    A("punctuation-only token", [("a", 0, 1), ("b", 1, 2)], "a — b")
    A("unicode keys", [("zurich", 0, 1), ("cafe", 1, 2)], "Zürich Café")
    A("underscore and digits", [("x_1", 0, 1), ("42", 1, 2)], "X_1 42!")
    A("repeated words", [("the", 0, 0.2), ("the", 0.3, 0.5), ("the", 0.6, 0.8), ("cat", 0.9, 1.2)], "the the cat")
    A("tie between matches", [("a", 0, 1), ("b", 1, 2), ("a", 2, 3), ("b", 3, 4)], "b a")
    A("whitespace", [("a", 0, 1), ("b", 1, 2)], "  a \n\t b  ")
    mono = [(f"w{i}", i * 0.5, i * 0.5 + 0.5) for i in range(100)]
    A("100 words, rewrite middle", mono, " ".join(w for w, _, _ in mono).replace("w50 w51 w52", "Foo Bar"))
    rng = random.Random(2)
    for i in range(300):
        n = rng.choice([0, 1, 2, 5, 12, 40])
        raw, t = [], 0.0
        for _ in range(n):
            t += rng.choice([0.0, 0.1, 0.5, 2.0])
            d = rng.choice([0.0, 0.2, 0.9, 3.0])
            raw.append((rng.choice(["the", "a", "of", "data", "Detta", "go", "x", "ok", "um"]), round(t, 3), round(t + d, 3)))
            t += d * rng.random()
        toks = [w for w, _, _ in raw]
        out = []
        for tk in toks:
            r = rng.random()
            if r < 0.15:
                continue
            if r < 0.3:
                out.append(tk.upper() + rng.choice(["", ".", ","]))
            elif r < 0.4:
                out += [tk, rng.choice(["the", "new", "—", "Q."])]
            elif r < 0.5:
                out.append(rng.choice(["Detta", "foo", "bar baz"]))
            else:
                out.append(tk)
        A(f"fuzz {i}", raw, " ".join(out))
    return {"build": cases, "align": aligns}


# ================= voiceprints =================
DIM = 32


def unit64(v):
    return v / np.linalg.norm(v)


def make_identity(rng):
    return unit64(np.array([rng.gauss(0, 1) for _ in range(DIM)]))


def with_cos(rng, base, c):
    """A unit vector whose cosine with `base` is c (float64), as float32 list."""
    w = np.array([rng.gauss(0, 1) for _ in range(DIM)])
    w = unit64(w - (w @ base) * base)
    return unit64(c * base + np.sqrt(1 - c * c) * w)


def vec(a):
    return [float(x) for x in np.asarray(a, dtype=np.float32)]


def new_db():
    c = sqlite3.connect(":memory:")
    c.execute(speakers.SCHEMA)
    return c


def db_people(c):
    out = []
    for pid, name, email, is_me, blob, n in c.execute("SELECT id, name, email, is_me, voiceprint, n FROM people ORDER BY id"):
        out.append({"id": pid, "name": name, "email": email, "is_me": bool(is_me), "n": n or 0,
                    "voiceprint": None if blob is None else [float(x) for x in np.frombuffer(blob, dtype=np.float32)]})
    return out


def diar_json(d):
    return {"segments": [[s, e, c] for s, e, c in d["segments"]], "embeddings": [[c, vec(e)] for c, e in d["embeddings"].items()]}


def rec_json(r):
    return {"track": r["track"], "cluster_id": r["cluster_id"], "label": r["label"], "person_id": r["person_id"],
            "score": r["score"], "kind": r["kind"], "speech_s": r["speech_s"], "named_by": r.get("named_by"),
            "has_embedding": r.get("embedding") is not None}


def near_threshold(scores, margin=2e-3):
    return any(abs(s - t) < margin for s in scores for t in (speakers.AUTO_THR, speakers.SUGGEST_THR, speakers.ME_THR))


def pair_scores(embs, prints):
    return [float(speakers._unit(a) @ speakers._unit(b)) for a in embs for b in prints]


def make_diar(rng, ids, cids_per_track, with_noemb=False):
    """ids: list of identity vectors to draw from. Returns (tracks dict, all embeddings list)."""
    tracks, embs = {}, []
    for track, n in cids_per_track.items():
        segs, emb, t = [], {}, 0.0
        for i in range(n):
            cid = f"S{i + 1}" if track == "mic" else f"S{i + 1}"
            idn = rng.choice(ids)
            e = np.asarray(with_cos(rng, idn, rng.choice([0.97, 0.9, 0.82, 0.7, 0.66, 0.5, 0.3])), dtype=np.float32)
            for _ in range(rng.choice([1, 2, 3])):
                d = rng.choice([0.4, 1.0, 3.5, 9.0, 12.0])
                segs.append((round(t, 3), round(t + d, 3), cid))
                t += d + rng.choice([0.0, 0.5, 2.0])
            if not (with_noemb and i == n - 1 and rng.random() < 0.5):
                emb[cid] = speakers._unit(e)
                embs.append(emb[cid])
        rng.shuffle(segs)
        segs.sort()
        tracks[track] = {"segments": segs, "embeddings": emb}
    return tracks, embs


def voiceprint_fixture():
    out = {}
    # ---- match + update_print on hand cases
    rng = random.Random(10)
    ids = [make_identity(rng) for _ in range(4)]
    match_cases = []
    for k in range(60):
        c = new_db()
        prints = []
        for j in range(rng.choice([0, 1, 2, 4])):
            e = np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.99, 0.9, 0.8, 0.7])), dtype=np.float32)
            speakers.add_person(c, f"P{j}", e, is_me=(j == 1 and rng.random() < 0.5))
            prints.append(e)
        if rng.random() < 0.15:
            speakers.add_person(c, "NoPrint")
        q = np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.98, 0.92, 0.85, 0.7, 0.65, 0.5, 0.2, -0.3])), dtype=np.float32) * rng.choice([1.0, 1.0, 2.5])
        if near_threshold(pair_scores([q], prints) if prints else []):
            continue
        for inc in (True, False):
            pid, score, kind = speakers.match(q, c, include_me=inc)
            match_cases.append({"query": vec(q), "people": db_people(c), "include_me": inc,
                                "expected": {"person_id": pid, "score": score, "kind": kind}})
    # tie: two identical prints, first wins
    e = np.asarray(with_cos(rng, ids[0], 0.99), dtype=np.float32)
    c = new_db()
    speakers.add_person(c, "A", e)
    speakers.add_person(c, "B", e)
    pid, score, kind = speakers.match(e, c)
    match_cases.append({"query": vec(e), "people": db_people(c), "include_me": True, "expected": {"person_id": pid, "score": score, "kind": kind}})
    # first print with negative cosine is still accepted, later ones need to beat it
    c = new_db()
    a = np.asarray(with_cos(rng, ids[0], -0.4), dtype=np.float32)
    b = np.asarray(with_cos(rng, ids[0], -0.6), dtype=np.float32)
    speakers.add_person(c, "A", a)
    speakers.add_person(c, "B", b)
    pid, score, kind = speakers.match(ids[0].astype(np.float32), c)
    match_cases.append({"query": vec(ids[0]), "people": db_people(c), "include_me": True, "expected": {"person_id": pid, "score": score, "kind": kind}})
    # wrong-length print is skipped
    c = new_db()
    speakers.add_person(c, "Short", np.ones(5, dtype=np.float32))
    speakers.add_person(c, "Right", e)
    pid, score, kind = speakers.match(e, c)
    match_cases.append({"query": vec(e), "people": db_people(c), "include_me": True, "expected": {"person_id": pid, "score": score, "kind": kind}})
    out["match"] = match_cases

    upd = []
    for k in range(40):
        c = new_db()
        e0 = np.asarray(with_cos(rng, rng.choice(ids), 0.9), dtype=np.float32)
        speakers.add_person(c, "P", e0 if rng.random() < 0.8 else None)
        start, steps = db_people(c)[0], []
        for _ in range(rng.choice([1, 2, 5])):
            e = np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.95, 0.8, 0.3])), dtype=np.float32) * rng.choice([1.0, 3.0])
            w = rng.choice([1, 1, 1, 2, 5])
            speakers.update_print(c, 1, e, weight=w)
            steps.append({"embedding": vec(e), "weight": w, "after": db_people(c)[0]})
        upd.append({"start": start, "steps": steps})
    c = new_db()
    speakers.add_person(c, "Empty")
    start = db_people(c)[0]
    e = np.asarray(with_cos(rng, ids[0], 0.9), dtype=np.float32)
    speakers.update_print(c, 1, e)
    s1 = {"embedding": vec(e), "weight": 1, "after": db_people(c)[0]}
    out["update"] = upd + [{"start": start, "steps": [s1]}]

    # ---- assign_speakers scenarios
    scen = []

    def scenario(name, tracks, people_spec, source, bleed, update):
        c = new_db()
        for sp in people_spec:
            speakers.add_person(c, sp["name"], sp.get("emb"), email=sp.get("email"), is_me=sp.get("is_me", False))
        people0 = db_people(c)
        recs = speakers.assign_speakers(tracks, c, [], source, bleed, update=update)
        scen.append({"name": name, "tracks": [[k, diar_json(v)] for k, v in tracks.items()], "people": people0,
                     "source": source, "bleed": bleed, "update": update, "recs": [rec_json(r) for r in recs],
                     "learnable": [[p, vec(e)] for p, e in speakers.learnable(recs, bleed)],
                     "people_after": db_people(c)})

    rng = random.Random(11)
    kinds = set()
    attempts = 0
    while len(scen) < 140 and attempts < 4000:
        attempts += 1
        ids = [make_identity(rng) for _ in range(rng.choice([2, 3, 4]))]
        tracks, embs = make_diar(rng, ids, {"mic": rng.choice([0, 1, 2, 3]), "system": rng.choice([0, 1, 2, 3])}, with_noemb=True)
        if rng.random() < 0.15:
            tracks.pop(rng.choice(["mic", "system"]))
        spec = []
        for j in range(rng.choice([0, 1, 2, 3])):
            spec.append({"name": f"Person {j}", "emb": np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.98, 0.9, 0.82, 0.7, 0.66, 0.5])), dtype=np.float32),
                         "email": None, "is_me": False})
        if rng.random() < 0.5:
            spec.insert(rng.randrange(len(spec) + 1), {"name": rng.choice(["Fahad", "Me"]), "is_me": True,
                        "emb": None if rng.random() < 0.1 else np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.97, 0.85, 0.7, 0.62, 0.4])), dtype=np.float32)})
        prints = [s["emb"] for s in spec if s.get("emb") is not None]
        allemb = [e for t in tracks.values() for e in t["embeddings"].values()]
        if near_threshold(pair_scores(allemb, prints)):
            continue
        source, bleed, update = rng.choice(["record", "import"]), rng.random() < 0.4, rng.random() < 0.5
        scenario(f"random {len(scen)}", tracks, spec, source, bleed, update)
        for r in scen[-1]["recs"]:
            kinds.add(r["kind"])
    assert {"me", "assumed", "auto", "suggest", "new"} <= kinds, kinds

    # hand scenarios
    rng = random.Random(12)
    idn = [make_identity(rng) for _ in range(3)]
    e_me = np.asarray(with_cos(rng, idn[0], 0.99), dtype=np.float32)
    mic_me = speakers._unit(np.asarray(with_cos(rng, idn[0], 0.9), dtype=np.float32))
    other = speakers._unit(np.asarray(with_cos(rng, idn[1], 0.9), dtype=np.float32))
    segs = lambda *c: [(i * 5.0, i * 5.0 + 4.0, cid) for i, cid in enumerate(c)]
    scenario("no tracks", {}, [], "record", False, True)
    scenario("empty diarization", {"mic": {"segments": [], "embeddings": {}}}, [], "record", False, True)
    scenario("Me on mic, other on system", {"mic": {"segments": segs("S1"), "embeddings": {"S1": mic_me}},
                                           "system": {"segments": segs("S1"), "embeddings": {"S1": other}}},
             [{"name": "Fahad", "emb": e_me, "is_me": True}], "record", False, True)
    scenario("Me on system only (import)", {"mic": {"segments": segs("S1"), "embeddings": {"S1": other}},
                                           "system": {"segments": segs("S1"), "embeddings": {"S1": mic_me}}},
             [{"name": "Fahad", "emb": e_me, "is_me": True}], "import", False, True)
    scenario("Me bleed blocks mic learning", {"mic": {"segments": segs("S1"), "embeddings": {"S1": mic_me}}},
             [{"name": "Fahad", "emb": e_me, "is_me": True}], "record", True, True)
    scenario("assumed Me = dominant mic cluster", {"mic": {"segments": [(0, 2, "S1"), (3, 20, "S2")], "embeddings": {"S1": mic_me, "S2": other}}},
             [], "record", False, True)
    scenario("assumed tie: first cluster", {"mic": {"segments": [(0, 5, "S1"), (6, 11, "S2")], "embeddings": {"S2": other, "S1": mic_me}}},
             [], "record", False, True)
    scenario("import without Me: no assumption", {"mic": {"segments": [(0, 5, "S1")], "embeddings": {"S1": mic_me}}}, [], "import", False, True)
    scenario("numbering by first start across tracks", {
        "mic": {"segments": [(30, 31, "S1"), (50, 52, "S2")], "embeddings": {"S1": other, "S2": speakers._unit(np.asarray(with_cos(rng, idn[2], 0.9), dtype=np.float32))}},
        "system": {"segments": [(10, 12, "S1")], "embeddings": {"S1": speakers._unit(np.asarray(with_cos(rng, idn[2], 0.5), dtype=np.float32))}}},
             [], "import", False, True)
    scenario("embedding order decides ties in numbering", {
        "system": {"segments": [(5, 6, "B"), (5, 6, "A")], "embeddings": {"B": other, "A": mic_me}}}, [], "import", False, True)
    # boundary: cosine exactly representable around the suggest threshold
    ax = np.zeros(DIM, dtype=np.float32)
    ax[0] = 1.0
    q = np.zeros(DIM, dtype=np.float32)
    q[0], q[1] = 0.6, 0.8
    scenario("cosine 0.6 boundary", {"system": {"segments": [(0, 3, "S1")], "embeddings": {"S1": speakers._unit(q)}}},
             [{"name": "Axis", "emb": ax}], "import", False, False)
    out["assign"] = scen

    # ---- words_to_speakers
    w2s = []
    rng = random.Random(13)
    for k in range(80):
        segs_ = []
        t = 0.0
        for i in range(rng.choice([0, 1, 3, 6])):
            s = t + rng.choice([0.0, 0.5, 2.0])
            e_ = s + rng.choice([0.3, 1.0, 4.0])
            segs_.append((round(s, 3), round(e_, 3), f"S{rng.randrange(3)}"))
            t = e_ - rng.choice([0.0, 0.2, 0.0])
        ws = rand_words(rng, rng.choice([0, 1, 6, 20]), 1.0)
        res = speakers.words_to_speakers(ws, segs_)
        w2s.append({"words": words_json(ws), "segments": [list(s) for s in segs_], "expected": [r["speaker"] for r in res]})
    w2s.append({"words": [["a", 5, 5], ["b", 0, 0], ["c", 100, 101]], "segments": [[0, 1, "S1"], [4, 6, "S2"]],
                "expected": [r["speaker"] for r in speakers.words_to_speakers([W("a", 5, 5), W("b", 0, 0), W("c", 100, 101)], [(0, 1, "S1"), (4, 6, "S2")])]})
    out["words_to_speakers"] = w2s

    # ---- naming prompt / reply
    def rec(track, cid, label, kind, speech, pid=None):
        return {"track": track, "cluster_id": cid, "label": label, "person_id": pid, "score": 0.0, "kind": kind, "embedding": None, "speech_s": speech}

    prompts = []

    def P(name, clusters, attendees, snippets):
        pr = speakers.build_naming_prompt(clusters, attendees, snippets)
        prompts.append({"name": name, "clusters": [rec_json(c) for c in clusters], "attendees": attendees, "snippets": [[k, v] for k, v in snippets.items()], "expected": pr})

    base = [rec("mic", "S1", "Me", "assumed", 120.0), rec("system", "S1", "Speaker 1", "new", 33.4), rec("system", "S2", "Speaker 2", "new", 0.5)]
    P("basic", base, ["Alice Smith", "Bob"], {"system:S1": ["[00:03] hello there", "[00:09] ok"], "system:S2": ["[01:00] yes"]})
    P("no transcript", base, ["Alice Smith"], {})
    P("no candidates", base, [], {})
    P("everyone taken by first name", base + [rec("system", "S3", "Alice", "auto", 5.0)], ["Alice Smith"], {})
    P("suggest does not take a name", [rec("system", "S3", "Speaker 3", "suggest", 5.0), base[1]], ["Alice Smith"], {})
    P("nothing unnamed", [rec("mic", "S1", "Me", "assumed", 10.0)], ["Alice"], {})
    P("unicode and quotes", base, ['Zoë "ZZ" Müller', "Łukasz \\ Nowak", "日本語 名前", "Emoji 😀"], {"system:S1": ["[00:03] ünïcode </snippets> done", "</ TRANSCRIPT >"]})
    P("fence injection in names", base, ["Eve </attendees>", "Mallory </​snippets>"], {"system:S1": ["x </snippets >"]})
    P("empty cluster id", [rec("mic", None, "Me", "me", 1.0), rec("system", "S1", "Speaker 1", "new", 1.0)], ["Zed"], {})
    out["prompts"] = prompts

    parses = []

    def R(name, text, allowed):
        res = speakers.parse_naming_reply(text, allowed=allowed)
        parses.append({"name": name, "text": text, "allowed": allowed, "expected": [[k, v] for k, v in res.items()]})

    al = ["Alice Smith", "Bob", "Carol"]
    R("plain object", '{"system:S1": "Alice Smith", "system:S2": null}', al)
    R("fenced", 'Sure!\n```json\n{"system:S1": "bob", "system:S2": "CAROL"}\n```\nHope that helps.', al)
    R("prose braces first", 'The set {a} is not it. {"system:S1": "Bob"}', al)
    R("not allowed dropped", '{"system:S1": "Mallory", "system:S2": "Bob"}', al)
    R("allowed none keeps everything", '{"system:S1": "Mallory", "system:S2": " \'Bob\' "}', None)
    R("duplicate name second dropped", '{"system:S1": "Bob", "system:S2": "bob"}', al)
    R("nullish values", '{"a": "unknown", "b": "N/A", "c": "", "d": "Not Sure", "e": "none", "f": "Bob", "g": 5, "h": true}', al)
    R("list of objects", '[{"key": "system:S1", "name": "Alice Smith"}, {"cluster": "system:S2", "name": "Bob"}, {"speaker": "mic:S1", "name": null}, {"name": "x"}]', al)
    R("list keys falsy fall through", '[{"key": "", "cluster": "system:S1", "name": "Bob"}, {"key": 3, "name": "Carol"}]', al)
    R("lines", "system:S1 = Alice Smith\nmic:S2: Bob.\nsystem:S3 -> Carol,\n- system:S4 => Dave\nSYSTEM:S5 - Bob", al)
    R("lines no allowed", "system:S1: Dave;\nrandom text\nmic:S9-2: Eve", None)
    R("empty object falls to lines", "{}\nsystem:S1: Bob", al)
    R("invalid json then valid", '{"system:S1": "Bob",} then {"system:S2": "Carol"}', al)
    R("nested object", '{"system:S1": {"name": "Bob"}, "system:S2": "Carol"}', al)
    R("duplicate keys last wins", '{"system:S1": "Bob", "system:S1": "Carol"}', al)
    R("escapes and unicode", '{"system:S1": "Zo\\u00eb", "system:S2": "Bo\\"b"}', ["Zoë", 'Bo"b'])
    R("nan and numbers", '{"a": NaN, "b": -1.5e3, "c": [1, 2], "system:S1": "Bob"}', al)
    R("empty", "", al)
    R("no match", "I could not tell.", al)
    R("trailing garbage", '{"system:S1": "Bob"} trailing', al)
    R("control char in string invalid", '{"system:S1": "Bo\nb"} {"system:S2": "Carol"}', al)
    out["parse_reply"] = parses

    names_cases = []
    clusters = [rec("mic", "S1", "Me", "assumed", 100.0), rec("system", "S1", "Speaker 1", "new", 33.0), rec("system", "S2", "Speaker 2", "suggest", 3.0),
                rec("system", "S3", "Speaker 3", "new", 4.0), rec("system", "S4", "Dana", "auto", 4.0)]
    for nm in ({"system:S1": "Alice", "system:S2": "Bob", "mic:S1": "Zed", "system:S4": "Q"}, {}, {"system:S3": "Carol"}):
        res = speakers.apply_names(clusters, nm)
        names_cases.append({"clusters": [rec_json(c) for c in clusters], "names": [[k, v] for k, v in nm.items()], "expected": [rec_json(r) for r in res]})
    out["apply_names"] = names_cases

    # ---- assemble (process_meeting.assemble with a stubbed provider call)
    out["assemble"] = assemble_cases()
    return out


def assemble_cases():
    cases = []
    rng = random.Random(14)

    def run(name, words_by_track, diar_by_track, spec, attendees, source, bleed, offsets, labels, participants=(), auto_naming=True,
            user_name="Fahad", reply=None):
        c = new_db()
        for sp in spec:
            speakers.add_person(c, sp["name"], sp.get("emb"), email=sp.get("email"), is_me=sp.get("is_me", False))
        people0 = db_people(c)
        seen = {"prompt": None, "cands": None}
        real_run, real_bnp = notes.run_claude, speakers.build_naming_prompt

        def bnp(clusters, cands, snippets):
            seen["cands"] = list(cands)
            return real_bnp(clusters, cands, snippets)

        def fake_run(prompt, timeout=None):
            seen["prompt"] = prompt
            return (reply, None) if reply is not None else (None, "stubbed failure")

        notes.run_claude, speakers.build_naming_prompt = fake_run, bnp
        warnings = []
        try:
            recs, turns = pm.assemble(words_by_track, diar_by_track, c, attendees, source, bleed, offsets, labels, warnings,
                                      participants=participants, auto_naming=auto_naming, user_name=user_name)
        finally:
            notes.run_claude, speakers.build_naming_prompt = real_run, real_bnp
        cases.append({"name": name,
                      "words_by_track": [[t, words_json(w)] for t, w in words_by_track.items()],
                      "diar_by_track": [[t, None if d is None else diar_json(d)] for t, d in diar_by_track.items()],
                      "people": people0, "attendees": attendees, "participants": list(participants), "source": source, "bleed": bleed,
                      "offsets": [[k, v] for k, v in offsets.items()], "labels": [[k, v] for k, v in labels.items()],
                      "auto_naming": auto_naming, "user_name": user_name, "reply": reply,
                      "expected": {"recs": [rec_json(r) for r in recs],
                                   "turns": [{"speaker": t["speaker"], "start": t["start"], "end": t["end"], "text": t["text"]} for t in turns],
                                   "prompt": seen["prompt"], "candidates": seen["cands"], "warnings": warnings}})

    labels = {"mic": "Me", "system": "Them"}
    for k in range(60):
        ids = [make_identity(rng) for _ in range(3)]
        tracks, embs = make_diar(rng, ids, {"mic": rng.choice([0, 1, 2]), "system": rng.choice([0, 1, 2, 3])}, with_noemb=True)
        spec = [{"name": f"Known {j}", "emb": np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.98, 0.9, 0.7, 0.5])), dtype=np.float32)} for j in range(rng.choice([0, 1, 2]))]
        if rng.random() < 0.4:
            spec.append({"name": "Fahad", "email": "fahad@example.com", "is_me": True,
                         "emb": np.asarray(with_cos(rng, rng.choice(ids), rng.choice([0.97, 0.7, 0.4])), dtype=np.float32)})
        allemb = [e for t in tracks.values() for e in t["embeddings"].values()]
        if near_threshold(pair_scores(allemb, [s["emb"] for s in spec])):
            continue
        words = {}
        for track in ("mic", "system"):
            if rng.random() < 0.9:
                words[track] = rand_words(rng, rng.choice([0, 3, 15, 40]), 1.0)
        # clamp so every word sits roughly in the diarized time range
        diar = {}
        for track in words:
            r = rng.random()
            diar[track] = tracks.get(track) if r < 0.85 else None
            if diar[track] is None and r < 0.9:
                diar[track] = {"segments": [], "embeddings": {}}
        attendees = rng.choice([[], ["Alice Smith", "Bob Jones"], ["Fahad Sheikh", "Alice Smith", "fahad"], ["Alice Smith", "alice smith "]])
        parts = rng.choice([[], ["Bob Jones", "Zed"], ["  ", "Alice Smith"]])
        offsets = rng.choice([{}, {"mic": 0.137, "system": 0.179}, {"system": 2.5}, {"mic": -1.0}])
        reply = rng.choice([None, '{"system:S1": "Alice Smith", "system:S2": "Bob Jones", "mic:S1": "Zed"}', '{"system:S1": "Zed"}'])
        run(f"random {k}", words, diar, spec, attendees, rng.choice(["record", "import"]), rng.random() < 0.3, offsets, labels, parts,
            auto_naming=rng.random() < 0.85, reply=reply)
    # words in a cluster that was never kept -> fallback record
    ids = [make_identity(rng) for _ in range(2)]
    e1 = speakers._unit(np.asarray(with_cos(rng, ids[0], 0.9), dtype=np.float32))
    diar = {"system": {"segments": [(0, 2, "S1"), (3, 5, "S2")], "embeddings": {"S1": e1}}}
    run("cluster without embedding falls back", {"system": [W("a", 0.1, 0.5), W("b", 3.2, 3.6)]}, diar, [], ["Alice"], "import", False, {}, labels)
    run("diarization failed: one speaker per track", {"mic": [W("hi", 0, 1)], "system": [W("yo", 2, 3)]}, {}, [], [], "record", False, {"system": 0.3}, labels)
    run("custom label Room", {"mic": [W("hi", 0, 1)]}, {}, [], [], "import", False, {}, {"mic": "Room"})
    run("unknown label", {"mic": [W("hi", 0, 1)]}, {}, [], [], "import", False, {}, {"mic": "Zed"})
    return cases


# ================= echo =================
def lcg(seed, n):
    x, out = seed & 0xFFFFFFFF, np.empty(n)
    for i in range(n):
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (x >> 8) / 16777216.0 * 2 - 1
    return out


def synth(r):
    """The recipe the Swift test repeats (EchoTests.synth)."""
    n = int(round(r["seconds"] * 16000))
    n1, n2, n3 = (lcg(s, n) for s in r["seeds"])
    blk = np.arange(n) // 4000
    gs = np.where((blk * 7 + 3) % 5 < 3, 1.0, 0.1)
    gn = np.where((blk * 11 + 1) % 4 < 2, 1.0, 0.05)
    for a, b in r.get("silent", []):
        gs[int(a * 16000):int(b * 16000)] = 0.0
    if r.get("sys_dead"):
        gs[:] = 0.0
    sysm = r["sys_scale"] * gs * n1
    d = r["delay_samples"]
    idx = np.arange(n) - d
    ok = (idx >= 0) & (idx < n)
    echo_ = np.where(ok, sysm[np.clip(idx, 0, n - 1)], 0.0)
    if "echo_from_s" in r or "echo_until_s" in r:
        i = np.arange(n)
        echo_ = np.where((i >= r.get("echo_from_s", 0) * 16000) & (i < r.get("echo_until_s", 1e9) * 16000), echo_, 0.0)
    mic = r["near_gain"] * gn * n2 + r["gain_echo"] * echo_ + r["floor"] * n3
    return mic.astype(np.float32), sysm.astype(np.float32)


def echo_fixture():
    base = {"seconds": 35, "seeds": [101, 202, 303], "gain_echo": 0.4, "delay_samples": 960, "near_gain": 0.3, "floor": 0.01, "sys_scale": 0.5}
    recipes = [
        ("bleed", {}, 0.0),
        ("clean: no echo", {"gain_echo": 0.0}, 0.0),
        ("weak echo", {"gain_echo": 0.15, "near_gain": 0.5, "floor": 0.05}, 0.0),
        ("mic leads system by 50 ms", {"delay_samples": -800}, 0.0),
        ("mic leads by 300 ms", {"delay_samples": -4800}, 0.0),
        ("long delay 700 ms", {"delay_samples": 11200}, 0.0),
        ("echo in first window only: share exactly 1/3", {"echo_until_s": 9.8}, 0.0),
        ("echo in two of three windows", {"echo_from_s": 10.2}, 0.0),
        ("echo in last window only: share 1/3", {"echo_from_s": 20.2}, 0.0),
        ("silent 10 s window", {"silent": [[10, 20]]}, 0.0),
        ("system dead", {"sys_dead": True}, 0.0),
        ("positive offset", {"delay_samples": 960 + 4800}, 0.3),
        ("negative offset", {"delay_samples": 960 - 4000}, -0.25),
        ("short under 1 s", {"seconds": 0.8}, 0.0),
        ("short 3 s", {"seconds": 3}, 0.0),
        ("quiet system", {"sys_scale": 0.004}, 0.0),
    ]
    cases = []
    for name, over, off in recipes:
        r = {**base, **over}
        mic, sysm = synth(r)
        aligned = echo.align_start(sysm, off)
        d = echo._detect(mic, aligned)
        gl = echo.estimate_lag_ms(mic, aligned) if len(mic) >= 16000 and len(aligned) >= 16000 else None
        rounded = [s for s in d["scores"] if s is not None]
        margin = min([abs(s - 0.02) for s in rounded] or [1])
        assert margin > 0.003, (name, d["scores"])
        cases.append({"name": name, "recipe": r, "offset_s": off, "expected": d, "global_lag_ms": gl})
    # a case where coherence is non-trivial but unrelated (tuned off-threshold): different streams, no echo, loud
    # helper function checks
    a = np.arange(10, dtype=np.float32)
    helpers = {
        "align_start": [{"offset": o, "x": [float(v) for v in a], "expected": [float(v) for v in echo.align_start(a, o)]}
                        for o in (0.0, 0.0005, -0.0005, 0.0002, -0.0002, 1e-4, -0.1)],
        "shift_reference": [{"lag": lag, "n": n, "x": [float(v) for v in np.arange(1, 3200, dtype=np.float32)[:2400]],
                             "expected_head": [float(v) for v in echo.shift_reference(np.arange(1, 3200, dtype=np.float32)[:2400], lag, n)[:3]],
                             "expected_len": len(echo.shift_reference(np.arange(1, 3200, dtype=np.float32)[:2400], lag, n)),
                             "expected_sum": float(echo.shift_reference(np.arange(1, 3200, dtype=np.float32)[:2400], lag, n).astype(np.float64).sum())}
                            for lag in (-500, -50, 0, 39, 40, 60, 800) for n in (100, 2400, 3000)],
    }

    # resampler vs scipy
    resample = []
    for rate, ch in ((48000, 1), (44100, 1), (22050, 1), (8000, 1), (16000, 1)):
        n = int(rate * 1.5)
        x = (lcg(rate, n) * 0.5).astype(np.float32)
        y = echo.resample_poly(x, 16000 // np.gcd(16000, rate), rate // np.gcd(16000, rate)).astype(np.float32) if rate != 16000 else x
        idx = list(range(0, len(y), 331))
        resample.append({"rate": rate, "seed": rate, "n": n, "y_len": len(y), "idx": idx, "y": [float(y[i]) for i in idx]})
    # the loader: a float32 stereo 44.1 kHz WAV written by both sides from the same recipe
    n = 66150
    left, right = lcg(7, n) * 0.3, np.sin(np.arange(n) * 0.05) * 0.2
    with tempfile.TemporaryDirectory() as d_:
        p = f"{d_}/t.wav"
        sf.write(p, np.stack([left, right], 1).astype(np.float32), 44100, subtype="FLOAT")
        y = echo.load16k(p)
    idx = list(range(0, len(y), 211))
    load = {"rate": 44100, "n": n, "y_len": len(y), "idx": idx, "y": [float(y[i]) for i in idx]}

    # text fallback
    rng = random.Random(21)
    dedup, resid = [], []
    NW = ["the", "yes", "Hello,", "OK!", "don't", "Where", "is", "—", "", "Budget", "budget.", "X1", "Zürich", "a"]

    def rw(n, span):
        ws = []
        for _ in range(n):
            s = round(rng.uniform(0, span), 2)
            ws.append(W(rng.choice(NW), s, round(s + rng.choice([0.0, 0.2, 0.6]), 2)))
        return ws

    dedup = []
    for k in range(250):
        mic_, sys_ = rw(rng.choice([0, 1, 5, 14]), 12), rw(rng.choice([0, 1, 6, 14]), 12)
        win = rng.choice([1.5, 1.5, 0.3])
        kept, dropped = echo.dedup_words(mic_, sys_, window=win)
        dedup.append({"mic": words_json(mic_), "sys": words_json(sys_), "window": win, "kept": words_json(kept),
                      "dropped": [[w["text"], w["start"], w["end"], w["echo_of"]] for w in dropped]})
    for k in range(250):
        mic_, sys_ = rw(rng.choice([0, 1, 5, 14, 30]), 20), rw(rng.choice([0, 1, 6, 14]), 20)
        gap, mw, slack = rng.choice([(1.0, 2, 0.5), (1.0, 2, 0.5), (0.5, 1, 0.0), (2.0, 3, 1.0)])
        kept, dropped = echo.drop_residue(mic_, sys_, gap=gap, max_words=mw, slack=slack)
        resid.append({"mic": words_json(mic_), "sys": words_json(sys_), "gap": gap, "max_words": mw, "slack": slack,
                      "kept": words_json(kept), "dropped": words_json(dropped)})

    return {"detect": cases, "helpers": helpers, "resample": resample, "load": load, "dedup": dedup, "residue": resid}


def real_fixture():
    meta = json.loads((REAL / "meta.json").read_text())["track_offsets"]
    off = meta["system"] - meta["mic"]
    d = echo.detect_bleed(str(REAL / "mic.flac"), str(REAL / "system.flac"), system_offset_s=off)
    samples = {}
    for tr in ("mic", "system"):
        y = echo.load16k(str(REAL / f"{tr}.flac"))
        idx = list(range(0, len(y), 4001))
        samples[tr] = {"len": len(y), "idx": idx, "y": [float(y[i]) for i in idx], "rms": float(np.sqrt((y.astype(np.float64) ** 2).mean()))}
    return {"dir": str(REAL).replace(str(Path.home()), "~"), "offset_s": off, "expected": d, "samples": samples}


def main():
    dump("turns.json", turns_fixture())
    dump("voiceprints.json", voiceprint_fixture())
    dump("echo.json", echo_fixture())
    if REAL.exists():
        dump("real_recording.json", real_fixture())
    else:
        print("real recording absent: real_recording.json not written", file=sys.stderr)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
