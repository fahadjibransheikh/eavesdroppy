#!/usr/bin/env python3
"""Eavesdroppy pipeline CLI (research/build-plan.md, "Pipeline CLI contract").

  process_meeting.py <session_dir> [--container DIR] [--out-root DIR]    process a recording or import
  process_meeting.py <command> ... --container DIR                       library edits (see build_parser)

Session: mic.wav [+ system.wav] + meta.json, or import.<ext> + meta.json with "source": "import".
Every command prints exactly one JSON line on stdout. Failure: exit 1, last stderr line "ERROR: <reason>"."""
import argparse, contextlib, difflib, functools, json, os, plistlib, re, shutil, struct, subprocess, sys, tempfile, time, traceback
import urllib.error, urllib.request
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from xml.parsers.expat import ExpatError

import numpy as np
import soundfile as sf

import echo, library, notes, speakers
from library import fmt_ts, folder_name, sanitize_title

HERE = Path(__file__).resolve().parent
FLUIDAUDIO = HERE / "bin" / "fluidaudiocli"  # built by tools/build_fluidaudio.sh
DEFAULT_OUT = "~/Documents/Eavesdroppy"
CLOUD_STORAGE = Path.home() / "Library" / "CloudStorage"
# Droppy live transcribe owns the Parakeet v3 model and the dictionary; reuse both instead of keeping copies
DROPPY_STATE = Path.home() / "Library/Application Support/Droppy/Extensions/voiceTranscribe/runtime-state.json"
DROPPY_MODEL_KEY = "fluid_parakeet-tdt-v3"
DROPPY_DEFAULTS_DOMAIN, DROPPY_VOCAB_KEY = "iordv.Droppy", "voiceTranscribe_customVocabulary"
MODEL_FILES = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
FLUIDAUDIO_TIMEOUT, AFCONVERT_TIMEOUT, NAMING_TIMEOUT, LINEAR_TIMEOUT = 1800, 600, 120, 30  # seconds
NAME_SIM = 0.8  # --vocab-min-similarity (0.6) lets attendee names rewrite near-sounding words ("notes" -> "Jones"); names need a closer match
MIN_TRACK_SECONDS = 0.5  # fluidaudiocli fails with invalidAudioData below ~0.5 s
SILENT_PEAK = 1e-4
BLOCK = 1 << 18  # frames per streamed block
WHAT = {"mic": "Mic", "system": "Call"}  # names used in warnings
LINEAR_URL = "https://api.linear.app/graphql"
OLD_LABEL = {"mic": "Me", "system": "Them"}  # one speaker per track when diarization is unavailable
IN_PERSON_LABEL = {"mic": "Room", "system": "Them"}  # ...in person the mic is the whole room, not the user alone
FALLBACK_KIND = {"Me": "me", "Them": "remote", "Room": "room"}
GAP = 1.0
MAX_WORD_S = 1.2  # Parakeet word ends often run on to the next word's start; no real word is held longer
TURN_GAP = 8.0  # same-speaker utterances further apart than this start a new turn
TURN_MAX = 30.0  # ...and no merged turn spans longer than this (one citation per ~30 s of talk)
UTT_SPLIT, UTT_MAX = 20.0, 40.0  # gapless speech splits at the first sentence end past UTT_SPLIT s, regardless past UTT_MAX s


class Fail(Exception):
    pass


# ---------- pure helpers ----------

def build_turns(tracks, offsets):
    """tracks: {speaker: [{text,start,end}]}, offsets: {speaker: seconds}. Returns [{speaker,start,end,text}]."""
    utts = []
    for spk, words in tracks.items():
        off = offsets.get(spk, 0.0)
        cur = None
        for w in sorted(words, key=lambda w: w["start"]):
            s, e = w["start"] + off, w["end"] + off
            span = cur and cur["end"] - cur["start"]
            if (cur is None or s - cur["end"] > GAP or span >= UTT_MAX
                    or (span >= UTT_SPLIT and cur["words"][-1].endswith((".", "?", "!")))):
                cur = {"speaker": spk, "start": s, "end": e, "words": []}
                utts.append(cur)
            cur["words"].append(w["text"])
            cur["end"] = max(cur["end"], e)
    utts.sort(key=lambda u: u["start"])
    turns = []
    for u in utts:
        text = " ".join(u["words"])
        last = turns[-1] if turns else None
        if (last and last["speaker"] == u["speaker"] and u["start"] - last["end"] <= TURN_GAP
                and max(last["end"], u["end"]) - last["start"] <= TURN_MAX):
            turns[-1]["text"] += " " + text
            turns[-1]["end"] = max(turns[-1]["end"], u["end"])
        else:
            turns.append({"speaker": u["speaker"], "start": u["start"], "end": u["end"], "text": text})
    return turns


@functools.lru_cache(maxsize=1)
def common_words():
    """Lowercase entries of the system word list (proper nouns are capitalised there, so they are not in it)."""
    try:
        return frozenset(w for w in Path("/usr/share/dict/words").read_text(errors="replace").split() if w.islower())
    except OSError:
        return frozenset()  # ponytail: without the list single-word attendees all pass; add a built-in stoplist if that bites


def attendee_names(attendees):
    """Attendee names safe to use as vocabulary: capitalised names only (an email or an all-lowercase string says
    nothing about spelling), kept whole ("Bob Jones" is one term; a bare surname token rewrote "notes" to "Jones").
    A one-word name must not be an ordinary English word ("Will", "Mark"). ponytail: lowercase particles
    ("van der Berg") drop the attendee; add a particle list when someone needs it."""
    out = []
    for a in attendees:
        toks = re.sub(r"[,:]", " ", a).split()
        if not toks or "@" in a or not all(t[:1].isupper() for t in toks):
            continue
        if len(toks) > 1 or toks[0].lower() not in common_words():
            out.append(" ".join(toks))
    return out


def build_hotwords(attendees, vocab_lines):
    """FluidAudio custom-vocab lines: Droppy dictionary lines first (they may carry aliases), then attendee_names.
    Deduped case-insensitively on the term before any ':'."""
    out, seen = [], set()
    for line in [*vocab_lines, *attendee_names(attendees)]:
        key = line.split(":")[0].strip().lower()
        if key and key not in seen:
            seen.add(key)
            out.append(line)
    return out


def droppy_vocab_lines(raw):
    """Droppy dictionary JSON ([{canonical, variants}]) -> `canonical` / `canonical: v1, v2` lines."""
    try:
        items = json.loads(raw)
    except (TypeError, ValueError):
        return []
    clean = lambda s: " ".join(re.sub(r"[,:]", " ", str(s)).split())  # ',' and ':' are the line syntax
    lines = []
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict) or not clean(it.get("canonical", "")):
            continue
        variants = [v for v in (clean(v) for v in it.get("variants") or []) if v]
        lines.append(f"{clean(it['canonical'])}: {', '.join(variants)}" if variants else clean(it["canonical"]))
    return lines


