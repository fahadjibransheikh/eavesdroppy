#!/usr/bin/env python3
"""Post-hoc echo removal for the mic track (build-plan D6).

  detect_bleed(mic, system)            coherence bleed detector -> verdict
  remove_echo(mic, system, out)        align reference, LocalVQE v1.4-AEC, trim latency, self-check
  dedup_words(mic_words, sys_words)    text-level fallback, only when remove_echo reports failed=True
  drop_residue(mic_words, sys_words)   bleed meetings: drop <=2-word mic fragments over system speech

LocalVQE is the standalone build from tools/build_localvqe.sh, not `fluidaudiocli enhance`: that command
ships a different model (v1.3 / v1.2, never v1.4-AEC) whose output differs by >30 dB ERLE and also gates the
noise floor (see build-plan D6). Detector and signal helpers are shared with tools/aec/*.py, which import them.
"""
import re
import subprocess
import tempfile
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.ndimage import binary_dilation
from scipy.signal import correlate, resample_poly

ROOT = Path(__file__).resolve().parent
LVQE = ROOT / ".build-tools/localvqe/ggml/build/localvqe"
MODEL = ROOT / ".build-tools/models/localvqe-v1.4-aec-200K-f32.gguf"
SR, FRAME, HOP, FR = 16000, 320, 160, 320
LATENCY = 256  # samples (16 ms): the model's output lags its input by one hop
LOCALVQE_TIMEOUT = 900  # seconds per call
BLEED_THR = 0.02  # mean coherence 300-3400 Hz; unrelated speech <= 0.010, bleed >= 0.018 (synthetic sweep)
BLEED_SHARE = 1 / 3  # flag when at least this share of scored windows reach BLEED_THR
TARGET_LAG_MS = 60  # LocalVQE copes with an echo lag from ~40 ms up; a lead beyond ~20 ms breaks it
MIN_REDUCTION_DB = 3.0  # self-check: the echo-to-rest ratio in echo windows must fall by at least this much
MAX_NEAR_LOSS_DB = 3.0  # ...and system-silent frames (near end alone) must not lose more than this
NULL_COH = 0.003  # coherence of unrelated signals over a 10 s window; floors the "after" score so it cannot be 0
CHUNK_GOOD_DB = 6.0  # a chunk whose echo windows fell by less than this is retried at the other reference lags
RETRY_LAGS_MS = (160, 240, 100, 400)  # LocalVQE sometimes passes a chunk through untouched (see _clean_chunk)
CHUNK_S, OVERLAP_S = 30, 2  # per-chunk lag estimate + alignment: 500 ppm drift gives ERLE 3 dB whole-file, 17 dB at 30 s


class LocalVQEMissing(RuntimeError):
    """The LocalVQE binary or model is not built (tools/build_localvqe.sh)."""


