#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d /private/tmp/web-studio-terminal-scenarios-test.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

sleep 60 &
PID=$!
RUN_OUT="$OUT/run"
"$ROOT/scripts/terminal-performance-probe-scenarios.sh" "$PID" "$RUN_OUT" > "$OUT/stdout.txt"
wait "$PID" 2>/dev/null || true

test "$(rg -c '^BEGIN TERMINAL-BENCHMARK' "$OUT/stdout.txt")" -eq 10
test "$(rg -c '^DONE TERMINAL-BENCHMARK' "$OUT/stdout.txt")" -eq 10
test "$(rg -c '^ASCII line=' "$OUT/stdout.txt")" -eq 50000
test "$(rg -c '^Unicode line=' "$OUT/stdout.txt")" -eq 50000
test "$(rg -c '^sample-complete' "$RUN_OUT/events.log")" -eq 6
if "$ROOT/scripts/terminal-performance-probe-scenarios.sh" "$$" "$RUN_OUT" >/dev/null 2>&1; then
  echo "existing output directory was accepted" >&2
  exit 1
fi
if "$ROOT/scripts/terminal-performance-probe-scenarios.sh" 999999 "$OUT/missing-target" >/dev/null 2>&1; then
  echo "missing sampling target was accepted" >&2
  exit 1
fi
echo "terminal-performance-probe-scenarios tests passed"
