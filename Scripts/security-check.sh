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
jwt_readme='Server/vendor/firebase/php-jwt/README.md'
jwt_readme_sha256='8e2392c48204a21ad0d73068fb273b7ec1f79ccf13eab3fe6f256382f741dc39'
if [[ ! -f "$jwt_readme" ]] \
  || [[ "$(shasum -a 256 "$jwt_readme" | awk '{print $1}')" != "$jwt_readme_sha256" ]]; then
  fail 'firebase/php-jwt README 与已审核的上游样例不一致'
fi
if git grep -I -q -E "$secret_pattern" -- . \
  ':(exclude)YishuTests/**' ':(exclude)YishuUITests/**' \
  ":(exclude)$jwt_readme"; then
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

if command -v composer >/dev/null 2>&1; then
  composer audit --locked --no-dev --working-dir=Server
elif [[ "${CI:-}" == "true" ]]; then
  fail 'CI 环境缺少 Composer，无法执行锁定依赖漏洞审计'
fi

python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("Server/entitlement-verifier/app.py").read_text(encoding="utf-8"))'
python3 -c 'import ast, pathlib; [ast.parse(path.read_text(encoding="utf-8")) for path in pathlib.Path("Server/operations").glob("*.py")]'
python3 Server/tests/app-content-release-contract-test.py
python3 Server/tests/account-authority-role-contract-test.py
python3 Server/tests/deploy-app-content-boot-guard-state-machine-test.py
python3 Server/tests/bootstrap-legacy-app-content-release-contract-test.py
python3 Server/tests/standby-seed-contract-test.py
python3 Server/tests/webroot-verifier-trust-contract-test.py
python3 Server/tests/sync-script-contract-test.py
python3 Server/tests/sync-scheduler-contract-test.py
python3 Server/tests/nginx-server-block-contract-test.py
python3 Server/tests/install-build34-nginx-routing-contract-test.py
python3 Server/tests/nginx-sensitive-routing-smoke-contract-test.py
bash -n Server/operations/deploy-app-content-release
bash -n Server/operations/bootstrap-legacy-app-content-release
bash -n Server/operations/seed-standby-app-content-release
bash -n Server/operations/apply-shuzijun-sync
bash -n Server/operations/sync-to-backup
bash -n Server/operations/verify-webroot-security
sh -n Server/operations/shuzijun-sync-ssh-gate
if command -v visudo >/dev/null 2>&1; then
  visudo -cf Server/operations/shuzijun-sync-transport.sudoers >/dev/null
fi
bash -n Server/tests/fan-api-smoke.sh
bash -n Server/tests/nginx-sensitive-routing-smoke.sh

grep -qF 'wp-config\.php' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF '\.php[^/]+$' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF 'location ~* ^/wp-content/.*\.php(?:$|/) {' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF '^/images/.*\.php' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF '\.env' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF '|p8|' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF 'return 404;' Server/nginx/shuzijun-sensitive-files-deny.conf
grep -qF 'shuzijun-sensitive-files-deny.conf' Server/nginx/README.md
grep -qF 'location ~* ^/images/' Server/nginx/shuzijun-legacy-images-alias.conf
grep -qF 'wp-content/uploads/hero-images/$1;' Server/nginx/shuzijun-legacy-images-alias.conf
if [[ "$(grep -cF 'location ~* ^/images/' Server/nginx/shuzijun-legacy-images-alias.conf)" -ne 2 ]]; then
  fail '旧图片映射必须包含有序的图片白名单与兜底正则'
fi
if grep -qF 'location /images/' Server/nginx/shuzijun-legacy-images-alias.conf; then
  fail '旧图片兜底不得使用可被后续正则覆盖的普通前缀'
fi
if grep -qF 'location ^~ /images/' Server/nginx/shuzijun-legacy-images-alias.conf; then
  fail '旧图片映射不得绕过敏感文件正则规则'
fi
grep -qF 'shuzijun-legacy-images-alias.conf' Server/nginx/README.md
grep -qF "const ACCOUNT_AUTHORITY_ROLE_PATH = '/etc/shuzijun/account-authority-role';" \
  Server/shuzijun-app-content.php
grep -qF '$payload === "authority\n"' Server/shuzijun-app-content.php
grep -qF 'yishu_account_authority_unavailable' Server/shuzijun-app-content.php
legacy_authority_constant='YISHU_ACCOUNT_''AUTHORITY'
if grep -R -I -q -F "$legacy_authority_constant" Server Scripts; then
  fail '检测到已废弃的 PHP authority 常量，必须只使用固定角色 marker'
fi
grep -qF -- '--authority-role authority' Server/operations/README.md
grep -qF -- '--authority-role standby' Server/operations/README.md
grep -qFx 'ExecStart=/usr/bin/flock -n /run/shuzijun-sync.lock /usr/local/sbin/sync-to-backup' \
  Server/operations/shuzijun-sync.service
grep -qFx 'Persistent=true' Server/operations/shuzijun-sync.timer
grep -qFx '    ForceCommand /usr/local/sbin/shuzijun-sync-ssh-gate' \
  Server/operations/shuzijun-sync-transport.sshd
grep -qFx 'shuzijun-sync-transport ALL=(root:root) NOPASSWD: SHUZIJUN_SYNC_RECEIVER' \
  Server/operations/shuzijun-sync-transport.sudoers
if grep -qF 'NOPASSWD: ALL' Server/operations/shuzijun-sync-transport.sudoers; then
  fail '同步传输账号不得拥有通配 sudo 权限'
fi

printf 'security-check: passed\n'
