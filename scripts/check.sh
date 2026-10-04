#!/bin/bash
set -u

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'USAGE'
Usage: ./scripts/check.sh [--ui]

Builds Web Studio, runs Web StudioTests, and optionally runs Web StudioUITests.
The script disables automatic package updates and uses the existing local SwiftPM cache.
USAGE
  exit 0
fi

run_ui=0
if [[ "$#" -gt 0 ]]; then
  if [[ "$1" == "--ui" && "$#" -eq 1 ]]; then
    run_ui=1
  else
    printf 'error: unknown option: %s\n' "$1" >&2
    printf 'usage: %s [--ui]\n' "$0" >&2
    exit 2
  fi
fi

project='Web Studio.xcodeproj'
scheme='Web Studio'
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root" || exit 2

. "$script_dir/build-artifacts.sh"
derived_data=$(build_artifacts_path "$repo_root" xcode-check /private/tmp/ws-phase2-check) || exit $?
result_root="$(mktemp -d "${TMPDIR:-/private/tmp}/web-studio-check-results.XXXXXX")"
build_result="$result_root/build.xcresult"
unit_result="$result_root/unit.xcresult"
ui_result="$result_root/ui.xcresult"
printf 'result bundles: %s\n' "$result_root"

common_args=(
  -project "$project"
  -scheme "$scheme"
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackageUpdates
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=
)

summarize_tests() {
  local bundle="$1"
  local summary
  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact)" || {
    printf 'tests: unable to read xcresult summary: %s\n' "$bundle" >&2
    return 1
  }
  SUMMARY_JSON="$summary" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["SUMMARY_JSON"])
except (KeyError, json.JSONDecodeError) as error:
    print(f"tests: invalid xcresult summary: {error}", file=sys.stderr)
    sys.exit(1)

total = data.get("totalTestCount")
passed = data.get("passedTests")
failed = data.get("failedTests")
skipped = data.get("skippedTests")
if not all(isinstance(value, int) for value in (total, passed, failed, skipped)):
    print("tests: xcresult summary did not contain Swift Testing counts", file=sys.stderr)
    sys.exit(1)
print(f"tests: total={total} passed={passed} failed={failed} skipped={skipped}")
PY
}

printf '%s\n' '== build =='
set +e
xcodebuild "${common_args[@]}" -resultBundlePath "$build_result" build
build_exit=$?
set -e
printf 'xcodebuild exit=%s\n' "$build_exit"
if [[ "$build_exit" -ne 0 ]]; then
  exit "$build_exit"
fi

printf '%s\n' '== Web StudioTests =='
set +e
xcodebuild "${common_args[@]}" -resultBundlePath "$unit_result" test \
  '-only-testing:Web StudioTests' -parallel-testing-enabled NO
unit_exit=$?
set -e
printf 'xcodebuild exit=%s\n' "$unit_exit"
summarize_tests "$unit_result" || true

final_exit=$unit_exit
if [[ "$run_ui" -eq 1 ]]; then
  printf '%s\n' '== Web StudioUITests =='
  set +e
  xcodebuild "${common_args[@]}" -resultBundlePath "$ui_result" test \
    '-only-testing:Web StudioUITests' -parallel-testing-enabled NO
  ui_exit=$?
  set -e
  printf 'xcodebuild exit=%s\n' "$ui_exit"
  summarize_tests "$ui_result" || true
  if [[ "$final_exit" -eq 0 && "$ui_exit" -ne 0 ]]; then
    final_exit=$ui_exit
  fi
fi

exit "$final_exit"
