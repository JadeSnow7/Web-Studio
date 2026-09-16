#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=/private/tmp/web-studio-terminal-window-probe-$$
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/module-cache"

swiftc -parse-as-library \
  -module-cache-path "$OUT/module-cache" \
  "$ROOT/scripts/terminal-window-probe.swift" \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -framework Foundation -o "$OUT/terminal-window-probe"

"$OUT/terminal-window-probe" --self-test
"$OUT/terminal-window-probe" --pid "$$" > "$OUT/result.json"
/usr/bin/python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); assert d["schema"] == "web-studio.terminal-window-probe.v1"; assert d["pid"] > 0; assert isinstance(d["ax"]["windows"], list); assert isinstance(d["cgWindows"], list); assert isinstance(d["displays"], list); print("terminal-window-probe JSON contract passed")' "$OUT/result.json"
