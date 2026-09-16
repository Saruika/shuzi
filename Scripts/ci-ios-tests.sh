#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

device_family="${1:-iPhone}"
runtime_version="${2:-latest}"
if (( $# > 2 )); then
  printf 'usage: %s iPhone|iPad [runtime-version|latest]\n' "$0" >&2
  exit 2
fi
if [[ "$runtime_version" != latest && ! "$runtime_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  printf 'Use an explicit runtime version such as 27.0, or latest.\n' >&2
  exit 2
fi
case "$device_family" in
  iPhone|iPad) ;;
  *)
    printf 'usage: %s iPhone|iPad [runtime-version|latest]\n' "$0" >&2
    exit 2
    ;;
esac

destination_id=""
destination_listing=""
for attempt in 1 2 3 4 5 6; do
  destination_listing="$(
    xcrun simctl list devices available --json 2>/dev/null || true
  )"
  destination_id="$(printf '%s\n' "$destination_listing" |
    python3 Scripts/select-ios-simulator.py --family "$device_family" --runtime "$runtime_version" || true)"
  [[ -n "$destination_id" ]] && break
  if (( attempt < 6 )); then
    sleep "$attempt"
  fi
done

if [[ -z "$destination_id" ]]; then
  printf 'No available %s simulator was found for runtime %s.\n' "$device_family" "$runtime_version" >&2
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
