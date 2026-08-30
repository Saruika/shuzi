#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  printf 'security-check: %s\n' "$1" >&2
  exit 1
}

git diff --check

while IFS= read -r file; do
  plutil -lint "$file" >/dev/null
done < <(git ls-files '*.plist' '*.xcprivacy' '*.entitlements' '*.pbxproj')

if git ls-files | grep -Eiq '\.(p8|p12|mobileprovision|cer|key|pem)$|(^|/)(\.env|AuthKey_)'; then
  fail '检测到不应纳入 Git 的密钥或环境文件'
fi

secret_pattern='AKID[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|-----BEGIN ([A-Z0-9 ]+)?PRIVATE KEY-----|Secret(Key|Id)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+_.=-]{16,}'
if git grep -I -q -E "$secret_pattern" -- . \
  ':(exclude)YishuTests/**' ':(exclude)YishuUITests/**'; then
  fail '检测到疑似长期凭据，已停止构建（不输出匹配内容）'
fi

credential_url_pattern='https?://[^/@[:space:]]+:[^/@[:space:]]+@'
if git grep -I -q -E "$credential_url_pattern" -- . \
  ':(exclude)YishuTests/**' ':(exclude)YishuUITests/**'; then
  fail '检测到 URL 内嵌账号密码'
fi

if git grep -q 'http://' -- ':(glob)Yishu/**/*.swift'; then
  fail 'iOS 生产源码中不允许明文 HTTP 地址'
fi

if command -v php >/dev/null 2>&1; then
  php -l Server/shuzijun-app-content.php >/dev/null
  php Server/tests/plugin-contract-test.php
fi

python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("Server/entitlement-verifier/app.py").read_text(encoding="utf-8"))'
python3 Server/tests/sync-script-contract-test.py
bash -n Server/operations/apply-shuzijun-sync

printf 'security-check: passed\n'
