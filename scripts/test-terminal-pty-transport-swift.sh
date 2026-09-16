#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); OUT=${TMPDIR:-/private/tmp}/web-studio-pty-swift-$$; trap 'rm -rf "$OUT"' EXIT INT TERM; mkdir -p "$OUT/module-cache"
clang -std=c11 -I"$ROOT/Web Studio" -c "$ROOT/Web Studio/StudioPTY.c" -o "$OUT/pty.o"
clang -std=c11 -Wall -Wextra -Werror "$ROOT/scripts/terminal-pty-resistant-fixture.c" -o "$OUT/resistant-fixture"
clang -std=c11 -Wall -Wextra -Werror "$ROOT/scripts/terminal-pty-sigmask-fixture.c" -o "$OUT/sigmask-fixture"
swiftc -module-cache-path "$OUT/module-cache" -import-objc-header "$ROOT/Web Studio/Web Studio-Bridging-Header.h" "$ROOT/Web Studio/TerminalPTYTransport.swift" "$ROOT/scripts/terminal-pty-transport-swift-smoke.swift" "$OUT/pty.o" -o "$OUT/smoke"
FIXTURE_PATH="$OUT/resistant-fixture" SIGMASK_FIXTURE_PATH="$OUT/sigmask-fixture" "$OUT/smoke"
