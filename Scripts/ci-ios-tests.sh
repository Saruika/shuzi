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

destination_id=""
destination_listing=""
for attempt in 1 2 3 4 5 6; do
  xcrun simctl list devices available >/dev/null 2>&1 || true
  destination_listing="$(
    xcodebuild -project Yishu.xcodeproj -scheme Yishu -showdestinations 2>&1 || true
  )"
  destination_id="$(printf '%s\n' "$destination_listing" | awk -v family="$device_family" '
    $0 ~ /platform:iOS Simulator/ && $0 ~ ("name:[[:space:]]*" family) {
      line = $0
      sub(/^.*id:/, "", line)
      sub(/,.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      print line
      exit
    }
  ')"
  [[ -n "$destination_id" ]] && break
  if (( attempt < 6 )); then
    sleep "$attempt"
  fi
done

if [[ -z "$destination_id" ]]; then
  printf 'No available %s simulator was found.\n' "$device_family" >&2
  xcodebuild -version >&2 || true
  printf '%s\n' "$destination_listing" >&2
  xcrun simctl list runtimes >&2 || true
  xcrun simctl list devices available >&2 || true
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
