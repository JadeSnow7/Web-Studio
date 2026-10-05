#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/build-artifacts.sh"
if [ -n "${1:-}" ]; then OUT=$1; else OUT=$(build_artifacts_path "$ROOT" performance-probe-test /private/tmp/web-studio-terminal-performance-probe-test); fi
"$ROOT/scripts/terminal-performance-probe-build.sh" "$OUT" >/dev/null
BIN="$OUT/terminal-performance-probe"
"$BIN" --self-test
if "$BIN" --config /tmp/unused.conf --width 0 >/dev/null 2>&1; then
  echo "invalid width was accepted" >&2
  exit 1
fi
if "$BIN" --config /tmp/unused.conf --height nan >/dev/null 2>&1; then
  echo "non-finite height was accepted" >&2
  exit 1
fi
echo "terminal-performance-probe argument tests passed"
