#!/usr/bin/env python3
"""Run LocalVQE on mic+system and score it; also scores the transcript-dedup fallback.

  .venv/bin/python tools/aec/aec_eval.py FIXDIR [FIXDIR...] [--out OUTDIR] [--ref-delay-ms N]

FIXDIR holds mic.* and system.* (wav/flac, any rate). If near_clean.wav, echo_clean.wav and
truth.json are also there (make_fixture.py), you get ERLE / SI-SDR / WER numbers; otherwise
(real recordings) you get the truth-free self-check and word-leak counts against the
system transcript. Needs bin/fluidaudiocli (tools/build_fluidaudio.sh) and the LocalVQE
build + model in .build-tools/ (tools/build_localvqe.sh).
"""
import argparse, json, re, subprocess, sys, tempfile
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.ndimage import binary_dilation
from scipy.signal import fftconvolve

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bleed_detect import window_scores, verdict  # noqa: E402
from echo import load16k, window_scores_coh, estimate_lag_ms, frames, active, db, LVQE, MODEL, SR, FR, _localvqe  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FA = ROOT / "bin/fluidaudiocli"


def find(d, stem):
    for ext in ("wav", "flac"):
        if (d / f"{stem}.{ext}").exists():
            return d / f"{stem}.{ext}"


def run_localvqe(mic, ref, out, ref_delay_ms=0):
    """Whole-file run (no chunking). ref_delay_ms > 0 delays the reference, < 0 advances it. The model latency
    is trimmed from the output, so out_lag_samples should read 0."""
    x, r = load16k(mic), load16k(ref)
    if ref_delay_ms > 0:
        r = np.concatenate([np.zeros(int(SR * ref_delay_ms / 1000), np.float32), r])
    elif ref_delay_ms < 0:  # mic echo LEADS the reference (measured: fails beyond ~20 ms)
        r = r[int(SR * -ref_delay_ms / 1000):]
    r = np.pad(r, (0, max(0, len(x) - len(r))))[: len(x)]
    sf.write(out, _localvqe(x, r), SR, subtype="PCM_16")


# ---------- signal metrics ----------
def masks(near, echo):
    na, ea = active(near), active(echo)
    n = min(len(na), len(ea))
    na, ea = na[:n], ea[:n]
    d = lambda m, k: binary_dilation(m, iterations=k)
    return {"far_only": ea & ~d(na, 10), "near_only": na & ~d(ea, 15), "double_talk": na & ea,
            "quiet": ~d(na, 12) & ~d(ea, 15)}


def sel(x, m):
    f = frames(x)[: len(m)]
    return f[m].ravel()


def si_sdr(est, ref):
    if len(ref) == 0 or (ref ** 2).sum() < 1e-12:
        return None
    est, ref = est - est.mean(), ref - ref.mean()
    t = (est @ ref) / (ref @ ref) * ref
    return float(10 * np.log10((t ** 2).sum() / max(((est - t) ** 2).sum(), 1e-20)))


def corr(est, ref):
    if len(ref) == 0 or ref.std() < 1e-9 or est.std() < 1e-9:
        return None
    return float(np.corrcoef(est, ref)[0, 1])


def best_lag(out, ref, maxlag=1600):
    c = fftconvolve(out, ref[::-1], mode="full")
    mid = len(ref) - 1
    seg = c[mid - maxlag: mid + maxlag + 1]
    return int(np.argmax(seg) - maxlag)


def shift(x, lag):  # x[t+lag] -> position t
    return np.pad(x[lag:], (0, lag)) if lag >= 0 else np.pad(x[:lag], (-lag, 0))


def signal_metrics(d, mic, out):
    near, echo = load16k(find(d, "near_clean")), load16k(find(d, "echo_clean"))
    n = min(len(near), len(out), len(mic))
    near, echo, out, mic = near[:n], echo[:n], out[:n], mic[:n]
    M = masks(near, echo)
    res = {"frames": {k: int(v.sum()) for k, v in M.items()}}
    lag = best_lag(out, near) if (near ** 2).sum() > 1e-9 else 0
    res["out_lag_samples"] = lag
    oa = shift(out, lag)
    if M["far_only"].sum():
        res["ERLE_far_only_dB"] = round(db(sel(mic, M["far_only"]), sel(out, M["far_only"])), 1)
    res["quiet_floor_change_dB"] = round(db(sel(mic, M["quiet"]), sel(out, M["quiet"])), 1) if M["quiet"].sum() else None
    for reg in ("near_only", "double_talk"):
        if M[reg].sum() and (near ** 2).sum() > 1e-9:
            r = sel(near, M[reg])
            res[f"{reg}_SISDR_mic_dB"] = round(si_sdr(sel(mic, M[reg]), r), 1)
            res[f"{reg}_SISDR_out_dB"] = round(si_sdr(sel(oa, M[reg]), r), 1)
            res[f"{reg}_corr_mic"] = round(corr(sel(mic, M[reg]), r), 3)
            res[f"{reg}_corr_out"] = round(corr(sel(oa, M[reg]), r), 3)
            res[f"{reg}_level_change_dB"] = round(db(sel(oa, M[reg]), r), 1)  # out level vs clean near, + = louder
    return res


def self_check(mic, out, system):
    """Truth-free: mic->out energy change on system-active vs system-silent frames (dB reduction)."""
    n = min(len(mic), len(out), len(system))
    sa = active(system[:n], -45)
    f = lambda x, m: frames(x[:n])[: len(m)][m].ravel()
    a, q = sa, ~binary_dilation(sa, iterations=15)
    return {"reduction_system_active_dB": round(db(f(mic, a), f(out, a)), 1) if a.sum() else None,
            "reduction_system_silent_dB": round(db(f(mic, q), f(out, q)), 1) if q.sum() else None}


