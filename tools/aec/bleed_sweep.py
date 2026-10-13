#!/usr/bin/env python3
"""Score distributions of the bleed detector over synthetic conditions (in memory, no files).

  .venv/bin/python tools/aec/bleed_sweep.py [--mode env|logenv]
Conditions: 3 voice sets x {headphones, echo -15/-9/-3/+3 dB re near x delay 30/80/150/300 ms,
near-silent} + unrelated-speech negatives (mic of one set vs system of another).
"""
import argparse, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_fixture as mf
from bleed_detect import window_scores
from echo import window_scores_coh

FN = window_scores


def scores(mic, system):
    return [w["score"] for w in FN(mic, system) if w["score"] is not None]


def pct(x):
    x = np.array(x)
    return f"n={len(x):3d} min={x.min():.3f} p10={np.percentile(x,10):.3f} med={np.median(x):.3f} p90={np.percentile(x,90):.3f} max={x.max():.3f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thr", type=float, default=0.7)
    ap.add_argument("--method", choices=["env", "coh"], default="env")
    a = ap.parse_args()
    global FN
    FN = window_scores if a.method == "env" else window_scores_coh
    sets, groups = [], {}
    for v in range(len(mf.VOICE_SETS)):
        rng, far, near, _ = mf.build(0, v)
        sets.append((rng, far, near))
        g = lambda k, s: groups.setdefault(k, []).extend(s)
        mic, _, _ = mf.fix(far, near, 80, None, rng)
        g("headphones", scores(mic, far))
        mic, _, _ = mf.fix(far, near, 80, -3, rng, near_silent=True)
        g("nearsilent (echo -3 dB)", scores(mic, far))
        for edb in (-15, -9, -3, 3):
            for dly in (30, 80, 150, 300):
                mic, _, _ = mf.fix(far, near, dly, edb, rng)
                g(f"bleed echo {edb:+d} dB", scores(mic, far))
    for i, (rng, far, near) in enumerate(sets):  # unrelated speech: mic of set i, system of set i+1
        n = min(len(far), len(sets[(i + 1) % 3][1]))
        mic, _, _ = mf.fix(far, near, 80, None, rng)
        groups.setdefault("negatives: unrelated speech", []).extend(scores(mic[:n], sets[(i + 1) % 3][1][:n]))
    for k, x in groups.items():
        print(f"{k:32s} {pct(x)}  share>={a.thr}: {np.mean(np.array(x) >= a.thr):.2f}")


if __name__ == "__main__":
    main()
