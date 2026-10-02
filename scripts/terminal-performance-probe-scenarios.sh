#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON=${PYTHON:-python3}
PID=${1:-}
OUT=${2:-}
if test -z "$PID" || test -z "$OUT" || ! printf '%s' "$PID" | rg '^[0-9]+$' >/dev/null || test "$PID" -le 0; then
  echo "usage: terminal-performance-probe-scenarios.sh APP_PID OUTPUT_DIR" >&2
  exit 64
fi
kill -0 "$PID" 2>/dev/null || { echo "sampling target is not running: $PID" >&2; exit 2; }
test ! -e "$OUT" || { echo "output already exists; choose a new path: $OUT" >&2; exit 2; }
mkdir -p "$OUT"

prepare_fixture() {
  kind=$1
  fixture="$OUT/fixture-$kind.txt"
  "$PYTHON" "$ROOT/scripts/terminal-benchmark.py" output --kind "$kind" --lines 10000 > "$fixture"
  sha256=$(shasum -a 256 "$fixture" | awk '{print $1}')
  printf 'fixture kind=%s lines=10000 sha256=%s path=%s\n' "$kind" "$sha256" "$fixture" >> "$OUT/manifest.txt"
}

run_load() {
  kind=$1
  label=$2
  cat "$OUT/fixture-$kind.txt"
  printf '%s\n' "load-complete label=$label kind=$kind lines=10000 fixture=$OUT/fixture-$kind.txt" >> "$OUT/events.log"
}

run_sampled() {
  kind=$1
  round=$2
  label="$kind-$round"
  sample_file="$OUT/$label-sample.json"
  ( "$PYTHON" "$ROOT/scripts/terminal-benchmark.py" sample --pid "$PID" --duration 5 --interval 0.25 --output "$sample_file" ) &
  sampler=$!
  sleep 1
  run_load "$kind" "$label"
  wait "$sampler"
  printf '%s\n' "sample-complete label=$label kind=$kind duration=5 interval=0.25 file=$sample_file" >> "$OUT/events.log"
}

{
  printf 'schema=web-studio.terminal-performance-probe-scenarios.v1\n'
  printf 'pid=%s\n' "$PID"
  printf 'lines=10000\n'
  printf 'warmup_rounds=2\n'
  printf 'sampled_rounds=3\n'
  printf 'sample_duration_seconds=5\n'
  printf 'sample_interval_seconds=0.25\n'
  printf 'settle_after_warmup_seconds=2\n'
  printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/manifest.txt"

prepare_fixture ascii
prepare_fixture unicode
for kind in ascii unicode; do
  for round in 1 2; do
    run_load "$kind" "warmup-$kind-$round"
  done
done
sleep 2
for kind in ascii unicode; do
  for round in 1 2 3; do
    run_sampled "$kind" "$round"
  done
done
printf 'ended_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/manifest.txt"
printf '%s\n' "$OUT"
