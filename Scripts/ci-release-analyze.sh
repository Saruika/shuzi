#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

temporary_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/yishu-analyze.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

xcodebuild \
  -project Yishu.xcodeproj \
  -scheme Yishu \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$temporary_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  analyze
