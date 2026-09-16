#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/private/tmp}/web-studio-vt-core-asan-$$
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT"
SANITIZER_FLAGS=${VT_ASAN_FLAGS:--fsanitize=address -fno-omit-frame-pointer}
clang -std=c11 $SANITIZER_FLAGS -DWEB_STUDIO_VT -DGHOSTTY_STATIC \
  -I"$ROOT/Vendor/GhosttyVT/include" -c "$ROOT/Web Studio/StudioVTCore.c" \
  -o "$OUT/core.o"
clang -std=c11 $SANITIZER_FLAGS -DWEB_STUDIO_VT -DGHOSTTY_STATIC \
  -I"$ROOT/Vendor/GhosttyVT/include" -I"$ROOT/Web Studio" \
  "$ROOT/scripts/vt-core-test.c" "$OUT/core.o" \
  "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" -framework Foundation -framework Security -framework CoreServices -o "$OUT/vt-core-test"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} "$OUT/vt-core-test"
