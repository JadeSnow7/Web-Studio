#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-/private/tmp/web-studio-terminal-performance-probe}
mkdir -p "$OUT/module-cache"
set -x
swiftc \
  -parse-as-library \
  -module-cache-path "$OUT/module-cache" \
  -I "$ROOT/Vendor/GhosttyKit.xcframework/macos-arm64/Headers" \
  "$ROOT/scripts/terminal-performance-probe.swift" \
  "$ROOT/Vendor/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a" \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework CoreText \
  -framework CoreFoundation \
  -framework CoreServices \
  -framework Foundation \
  -framework Carbon \
  -lc++ \
  -o "$OUT/terminal-performance-probe"
printf '%s\n' "$OUT/terminal-performance-probe"
