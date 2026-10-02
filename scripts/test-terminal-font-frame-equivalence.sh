#!/bin/sh
set -eu
SOURCE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=/private/tmp/web-studio-font-frame-equivalence
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root) SOURCE_ROOT=$2; shift 2;;
    --output) OUTPUT=$2; shift 2;;
    *) echo "usage: $0 --source-root ROOT --output DIR" >&2; exit 64;;
  esac
done
case "$OUTPUT" in /private/tmp/*) ;; *) echo "output must be under /private/tmp" >&2; exit 64;; esac
if [ -e "$OUTPUT" ]; then echo "output exists; refusing overwrite" >&2; exit 64; fi
BUILD="$OUTPUT-build"
if [ -e "$BUILD" ]; then echo "build output exists; refusing overwrite" >&2; exit 64; fi
mkdir -p "$BUILD/module-cache"
clang -O2 -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC -I"$SOURCE_ROOT/Vendor/GhosttyVT/include" -I"$SOURCE_ROOT/Web Studio" -c "$SOURCE_ROOT/Web Studio/StudioVTCore.c" -o "$BUILD/vt.o"
swiftc -O -DWEB_STUDIO_VT -module-cache-path "$BUILD/module-cache" -I"$SOURCE_ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$SOURCE_ROOT/Vendor/GhosttyVT/include" \
  "$SOURCE_ROOT/Web Studio/TerminalVTCore.swift" "$SOURCE_ROOT/Web Studio/TerminalVisuals.swift" "$SOURCE_ROOT/Web Studio/TerminalMetalRenderer.swift" "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/terminal-font-frame-equivalence.swift" "$BUILD/vt.o" "$SOURCE_ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" \
  -framework AppKit -framework Metal -framework MetalKit -framework CoreText -framework Security -framework CoreServices -framework Foundation -framework CoreFoundation -o "$BUILD/font-frame-equivalence"
"$BUILD/font-frame-equivalence" --output "$OUTPUT"
