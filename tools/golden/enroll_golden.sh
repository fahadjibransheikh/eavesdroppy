#!/bin/sh
# enroll: process_meeting.py vs NativeCommands.enroll on the same sample (the mic track of a raw session, which is one voice).
#   tools/golden/enroll_golden.sh <scratch_dir> [raw_session_dir]
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCR="$1"; RAW="${2:-$HOME/Library/Application Support/Droppy/Droplets/eavesdroppy/Container/raw/20261013-123545-736-0001}"
mkdir -p "$SCR/py-container"; rm -f "$SCR/py-container/library.db"*
"$ROOT/.venv/bin/python" -c "
import soundfile as sf, sys
x, sr = sf.read('$RAW/mic.flac', dtype='float32'); sf.write('$SCR/sample.wav', x, sr, subtype='FLOAT')"
"$ROOT/.venv/bin/python" "$ROOT/process_meeting.py" enroll "$SCR/sample.wav" --name Fahad --container "$SCR/py-container" > "$SCR/py.json"
( cd "$ROOT/eavesdroppy" && EAVESDROPPY_PERSONAL=1 EAVESDROPPY_ENROLL_GOLDEN_DIR="$SCR" swift test --filter EnrollGolden >/dev/null )
"$ROOT/.venv/bin/python" - <<PY
import json, sqlite3, numpy as np
py, sw = json.load(open('$SCR/py.json')), json.load(open('$SCR/sw.json'))
print('python', py, 'swift', sw)
row = lambda p: sqlite3.connect(p).execute('SELECT id, name, is_me, n, voiceprint FROM people').fetchall()
a, b = row('$SCR/py-container/library.db'), row('$SCR/sw-container/library.db')
va, vb = np.frombuffer(a[0][4], np.float32), np.frombuffer(b[0][4], np.float32)
print('rows py/sw:', [r[:4] for r in a], [r[:4] for r in b], 'cosine', float(va @ vb / (np.linalg.norm(va) * np.linalg.norm(vb))))
PY
