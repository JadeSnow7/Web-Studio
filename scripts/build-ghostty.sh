#!/bin/sh
set -eu

# Reproducible direct-download build inputs. The source directory is supplied
# by the release/bootstrap job so this script never follows upstream HEAD.
SOURCE_DIR=${GHOSTTY_SOURCE_DIR:-/private/tmp/web-studio-ghostty-1.3.1}
ZIG_BIN=${ZIG_BIN:-/private/tmp/zig-aarch64-macos-0.15.2/zig}
OUTPUT_DIR=${GHOSTTY_OUTPUT_DIR:-"$PWD/Vendor"}
CACHE_DIR=${GHOSTTY_ZIG_CACHE_DIR:-/private/tmp/web-studio-ghostty-zig-cache}
BUILD_TOOLS=${GHOSTTY_BUILD_TOOLS:-"$PWD/scripts/ghostty-build-tools"}

test -x "$ZIG_BIN" || { echo "missing Zig 0.15.2: $ZIG_BIN" >&2; exit 2; }
export ZIG_BIN
test -f "$SOURCE_DIR/include/ghostty.h" || { echo "missing pinned Ghostty source: $SOURCE_DIR" >&2; exit 2; }
test "$("$ZIG_BIN" version)" = "0.15.2" || { echo "Ghostty build requires Zig 0.15.2" >&2; exit 2; }
test "$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)" = "332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28" || {
  echo "Ghostty source must be a git checkout pinned to v1.3.1" >&2
  exit 2
}

mkdir -p "$OUTPUT_DIR"
cd "$SOURCE_DIR"
if [ -d "$BUILD_TOOLS" ]; then
  PATH="$BUILD_TOOLS:$PATH"
  export PATH
fi
"$ZIG_BIN" build \
  -Doptimize=ReleaseFast \
  -Dsentry=false \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  --cache-dir "${GHOSTTY_DARWIN_CACHE_DIR:-/private/tmp/web-studio-ghostty-darwin-cache}" \
  --global-cache-dir "$CACHE_DIR"

XCFRAMEWORK="$SOURCE_DIR/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
  XCFRAMEWORK="$SOURCE_DIR/zig-out/GhosttyKit.xcframework"
fi
test -d "$XCFRAMEWORK" || { echo "GhosttyKit.xcframework was not emitted" >&2; exit 3; }
LIBRARY="$XCFRAMEWORK/macos-arm64/libghostty-fat.a"
test -f "$LIBRARY" || { echo "GhosttyKit arm64 archive is missing" >&2; exit 3; }
if ! nm -g "$LIBRARY" 2>/dev/null | grep -q '_ghostty_app_new'; then
  echo "GhosttyKit archive does not export the pinned embedding API" >&2
  exit 3
fi
rm -rf "$OUTPUT_DIR/GhosttyKit.xcframework"
cp -R "$XCFRAMEWORK" "$OUTPUT_DIR/GhosttyKit.xcframework"

# The shell integration and terminfo are runtime resources, separate from the
# framework binary. Keep the upstream resource directory beside the framework.
test -d "$SOURCE_DIR/zig-out/share/ghostty" || { echo "Ghostty runtime resources are missing" >&2; exit 3; }
rm -rf "$OUTPUT_DIR/ghostty"
cp -R "$SOURCE_DIR/zig-out/share" "$OUTPUT_DIR/ghostty"
test -f "$SOURCE_DIR/LICENSE" || { echo "Ghostty LICENSE is missing" >&2; exit 3; }
cp "$SOURCE_DIR/LICENSE" "$OUTPUT_DIR/ghostty/LICENSE"
cat > "$OUTPUT_DIR/ghostty/web-studio.conf" <<'EOF'
clipboard-read = deny
clipboard-write = deny
window-vsync = false
EOF
echo "GhosttyKit v1.3.1 ready at $OUTPUT_DIR/GhosttyKit.xcframework"
