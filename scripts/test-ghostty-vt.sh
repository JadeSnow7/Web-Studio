#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INCLUDE_DIR=${GHOSTTY_VT_INCLUDE_DIR:-$ROOT/Vendor/GhosttyVT/include}
LIBRARY=${GHOSTTY_VT_LIBRARY:-$ROOT/Vendor/GhosttyVT/lib/libghostty-vt.a}
SMOKE=${GHOSTTY_VT_SMOKE_SOURCE:-$ROOT/scripts/ghostty-vt-smoke.c}
CC=${CC:-clang}

test -f "$INCLUDE_DIR/ghostty/vt.h" || { echo "run build-ghostty-vt.sh first" >&2; exit 2; }
test -f "$LIBRARY" || { echo "missing library: $LIBRARY" >&2; exit 2; }

for symbol in ghostty_terminal_new ghostty_terminal_vt_write ghostty_terminal_resize ghostty_formatter_terminal_new ghostty_key_encoder_encode ghostty_render_state_new; do
  nm -gU "$LIBRARY" | grep -q "_$symbol" || { echo "missing C symbol: $symbol" >&2; exit 3; }
done

OUT=${TMPDIR:-/private/tmp}/web-studio-ghostty-vt-smoke-$$
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT/extract"
"$CC" -std=c11 -Wall -Wextra -Werror -fsyntax-only -I"$INCLUDE_DIR" "$SMOKE"

"$CC" -std=c11 -Wall -Wextra -Werror -I"$INCLUDE_DIR" "$SMOKE" \
  "$LIBRARY" \
  -framework Security -framework CoreFoundation -framework CoreServices -framework Foundation \
  -o "$OUT/vt-smoke"
"$OUT/vt-smoke"
echo "libghostty-vt runtime M0 smoke passed (VT parse, UTF-8 format, resize, key, render state)"