# ---------- signal helpers (shared with tools/aec) ----------
def load16k(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x.mean(1)
    if sr != SR:
        g = gcd(SR, sr)
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return x


def envelope(x):
    n = 1 + (len(x) - FRAME) // HOP
    idx = np.arange(FRAME)[None, :] + HOP * np.arange(n)[:, None]
    return np.sqrt((x[idx] ** 2).mean(1))


def frames(x):
    n = len(x) // FR
    return x[: n * FR].reshape(n, FR)


def active(x, db=-40):
    """Per-frame mask: frame RMS within `db` of the RMS of the non-silent frames."""
    r = np.sqrt((frames(x) ** 2).mean(1))
    a = r > 1e-5
    if not a.any():
        return np.zeros(len(r), bool)
    return r > 10 ** (db / 20) * np.sqrt((r[a] ** 2).mean())


def db(a, b):
    return float(10 * np.log10((a ** 2).sum() / max((b ** 2).sum(), 1e-20)))


def window_scores_coh(mic, sysm, win_s=10, lag_max_ms=800, active_db=-50, min_active=0.15):
    """Lag from waveform cross-correlation (0..lag_max), then mean magnitude-squared coherence of mic vs the
    lag-aligned system over 300-3400 Hz. Null (unrelated speech) ~ 0.003; echo >> that."""
    from scipy.signal import coherence
    w, out = win_s * SR, []
    for s in range(0, len(sysm) - w // 2, w):
        a, m = sysm[s:s + w], mic[s:s + w + int(lag_max_ms * 16) + 1]
        a_env = envelope(a)
        if len(a) < w // 2 or (a_env > 10 ** (active_db / 20)).mean() < min_active:
            out.append({"t": s / SR, "score": None, "lag_ms": None})
            continue
        L = int(lag_max_ms * 16)
        mm = np.pad(m, (0, max(0, len(a) + L - len(m))))
        c = correlate(mm[: len(a) + L], a, mode="valid", method="fft")  # c[k] = sum mic[t+k]*sys[t]
        lag = int(np.argmax(c[: L + 1]))
        f, g = coherence(mm[lag: lag + len(a)], a, fs=SR, nperseg=2048, noverlap=1536)
        b = (f >= 300) & (f <= 3400)
        out.append({"t": s / SR, "score": round(float(g[b].mean()), 4), "lag_ms": round(lag / 16)})
    return out


def estimate_lag_ms(mic, sysm, lo_ms=-500, hi_ms=800, seg_s=60):
    """Lag (ms) of the echo in mic relative to system (positive = mic echo is later), from waveform
    cross-correlation on the loudest seg_s of the system track. Negative lag = the reference is
    *behind* the mic (track start offsets); LocalVQE cannot cancel that, advance the reference."""
    w = int(seg_s * SR)
    e = envelope(sysm)
    hop = SR // 100
    tot = np.convolve(e ** 2, np.ones(min(w // hop, len(e))), "valid")
    s = int(np.argmax(tot)) * hop
    a = sysm[s: s + w]
    lo, hi = int(lo_ms * 16), int(hi_ms * 16)
    m = mic[max(0, s + lo): s + len(a) + hi]
    m = np.pad(m, (max(0, -(s + lo)), 0))  # keep index 0 == sample s+lo
    m = np.pad(m, (0, max(0, len(a) + hi - lo - len(m))))
    c = correlate(m, a, mode="valid", method="fft")
    return round((int(np.argmax(c[: hi - lo + 1])) + lo) / 16)


def shift_reference(ref, lag_ms, n, target_ms=None):
    """Reference cropped/padded to n samples. If the mic echo leads or barely trails it (lag < 40 ms) the reference
    is advanced (leading samples dropped) so the echo lag becomes ~TARGET_LAG_MS; otherwise it is left alone.
    target_ms: always move the echo lag to this value instead (advance, or delay with leading zeros)."""
    if target_ms is not None:
        adv = int(SR * (target_ms - lag_ms) / 1000)
    else:
        adv = int(SR * max(0, TARGET_LAG_MS - lag_ms) / 1000) if lag_ms < 40 else 0
    r = ref[adv:] if adv >= 0 else np.concatenate([np.zeros(-adv, np.float32), ref])
    return np.pad(r, (0, max(0, n - len(r))))[:n].astype(np.float32)


def align_start(system, offset_s):
    """Put the system track on the mic track's clock. offset_s = system track start minus mic track start on the
    meeting timeline (process_meeting's track_offsets): > 0 pads the front, < 0 drops leading samples."""
    k = int(round(abs(offset_s) * SR))
    return np.concatenate([np.zeros(k, np.float32), system]) if offset_s > 0 else system[k:]


# ---------- detector ----------
def detect_bleed(mic_path, system_path, thr=BLEED_THR, system_offset_s=0.0):
    """-> {"bleed": bool, "verdict": "bleed"|"clean"|"unknown", "share": float|None, "lag_ms": int,
           "scores": [per-10s-window coherence or None], "times": [window start s], "thr": thr}
    "unknown" = no window had enough system audio to score (e.g. system track silent): treat as no bleed."""
    mic, sysm = load16k(mic_path), align_start(load16k(system_path), system_offset_s)
    return _detect(mic, sysm, thr)


def _detect(mic, sysm, thr=BLEED_THR):
    if len(mic) < SR or len(sysm) < SR:
        return {"bleed": False, "verdict": "unknown", "share": None, "lag_ms": 0, "scores": [], "times": [], "thr": thr}
    lag = estimate_lag_ms(mic, sysm)
    # the coherence scorer only searches lags >= 0, so a mic that leads the reference must be re-aligned first
    wins = window_scores_coh(mic, shift_reference(sysm, lag, len(sysm)) if lag < 0 else sysm)
    sc = [w["score"] for w in wins if w["score"] is not None]
    if not sc:
        return {"bleed": False, "verdict": "unknown", "share": None, "lag_ms": lag, "scores": [w["score"] for w in wins],
                "times": [w["t"] for w in wins], "thr": thr}
    share = float(np.mean([s >= thr for s in sc]))
    bleed = share >= BLEED_SHARE
    return {"bleed": bleed, "verdict": "bleed" if bleed else "clean", "share": round(share, 3), "lag_ms": lag,
            "scores": [w["score"] for w in wins], "times": [w["t"] for w in wins], "thr": thr}


# ---------- LocalVQE ----------
def _localvqe(mic, ref):
    """Run the standalone binary on equal-length float arrays -> output aligned to mic (latency trimmed)."""
    n = len(mic)
    with tempfile.TemporaryDirectory() as d:
        sf.write(f"{d}/m.wav", mic, SR, subtype="FLOAT")
        sf.write(f"{d}/r.wav", ref, SR, subtype="FLOAT")
        p = subprocess.run([str(LVQE), str(MODEL), "--in-wav", f"{d}/m.wav", f"{d}/r.wav", "--out-wav", f"{d}/o.wav"],
                           capture_output=True, text=True, timeout=LOCALVQE_TIMEOUT)
        if p.returncode or not Path(f"{d}/o.wav").exists():
            raise RuntimeError("localvqe failed: " + (p.stdout + p.stderr)[-600:])
        o = sf.read(f"{d}/o.wav", dtype="float32")[0]
    o = o[LATENCY:]
    return np.pad(o, (0, max(0, n - len(o))))[:n]


def _chunks(n, chunk, overlap):
    """[(a, b)] core ranges covering n; a tail shorter than half a chunk merges into the previous one."""
    cuts = list(range(0, n, chunk)) + [n]
    if len(cuts) > 2 and cuts[-1] - cuts[-2] < chunk // 2:
        del cuts[-2]
    return list(zip(cuts[:-1], cuts[1:]))


def _reduction(mic_scores, out_scores):
    """Echo-to-rest ratio before/after, dB, over the windows where the mic is coherent with the reference (echo
    present: score >= BLEED_THR). Coherence g = E / (E + rest), so g / (1 - g) = E / rest; the ratio of the summed
    values is how much the echo fell relative to everything else, which near-end speech cannot fake. None = no echo
    window, so there is nothing to measure."""
    before = after = 0.0
    n = 0
    for a, b in zip(mic_scores, out_scores):
        if a["score"] is None or a["score"] < BLEED_THR or b["score"] is None:
            continue
        g, h = min(a["score"], 0.999), min(max(b["score"] if b["score"] == b["score"] else 0.0, NULL_COH), 0.999)
        before += g / (1 - g)
        after += h / (1 - h)
        n += 1
    return round(float(10 * np.log10(before / after)), 1) if n else None


def echo_reduction_db(mic, out, ref):
    """_reduction over whole tracks. ref must be on the mic's clock with a non-negative echo lag (see shift_reference)."""
    return _reduction(window_scores_coh(mic, ref), window_scores_coh(out, ref))


def _clean_chunk(m, s, lag):
    """-> cleaned chunk, or None when the mic shows no echo to remove. The standalone LocalVQE sometimes returns a
    clip untouched (measured: 0.3 dB instead of 11-19 dB on a 34 s clip with a 260 ms echo; it flips with the echo lag
    and the clip bounds, deterministically). That is visible as an unchanged echo window, so the chunk is retried with
    the echo lag moved to RETRY_LAGS_MS and the best result kept. Chunks without coherent echo (a silent or sparse
    system track: pings, clicks) are not run at all: LocalVQE adds energy there instead of removing any."""
    ref = shift_reference(s, lag, len(m))
    mic_scores = window_scores_coh(m, ref)
    if not any(w["score"] is not None and w["score"] >= BLEED_THR for w in mic_scores):
        return None
    best, best_db = None, None
    for target in (None, *RETRY_LAGS_MS):
        y = _localvqe(m, ref if target is None else shift_reference(s, lag, len(m), target))
        db_ = _reduction(mic_scores, window_scores_coh(y, ref)) or 0.0
        if best is None or db_ > best_db:
            best, best_db = y, db_
        if best_db >= CHUNK_GOOD_DB:
            break
    return best


def process(mic, system, chunk_s=CHUNK_S, overlap_s=OVERLAP_S):
    """Arrays -> (cleaned, info). Each chunk gets its own lag estimate and reference alignment; chunk cores are
    joined with a short crossfade taken from the overlap context. Chunks with no echo pass through unchanged (lag None)."""
    n = len(mic)
    system = np.pad(system, (0, max(0, n - len(system))))[:n]
    chunk, ov, xf = int(chunk_s * SR), int(overlap_s * SR), int(0.05 * SR)
    out, wsum, lags = np.zeros(n, np.float32), np.zeros(n, np.float32), []
    glag = estimate_lag_ms(mic, system) if n > SR else 0
    for a, b in _chunks(n, chunk, ov):
        lo, hi = max(0, a - ov), min(n, b + ov)
        m, s = mic[lo:hi], system[lo:hi]
        lag = estimate_lag_ms(m, s, seg_s=chunk_s) if len(m) > 10 * SR else glag
        y = _clean_chunk(m, s, lag)
        lags.append(None if y is None else lag)
        if y is None:
            y = m
        t = np.arange(lo, hi)  # absolute sample index; weight is 1 in the core, ramps over xf at interior edges
        w = np.ones(len(m), np.float32)
        if a > 0:
            w *= np.clip((t - (a - xf // 2)) / xf, 0, 1)
        if b < n:
            w *= np.clip(((b + xf // 2) - t) / xf, 0, 1)
        out[lo:hi] += y * w
        wsum[lo:hi] += w
    out /= np.maximum(wsum, 1e-6)
    return out, {"chunk_lags_ms": lags, "global_lag_ms": glag}


def self_check(mic, out, system, lag_ms=0):
    """Truth-free check. reduction_echo_dB: in the 10 s windows where the mic is coherent with the system track (echo
    present), the echo-to-rest ratio must fall by >= MIN_REDUCTION_DB (see _reduction; None = no echo window to judge).
    Energy is the wrong yardstick here: echo-dominant frames picked by mic level are the ones where the echo is weakest,
    and the energy of a laptop-speaker recording sits below 300 Hz where LocalVQE does nothing (measured: 1.3 dB energy
    reduction on a recording whose coherence fell from 0.8-0.95 to 0.01). System-silent frames (near end alone) must keep
    their energy within MAX_NEAR_LOSS_DB. lag_ms: echo lag; a negative one means the reference is advanced first."""
    n = min(len(mic), len(out), len(system))
    mic, out, system = mic[:n], out[:n], system[:n]
    sa = active(system, -45)
    mf, of = frames(mic), frames(out)
    k = min(len(sa), len(mf))
    sa, mf, of = sa[:k], mf[:k], of[:k]
    r = {"reduction_echo_dB": None, "near_change_dB": None, "ok": False}
    r["reduction_echo_dB"] = echo_reduction_db(mic, out, shift_reference(system, lag_ms, n) if lag_ms < 0 else system)
    quiet = ~binary_dilation(sa, iterations=15)
    if quiet.sum() >= 20 and (mf[quiet] ** 2).sum() > 1e-9:
        r["near_change_dB"] = round(db(of[quiet].ravel(), mf[quiet].ravel()), 1)  # negative = near end got quieter
    r["ok"] = (r["reduction_echo_dB"] is not None and r["reduction_echo_dB"] >= MIN_REDUCTION_DB
               and (r["near_change_dB"] is None or r["near_change_dB"] >= -MAX_NEAR_LOSS_DB))
    return r


def remove_echo(mic_path, system_path, out_path, chunk_s=CHUNK_S, system_offset_s=0.0):
    """Clean the mic track. Writes out_path (16 kHz mono float WAV) and returns
    {"failed": bool, "reason": str|None, "self_check": {...}, "lag_ms": int, "chunk_lags_ms": [...], "seconds": float}.
    failed=True means the caller should discard out_path and fall back to dedup_words (a file is still written,
    for inspection). system_offset_s as in align_start; the output stays on the mic track's clock and length.
    Raises only for environment problems (missing binary/model: LocalVQEMissing)."""
    import time
    if not LVQE.exists() or not MODEL.exists():
        raise LocalVQEMissing("LocalVQE not built: run tools/build_localvqe.sh")
    t0 = time.time()
    mic, system = load16k(mic_path), align_start(load16k(system_path), system_offset_s)
    info = {"failed": False, "reason": None, "self_check": None, "lag_ms": None, "chunk_lags_ms": [], "seconds": 0.0}
    if len(mic) < 2 * SR or len(system) < 2 * SR:
        sf.write(out_path, mic, SR, subtype="FLOAT")
        return {**info, "failed": True, "reason": "track shorter than 2 s", "seconds": round(time.time() - t0, 1)}
    try:
        out, pi = process(mic, system, chunk_s)
    except (RuntimeError, subprocess.TimeoutExpired, OSError) as e:
        sf.write(out_path, mic, SR, subtype="FLOAT")
        return {**info, "failed": True, "reason": str(e)[:300], "seconds": round(time.time() - t0, 1)}
    sf.write(out_path, out, SR, subtype="FLOAT")
    chk = self_check(mic, out, system, pi["global_lag_ms"])
    info.update(self_check=chk, lag_ms=pi["global_lag_ms"], chunk_lags_ms=pi["chunk_lags_ms"])
    if not chk["ok"]:
        info.update(failed=True, reason="self-check: " + (
            "no meaningful echo reduction" if (chk["reduction_echo_dB"] or 0) < MIN_REDUCTION_DB else "near-end energy lost"))
    info["seconds"] = round(time.time() - t0, 1)
    return info


# ---------- text fallback ----------
def _norm(t):
    return re.sub(r"[^a-z0-9']", "", t.lower())


def dedup_words(mic_words, system_words, window=1.5):
    """Fallback when remove_echo failed. Words are dicts {text,start,end}. A mic word is flagged as echo when the
    same word occurs in the system words within +-window s of its start, and it is either >= 4 letters or
    next to another flagged word (so a genuine short "the"/"yes" between echoes survives only if isolated).
    Returns (kept, dropped); dropped items are copies with "echo": True and "echo_of": matching system word."""
    sysw = [(_norm(w["text"]), w["start"], w) for w in system_words if _norm(w["text"])]
    cand = []
    for w in mic_words:
        t = _norm(w["text"])
        hit = next((sw for st, ss, sw in sysw if t and st == t and abs(w["start"] - ss) <= window), None)
        cand.append(hit)
    kept, dropped = [], []
    for i, w in enumerate(mic_words):
        hit = cand[i]
        t = _norm(w["text"])
        near = (i > 0 and cand[i - 1] is not None) or (i + 1 < len(cand) and cand[i + 1] is not None)
        if hit is not None and (len(t) >= 4 or near):
            dropped.append({**w, "echo": True, "echo_of": hit["text"]})
        else:
            kept.append(w)
    return kept, dropped


def drop_residue(mic_words, system_words, gap=1.0, max_words=2, slack=0.5):
    """Bleed meetings: removal leaves scraps of the other side ("Where", "the", "is"). Drop any mic utterance (words
    split at `gap` s of silence) of <= max_words words that overlaps system-track speech within `slack` s. Both
    word lists must be on one clock. Known trade-off: a real one-word backchannel while the other side talks goes too.
    Returns (kept, dropped)."""
    kept, dropped, run = [], [], []

    def flush():
        hit = len(run) <= max_words and any(
            w["start"] - slack < max(r["end"] for r in run) and w["end"] + slack > run[0]["start"] for w in system_words)
        (dropped if hit else kept).extend(run)
        run.clear()

    for w in sorted(mic_words, key=lambda w: w["start"]):
        if run and w["start"] - max(r["end"] for r in run) > gap:
            flush()
        run.append(w)
    if run:
        flush()
    return kept, dropped
