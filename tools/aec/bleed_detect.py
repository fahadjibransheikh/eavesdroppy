#!/usr/bin/env python3
"""Echo-bleed detector: envelope correlation between mic and system tracks.

  .venv/bin/python tools/aec/bleed_detect.py mic.flac system.flac [--json]

Per 10 s window (of system time), two scorers (lag searched over 0..800 ms):
  env: Pearson correlation of 20 ms-frame RMS envelopes, system[t] vs mic[t+lag]  (thr ~0.7; weak, see notes)
  coh: mean magnitude-squared coherence 300-3400 Hz after aligning at the waveform xcorr lag
       (default; unrelated speech scores <= 0.010, bleed >= 0.018 on the synthetic sweep)
Windows where the system track is mostly silent carry no information and are skipped.
verdict = share of scored windows with score >= --thr.
"""
import argparse, json, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from echo import SR, FRAME, HOP, load16k, envelope, window_scores_coh, estimate_lag_ms  # noqa: E402,F401  (shared with the pipeline)


def window_scores(mic, sysm, win_s=10, lag_min_ms=0, lag_max_ms=800, active_db=-50, min_active=0.15):
    """-> list of dicts {t, score, lag_ms} (score None = skipped, system mostly silent)."""
    em, es = envelope(mic), envelope(sysm)
    n = min(len(em), len(es))
    em, es = em[:n], es[:n]
    w = int(win_s * 100)
    lags = range(int(lag_min_ms / 10), int(lag_max_ms / 10) + 1)
    thr = 10 ** (active_db / 20)
    out = []
    for s in range(0, n - w // 2, w):  # last partial window kept if >= half a window
        a = es[s:s + w]
        if len(a) < w // 2 or (a > thr).mean() < min_active:
            out.append({"t": s / 100, "score": None, "lag_ms": None})
            continue
        best, bl = -2.0, 0
        for L in lags:
            b = em[s + L: s + L + len(a)]
            if len(b) < len(a) or a.std() < 1e-9 or b.std() < 1e-9:
                continue
            r = np.corrcoef(a, b)[0, 1]
            if r > best:
                best, bl = r, L * 10
        out.append({"t": s / 100, "score": None if best < -1 else round(float(best), 3), "lag_ms": bl})
    return out


def verdict(wins, thr=0.7):
    sc = [x["score"] for x in wins if x["score"] is not None]
    share = float(np.mean([s >= thr for s in sc])) if sc else None
    return {"scored_windows": len(sc), "total_windows": len(wins), "share_ge_thr": share, "thr": thr,
            "median_score": float(np.median(sc)) if sc else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mic")
    ap.add_argument("system")
    ap.add_argument("--method", choices=["coh", "env"], default="coh")
    ap.add_argument("--thr", type=float, help="default: 0.02 for coh, 0.7 for env")
    ap.add_argument("--lag-max-ms", type=int, default=800)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    thr = a.thr if a.thr is not None else (0.02 if a.method == "coh" else 0.7)
    mic, sysm = load16k(a.mic), load16k(a.system)
    wins = (window_scores_coh if a.method == "coh" else window_scores)(mic, sysm, lag_max_ms=a.lag_max_ms)
    v = verdict(wins, thr)
    if a.json:
        print(json.dumps({**v, "windows": wins}))
    else:
        for x in wins:
            print(f"t={x['t']:6.1f}s score={x['score']} lag={x['lag_ms']}ms")
        print(v)


if __name__ == "__main__":
    main()
