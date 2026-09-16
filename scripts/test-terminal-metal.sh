#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=/private/tmp/web-studio-vt-renderer-$$; trap 'rm -rf "$OUT"' EXIT; mkdir -p "$OUT/module-cache"
clang -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -c "$ROOT/Web Studio/StudioVTCore.c" -o "$OUT/core.o"
swiftc -module-cache-path "$OUT/module-cache" -DWEB_STUDIO_VT -I "$ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$ROOT/Vendor/GhosttyVT/include" "$ROOT/Web Studio/TerminalVTCore.swift" "$ROOT/Web Studio/TerminalVisuals.swift" "$ROOT/Web Studio/TerminalMetalRenderer.swift" "$ROOT/scripts/terminal-metal-smoke.swift" "$OUT/core.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" -framework Metal -framework MetalKit -framework AppKit -framework CoreText -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation -o "$OUT/smoke"
"$OUT/smoke"
