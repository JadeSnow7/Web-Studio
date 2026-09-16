#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCK="$ROOT/Vendor/GhosttyVT/DEPENDENCY.lock"
SOURCE_DIR=${GHOSTTY_VT_SOURCE_DIR:-/private/tmp/web-studio-ghostty-vt-source}
ZIG_DIR=${GHOSTTY_VT_ZIG_DIR:-/private/tmp/zig-aarch64-macos-0.16.0}
ZIG_BIN="$ZIG_DIR/zig"
CACHE_DIR=${GHOSTTY_VT_CACHE_DIR:-/private/tmp/web-studio-ghostty-vt-cache}
GLOBAL_CACHE_DIR=${GHOSTTY_VT_GLOBAL_CACHE_DIR:-/private/tmp/web-studio-ghostty-vt-global-cache}
BUILD_DIR=${GHOSTTY_VT_BUILD_DIR:-/private/tmp/web-studio-ghostty-vt-prefix}
OUTPUT_DIR=${GHOSTTY_VT_OUTPUT_DIR:-$ROOT/Vendor/GhosttyVT}

lock_value() {
  awk -F ' = ' -v key="$1" '$1 == key { gsub(/^"|"$/, "", $2); print $2 }' "$LOCK"
}

COMMIT=$(lock_value commit)
ZIG_VERSION=$(lock_value zig_version)
ZIG_SHA256=$(lock_value zig_sha256)
ZIG_URL=$(lock_value zig_tarball)
API_HEADER_SHA256=$(lock_value api_header_sha256)
SOURCE_LICENSE_SHA256=$(lock_value source_license_sha256)
HEADER_MANIFEST_SHA256=$(lock_value header_manifest_sha256)
ARTIFACT_SHA256=$(lock_value artifact_sha256)

