#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ $# != 3 && $# != 4 ]]; then
  printf 'usage: %s template-simulator-uuid derived-data-path permission-result-path [full-suite-result-path]\n' "$0" >&2
  exit 2
fi

template_id="$1"
derived_data="$2"
result_bundle="$3"
full_suite_result="${4:-}"
uuid_pattern='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
if [[ ! "$template_id" =~ $uuid_pattern ]]; then
  printf 'The template simulator must be an exact UUID.\n' >&2
  exit 2
fi
if [[ "$derived_data" != /* || "$result_bundle" != /* || -e "$result_bundle" ]]; then
  printf 'Use absolute build/result paths and a new result-bundle path.\n' >&2
  exit 2
fi
if [[ -n "$full_suite_result" && ( "$full_suite_result" != /* ||
      -e "$full_suite_result" || "$full_suite_result" == "$result_bundle" ) ]]; then
  printf 'The full suite needs its own new absolute result-bundle path.\n' >&2
  exit 2
fi

# The template supplies only its hardware/runtime, never its application or
# notification-permission state. No unit-test host may run on the new device
# before the UI test asserts the first-launch system permission prompt.
device_metadata="$(
  xcrun simctl list devices available --json | python3 -c '
import json
import sys

template_id = sys.argv[1].upper()
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["udid"].upper() == template_id and device.get("isAvailable"):
            print(device["deviceTypeIdentifier"], runtime, sep="\t")
            raise SystemExit(0)
raise SystemExit("Template simulator is not available.")
' "$template_id"
)"
IFS=$'\t' read -r device_type runtime_id <<< "$device_metadata"
if [[ "$device_type" != com.apple.CoreSimulator.SimDeviceType.* ||
      "$runtime_id" != com.apple.CoreSimulator.SimRuntime.iOS-* ]]; then
  printf 'The template must be an available iOS simulator.\n' >&2
  exit 1
fi

created_id=""
cleanup() {
  local exit_status=$?
  trap - EXIT
  if [[ "$created_id" =~ $uuid_pattern && "$created_id" != "$template_id" ]]; then
    xcrun simctl shutdown "$created_id" >/dev/null 2>&1 || true
    if ! xcrun simctl delete "$created_id"; then
      printf 'Could not delete the temporary permission-test simulator %s.\n' "$created_id" >&2
      if (( exit_status == 0 )); then exit_status=1; fi
    fi
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

created_id="$(xcrun simctl create "Yishu Startup Permission $(uuidgen)" "$device_type" "$runtime_id")"
if [[ ! "$created_id" =~ $uuid_pattern || "$created_id" == "$template_id" ]]; then
  printf 'simctl did not return a new simulator UUID.\n' >&2
  exit 1
fi
printf 'Running first-launch notification permission on fresh simulator %s.\n' "$created_id"
printf 'Test hardware: %s; runtime: %s.\n' "$device_type" "$runtime_id"
xcrun simctl boot "$created_id"
xcrun simctl bootstatus "$created_id" -b

# Use test (rather than a separate build directory) so the ordinary suite can
# reuse these exact build products afterwards. only-testing excludes unit hosts.
xcodebuild \
  -project Yishu.xcodeproj \
  -scheme Yishu \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$created_id" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage YES \
  -only-testing:YishuUITests/YishuUITests/testStartupAsksSystemNotificationPermissionBeforeLogin \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test

if [[ -n "$full_suite_result" ]]; then
  # Keep the full suite on this SAME freshly authorized device. Previously the
  # caller switched back to the untouched template: its unit-test host opened
  # an unanswered system permission alert that survived into layout tests.
  # No tests are removed; only the dedicated first-launch test is not repeated.
  printf 'Running full suite on the same authorized simulator %s.\n' "$created_id"
  xcodebuild \
    -project Yishu.xcodeproj \
    -scheme Yishu \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$created_id" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$full_suite_result" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage YES \
    -skip-testing:YishuUITests/YishuUITests/testStartupAsksSystemNotificationPermissionBeforeLogin \
    COMPILER_INDEX_STORE_ENABLE=NO \
    test
fi
