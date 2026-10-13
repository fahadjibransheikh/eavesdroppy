import json, subprocess, tempfile, numpy as np
FA = "fluidaudio/.build/release/fluidaudiocli"   # swift build -c release --product fluidaudiocli (tag v0.17.7)
def diarize(wav16k_mono, min_seg=0.3):
    out = tempfile.mktemp(suffix=".json")
    subprocess.run([FA, "process", wav16k_mono, "--mode", "offline", "--min-segment-duration", str(min_seg), "--output", out],
                   check=True, capture_output=True)
    d = json.load(open(out)); segs, emb = [], {}
    for s in d["segments"]:
        segs.append((s["startTimeSeconds"], s["endTimeSeconds"], s["speakerId"]))
        v = np.array(s["embedding"], "float64"); emb[s["speakerId"]] = v / np.linalg.norm(v)   # per-SPEAKER voiceprint (identical across that speaker's segments)
    return segs, emb
def match(vec, profiles, thr=0.7):   # profiles: {name: unit-vector}
    name, sim = max(((n, float(vec @ p)) for n, p in profiles.items()), key=lambda t: t[1], default=(None, -1))
    return (name, sim) if sim >= thr else (None, sim)
if __name__ == "__main__":
    s1, e1 = diarize("data/d_meeting1.wav"); s2, e2 = diarize("data/d_meeting2.wav")
    print(len(s1), "segs;", sorted(e1), sorted(e2))
    for k, v in e2.items(): print(k, match(v, e1, 0.0), "all:", {a: round(float(v @ b), 3) for a, b in e1.items()})
