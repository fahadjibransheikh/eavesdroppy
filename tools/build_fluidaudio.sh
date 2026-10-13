#!/usr/bin/env bash
# Build a pinned FluidAudio CLI into bin/fluidaudiocli. Re-run safe.
# Bump PIN to upgrade; verify `process --mode offline` and `transcribe --custom-vocab` still exist.
set -euo pipefail
PIN=e560c6445ffdc42e60c7b282d162aae271f18e2a   # e560c64, 2026-10-11
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.build-tools/FluidAudio"
mkdir -p "$ROOT/.build-tools" "$ROOT/bin"
if [ ! -d "$SRC/.git" ]; then git init -q "$SRC" && git -C "$SRC" remote add origin https://github.com/FluidInference/FluidAudio; fi
git -C "$SRC" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$SRC" fetch -q --depth 1 origin "$PIN"
git -C "$SRC" checkout -q --detach "$PIN"
(cd "$SRC" && swift build -c release --product fluidaudiocli)
cp "$SRC/.build/release/fluidaudiocli" "$ROOT/bin/fluidaudiocli"
echo "built $ROOT/bin/fluidaudiocli @ $(git -C "$SRC" rev-parse --short HEAD)"