def load_droppy_vocab():
    try:
        r = subprocess.run(["/usr/bin/defaults", "export", DROPPY_DEFAULTS_DOMAIN, "-"], capture_output=True, timeout=10)
        return droppy_vocab_lines(plistlib.loads(r.stdout).get(DROPPY_VOCAB_KEY)) if r.returncode == 0 else []
    except (OSError, subprocess.SubprocessError, ValueError, ExpatError):
        return []


def link_droppy_model(link_dir, state=DROPPY_STATE):
    """Symlink dir over Droppy's Parakeet v3 model, with the joint named the way fluidaudiocli expects
    (JointDecisionv3). Returns link_dir, or None if Droppy's model is absent or the link dir is incomplete."""
    link_dir = Path(link_dir)
    try:
        src = Path(json.loads(Path(state).read_text())["installedModels"][DROPPY_MODEL_KEY])
        entries = sorted(src.iterdir())
        link_dir.mkdir(parents=True, exist_ok=True)
        for old in link_dir.iterdir():  # refresh: drop links from an earlier model location
            if old.is_symlink():
                old.unlink()
        for e in entries:
            (link_dir / e.name).symlink_to(e)
        if not (src / "JointDecisionv3.mlmodelc").exists() and (src / "JointDecision.mlmodelc").exists():
            (link_dir / "JointDecisionv3.mlmodelc").symlink_to(src / "JointDecision.mlmodelc")
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return link_dir if all((link_dir / f).exists() for f in MODEL_FILES) else None


# ---------- audio ----------

def repair_wav(path):
    """AVAudioFile only finalizes the WAV header on close, so a crashed recording has a data-chunk size of 0
    (or past EOF) and reads as 0 frames though the audio is on disk. Point the sizes at EOF, truncated to whole
    frames. Returns True if the file was modified."""
    with open(path, "r+b") as f:
        end = f.seek(0, 2)
        f.seek(0)
        head = f.read(12)
        if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            return False
        pos, block_align = 12, 0
        while pos + 8 <= end:
            f.seek(pos)
            cid, size = struct.unpack("<4sI", f.read(8))
            if cid == b"fmt " and size >= 14:  # same offset for PCM, float and WAVE_FORMAT_EXTENSIBLE
                f.seek(pos + 8 + 12)
                block_align = struct.unpack("<H", f.read(2))[0]
            elif cid == b"data":
                start = pos + 8
                break
            pos += 8 + size + (size & 1)
        else:
            return False
        if not block_align or (0 < size < 0xFFFFFFFF and start + size <= end):
            return False
        n = (end - start) // block_align * block_align
        f.truncate(start + n)
        # ponytail: sizes cap at 4 GiB (~3 h of 48 kHz stereo float); RF64 if recordings ever get that long
        f.seek(4)
        f.write(struct.pack("<I", min(start + n - 8, 0xFFFFFFFF)))
        f.seek(pos + 4)
        f.write(struct.pack("<I", min(n, 0xFFFFFFFF)))
    return True


def prepare_track(key, src, tmp):
    """Repairs src if crash-truncated, then streams it once to find the loudest channel and the peak.
    Returns {mono: path of a mono float WAV (src itself if already mono), sr, dur, peak}."""
    repair_wav(src)
    info = sf.info(str(src))
    if info.frames == 0:
        raise Fail(f"{Path(src).name} has no audio")
    sumsq, peaks = np.zeros(info.channels), np.zeros(info.channels)
    for b in sf.blocks(str(src), blocksize=BLOCK, dtype="float32", always_2d=True):
        sumsq += (b.astype(np.float64) ** 2).sum(axis=0)
        peaks = np.maximum(peaks, np.abs(b).max(axis=0))
    ch = int(sumsq.argmax())  # loudest channel, not the mean: a quiet or silent channel would dilute it
    mono = src
    if info.channels > 1:
        mono = tmp / f"{key}-mono.wav"
        with sf.SoundFile(str(mono), "w", info.samplerate, 1, subtype="FLOAT") as out:
            for b in sf.blocks(str(src), blocksize=BLOCK, dtype="float32", always_2d=True):
                out.write(b[:, ch])
    return {"mono": mono, "sr": info.samplerate, "dur": info.frames / info.samplerate, "peak": float(peaks[ch])}


def to_16k_wav(src, dst):
    run_checked(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(src), str(dst)], "afconvert", AFCONVERT_TIMEOUT)


def mix_blocks(parts, n):
    """parts: [(mono wav path, offset in samples)]. Yields their sum as float32 blocks covering n samples."""
    with ExitStack() as stack:
        srcs = [(stack.enter_context(sf.SoundFile(str(p))), o) for p, o in parts]
        for i in range(0, n, BLOCK):
            buf = np.zeros(min(BLOCK, n - i), dtype=np.float32)
            for f, o in srcs:
                lo, hi = max(i - o, 0), min(i + len(buf) - o, f.frames)
                if hi > lo:
                    f.seek(lo)
                    buf[lo + o - i:hi + o - i] += f.read(hi - lo, dtype="float32")
            yield buf


