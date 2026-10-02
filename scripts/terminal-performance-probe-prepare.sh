#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-/private/tmp/web-studio-performance-alignment-20260916}
LEGACY_SRC=${2:-/private/tmp/web-studio-m2-legacy-20260916-frozen/Build/Products/Release/Web Studio.app}
VT_SRC=${3:-/private/tmp/web-studio-m2-20260916-frozen/Build/Products/Release/Web Studio VT.app}
TUNED_CONFIG="$ROOT/output/terminal-vt-migration/evidence/performance-alignment-20260916/legacy-vt-tuned-adjust-1x4.conf"

test -d "$LEGACY_SRC" || { echo "missing legacy app: $LEGACY_SRC" >&2; exit 2; }
test -d "$VT_SRC" || { echo "missing VT app: $VT_SRC" >&2; exit 2; }
test -f "$TUNED_CONFIG" || { echo "missing tuned config: $TUNED_CONFIG" >&2; exit 2; }
case "$OUT" in /private/tmp/*) ;; *) echo "output must be under /private/tmp" >&2; exit 2 ;; esac
test ! -e "$OUT" || { echo "output already exists; choose a new path: $OUT" >&2; exit 2; }

mkdir -p "$OUT"
cp -R "$LEGACY_SRC" "$OUT/legacy-normalized.app"
cp -R "$VT_SRC" "$OUT/vt-control.app"

cp "$TUNED_CONFIG" "$OUT/legacy-normalized.app/Contents/Resources/ghostty/web-studio.conf"
plutil -replace CFBundleIdentifier -string com.huaodong.Web-Studio.M2NormalizedLegacy20260916 "$OUT/legacy-normalized.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.huaodong.Web-Studio.M2NormalizedVT20260916 "$OUT/vt-control.app/Contents/Info.plist"

codesign --force --deep --sign - "$OUT/legacy-normalized.app"
codesign --force --deep --sign - "$OUT/vt-control.app"

{
  printf 'source_revision='; git -C "$ROOT" rev-parse HEAD
  printf 'legacy_source='; printf '%s\n' "$LEGACY_SRC"
  printf 'vt_source='; printf '%s\n' "$VT_SRC"
  printf 'legacy_source_app='; shasum -a 256 "$LEGACY_SRC/Contents/MacOS/Web Studio"
  printf 'vt_source_app='; shasum -a 256 "$VT_SRC/Contents/MacOS/Web Studio VT"
  printf 'legacy_source_bundle_id='; plutil -extract CFBundleIdentifier raw "$LEGACY_SRC/Contents/Info.plist"
  printf 'vt_source_bundle_id='; plutil -extract CFBundleIdentifier raw "$VT_SRC/Contents/Info.plist"
  printf 'legacy_app='; shasum -a 256 "$OUT/legacy-normalized.app/Contents/MacOS/Web Studio"
  printf 'vt_app='; shasum -a 256 "$OUT/vt-control.app/Contents/MacOS/Web Studio VT"
  printf 'legacy_config='; shasum -a 256 "$OUT/legacy-normalized.app/Contents/Resources/ghostty/web-studio.conf"
  printf 'legacy_bundle_id='; plutil -extract CFBundleIdentifier raw "$OUT/legacy-normalized.app/Contents/Info.plist"
  printf 'vt_bundle_id='; plutil -extract CFBundleIdentifier raw "$OUT/vt-control.app/Contents/Info.plist"
  printf 'legacy_code_signature='; codesign --display --verbose=2 "$OUT/legacy-normalized.app" 2>&1 | rg 'Identifier=|TeamIdentifier=|Signature=' || true
  printf 'vt_code_signature='; codesign --display --verbose=2 "$OUT/vt-control.app" 2>&1 | rg 'Identifier=|TeamIdentifier=|Signature=' || true
  printf 'changes=legacy config replaced; both Info.plist bundle identifiers replaced; both app bundles ad-hoc signed\n'
} > "$OUT/manifest.txt"
printf '%s\n' "$OUT"
