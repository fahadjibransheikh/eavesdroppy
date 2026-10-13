#!/usr/bin/env python3
"""Golden fixtures for Port/EngineVocab.swift, produced by running the Python oracle (process_meeting.py).
Run from the repo root:  .venv/bin/python tools/golden/engine_golden.py
Writes eavesdroppy/Tests/EavesdroppyTests/Fixtures/engine_vocab.json."""
import json, random, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import process_meeting as pm

COMMON = ["will", "mark", "bill", "grant", "notes", "apple", "the", "jones"]  # lowercase "system word list" used by both sides
pm.common_words = lambda: frozenset(COMMON)

rng = random.Random(20261013)
VOCAB = ["notes", "Jones", "Fahad", "Rehan", "Acme", "Widgets", "okay", "so", "we", "ship", "the", "wholesale", "desk", "on", "Friday",
         "it's", "Bob's", "re-run", "e-mail", "3pm", "über", "naïve", "Parakeet", "VBx"]


def align_case():
    n = rng.randint(0, 25)
    t, raw = 0.0, []
    for _ in range(n):
        t += rng.choice([0.0, 0.05, 0.2, 1.5])  # gaps, including > MAX_WORD_S
        d = rng.choice([0.1, 0.4, 0.9, 2.5])  # durations, including runs-on past MAX_WORD_S
        raw.append((rng.choice(VOCAB), round(t, 3), round(t + d, 3)))
        t += rng.choice([0.0, d])
    toks = [w for w, _, _ in raw]
    for _ in range(rng.randint(0, 4)):  # vocab-style rewrites: replace, insert, delete, split, merge
        op = rng.choice(["rep", "ins", "del", "split", "merge", "case", "punct"])
        if not toks and op != "ins":
            continue
        i = rng.randrange(len(toks)) if toks else 0
        if op == "rep": toks[i] = rng.choice(VOCAB)
        elif op == "ins": toks.insert(i, rng.choice(VOCAB))
        elif op == "del": del toks[i]
        elif op == "split": toks[i:i + 1] = [toks[i], rng.choice(VOCAB)]
        elif op == "merge" and i + 1 < len(toks): toks[i:i + 2] = [toks[i] + toks[i + 1]]
        elif op == "case": toks[i] = toks[i].upper()
        elif op == "punct": toks[i] += rng.choice([",", ".", "?"])
    text = " ".join(toks)
    return {"raw": [{"word": w, "start": s, "end": e} for w, s, e in raw], "text": text,
            "expected": pm.align_words(raw, text)}


attendees_cases = [
    [], ["Fahad Sheikh"], ["bob@example.com", "Will", "Mark Twain", "Grant", "Rehan", "alice", "Bob, Jones", "Jones: x", "Ünal Öz", ""],
    ["Apple", "The", "Notes Taker", "van der Berg"],
]
droppy_raw = [
    "[]", "not json", json.dumps({"a": 1}), json.dumps([{"canonical": "Fahad", "variants": []}]),
    json.dumps([{"canonical": "Acme Widgets", "variants": ["acme widgets", "Acme, Widgets", "x:y"]},
                {"canonical": " ", "variants": ["z"]}, {"canonical": "A,B:C", "variants": None}, "str", {"variants": ["q"]},
                {"canonical": "Rehan", "variants": ["Hisham", "  "]}, {"canonical": 5, "variants": [7, 8]}]),
]
vocab_lines = ["Fahad", "Acme Widgets: acme widgets, X widgets", "rehan", "Jones : Joans"]
hot_cases = [
    {"attendees": a, "vocab": v, "expected": pm.build_hotwords(a, v)}
    for a in attendees_cases for v in ([], vocab_lines, ["Bob Jones", "bob jones: bob"])
]
vj_cases = [
    {"hotwords": h, "names": n, "expected": json.loads(pm.vocab_json(h, n))}
    for h, n in [([], []), (["Fahad", "Acme Widgets: acme widgets, X widgets"], ["Fahad"]), (["a: , b,, c", ":x", "Bob Jones"], ["Bob Jones", "a"])]
]

with tempfile.TemporaryDirectory() as d:  # link_droppy_model against a fake Droppy model dir
    d = Path(d)
    link_cases = []
    for variant in ("JointDecision", "JointDecisionv3", None):
        src = d / f"model-{variant}"
        src.mkdir()
        for f in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "parakeet_vocab.json", "config.json"]:
            (src / f).write_text("x")
        if variant:
            (src / f"{variant}.mlmodelc").write_text("x")
        state = d / f"state-{variant}.json"
        state.write_text(json.dumps({"installedModels": {pm.DROPPY_MODEL_KEY: str(src)}}))
        got = pm.link_droppy_model(d / f"link-{variant}", state)
        link_cases.append({"joint": variant, "linked": got is not None,
                           "files": sorted(p.name for p in got.iterdir()) if got else []})

out = {
    "common_words": COMMON,
    "attendees": [{"attendees": a, "expected": pm.attendee_names(a)} for a in attendees_cases],
    "hotwords": hot_cases,
    "droppy_vocab": [{"raw": r, "expected": pm.droppy_vocab_lines(r)} for r in droppy_raw],
    "vocab_json": vj_cases,
    "link_model": link_cases,
    "align": [align_case() for _ in range(300)],
}
dst = ROOT / "eavesdroppy/Tests/EavesdroppyTests/Fixtures/engine_vocab.json"
dst.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(f"wrote {dst} ({len(out['align'])} align cases)")
