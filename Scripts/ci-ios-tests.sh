#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

device_family="${1:-iPhone}"
case "$device_family" in
  iPhone|iPad) ;;
  *)
    printf 'usage: %s iPhone|iPad\n' "$0" >&2
    exit 2
    ;;
esac

destination_id="$({
  xcodebuild -project Yishu.xcodeproj -scheme Yishu -showdestinations
} | awk -v family="$device_family" '
  $0 ~ /platform:iOS Simulator/ && index($0, "name:" family) {
    line = $0
    sub(/^.*id:/, "", line)
    sub(/,.*/, "", line)
    gsub(/[[:space:]]/, "", line)
    print line
    exit
  }
')"

if [[ -z "$destination_id" ]]; then
  printf 'No available %s simulator was found.\n' "$device_family" >&2
  exit 1
fi

temporary_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/yishu-ci-${device_family}.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

result_root="${CI_RESULT_DIR:-${RUNNER_TEMP:-/tmp}/yishu-results}"
mkdir -p "$result_root"
result_bundle="$result_root/Yishu-${device_family}-$(date +%s).xcresult"

xcodebuild \
  -project Yishu.xcodeproj \
  -scheme Yishu \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$destination_id" \
  -derivedDataPath "$temporary_root/DerivedData" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test
