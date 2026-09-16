#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/private/tmp}/web-studio-vt-host-$$
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT/module-cache"
clang -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -I"$ROOT/Web Studio" -c "$ROOT/Web Studio/StudioPTY.c" -o "$OUT/pty.o"
clang -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -c "$ROOT/Web Studio/StudioVTCore.c" -o "$OUT/vt.o"
swiftc -DWEB_STUDIO_VT -default-isolation MainActor -module-cache-path "$OUT/module-cache" -I"$ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$ROOT/Vendor/GhosttyVT/include" -import-objc-header "$ROOT/Web Studio/Web Studio-Bridging-Header.h" \
  "$ROOT/Web Studio/TerminalPTYTransport.swift" "$ROOT/Web Studio/TerminalVTCore.swift" "$ROOT/Web Studio/TerminalVisuals.swift" "$ROOT/Web Studio/TerminalMetalRenderer.swift" "$ROOT/Web Studio/TerminalVTBackend.swift" "$ROOT/Web Studio/TerminalVTView.swift" "$ROOT/Web Studio/TerminalVTSession.swift" "$ROOT/scripts/terminal-vt-host-smoke.swift" "$OUT/pty.o" "$OUT/vt.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation -o "$OUT/smoke"
"$OUT/smoke"
