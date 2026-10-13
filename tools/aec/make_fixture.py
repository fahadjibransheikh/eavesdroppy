#!/usr/bin/env python3
"""Synthetic echo-bleed fixtures for AEC / bleed-detector tests (macOS `say`, 16 kHz).

  .venv/bin/python tools/aec/make_fixture.py OUTDIR [--seed N]

Each fixture dir has: mic.wav, system.wav, near_clean.wav, echo_clean.wav, truth.json.
  system = far-end conversation (2 voices). mic = near-end voice + far-end through a
  synthetic room (delay + reflections + diffuse tail) + light noise.
Fixtures: bleed (80 ms, echo ~ -3 dB re near), bleed_hard (150 ms, +3 dB, speaker
nonlinearity), bleed_weak (30 ms, -15 dB), headphones (no echo), nearsilent (echo only).
"""
import argparse, json, subprocess, sys, tempfile
from math import gcd
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.signal import resample_poly, fftconvolve

SR = 16000
# (far voices, near voice, say rate); set 0 is the default fixture
VOICE_SETS = [(["Daniel", "Karen"], "Samantha", 175), (["Rishi", "Moira"], "Ralph", 160), (["Tessa", "Fred"], "Kathy", 190)]
FAR = [
    "Thanks everyone for joining, let's start with the quarterly numbers for the northern region.",
    "Revenue grew strongly compared with last quarter, mostly driven by the new subscription plans.",
    "The biggest risk is the supplier delay in Rotterdam, which could push the launch back two weeks.",
    "We should also discuss the hiring plan, because three engineers are leaving before the end of November.",
    "Marketing needs final approval on the brochure before Friday, otherwise the printer will miss the deadline.",
    "Customers keep asking about the mobile application, so I would prioritize offline mode next sprint.",
    "Let me summarize the action items and send the notes to the whole team this afternoon.",
    "Great, thank you all, and please remember to update the shared spreadsheet before you leave.",
]
NEAR = [
    "Sounds good, I have the slides ready whenever you want me to share them.",
    "That is a fair point, but the supplier has promised a new delivery date by Wednesday.",
    "I can take the brochure approval, and I will check with legal this morning.",
    "Offline mode is already partly finished, so we could ship a beta in a couple of weeks.",
    "Yes, and I will also add the budget figures to that spreadsheet tonight.",
    "Thanks, talk to you all tomorrow.",
]
# (kind, index, mode). near "after": starts 0.4 s after the pointer (near-only); "over": starts 45% into the last far turn.
LAYOUT = [("F", 0), ("N", 0, "after"), ("F", 1), ("N", 1, "over"), ("F", 2), ("F", 3), ("N", 2, "over"),
          ("F", 4), ("N", 3, "after"), ("F", 5), ("N", 4, "over"), ("F", 6), ("F", 7), ("N", 5, "after")]


def say(voice, text, rate=175):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "u.aiff"
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(p), text], check=True)
        x, sr = sf.read(p, dtype="float32")
    if x.ndim > 1:
        x = x.mean(1)
    g = gcd(SR, sr)
    x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    nz = np.flatnonzero(np.abs(x) > 1e-3)  # trim leading/trailing silence
    return x[nz[0]: nz[-1] + 1] if len(nz) else x


def act_rms(x, frame=320):
    n = len(x) // frame
    r = np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(1))
    a = r > 10 ** (-35 / 20) * np.sqrt((x ** 2).mean() + 1e-12) * 1.0
    return float(np.sqrt((r[a] ** 2).mean())) if a.any() else 1e-9


def rir(rng, delay_ms, nonlin=False):
    n = int(SR * (delay_ms / 1000 + 0.45))
    h = np.zeros(n, np.float32)
    d = int(SR * delay_ms / 1000)
    h[d] = 1.0
    for off, g in [(7, 0.5), (19, 0.4), (41, -0.3), (66, 0.25), (110, -0.15)]:
        h[d + int(SR * off / 1000)] += g
    t = np.arange(n - d - int(0.01 * SR)) / SR  # diffuse tail, RT60 ~ 0.25 s
    tail = rng.standard_normal(len(t)) * np.exp(-6.9 * t / 0.25) * 0.12
    h[d + int(0.01 * SR):] += tail.astype(np.float32)
    return h