printf '%s\n' "$COMMIT" | awk 'length($0) == 40 && $0 ~ /^[0-9a-f]+$/ { found = 1 } END { exit(found ? 0 : 1) }' || {
  echo "invalid commit lock" >&2; exit 2;
}
case "$OUTPUT_DIR" in /|/private/tmp|/tmp|"$ROOT") echo "unsafe output directory" >&2; exit 2 ;; esac
for temporary_path in "$BUILD_DIR" "$CACHE_DIR" "$GLOBAL_CACHE_DIR"; do
  case "$temporary_path" in /private/tmp/*|/tmp/*) ;; *) echo "build/cache paths must be under /private/tmp or /tmp" >&2; exit 2 ;; esac
done

test -f "$LOCK" || { echo "missing lock: $LOCK" >&2; exit 2; }

if [ ! -x "$ZIG_BIN" ]; then
  ARCHIVE=/private/tmp/zig-aarch64-macos-0.16.0.tar.xz
  curl -fL "$ZIG_URL" -o "$ARCHIVE"
  test "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$ZIG_SHA256" || {
    echo "Zig SHA256 mismatch" >&2; exit 2;
  }
  tar -xJf "$ARCHIVE" -C "$(dirname "$ZIG_DIR")"
fi
test "$($ZIG_BIN version)" = "$ZIG_VERSION" || { echo "requires Zig $ZIG_VERSION" >&2; exit 2; }

if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SOURCE_DIR"
fi
git -C "$SOURCE_DIR" fetch --quiet --depth=1 origin "$COMMIT"
git -C "$SOURCE_DIR" checkout --quiet --detach "$COMMIT"
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$COMMIT" || {
  echo "Ghostty source is not at locked commit" >&2; exit 2;
}
test -z "$(git -C "$SOURCE_DIR" status --porcelain)" || { echo "Ghostty source checkout is dirty" >&2; exit 2; }

mkdir -p "$BUILD_DIR"
cd "$SOURCE_DIR"
"$ZIG_BIN" build \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast \
  --prefix "$BUILD_DIR" \
  --cache-dir "$CACHE_DIR" \
  --global-cache-dir "$GLOBAL_CACHE_DIR"

ARCHIVE="$BUILD_DIR/lib/libghostty-vt.a"
test -s "$ARCHIVE" || { echo "libghostty-vt.a was not installed at the exact build prefix" >&2; exit 3; }
mkdir -p "$OUTPUT_DIR/include" "$OUTPUT_DIR/lib"
rm -rf "$OUTPUT_DIR/include/ghostty" "$OUTPUT_DIR/lib/libghostty-vt.a"
cp -R "$BUILD_DIR/include/ghostty" "$OUTPUT_DIR/include/ghostty"
cp "$SOURCE_DIR/LICENSE" "$OUTPUT_DIR/LICENSE"
# Zig's Darwin archive contains compiler_rt's global memset as well as the
# same symbol in the terminal object. Normalize this known upstream artifact
# once at packaging time so consumers link the checked-in archive directly.
NORMALIZE_DIR=$(mktemp -d "$BUILD_DIR/normalize.XXXXXX")
(cd "$NORMALIZE_DIR" && ar -x "$ARCHIVE" && chmod 0644 ./*.o)
printf '___memset\n' > "$NORMALIZE_DIR/remove-symbols.txt"
nmedit -R "$NORMALIZE_DIR/remove-symbols.txt" -o "$NORMALIZE_DIR/compiler_rt.nm.o" "$NORMALIZE_DIR/compiler_rt.o"
rm -f "$NORMALIZE_DIR/compiler_rt.o" "$NORMALIZE_DIR/remove-symbols.txt"
(cd "$NORMALIZE_DIR" && /usr/bin/strip -S ./*.o)
(cd "$NORMALIZE_DIR" && ZERO_AR_DATE=1 /usr/bin/libtool -static -o "$OUTPUT_DIR/lib/libghostty-vt.a" ./*.o)
if [ -f "$BUILD_DIR/share/pkgconfig/libghostty-vt-static.pc" ]; then
  mkdir -p "$OUTPUT_DIR/share/pkgconfig"
  cp "$BUILD_DIR/share/pkgconfig/libghostty-vt-static.pc" "$OUTPUT_DIR/share/pkgconfig/"
  sed -i.bak 's|^prefix=.*$|prefix=${pcfiledir}/../..|' "$OUTPUT_DIR/share/pkgconfig/libghostty-vt-static.pc"
  rm -f "$OUTPUT_DIR/share/pkgconfig/libghostty-vt-static.pc.bak"
fi
test "$(shasum -a 256 "$OUTPUT_DIR/include/ghostty/vt.h" | awk '{print $1}')" = "$API_HEADER_SHA256" || {
  echo "libghostty-vt header SHA256 mismatch" >&2; exit 3;
}
MANIFEST_FILE=$(mktemp "$BUILD_DIR/header-manifest.XXXXXX")
(cd "$OUTPUT_DIR/include/ghostty" && find . -type f -print | LC_ALL=C sort | while IFS= read -r header; do shasum -a 256 "$header"; done) > "$MANIFEST_FILE"
test "$(wc -l < "$MANIFEST_FILE" | tr -d ' ')" = 35 || { echo "unexpected Ghostty header count" >&2; exit 3; }
test "$(shasum -a 256 "$MANIFEST_FILE" | awk '{print $1}')" = "$HEADER_MANIFEST_SHA256" || { echo "Ghostty header manifest SHA256 mismatch" >&2; exit 3; }
test "$(shasum -a 256 "$OUTPUT_DIR/lib/libghostty-vt.a" | awk '{print $1}')" = "$ARTIFACT_SHA256" || {
  echo "libghostty-vt artifact SHA256 mismatch" >&2; exit 3;
}
test "$(shasum -a 256 "$SOURCE_DIR/LICENSE" | awk '{print $1}')" = "$SOURCE_LICENSE_SHA256" || {
  echo "Ghostty source LICENSE SHA256 mismatch" >&2; exit 3;
}

printf 'libghostty-vt ready\nsource=%s\nzig=%s\narchive=%s\n' "$COMMIT" "$($ZIG_BIN version)" "$OUTPUT_DIR/lib/libghostty-vt.a"
