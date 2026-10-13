#!/usr/bin/env bash
# Build LocalVQE (CPU) + fetch the v1.4-AEC model into .build-tools/.
# Build-time only needs: cmake and Homebrew's static libs (brew install cmake libsndfile flac libogg libvorbis opus mpg123 lame).
# libsndfile and its codecs are linked statically, so the built binary depends only on macOS system libraries and keeps
# working after `brew cleanup` or on a Mac without Homebrew (verified at the end with otool -L).
set -euo pipefail
PIN=f53063c9eb2a85f96479867d1dd911dc3bf6319b   # 2026-07, "fix(obs): preserve continuous filtered audio"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.build-tools/localvqe"
mkdir -p "$ROOT/.build-tools/models"
[ -d "$SRC/.git" ] || git clone -q https://github.com/localai-org/LocalVQE "$SRC"
git -C "$SRC" fetch -q --depth 1 origin "$PIN" 2>/dev/null || true
git -C "$SRC" checkout -q --detach "$PIN"
git -C "$SRC" submodule update -q --init --depth 1
# LocalVQE's CMake takes SNDFILE_LIBRARY as a plain library list, so the static archives go straight in.
# Order matters for static linking: libsndfile first, then what it calls.
lib() { echo "$(brew --prefix "$1")/lib/$2"; }
SNDFILE_STATIC="$(lib libsndfile libsndfile.a);$(lib flac libFLAC.a);$(lib libvorbis libvorbisenc.a);$(lib libvorbis libvorbis.a)"
SNDFILE_STATIC="$SNDFILE_STATIC;$(lib libogg libogg.a);$(lib opus libopus.a);$(lib mpg123 libmpg123.a);$(lib lame libmp3lame.a)"
for f in ${SNDFILE_STATIC//;/ }; do [ -f "$f" ] || { echo "missing static library: $f (brew install libsndfile flac libogg libvorbis opus mpg123 lame)" >&2; exit 1; }; done
cmake -S "$SRC/ggml" -B "$SRC/ggml/build" -DCMAKE_BUILD_TYPE=Release -DSNDFILE_LIBRARY="$SNDFILE_STATIC" >/dev/null
cmake --build "$SRC/ggml/build" -j8 --target localvqe
M="$ROOT/.build-tools/models/localvqe-v1.4-aec-200K-f32.gguf"
SHA=b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731
[ -f "$M" ] || curl -sSL -o "$M" https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/localvqe-v1.4-aec-200K-f32.gguf
echo "$SHA  $M" | shasum -a 256 -c -
BIN="$SRC/ggml/build/localvqe"
if otool -L "$BIN" | grep -E '/opt/homebrew|/usr/local' >&2; then echo "localvqe still links Homebrew dylibs" >&2; exit 1; fi
echo "built $BIN"
