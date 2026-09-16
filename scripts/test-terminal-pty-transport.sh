#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); OUT=${TMPDIR:-/private/tmp}/web-studio-pty-transport-$$; trap 'rm -rf "$OUT"' EXIT INT TERM; mkdir -p "$OUT"
clang -std=c11 -Wall -Wextra -Werror -I"$ROOT/Web Studio" "$ROOT/Web Studio/StudioPTY.c" "$ROOT/scripts/terminal-pty-transport-smoke.c" -o "$OUT/smoke"
"$OUT/smoke"