def mix_to_m4a(tracks, offsets, dst_m4a, tmp):
    """tracks: {key: mono wav path}. Streams the mix (peak pass, then write pass) so long meetings stay small."""
    sr = sf.info(str(next(iter(tracks.values())))).samplerate
    parts = []
    for key, path in tracks.items():
        if sf.info(str(path)).samplerate != sr:  # resample the odd one out to the first track's rate
            rs = tmp / f"{key}-rs.wav"
            run_checked(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEF32@{sr}", str(path), str(rs)], "afconvert", AFCONVERT_TIMEOUT)
            path = rs
        parts.append((path, int(round(offsets.get(key, 0.0) * sr))))
    n = max(o + sf.info(str(p)).frames for p, o in parts)
    peak = max((float(np.abs(b).max()) for b in mix_blocks(parts, n)), default=0.0)
    scale = 0.95 / peak if peak > 0.95 else 1.0
    wav = tmp / "mix.wav"
    with sf.SoundFile(str(wav), "w", sr, 1, subtype="PCM_16") as out:
        for b in mix_blocks(parts, n):
            out.write(b * scale)
    run_checked(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", str(wav), str(dst_m4a)], "afconvert", AFCONVERT_TIMEOUT)


def stderr_tail(stderr, n=400):
    lines = [l.strip() for l in stderr.splitlines() if l.strip()]
    return " | ".join(([l for l in lines if "[ERROR]" in l] or lines)[-3:])[-n:]


def run_checked(cmd, what, timeout):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Fail(f"{what} timed out after {timeout} s")
    except OSError as e:
        raise Fail(f"could not run {what}: {e}")
    if r.returncode != 0:
        raise Fail(f"{what} failed (exit {r.returncode}): {stderr_tail(r.stderr)}")
    return r


# ---------- transcription ----------

def align_words(raw, text):
    """Custom vocab rewrites `text` but leaves word timings raw; map text tokens back onto the timings.
    raw: [(word, start, end)]. Returns [{text,start,end}] whose texts reproduce text.split().
    Word ends are clamped first (see MAX_WORD_S): a pause belongs to the gap between words, or build_turns never sees it."""
    raw = [(w, s, max(s, min(e, s + MAX_WORD_S, raw[i + 1][1] if i + 1 < len(raw) else e))) for i, (w, s, e) in enumerate(raw)]
    key = lambda w: re.sub(r"\W", "", w).lower()
    toks, words = text.split(), []
    sm = difflib.SequenceMatcher(None, [key(w) for w, _, _ in raw], [key(t) for t in toks], autojunk=False)
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal":
            words += [{"text": toks[b0 + i], "start": raw[a0 + i][1], "end": raw[a0 + i][2]} for i in range(a1 - a0)]
        elif b1 > b0 and a1 > a0:  # replaced span: spread the new tokens over the old span's time range
            s, e, n = raw[a0][1], raw[a1 - 1][2], b1 - b0
            words += [{"text": toks[b0 + i], "start": s + (e - s) * i / n, "end": s + (e - s) * (i + 1) / n} for i in range(n)]
        elif b1 > b0:  # pure insertion: zero-width at the previous word
            t = words[-1]["end"] if words else (raw[0][1] if raw else 0.0)
            words += [{"text": toks[b0 + i], "start": t, "end": t} for i in range(b1 - b0)]
    return words


def vocab_json(hotwords, names=()):
    """Vocab lines (`term` / `term: alias, alias`) -> FluidAudio's JSON vocab config. JSON, not the text list, because
    only it carries a per-term minSimilarity; lines whose term is in `names` get NAME_SIM."""
    terms = []
    for line in hotwords:
        term, _, rest = line.partition(":")
        t = {"text": term.strip(), "aliases": [a.strip() for a in rest.split(",") if a.strip()] or None,
             "minSimilarity": NAME_SIM if term.strip() in names else None}
        terms.append({k: v for k, v in t.items() if v is not None})
    return json.dumps({"terms": terms})


def transcribe(wav, hotwords, model_dir=None, names=()):
    """FluidAudio Parakeet TDT v3. Returns {"words": [{text,start,end}], "duration_seconds"}. `names`: the hotwords
    that are attendee names (stricter match, see NAME_SIM)."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "out.json"
        cmd = [str(FLUIDAUDIO), "transcribe", str(Path(wav).resolve()), "--output-json", str(out), "--model-version", "v3"]
        if model_dir:
            cmd += ["--local-model-dir", str(model_dir)]
        if hotwords:
            vocab = Path(d) / "vocab.json"
            vocab.write_text(vocab_json(hotwords, set(names)))
            # default vocab flags rewrite ordinary words into names; these were benchmarked safe
            cmd += ["--custom-vocab", str(vocab), "--vocab-disable-spotter-rescue", "--vocab-min-similarity", "0.6"]
        r = run_checked(cmd, "fluidaudiocli", FLUIDAUDIO_TIMEOUT)
        if not out.is_file():  # the CLI exits 0 on failure and logs "[ERROR] ..."; a missing JSON is the only signal
            raise Fail(f"fluidaudiocli produced no output: {stderr_tail(r.stderr)}")
        try:
            j = json.loads(out.read_text())
        except json.JSONDecodeError as e:
            raise Fail(f"fluidaudiocli returned non-JSON output: {e}")
    raw = [(w["word"], w["startTime"], w["endTime"]) for w in j.get("wordTimings", [])]
    return {"words": align_words(raw, j.get("text", "")), "duration_seconds": j.get("durationSeconds", 0.0)}


# ---------- main flows ----------

def keep_raw(session, files):
    """Archive the raw tracks as FLAC beside the sessions dir (<container>/raw/<session>/), since the
    recorder deletes the session dir once we exit 0. Needed for echo A/B tests and re-processing.
    A track soundfile can't read is copied as-is rather than lost."""
    dst = session.parent.parent / "raw" / session.name
    dst.mkdir(parents=True, exist_ok=True)
    for key, path in files.items():  # streamed: an hour of 48 kHz float stereo is ~1.4 GB
        try:
            info = sf.info(str(path))
            with sf.SoundFile(dst / f"{key}.flac", "w", info.samplerate, info.channels, subtype="PCM_24") as out:
                for block in sf.blocks(str(path), blocksize=BLOCK, dtype="float32"):
                    out.write(block)
        except RuntimeError:
            (dst / f"{key}.flac").unlink(missing_ok=True)
            shutil.copy2(path, dst / Path(path).name)
    shutil.copy2(session / "meta.json", dst / "meta.json")
    return dst


def check_out_root(out_root):
    """Don't mkdir -p into a Drive path whose CloudStorage mount isn't there (that would create a fake local copy)."""
    try:
        mount = CLOUD_STORAGE / out_root.relative_to(CLOUD_STORAGE).parts[0]
    except (ValueError, IndexError):
        return
    if not mount.is_dir():
        raise Fail(f"Drive folder not available: {out_root}")


def clean_stale(out_root, max_age=3600):
    """Remove .incoming-* stage dirs left behind by a killed run."""
    for d in out_root.glob(".incoming-*"):
        try:
            if d.is_dir() and time.time() - d.stat().st_mtime > max_age:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def import_wav(session, tmp):
    srcs = sorted(session.glob("import.*"))
    if len(srcs) != 1:
        raise Fail(f"expected exactly one import.<ext> in {session}, found {len(srcs)}")
    dst = tmp / "mic.wav"
    run_checked(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32", str(srcs[0]), str(dst)], "afconvert", AFCONVERT_TIMEOUT)
    return dst



# ---------- echo, speakers, turns ----------

def echo_stage(mic16, sys16, off, removal, tmp, warnings):
    """Bleed check on the 16 kHz tracks (off = system track start minus mic track start, seconds).
    Returns (bleed, mic path to transcribe/diarize, dedup): dedup=True means removal was tried and failed, so the
    caller drops duplicate words instead (also when LocalVQE is not built). Never dedups a clean meeting."""
    try:
        det = echo.detect_bleed(mic16, sys16, system_offset_s=off)
    except Exception as e:  # a detector problem must not lose the meeting
        warnings.append(f"Echo detection failed: {e}")
        return False, mic16, False
    if not det.get("bleed"):
        return False, mic16, False
    print(f"Echo: bleed detected (share {det.get('share')}, lag {det.get('lag_ms')} ms)", file=sys.stderr)
    if not removal:
        warnings.append("Speaker echo detected; echo removal is off")
        return True, mic16, False
    cleaned, out = tmp / "mic-cleaned.wav", tmp / "mic-clean16k.wav"
    try:
        r = echo.remove_echo(mic16, sys16, cleaned, system_offset_s=off)
        if not r.get("failed"):
            to_16k_wav(cleaned, out)  # fluidaudiocli only ever sees 16-bit PCM
    except echo.LocalVQEMissing:  # not a failure of this meeting: say so once and fall back to dedup
        print("Echo removal unavailable: LocalVQE not built (tools/build_localvqe.sh)", file=sys.stderr)
        warnings.append("Echo removal unavailable (LocalVQE not built)")
        return True, mic16, True
    except Exception as e:
        r = {"failed": True, "reason": str(e)}
    if r.get("failed"):
        print(f"Echo removal failed: {r.get('reason')}", file=sys.stderr)
        warnings.append("Echo removal failed; removed duplicate words instead")
        return True, mic16, True
    print(f"Echo removed ({r.get('self_check')})", file=sys.stderr)
    return True, out, False


def user_name_of(*cands):
    """First usable name of --user-name, meta.json user_name (the "Your name" setting), else notes.USER_NAME."""
    for c in cands:
        if isinstance(c, str) and c.strip():
            return " ".join(c.split())
    return notes.USER_NAME


def own_names(db, user_name=None):
    """Lowercase names/emails that identify the user: their configured name plus the enrolled Me person."""
    norm = lambda x: " ".join(x.lower().split())
    names = {norm(user_name_of(user_name))}
    for name, email in db.execute("SELECT name, email FROM people WHERE is_me = 1").fetchall():
        names |= {norm(x) for x in (name, email) if x and x.strip()}
    names.discard("me")
    return names


def drop_user(attendees, names):
    """Attendees minus the user: a full-name or email match, or a bare first name ("Fahad") equal to the first name
    of a known name. "Fahad Khan" is someone else when the user is "Fahad Sheikh"."""
    firsts = {n.split()[0] for n in names if "@" not in n and n.split()}
    out = []
    for a in attendees:
        low = " ".join(a.lower().split())
        if low not in names and low not in firsts:
            out.append(a)
    return out


def naming_snippets(recs, turns, n=10, chars=240):
    out = {}
    for t in turns:
        lines = out.setdefault(speakers.cluster_key(recs[t["speaker"]]), [])
        if len(lines) < n:
            lines.append(f"[{fmt_ts(t['start'])}] {t['text'][:chars]}")
    return out


def assemble(words_by_track, diar_by_track, db, attendees, source, bleed, offsets, labels, warnings,
             participants=(), auto_naming=True, user_name=None, in_person=False):
    """Words + diarization -> (speaker records, turns). words_by_track: {track: [{text,start,end}]};
    diar_by_track: {track: speakers.diarize() result, or None when diarization failed}; offsets/labels per track
    (labels = the one-speaker-per-track fallback names). Turn `speaker` is an index into the returned records."""
    mapped, kept = {}, {}
    for track, words in words_by_track.items():
        d = diar_by_track.get(track)
        mapped[track] = speakers.words_to_speakers(words, d["segments"]) if d else [{**w, "speaker": None} for w in words]
        if d:  # only clusters that own words become speakers (echoed voices whose words were deduped drop out)
            used = {w["speaker"] for w in mapped[track]} & set(d["embeddings"])
            if used:
                kept[track] = {"segments": [s for s in d["segments"] if s[2] in used],
                               "embeddings": {c: e for c, e in d["embeddings"].items() if c in used}}
    recs = speakers.assign_speakers(kept, db, attendees, source, bleed, update=False, in_person=in_person)  # process() learns once the meeting is stored
    index = {(r["track"], r["cluster_id"]): i for i, r in enumerate(recs)}

    def home(track, cid):
        if (track, cid) not in index:
            if (track, None) not in index:
                index[(track, None)] = len(recs)
                recs.append({"track": track, "cluster_id": None, "label": labels[track], "person_id": None, "score": 0.0,
                             "kind": FALLBACK_KIND.get(labels[track], "other"), "embedding": None, "speech_s": 0.0})
            return index[(track, None)]
        return index[(track, cid)]

    by_rec = {}
    for track, words in mapped.items():
        for w in words:
            by_rec.setdefault(home(track, w["speaker"]), []).append(w)
    turns = build_turns(by_rec, {i: float(offsets.get(recs[i]["track"], 0.0)) for i in by_rec})

    # call-app participant names (read via Accessibility) are candidates too, never ground truth
    seen, pool = set(), []
    for n in [*attendees, *participants]:
        if n.strip() and n.strip().lower() not in seen:
            seen.add(n.strip().lower())
            pool.append(n.strip())
    cands = drop_user(pool, own_names(db, user_name))
    prompt = speakers.build_naming_prompt(recs, cands, naming_snippets(recs, turns)) if auto_naming else ""
    if prompt:
        text, err = notes.run_claude(prompt, timeout=NAMING_TIMEOUT)
        if text:
            recs = speakers.apply_names(recs, speakers.parse_naming_reply(text, allowed=cands))
        else:
            warnings.append(f"Speaker naming failed: {err}")
    return recs, turns


def db_speakers(recs, source):
    """Records -> library.add_meeting speakers. Only me/auto matches are linked to a person: a suggestion is not a
    link (rename_speaker relabels every speaker linked to a person), so it goes to suggested_person_id."""
    return [{"track": "room" if source == "import" else r["track"], "cluster": r["cluster_id"], "label": r["label"],
             "person_id": r["person_id"] if r["kind"] in ("me", "auto") else None,
             "suggested_person_id": r["person_id"] if r["kind"] == "suggest" else None, "score": r.get("score"),
             "kind": r["kind"], "embedding": None if r.get("embedding") is None else np.asarray(r["embedding"], np.float32).tobytes()}
            for r in recs]


# ---------- notes ----------

def generate_and_store(db, mid, template=None, custom_text=None, keep_good=False, user_name=None):
    """Claude notes for a stored meeting -> library.set_notes. Returns the failure reason or None. On failure the
    transcript is untouched; the notes become a placeholder (status 'failed'), unless keep_good and the existing
    notes were fine, in which case nothing changes."""
    m = library.get_meeting(db, mid)
    hint = [l.split(":")[0] for l in build_hotwords(m["attendees"], load_droppy_vocab())]
    try:
        text, actions, err = notes.generate_notes(m, template, custom_text, hint, user_name=user_name_of(user_name))
    except ValueError as e:  # unknown template, custom without text
        raise Fail(str(e))
    if err and keep_good and m["summary_status"] == "ok":
        return err
    library.set_notes(db, mid, text, actions if not err else None, "failed" if err else "ok", template)
    return err


def read_user_notes(session, meta):
    for n in (meta.get("user_notes_file"), "notes.txt"):  # notes.txt even when meta does not name it
        p = Path(n) if n else None
        if p is None:
            continue
        p = p if p.is_absolute() else session / p
        try:
            if p.is_file():
                return p.read_text(errors="replace")
        except OSError:
            pass
    return ""


# ---------- files ----------

def under(path, roots):
    """True if path resolves strictly inside one of roots (symlinks followed, so a link out is refused)."""
    try:
        p = Path(path).resolve()
        return any(p != r and p.is_relative_to(r) for r in (Path(x).resolve() for x in roots))
    except OSError:
        return False


def remove_path(p, roots, warnings):
    """Delete one file/dir, but only inside `roots` (the Drive out root and the container). Returns "deleted", "absent"
    (not there; a Drive path under a mount that is not there only counts as unreachable), "failed" or "refused"."""
    if not under(p, roots):
        warnings.append(f"Not deleting {p}: outside the Drive folder and the container")
        return "refused"
    p = Path(p)
    try:
        if p.is_dir() and not p.is_symlink():
            shutil.rmtree(p)
        elif p.exists() or p.is_symlink():
            p.unlink()
        else:
            check_out_root(p)  # Drive offline looks like "absent"; it is not
            return "absent"
    except Fail as e:
        warnings.append(f"Could not delete {p}: {e}")
        return "failed"
    except OSError as e:
        warnings.append(f"Could not delete {p}: {e}")
        return "failed"
    return "deleted"


def remove_paths(paths, roots, warnings):
    """remove_path for each; returns how many were deleted."""
    return sum(remove_path(p, roots, warnings) == "deleted" for p in filter(None, paths))


def expire(db, days, roots, warnings, exclude=()):
    """Retention (D20): library.expire_audio with the safe deleter. Returns how many paths were deleted."""
    done = library.expire_audio(db, days, lambda p: remove_path(p, roots, warnings), exclude=exclude)
    return sum(res == "deleted" for _, res in done)


def sync(db, ids, out_root, warnings):
    """Re-render the Drive mirror after an edit. A missing Drive is a warning, never a failed edit."""
    for mid in ids:
        try:
            library.sync_mirror(db, mid, out_root)
        except (library.LibraryError, OSError) as e:
            msg = f"Drive mirror not updated for meeting {mid}: {e}"
            print(f"WARNING: {msg}", file=sys.stderr)
            warnings.append(msg)

# ---------- processing ----------

def read_custom_template(meta, container, warnings):
    """meta custom_template (the text), else the file named by custom_template_file: relative to the container or
    absolute, but it must resolve inside the container. Returns the text or None."""
    text = meta.get("custom_template")
    if isinstance(text, str) and text.strip():
        return text
    name = meta.get("custom_template_file")
    if not name:
        return None
    p = Path(str(name)).expanduser()
    p = p if p.is_absolute() else container / p
    if not under(p, [container]):
        warnings.append(f"Custom template file {name} is outside the container; ignored")
        return None
    try:
        return p.read_text(errors="replace")
    except OSError as e:
        warnings.append(f"Custom template file {name} unreadable: {e}")
        return None


def reusable(folder, leftover, out_root, db):
    """True if `folder` is a Drive folder an earlier, killed attempt of this same session made (it is in `leftover`,
    inside out_root) and no meeting owns it."""
    return (folder in leftover and under(folder, [out_root]) and folder.is_dir()
            and not db.execute("SELECT 1 FROM meetings WHERE folder = ?", (str(folder),)).fetchone())


def process(session, out_root, container=None, user_name=None):
    """Session dir -> library meeting + Drive folder. Returns (folder, meeting_id, warnings)."""
    session = Path(session).resolve()
    container = Path(container).expanduser().resolve() if container else session.parent.parent
    try:
        meta = json.loads((session / "meta.json").read_text())
        title = meta["title"]
        start_dt = datetime.fromisoformat(meta["start"])
    except (OSError, ValueError, KeyError) as e:
        raise Fail(f"bad or missing meta.json (need title, start): {e!r}")
    if start_dt.tzinfo is None:
        raise Fail("meta.json start must include a UTC offset")
    attendees = [str(a) for a in meta.get("attendees", [])]
    track_off = meta.get("track_offsets", {})
    is_import = meta.get("source") == "import"
    source = "import" if is_import else "record"
    echo_removal = meta.get("echo_removal", True) is not False
    in_person = not is_import and meta.get("setting") == "in_person"  # no call: the mic carries the whole room, nothing plays back into it
    template = meta.get("template") or "general"
    user_name = user_name_of(user_name, meta.get("user_name"))
    user_notes = read_user_notes(session, meta)

    check_out_root(out_root)
    out_root.mkdir(parents=True, exist_ok=True)
    clean_stale(out_root)
    warnings = []
    custom_text = read_custom_template(meta, container, warnings) if template == "custom" else meta.get("custom_template")
    if template not in notes.TEMPLATES or (template == "custom" and not (custom_text or "").strip()):
        warnings.append(f"Template {template!r} unavailable; used General")
        template = "general"
    db = library.open_db(container / "library.db")
    try:
        # All intermediates live on local disk; only finished files are copied into out_root (Drive), at the end.
        with tempfile.TemporaryDirectory(prefix="eavesdroppy-") as t:
            tmp = Path(t)
            if is_import:
                files, labels, names = {"mic": import_wav(session, tmp)}, {"mic": "Room"}, {"mic": "Recording"}
            else:
                mic = session / "mic.wav"
                if not mic.is_file():
                    raise Fail(f"{mic} not found")
                files, labels, names = {"mic": mic}, IN_PERSON_LABEL if in_person else OLD_LABEL, WHAT
                if (session / "system.wav").is_file():
                    files["system"] = session / "system.wav"

            model_dir = link_droppy_model(container / "models" / "parakeet-tdt-0.6b-v3")
            print(f"Using Droppy's Parakeet model via {model_dir}" if model_dir
                  else "Droppy's Parakeet model not found; FluidAudio will use its own cache", file=sys.stderr)
            droppy = load_droppy_vocab()
            hot = build_hotwords(attendees, droppy)
            # a name the Droppy dictionary already has keeps the dictionary's (looser) matching
            att = [n for n in attendee_names(attendees) if n.lower() not in {l.split(":")[0].strip().lower() for l in droppy}]
            print(f"Custom vocabulary ({len(hot)}): {', '.join(hot)[:300]}", file=sys.stderr)
            prepped, w16, failures, duration = {}, {}, [], 0.0
            for key, path in files.items():
                off = float(track_off.get(key, 0.0))
                try:
                    tr = prepped[key] = prepare_track(key, path, tmp)
                except (Fail, OSError, RuntimeError) as e:
                    failures.append(f"{names[key]} track unreadable ({e})")
                    continue
                duration = max(duration, off + tr["dur"])
                if tr["dur"] < MIN_TRACK_SECONDS:
                    warnings.append(f"{names[key]} track too short ({tr['dur']:.1f} s), skipped")
                elif tr["peak"] < SILENT_PEAK:
                    if not (in_person and key == "system"):  # a quiet call-audio track is what an in-person meeting records
                        warnings.append(f"{names[key]} audio was silent")
                else:
                    try:
                        to_16k_wav(tr["mono"], tmp / f"{key}16k.wav")
                        w16[key] = tmp / f"{key}16k.wav"
                    except (Fail, OSError, RuntimeError) as e:
                        failures.append(f"{names[key]} track transcription failed ({e})")

            # echo (record sessions with a usable system track): mic transcription and diarization use the cleaned mic
            src, bleed, dedup, sys_off = dict(w16), False, False, 0.0
            echo_warnings = []
            if in_person:
                print("Echo: skipped (in-person meeting: no call audio to bleed into the mic)", file=sys.stderr)
            elif "mic" in w16 and "system" in w16:
                sys_off = float(track_off.get("system", 0.0)) - float(track_off.get("mic", 0.0))
                bleed, src["mic"], dedup = echo_stage(w16["mic"], w16["system"], sys_off, echo_removal, tmp, echo_warnings)

            words = {}
            for key in w16:
                try:
                    res = transcribe(src[key], hot, model_dir, att)
                except (Fail, OSError, RuntimeError) as e:
                    failures.append(f"{names[key]} track transcription failed ({e})")
                    continue
                words[key] = res.get("words") or []
                duration = max(duration, float(track_off.get(key, 0.0)) + float(res.get("duration_seconds", 0.0)))
            if len(failures) == len(files):
                raise Fail("; ".join(failures))
            warnings += failures + echo_warnings  # some tracks failed, others carried the meeting
            if "mic" in words and "system" in words:  # system words onto the mic clock
                sysw = [{**w, "start": w["start"] + sys_off, "end": w["end"] + sys_off} for w in words["system"]]
                if dedup:  # removal failed: drop repeats
                    words["mic"], _ = echo.dedup_words(words["mic"], sysw)
                if bleed:  # removal leaves 1-2 word scraps that dedup can't see
                    words["mic"], _ = echo.drop_residue(words["mic"], sysw, GAP)

            diar = {}
            for key, ws in words.items():
                if not ws:
                    continue
                try:
                    diar[key] = speakers.diarize(src[key])
                except Exception as e:
                    warnings.append(f"Speaker separation failed on the {names[key]} track ({e}); labelled it as one speaker")
                    diar[key] = None
            recs, turns = assemble(words, diar, db, attendees, source, bleed, track_off, labels, warnings,
                                   [str(n) for n in meta.get("participants", [])], meta.get("auto_naming", True) is not False, user_name, in_person)

            play = {k: tr["mono"] for k, tr in prepped.items()}
            if "mic" in play and src.get("mic") != w16.get("mic"):  # echo removed: play the cleaned mic, not the echo
                try:  # the cleaned mic is 16 kHz; bring it back to the recording's rate for the mix
                    up = tmp / "mic-cleaned-up.wav"
                    run_checked(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEF32@{prepped['mic']['sr']}", str(src["mic"]), str(up)],
                                "afconvert", AFCONVERT_TIMEOUT)
                    play["mic"] = up
                except Fail as e:
                    warnings.append(f"Playback audio still has the echo ({e})")
            mix_to_m4a(play, {k: float(track_off.get(k, 0.0)) for k in prepped}, tmp / "audio.m4a", tmp)
            raw_dir = keep_raw(session, files)  # before the rename: a failure here leaves no half-made meeting folder

            # a killed earlier run of this session left a meeting without a folder: replace it, don't duplicate it.
            # Its Drive folder may exist already (killed between the rename and set_audio): reuse that name, not "(2)".
            leftover = []
            for r in db.execute("SELECT id, pending_folder FROM meetings WHERE raw_dir = ? AND folder IS NULL", (str(raw_dir),)).fetchall():
                library.delete_meeting(db, r["id"])
                if r["pending_folder"]:
                    leftover.append(Path(r["pending_folder"]))
            mid = library.add_meeting(db, {"title": title, "start": start_dt, "duration": duration, "attendees": attendees,
                                           "source": source, "bleed": bleed, "raw_dir": str(raw_dir), "template": template,
                                           "user_notes": user_notes, "summary_status": "pending"},
                                      db_speakers(recs, source), turns, [])
            stage, renamed = None, False
            try:
                err = generate_and_store(db, mid, template, custom_text, user_name=user_name)
                if err:
                    warnings.append(f"Summary failed: {err}")
                m = library.get_meeting(db, mid)
                name = folder_name(m["title"], start_dt)
                final, n = out_root / name, 1
                while final.exists() and not reusable(final, leftover, out_root, db):
                    n += 1
                    final = out_root / f"{name} ({n})"
                library.set_pending_folder(db, mid, final)
                stage = Path(tempfile.mkdtemp(prefix=".incoming-", dir=out_root))
                (stage / "transcript.md").write_text(library.render_transcript_md(m))
                (stage / "notes.md").write_text(library.render_notes_md(m))
                shutil.copyfile(tmp / "audio.m4a", stage / f"{final.name}.m4a")
                if final.exists():  # the earlier attempt's folder (reusable): the new files replace it
                    shutil.rmtree(final)
                os.rename(stage, final)
                renamed = True
                library.set_audio(db, mid, audio_path=str(final / f"{final.name}.m4a"), folder=str(final))
            except BaseException:  # no half-made meeting: the session dir is kept, so a retry starts clean
                if stage:
                    shutil.rmtree(stage, ignore_errors=True)
                if renamed:  # in place but not recorded: with the row gone nothing would point at it
                    shutil.rmtree(final, ignore_errors=True)
                library.delete_meeting(db, mid)
                raise
        # voiceprints learn only now: the meeting is complete, so a failed run that gets retried never counts twice
        for pid, emb in speakers.learnable(recs, bleed):
            try:
                speakers.update_print(db, pid, emb)
            except Exception as e:  # the meeting is done; a print that cannot learn is a warning
                warnings.append(f"Voiceprint not updated: {e}")
        try:  # the meeting is complete: whatever goes wrong with retention is a warning, never a failed run
            days = meta.get("retention_days")
            if days:
                expire(db, float(days), [out_root, container], warnings, exclude=(mid,))
        except Exception as e:
            warnings.append(f"Audio retention skipped: {e!r}")
        return final, mid, warnings
    finally:
        db.close()


# ---------- library commands ----------

@contextlib.contextmanager
def library_db(container):
    if not container:
        raise Fail("--container is required")
    c = Path(container).expanduser().resolve()
    if not c.is_dir():
        raise Fail(f"container not found: {c}")
    db = library.open_db(c / "library.db")
    try:
        yield db, c
    finally:
        db.close()


def out_root_of(a):
    return Path(os.path.abspath(os.path.expanduser(a.out_root or os.environ.get("EAVESDROPPY_OUT_ROOT") or DEFAULT_OUT)))


def need_meeting(db, mid):
    m = library.get_meeting(db, mid)
    if not m:
        raise Fail(f"no meeting {mid}")
    return m


def cmd_process(a):
    folder, mid, warnings = process(a.session_dir, out_root_of(a), a.container, a.user_name)
    return {"folder": str(folder), "meeting_id": mid, "warnings": warnings}


def cmd_rename_meeting(a):
    with library_db(a.container) as (db, _):
        library.rename_meeting(db, a.id, a.title)
        sync(db, [a.id], out_root_of(a), [])
    return {"ok": True}


def cmd_rename_speaker(a):
    """Relabel one meeting's speaker and teach the voiceprint. --person-id N: the speaker is person N (print learns
    from it). --new-person: create a person with this voice. Neither: relabel only (a speaker already linked to a
    person keeps that link; the person is not renamed). The mic track of a bleed meeting never feeds a print."""
    if a.person_id is not None and a.new_person:
        raise Fail("use either --person-id or --new-person, not both")
    name = (a.name or "").strip()
    with library_db(a.container) as (db, _):
        row = db.execute("SELECT s.track, s.kind, s.person_id, s.embedding, m.bleed FROM speakers s"
                         " JOIN meetings m ON m.id = s.meeting_id WHERE s.id = ?", (a.speaker_id,)).fetchone()
        if not row:
            raise Fail(f"no speaker {a.speaker_id}")
        if not name:
            raise Fail("empty name")
        emb = None if row["embedding"] is None else speakers._vec(row["embedding"])
        learn = emb is not None and not (row["bleed"] and row["track"] == "mic")
        pid = a.person_id
        if a.new_person:
            pid = speakers.add_person(db, name, emb if learn else None)
        elif pid is not None:
            if not db.execute("SELECT 1 FROM people WHERE id = ?", (pid,)).fetchone():
                raise Fail(f"no person {pid}")
            already = row["person_id"] == pid and row["kind"] in ("me", "auto")  # learned when the meeting was processed
            if learn and not already:
                speakers.confirm_speaker(db, pid, emb)
        ids = library.rename_speaker(db, a.speaker_id, name, pid)
        sync(db, ids, out_root_of(a), [])
    return {"meetings": ids}


def cmd_regenerate(a):
    try:
        custom = Path(a.custom_text_file).read_text() if a.custom_text_file else None
    except OSError as e:
        raise Fail(f"cannot read {a.custom_text_file}: {e}")
    warnings = []
    with library_db(a.container) as (db, _):
        need_meeting(db, a.id)
        err = generate_and_store(db, a.id, a.template, custom, keep_good=True, user_name=a.user_name)
        if err:
            warnings.append(f"Summary failed: {err}")
        sync(db, [a.id], out_root_of(a), warnings)
    return {"ok": True, "warnings": warnings}


def cmd_set_user_notes(a):
    """Text on stdin replaces the typed notes. Nothing on stdin (a tty, a closed pipe, an empty write) is refused so a
    caller bug can never blank the notes; --clear blanks them on purpose."""
    if a.clear:
        text = ""
    else:
        text = "" if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read()
        if not text.strip():
            raise Fail("no text on stdin (use --clear to empty the notes)")
    with library_db(a.container) as (db, _):
        library.set_user_notes(db, a.id, text)
        sync(db, [a.id], out_root_of(a), [])
    return {"ok": True}


def cmd_ask(a):
    if a.meeting_id is not None and a.person_id is not None:
        raise Fail("use either --meeting-id or --person-id, not both")
    scope = {"meeting_id": a.meeting_id} if a.meeting_id is not None else {"person_id": a.person_id} if a.person_id is not None else None
    with library_db(a.container) as (db, _):
        answer, err = notes.ask(db, a.question, scope, user_name=user_name_of(a.user_name))
    if err:
        raise Fail(err)
    return {"answer": answer}


def cmd_delete(a):
    warnings = []
    with library_db(a.container) as (db, container):
        info = library.delete_meeting(db, a.id)
        if info is None:
            raise Fail(f"no meeting {a.id}")
        remove_paths([info["folder"], info["audio_path"], info["raw_dir"]], [out_root_of(a), container], warnings)
    for w in warnings:
        print(f"WARNING: {w}", file=sys.stderr)
    return {"ok": True}


def cmd_set_action_done(a):
    with library_db(a.container) as (db, _):
        library.set_action_done(db, a.action_id, not a.undone)
    return {"ok": True}


def cmd_set_action_exported(a):
    with library_db(a.container) as (db, _):
        library.set_action_exported(db, a.action_id, a.target, a.external_id)
    return {"ok": True}


def linear_call(query, variables=None):
    """One Linear GraphQL request -> the `data` dict. Personal API keys go in Authorization with no Bearer."""
    key = os.environ.get("EAVESDROPPY_LINEAR_KEY", "").strip()
    if not key:
        raise Fail("Linear API key not set")
    req = urllib.request.Request(LINEAR_URL, data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": key, "User-Agent": "eavesdroppy/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=LINEAR_TIMEOUT) as r:
            body, code = r.read(), 200
    except urllib.error.HTTPError as e:  # GraphQL errors (bad key, bad team) arrive as 4xx with a JSON body
        body, code = e.read(), e.code
    except (urllib.error.URLError, OSError) as e:
        raise Fail(f"Linear request failed: {getattr(e, 'reason', e)}")
    try:
        j = json.loads(body)
    except ValueError:
        raise Fail(f"Linear returned HTTP {code} with a non-JSON body")
    if j.get("errors"):
        raise Fail("Linear: " + "; ".join(str(e.get("message", e)) for e in j["errors"]))
    if code != 200 or not isinstance(j.get("data"), dict):
        raise Fail(f"Linear returned HTTP {code}")
    return j["data"]


def cmd_linear_teams(a):
    data = linear_call("{ teams { nodes { id name key } } }")
    return {"teams": [{"id": t["id"], "name": t["name"], "key": t["key"]} for t in data["teams"]["nodes"]]}


def linear_description(action, meeting):
    lines = [f"{k}: {v}" for k, v in (("Owner", action["owner"]), ("Due", action["due"])) if v]
    lines += ["", f"From meeting: {meeting['title']} ({meeting['start'][:10]})"]
    t = next((t for t in meeting["turns"] if t["idx"] == action["turn_idx"]), None) if action["turn_idx"] is not None else None
    if t:
        lines += ["", f"> [{fmt_ts(t['start'])}] {t['speaker']}: {t['text']}"]
    return "\n".join(lines).strip()


def cmd_linear_export(a):
    with library_db(a.container) as (db, _):
        action = db.execute("SELECT * FROM action_items WHERE id = ?", (a.action_id,)).fetchone()
        if not action:
            raise Fail(f"no action item {a.action_id}")
        if action["exported_to"] == "linear" and action["external_id"]:  # idempotent: a repeat never creates a second issue
            ident = action["external_id"]  # the Linear UUID is not stored; rows from before schema v3 have no stored URL
            return {"id": ident, "identifier": ident, "url": action["external_url"] or ""}
        desc = linear_description(dict(action), need_meeting(db, action["meeting_id"]))
        data = linear_call("mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }",
                           {"input": {"teamId": a.team, "title": action["task"], "description": desc}})
        res = data.get("issueCreate") or {}
        issue = res.get("issue")
        if not res.get("success") or not issue:
            raise Fail("Linear did not create the issue")
        library.set_action_exported(db, a.action_id, "linear", issue["identifier"], issue["url"])
    return {"id": issue["id"], "identifier": issue["identifier"], "url": issue["url"]}


def cmd_enroll(a):
    report = {}
    with library_db(a.container) as (db, container):
        try:
            pid = speakers.enroll_me(db, a.wav, a.name, report=report)
        except (ValueError, RuntimeError, OSError) as e:  # the sample stays, so the user can retry
            raise Fail(str(e))
        if under(a.wav, [container / "enroll"]):  # the droplet's own recording; never delete a file the user pointed us at
            with contextlib.suppress(OSError):
                Path(a.wav).unlink(missing_ok=True)
    return {"person_id": pid, "seconds": report["seconds"]}


def cmd_import_drive(a):
    with library_db(a.container) as (db, _):
        r = library.import_existing_drive_meetings(db, out_root_of(a))
    return {"imported": len(r["imported"]), "skipped": r["skipped"], "failed": len(r["failed"]),
            "ids": r["imported"], "errors": [f"{f}: {why}" for f, why in r["failed"]]}


def cmd_expire_audio(a):
    if a.days <= 0:
        raise Fail("DAYS must be positive")
    warnings = []
    with library_db(a.container) as (db, container):
        n = expire(db, a.days, [out_root_of(a), container], warnings)
    for w in warnings:
        print(f"WARNING: {w}", file=sys.stderr)
    return {"deleted": n}


# ---------- CLI ----------

class Parser(argparse.ArgumentParser):
    def error(self, message):  # the Swift side shows the last stderr line, so usage errors must be ERROR: too
        raise Fail(f"bad arguments: {message}")


def build_parser():
    ap = Parser(prog="process_meeting.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def cmd(name, fn, *args):
        p = sub.add_parser(name)
        p.add_argument("--container", help="library container dir (holds library.db)")
        p.add_argument("--out-root", help="Drive meetings folder (default: $EAVESDROPPY_OUT_ROOT)")
        p.add_argument("--user-name", help="the user's own name for prompts and speaker naming (default: meta.json user_name)")
        for spec, kw in args:
            p.add_argument(*spec, **kw)
        p.set_defaults(fn=fn)

    arg = lambda *spec, **kw: (spec, kw)
    cmd("process", cmd_process, arg("session_dir"))
    cmd("rename-meeting", cmd_rename_meeting, arg("id", type=int), arg("title"))
    cmd("rename-speaker", cmd_rename_speaker, arg("speaker_id", type=int), arg("name"),
        arg("--person-id", type=int), arg("--new-person", action="store_true"))
    cmd("regenerate", cmd_regenerate, arg("id", type=int), arg("--template"), arg("--custom-text-file"))
    cmd("set-user-notes", cmd_set_user_notes, arg("id", type=int), arg("--clear", action="store_true"))
    cmd("ask", cmd_ask, arg("question"), arg("--meeting-id", type=int), arg("--person-id", type=int))
    cmd("delete", cmd_delete, arg("id", type=int))
    cmd("set-action-done", cmd_set_action_done, arg("action_id", type=int), arg("--undone", action="store_true"))
    cmd("set-action-exported", cmd_set_action_exported, arg("action_id", type=int), arg("target"), arg("external_id"))
    cmd("linear-teams", cmd_linear_teams)
    cmd("linear-export", cmd_linear_export, arg("action_id", type=int), arg("--team", required=True))
    cmd("enroll", cmd_enroll, arg("wav"), arg("--name", default="Me"))
    cmd("import-drive", cmd_import_drive)
    cmd("expire-audio", cmd_expire_audio, arg("days", type=int))
    return ap


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = build_parser()
    commands = set(ap._subparsers._group_actions[0].choices)
    if argv and not argv[0].startswith("-") and (os.path.isdir(argv[0]) or argv[0] not in commands):
        argv.insert(0, "process")  # the original `process_meeting.py <session_dir>` form
    try:
        a = ap.parse_args(argv)
        print(json.dumps(a.fn(a)))
    except Exception as e:  # the Swift side shows the last stderr line, so it must always be "ERROR: ..."
        known = isinstance(e, (Fail, library.LibraryError))
        if not known:
            traceback.print_exc()
        reason = " ".join((str(e) if known else f"unexpected {type(e).__name__}: {e}").split())
        print(f"ERROR: {reason[:500]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
