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

xcodebuild \
  -project Yishu.xcodeproj \
  -scheme Yishu \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$temporary_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

app_path="$temporary_root/DerivedData/Build/Products/Release-iphonesimulator/Yishu.app"
executable="$app_path/Yishu"
test -d "$app_path"
test -x "$executable"

if find "$app_path" -type f \
  \( -iname '*.p8' -o -iname '*.p12' -o -iname '*.pem' -o -iname '*.key' \
  -o -iname '.env*' -o -iname 'AuthKey_*' \) -print -quit | grep -q .; then
  printf 'release-bundle-audit: sensitive file found\n' >&2
  exit 1
fi

secret_pattern='AKID[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|-----BEGIN ([A-Z0-9 ]+)?PRIVATE KEY-----|Secret(Key|Id)[[:space:]]*[:=]'
if strings "$executable" | grep -Eiq "$secret_pattern"; then
  printf 'release-bundle-audit: sensitive string found\n' >&2
  exit 1
fi

printf 'release-bundle-audit: passed files=%s size_mb=%s\n' \
  "$(find "$app_path" -type f | wc -l | tr -d ' ')" \
  "$(du -sm "$app_path" | awk '{print $1}')"
