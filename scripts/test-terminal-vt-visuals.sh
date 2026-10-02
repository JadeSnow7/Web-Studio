#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${TMPDIR:-/private/tmp}/web-studio-vt-visuals-$$
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT/module-cache"
clang -std=c11 -O2 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -I"$ROOT/Web Studio" -c "$ROOT/Web Studio/StudioPTY.c" -o "$OUT/pty.o"
clang -std=c11 -O2 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$ROOT/Vendor/GhosttyVT/include" -c "$ROOT/Web Studio/StudioVTCore.c" -o "$OUT/core.o"
# A: pure fingerprint/selection-signature functions against real TerminalVTCore frames (-O, so the printed cost comparison is meaningful).
swiftc -O -module-cache-path "$OUT/module-cache" -DWEB_STUDIO_VT -I "$ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$ROOT/Vendor/GhosttyVT/include" \
  "$ROOT/Web Studio/TerminalVTCore.swift" "$ROOT/Web Studio/TerminalVisuals.swift" "$ROOT/scripts/terminal-vt-visuals-smoke.swift" "$OUT/core.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" \
  -framework AppKit -framework CoreText -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation -o "$OUT/visuals-smoke"
"$OUT/visuals-smoke"
# B: the same smoke plus TerminalVTView itself (compiled like the app / test-terminal-vt-host.sh): lazy AX model and layout checks.
swiftc -DWEB_STUDIO_VT -DVISUALS_VIEW -default-isolation MainActor -module-cache-path "$OUT/module-cache" -I"$ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$ROOT/Vendor/GhosttyVT/include" -import-objc-header "$ROOT/Web Studio/Web Studio-Bridging-Header.h" \
  "$ROOT/Web Studio/TerminalPTYTransport.swift" "$ROOT/Web Studio/TerminalVTCore.swift" "$ROOT/Web Studio/TerminalVisuals.swift" "$ROOT/Web Studio/TerminalMetalRenderer.swift" "$ROOT/Web Studio/TerminalVTBackend.swift" "$ROOT/Web Studio/TerminalVTView.swift" "$ROOT/Web Studio/TerminalVTSession.swift" "$ROOT/scripts/terminal-vt-visuals-smoke.swift" "$OUT/pty.o" "$OUT/core.o" "$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation -o "$OUT/visuals-view-smoke"
"$OUT/visuals-view-smoke"
