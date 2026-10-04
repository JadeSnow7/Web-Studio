#!/bin/sh
# Read a machine-local root; the checkout identity keeps parallel worktrees apart.
build_artifacts_path() {
  artifact_repo=$1
  artifact_kind=$2
  artifact_fallback=$3
  artifact_root=${BUILD_ARTIFACTS_ROOT:-}
  if [ -z "$artifact_root" ] && [ -f "$HOME/.config/build-artifacts/root" ]; then
    artifact_root=$(cat "$HOME/.config/build-artifacts/root") || return
    [ -n "$artifact_root" ] || { echo "empty build artifacts root configuration" >&2; return 2; }
  fi
  if [ -z "$artifact_root" ]; then
    printf '%s\n' "$artifact_fallback"
    return
  fi
  case "$artifact_root" in /*) ;; *) echo "build artifacts root must be absolute: $artifact_root" >&2; return 2 ;; esac
  case "$artifact_root" in /Volumes/*)
    artifact_volume=${artifact_root#/Volumes/}
    artifact_volume=/Volumes/${artifact_volume%%/*}
    /sbin/mount | grep -F " on $artifact_volume (" >/dev/null || {
      echo "build artifacts volume is not mounted: $artifact_volume" >&2; return 2;
    }
    ;;
  esac
  [ -d "$artifact_root" ] || { echo "build artifacts root is missing: $artifact_root" >&2; return 2; }
  artifact_repo=$(CDPATH= cd -P -- "$artifact_repo" && pwd) || return
  artifact_id=$(printf '%s' "$artifact_repo" | shasum -a 256 | cut -c 1-16) || return
  artifact_path="$artifact_root/web-studio-$artifact_id/$artifact_kind"
  printf '%s\n' "$artifact_path"
}
