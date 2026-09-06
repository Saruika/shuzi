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
    function identifier(line) {
      sub(/^.*id:/, "", line)
      sub(/,.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      return line
    }
    $0 ~ /platform:iOS Simulator/ && $0 ~ ("name:[[:space:]]*" family) {
      if (fallback == "") { fallback = identifier($0) }
      if (family == "iPhone") {
        preferred = $0 ~ /name:[[:space:]]*iPhone .* Pro Max/
      } else {
        preferred = $0 ~ /name:[[:space:]]*iPad Pro 13-inch/
      }
      if (preferred) {
        print identifier($0)
        found = 1
        exit
      }
    }
    END {
      if (!found && fallback != "") { print fallback }
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
result_root="$(cd "$result_root" && pwd -P)"
run_id="$(date +%s)-$(uuidgen)"
result_bundle="$result_root/Yishu-${device_family}-${run_id}.xcresult"

# Use the discovered simulator ONLY as a hardware/runtime template. The helper
# runs first-launch authorization and the complete suite on one fresh device,
# then deletes only that owned device. Unit hosts must not leave an unanswered
# permission alert on a different simulator ahead of UI layout assertions.
# The full suite keeps XCTest's system accessibility audit on iPhone. On iPad
# it uses the existing deterministic safe-area, 44pt, Dynamic Type, VoiceOver
# and actual UI-configuration checks rather than accepting framework error -56.
Scripts/ci-notification-permission-test.sh \
  "$destination_id" \
  "$temporary_root/DerivedData" \
  "$result_root/Yishu-${device_family}-NotificationPermission-${run_id}.xcresult" \
  "$result_bundle"
