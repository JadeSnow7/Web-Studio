#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/private/tmp}/studio-vt-swift-$$
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT/module-cache"
clang -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -c "$ROOT/Web Studio/StudioVTCore.c" -o "$OUT/studio-vt-core.o"
clang -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -I"$ROOT/Web Studio" "$ROOT/scripts/vt-core-test.c" "$OUT/studio-vt-core.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" -framework Foundation -framework Security -framework CoreServices -o "$OUT/vt-core-test"
"$OUT/vt-core-test"
swiftc -module-cache-path "$OUT/module-cache" -DWEB_STUDIO_VT -I "$ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$ROOT/Vendor/GhosttyVT/include" "$ROOT/Web Studio/TerminalVTCore.swift" "$ROOT/Web Studio/TerminalVisuals.swift" "$ROOT/scripts/terminal-vt-core-swift-smoke.swift" "$OUT/studio-vt-core.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" -framework AppKit -framework CoreText -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation -o "$OUT/studio-vt-swift-smoke"
"$OUT/studio-vt-swift-smoke"
