#!/usr/bin/env bash
# Copy the pinned FluidAudio sources into eavesdroppy/Vendor/FluidAudio (git-ignored) as local SwiftPM targets,
# patched so they compile under `-enable-library-evolution`. Re-run safe. Personal build only (EAVESDROPPY_PERSONAL=1).
#
# Why vendor instead of a package dependency: Scripts/build-droplet.sh (DroppyKit) links only the droplet target's
# objects plus the package's *own* targets, and compiles everything with -enable-library-evolution. A package
# dependency's objects are never linked into the .droplet (undefined symbols), and FluidAudio does not compile
# under library evolution on this toolchain (`consume` sites in the unused streaming diarizer), and its C++ target needs `link "c++"` because the script links with swiftc.
set -euo pipefail
PIN=e560c6445ffdc42e60c7b282d162aae271f18e2a   # must match tools/build_fluidaudio.sh (the CLI oracle)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${FLUIDAUDIO_SRC:-$ROOT/.build-tools/FluidAudio}"
DST="$ROOT/eavesdroppy/Vendor/FluidAudio"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$PIN" ] || { echo "error: $SRC is not at $PIN" >&2; exit 1; }
rm -rf "$DST"
mkdir -p "$DST/Sources"
cp -R "$SRC/Sources/FluidAudio" "$SRC/Sources/FastClusterWrapper" "$SRC/Sources/MachTaskSelfWrapper" "$DST/Sources/"
cp "$SRC/LICENSE" "$DST/LICENSE"
cp -R "$SRC/ThirdPartyLicenses" "$DST/ThirdPartyLicenses"
patch -p1 -d "$DST/Sources" < "$ROOT/tools/fluidaudio-resilience.patch"
echo "vendored FluidAudio @ ${PIN:0:7} into $DST"
