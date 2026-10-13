"""Drop-in for process_meeting.transcribe(): FluidAudio Parakeet/Phonon-2 -> Fermion-shaped {"text", "words":[{"text","start","end"}]}.
With vocab, FluidAudio replaces words in `text` but leaves `wordTimings` raw, so re-align text tokens onto word timings."""
import json, subprocess, tempfile, difflib, re, os
FA = os.environ.get("FLUIDAUDIOCLI", "/private/tmp/claude-501/-Users-fahad-code-detta-meetings/4e897c6d-5a26-425c-a598-04085b2e1385/scratchpad/asr/FluidAudio/.build/release/fluidaudiocli")
def _k(w): return re.sub(r"\W", "", w).lower()
def transcribe(wav, vocab_file=None, model="v3", timeout=1800):
    with tempfile.TemporaryDirectory() as d:
        out = f"{d}/o.json"
        cmd = [FA, "transcribe", os.path.abspath(str(wav)), "--output-json", out, "--model-version", model]
        if vocab_file: cmd += ["--custom-vocab", os.path.abspath(str(vocab_file)), "--vocab-disable-spotter-rescue", "--vocab-min-similarity", "0.6"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd="/tmp")
        if r.returncode or not os.path.exists(out):  # CLI exits 0 on failure; the missing JSON is the signal
            raise RuntimeError(f"fluidaudiocli failed: {r.stderr[-400:]}")
        j = json.load(open(out))
    raw = [(w["word"], w["startTime"], w["endTime"]) for w in j["wordTimings"]]
    toks = j["text"].split()
    words = []
    sm = difflib.SequenceMatcher(None, [_k(w) for w, _, _ in raw], [_k(t) for t in toks], autojunk=False)
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal":
            words += [{"text": toks[b0 + i], "start": raw[a0 + i][1], "end": raw[a0 + i][2]} for i in range(a1 - a0)]
        elif b1 > b0 and a1 > a0:  # replaced span: spread new tokens evenly over the old span's time range
            s, e = raw[a0][1], raw[a1 - 1][2]; n = b1 - b0
            words += [{"text": toks[b0 + i], "start": s + (e - s) * i / n, "end": s + (e - s) * (i + 1) / n} for i in range(n)]
        elif b1 > b0:  # pure insertion (rare): zero-width at neighbour
            t = words[-1]["end"] if words else 0.0
            words += [{"text": toks[b0 + i], "start": t, "end": t} for i in range(b1 - b0)]
        # pure deletion: drop
    return {"text": j["text"], "words": words, "duration": j["durationSeconds"], "processing": j["processingTimeSeconds"]}
if __name__ == "__main__":
    import sys
    r = transcribe(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    assert r["words"] and all(w["end"] >= w["start"] for w in r["words"])
    assert [w["text"] for w in r["words"]] == r["text"].split(), "word list must reproduce text"
    print(r["text"][:200]); print(r["words"][:6]); print("OK", len(r["words"]), "words")