# ---------- ASR ----------
def transcribe(wav):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([str(FA), "transcribe", str(wav), "--word-timestamps", "--output-json", f"{d}/o.json"],
                       capture_output=True, check=True)
        j = json.load(open(f"{d}/o.json"))
    return [(norm(w["word"]), w["startTime"], w["endTime"]) for w in j["wordTimings"] if norm(w["word"])]


def norm(t):
    return re.sub(r"[^a-z' ]", "", t.lower().replace("-", " ")).strip()


def toks(text):
    return [w for w in norm(text).split() if w]


def align(ref, hyp):
    """Levenshtein with backtrace -> (C, S, D, I, extra_hyp_tokens)."""
    R, H = len(ref), len(hyp)
    D = np.zeros((R + 1, H + 1), int)
    D[:, 0], D[0, :] = np.arange(R + 1), np.arange(H + 1)
    for i in range(1, R + 1):
        for j in range(1, H + 1):
            D[i, j] = min(D[i - 1, j - 1] + (ref[i - 1] != hyp[j - 1]), D[i - 1, j] + 1, D[i, j - 1] + 1)
    i, j, C, S, De, I, extra = R, H, 0, 0, 0, 0, []
    while i or j:
        if i and j and D[i, j] == D[i - 1, j - 1] + (ref[i - 1] != hyp[j - 1]):
            if ref[i - 1] == hyp[j - 1]:
                C += 1
            else:
                S += 1
                extra.append(hyp[j - 1])
            i, j = i - 1, j - 1
        elif i and D[i, j] == D[i - 1, j] + 1:
            De += 1
            i -= 1
        else:
            I += 1
            extra.append(hyp[j - 1])
            j -= 1
    return C, S, De, I, extra


def asr_metrics(words, truth):
    near, far = toks(truth["near_text"]), toks(truth["far_text"])
    hyp = [w for w, _, _ in words]
    far_distinct = [w for w in far if w not in set(near)]
    pool, hit = list(hyp), 0
    for w in far_distinct:
        if w in pool:
            pool.remove(w)
            hit += 1
    r = {"hyp_words": len(hyp)}
    if near:
        C, S, De, I, extra = align(near, hyp)
        r.update(near_WER_pct=round(100 * (S + De + I) / len(near), 1), near_words_kept_pct=round(100 * C / len(near), 1),
                 inserted_words=I + S)
    else:
        r.update(inserted_words=len(hyp))
    r["far_distinct_words_in_mic_pct"] = round(100 * hit / max(len(far_distinct), 1), 1)
    return r


def dedup(mic_words, sys_words, win=1.5):
    """Drop mic words that also occur in the system transcript within +-win seconds."""
    return [(w, s, e) for w, s, e in mic_words if not any(w == sw and abs(s - ss) <= win for sw, ss, _ in sys_words)]


# ---------- driver ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fixdirs", nargs="+")
    ap.add_argument("--out", help="where to write <name>_out.wav (default: <fixdir>/localvqe_out.wav)")
    ap.add_argument("--ref-delay-ms", type=int, default=0, help="manual reference shift (negative = advance)")
    ap.add_argument("--auto-align", action="store_true", help="estimate echo lag; advance the reference if mic echo leads it by < 40 ms")
    ap.add_argument("--json", help="write all results here")
    a = ap.parse_args()
    allr = {}
    for fd in map(Path, a.fixdirs):
        mic_p, sys_p = find(fd, "mic"), find(fd, "system")
        out_p = Path(a.out) / f"{fd.name}_out.wav" if a.out else fd / "localvqe_out.wav"
        out_p.parent.mkdir(parents=True, exist_ok=True)
        import time
        t0 = time.time()
        mic, sysm = load16k(mic_p), load16k(sys_p)
        lag = estimate_lag_ms(mic, sysm)
        shift_ms = a.ref_delay_ms or (min(0, lag - 60) if a.auto_align and lag < 40 else 0)
        run_localvqe(mic_p, sys_p, out_p, shift_ms)
        dt = time.time() - t0
        out = load16k(out_p)
        R = {"audio_s": round(len(mic) / SR, 1), "localvqe_wall_s": round(dt, 1), "est_echo_lag_ms": lag, "ref_shift_ms": shift_ms,
             "bleed_env": verdict(window_scores(mic, sysm), 0.7),
             "bleed_coh": verdict(window_scores_coh(mic, sysm), 0.02), "self_check": self_check(mic, out, sysm)}
        tw_mic, tw_out, tw_sys = transcribe(mic_p), transcribe(out_p), transcribe(sys_p)
        tw_dd = dedup(tw_mic, tw_sys)
        if find(fd, "near_clean") and (fd / "truth.json").exists():
            R["signal"] = signal_metrics(fd, mic, out)
            truth = json.load(open(fd / "truth.json"))
            R["asr_mic_raw"], R["asr_mic_localvqe"], R["asr_mic_dedup"] = (
                asr_metrics(w, truth) for w in (tw_mic, tw_out, tw_dd))
        else:
            R["words"] = {"mic_raw": len(tw_mic), "localvqe": len(tw_out), "dedup": len(tw_dd), "system": len(tw_sys)}
        allr[fd.name] = R
        print(f"=== {fd.name}\n{json.dumps(R, indent=1)}")
    if a.json:
        json.dump(allr, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
