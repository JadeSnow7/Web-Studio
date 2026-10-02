#!/bin/sh
set -eu
SOURCE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root) [ "$#" -ge 2 ] || { echo "missing source root" >&2; exit 64; }; SOURCE_ROOT=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { echo "missing output" >&2; exit 64; }; OUTPUT=$2; shift 2 ;;
    *) echo "usage: $0 --output DIR [--source-root ROOT]" >&2; exit 64 ;;
  esac
done
[ -n "$OUTPUT" ] || { echo "--output is required" >&2; exit 64; }
case "$OUTPUT" in /private/tmp/*) ;; *) echo "output must be under /private/tmp" >&2; exit 64 ;; esac
[ ! -e "$OUTPUT" ] || { echo "output exists; refusing overwrite" >&2; exit 64; }
BUILD="${OUTPUT}-build"
[ ! -e "$BUILD" ] || { echo "build output exists; refusing overwrite" >&2; exit 64; }
mkdir -p "$BUILD/module-cache"

clang -O2 -std=c11 -DWEB_STUDIO_VT -DGHOSTTY_STATIC \
  -I"$SOURCE_ROOT/Vendor/GhosttyVT/include" -I"$SOURCE_ROOT/Web Studio" \
  -c "$SOURCE_ROOT/Web Studio/StudioVTCore.c" -o "$BUILD/studio-vt-core.o"
swiftc -O -DWEB_STUDIO_VT -module-cache-path "$BUILD/module-cache" \
  -I"$SOURCE_ROOT/scripts" -Xcc -DWEB_STUDIO_VT -Xcc -I -Xcc "$SOURCE_ROOT/Vendor/GhosttyVT/include" \
  "$SOURCE_ROOT/Web Studio/TerminalVTCore.swift" \
  "$SOURCE_ROOT/Web Studio/TerminalVisuals.swift" \
  "$SOURCE_ROOT/Web Studio/TerminalMetalRenderer.swift" \
  "$SCRIPT_ROOT/terminal-unicode-diagnostic.swift" \
  "$BUILD/studio-vt-core.o" "$SOURCE_ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a" \
  -framework Metal -framework MetalKit -framework AppKit -framework CoreText \
  -framework Security -framework CoreServices -framework Foundation -framework CoreFoundation \
  -o "$BUILD/terminal-unicode-diagnostic"

SOURCE_HASH=$(shasum -a 256 \
  "$SCRIPT_ROOT/terminal-unicode-diagnostic.swift" \
  "$SOURCE_ROOT/Web Studio/TerminalVTCore.swift" \
  "$SOURCE_ROOT/Web Studio/TerminalVisuals.swift" \
  "$SOURCE_ROOT/Web Studio/TerminalMetalRenderer.swift" \
  "$SOURCE_ROOT/Web Studio/StudioVTCore.c" | shasum -a 256 | awk '{print $1}')
BUILD_HASH=$(shasum -a 256 "$BUILD/terminal-unicode-diagnostic" | awk '{print $1}')
cat > "$BUILD/build-manifest.json" <<EOF
{"configuration":"Release","optimization":"swiftc -O; clang -O2","source_digest":"$SOURCE_HASH","binary_sha256":"$BUILD_HASH","binary":"$BUILD/terminal-unicode-diagnostic"}
EOF

"$BUILD/terminal-unicode-diagnostic" --output "$OUTPUT"