def fix(far, near, delay_ms, echo_db, rng, noise_dbfs=-50, nonlin=False, near_silent=False, drift_ppm=0):
    n = len(far)
    f = np.tanh(2.0 * far) / 2.0 if nonlin else far
    echo = fftconvolve(f, rir(rng, delay_ms))[:n].astype(np.float32)
    if drift_ppm:  # mic clock slightly off the tap clock: the echo slides against the reference
        echo = np.interp(np.arange(n) * (1 + drift_ppm * 1e-6), np.arange(n), echo).astype(np.float32)
    nrms = act_rms(near)
    if echo_db is None:
        echo[:] = 0
    else:
        echo *= 10 ** (echo_db / 20) * nrms / act_rms(echo)
    nz = rng.standard_normal(n).astype(np.float32)
    nz = np.convolve(nz, np.ones(4) / 4, "same")  # light low-pass: roomy hiss
    nz *= 10 ** (noise_dbfs / 20) / (nz.std() + 1e-9)
    nr = np.zeros(n, np.float32) if near_silent else near
    return (nr + echo + nz).astype(np.float32), echo, nr


def build(seed, vset=0):
    rng = np.random.default_rng(seed)
    fv, nv, rate = VOICE_SETS[vset]
    far_u = [say(fv[i % 2], t, rate) for i, t in enumerate(FAR)]
    near_u = [say(nv, t, rate) for t in NEAR]
    gap = lambda s: int(SR * s)
    segs, ptr, last_far = [], gap(1.0), None  # (who, idx, start, end)
    for e in LAYOUT:
        if e[0] == "F":
            u = far_u[e[1]]
            segs.append(("far", e[1], ptr, ptr + len(u)))
            last_far = segs[-1]
            ptr += len(u) + gap(0.5)
        else:
            u = near_u[e[1]]
            s = ptr + gap(0.4) if e[2] == "after" else last_far[2] + int(0.45 * (last_far[3] - last_far[2]))
            segs.append(("near", e[1], s, s + len(u)))
            ptr = max(ptr, s + len(u) + gap(0.3))
    total = ptr + gap(1.0)
    far, near = np.zeros(total, np.float32), np.zeros(total, np.float32)
    for who, i, s, e in segs:
        (far if who == "far" else near)[s:e] += (far_u if who == "far" else near_u)[i]
    far *= 0.05 / act_rms(far)
    near *= 0.05 / act_rms(near)
    return rng, far, near, segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--voice-set", type=int, default=0, choices=range(len(VOICE_SETS)))
    a = ap.parse_args()
    rng, far, near, segs = build(a.seed, a.voice_set)
    print(f"far/near length {len(far)/SR:.1f}s", file=sys.stderr)
    specs = {  # name: (delay_ms, echo_db re near, nonlin, near_silent, drift_ppm, system_gain_db)
        "bleed": (80, -3, False, False, 0, 0), "bleed_hard": (150, 3, True, False, 0, 0),
        "bleed_weak": (30, -15, False, False, 0, 0), "headphones": (80, None, False, False, 0, 0),
        "nearsilent": (80, -3, False, True, 0, 0), "bleed_late": (300, -3, False, False, 0, 0),
        "bleed_drift": (80, -3, False, False, 500, 0),   # 500 ppm = 32 ms slip over 64 s
        "bleed_quietref": (80, -3, False, False, 0, -20),  # tap level != speaker level
    }
    for name, (dly, edb, nl, ns, drift, sg) in specs.items():
        mic, echo, nr = fix(far, near, dly, edb, rng, nonlin=nl, near_silent=ns, drift_ppm=drift)
        d = Path(a.outdir) / name
        d.mkdir(parents=True, exist_ok=True)
        for fn, x in [("mic", mic), ("system", far * 10 ** (sg / 20)), ("near_clean", nr), ("echo_clean", echo)]:
            sf.write(d / f"{fn}.wav", np.clip(x, -1, 1), SR, subtype="PCM_16")
        near_t = [] if ns else [NEAR[i] for w, i, s, e in sorted(segs, key=lambda z: z[2]) if w == "near"]
        far_t = [FAR[i] for w, i, s, e in sorted(segs, key=lambda z: z[2]) if w == "far"]
        json.dump({"name": name, "delay_ms": dly, "echo_db_re_near": edb, "nonlinear": nl,
                   "near_text": " ".join(near_t), "far_text": " ".join(far_t),
                   "segments": [{"who": w, "idx": i, "start": s / SR, "end": e / SR} for w, i, s, e in segs]},
                  open(d / "truth.json", "w"), indent=1)
        print("wrote", d)


if __name__ == "__main__":
    main()
