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

# Screenshot-protection boundary: this intentionally isolated compatibility
# layer relies on secure-text rendering behavior that Apple does not document as
# a general screenshot API. Keep it in one reviewed file, never bind to a named
# private UIKit class, and fail closed when the expected descendant is absent.
secure_canvas_file='Yishu/Components/ArtworkImage.swift'
while IFS= read -r implementation_file; do
  if [[ "$implementation_file" != "$secure_canvas_file" ]]; then
    fail '截图保护兼容实现越过已审核文件边界'
  fi
done < <(git grep -l -E 'isSecureTextEntry|SecureCanvasResolver|SecureHostingContainerView' -- \
  ':(glob)Yishu/**/*.swift' || true)

if [[ "$(grep -cF 'secureTextField.isSecureTextEntry = true' "$secure_canvas_file" || true)" -ne 1 ]]; then
  fail '安全画布必须且只能由一个非交互 secure text field 提供'
fi
grep -qF 'override var canBecomeFirstResponder: Bool' "$secure_canvas_file" \
  || fail '安全画布 text field 必须禁止获取焦点'
grep -qF 'secureTextField.isAccessibilityElement = false' "$secure_canvas_file" \
  || fail '安全画布 text field 不得进入辅助功能焦点'
grep -qF 'candidate.isDescendant(of: textField)' "$secure_canvas_file" \
  || fail '安全画布解析器必须验证 UIKit 宿主从属关系'
grep -qF 'enterPrivacyFallback' "$secure_canvas_file" \
  || fail '安全画布缺失时必须失败关闭并隐藏受保护内容'
grep -qF 'CaptureProtectionCover()' "$secure_canvas_file" \
  || fail '安全画布下方必须保留品牌保护页'
if grep -q -E '_UIText|NSClassFromString|objc_getClass|object_getClass|value\(forKey:|perform\(Selector' \
  "$secure_canvas_file"; then
  fail '安全画布不得硬编码或动态调用私有 UIKit 类与选择器'
fi

if command -v php >/dev/null 2>&1; then
  php -l Server/shuzijun-app-content.php >/dev/null
  php -l Server/vendor/shuzijun/app-content/class-shuzijun-collaboration-private-payload.php >/dev/null
  php Server/tests/collaboration-private-payload-test.php
  php Server/tests/collaboration-outbox-deletion-test.php
  php Server/tests/collaboration-admin-notice-test.php
  php Server/tests/fan-bound-administrator-auth-test.php
  php -l Server/tests/fan-administrator-binding-wordpress-integration.php >/dev/null
  php -l Server/tests/fan-administrator-media-wordpress-integration.php >/dev/null
  while IFS= read -r -d '' plugin_module; do
    php -l "$plugin_module" >/dev/null
  done < <(find Server/vendor/shuzijun/app-content -type f -name '*.php' -print0)
  php Server/tests/plugin-contract-test.php
  for service_environment in unset production review invalid wrong-home; do
    php Server/tests/service-environment-regression.php "$service_environment"
  done
  php Server/tests/collaboration-schema-regression.php
  python3 Server/tests/collaboration-release-probe-test.py
fi

if command -v composer >/dev/null 2>&1; then
  composer audit --locked --no-dev --working-dir=Server
elif [[ "${CI:-}" == "true" ]]; then
  fail 'CI 环境缺少 Composer，无法执行锁定依赖漏洞审计'
fi

python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("Server/entitlement-verifier/app.py").read_text(encoding="utf-8"))'
python3 -c 'import ast, pathlib; [ast.parse(path.read_text(encoding="utf-8")) for path in pathlib.Path("Server/operations").glob("*.py")]'
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("Server/operations/deploy-shuzijun-sync-release").read_text(encoding="utf-8"))'
python3 Scripts/test-signout-contract.py
python3 Scripts/test-apple-login-lifecycle-contract.py
python3 Scripts/test-launch-poster-contract.py
python3 Scripts/test-weather-privacy-contract.py
python3 Scripts/test-collaboration-mail-privacy-contract.py
python3 Scripts/test-privacy-alignment.py
python3 Scripts/test-push-auto-enable-contract.py
python3 Server/tests/drama-link-monitor-test.py
python3 Scripts/test-album-title-style-contract.py
python3 Scripts/test-scroll-chrome-contract.py
python3 Scripts/test-ci-permission-isolation.py
python3 Scripts/test-ci-test-summary.py
python3 Scripts/test-distribution-package.py
python3 Server/tests/app-content-release-contract-test.py
python3 Server/tests/review-bootstrap-test.py
python3 Server/tests/review-catalog-test.py
python3 Server/tests/review-accounts-test.py
python3 Server/tests/review-upgrade-test.py
python3 Server/tests/review-permalinks-test.py
python3 Server/tests/account-authority-role-contract-test.py
python3 Server/tests/deploy-app-content-boot-guard-state-machine-test.py
python3 Server/tests/bootstrap-legacy-app-content-release-contract-test.py
python3 Server/tests/standby-seed-contract-test.py
python3 Server/tests/internal-health-contract-test.py
python3 Server/tests/health-monitor-deployer-contract-test.py
python3 Server/tests/webroot-verifier-trust-contract-test.py
python3 Server/tests/sync-script-contract-test.py
python3 Server/tests/sync-receipt-recovery-contract-test.py
python3 Server/tests/sync-reconcile-generation7-service-contract-test.py
python3 Server/tests/sync-scheduler-contract-test.py
python3 Server/tests/sync-lock-contention-test.py
python3 Server/tests/sync-release-deployer-contract-test.py
python3 Server/tests/nginx-server-block-contract-test.py
python3 Server/tests/install-build34-nginx-routing-contract-test.py
python3 Server/tests/nginx-sensitive-routing-smoke-contract-test.py
bash -n Server/operations/deploy-app-content-release
bash -n Server/operations/bootstrap-legacy-app-content-release
bash -n Server/operations/seed-standby-app-content-release
bash -n Server/operations/apply-shuzijun-sync
bash -n Server/operations/deploy-shuzijun-health-monitor
bash -n Server/operations/sync-to-backup
bash -n Server/operations/verify-webroot-security
sh -n Server/operations/shuzijun-sync-ssh-gate
if command -v visudo >/dev/null 2>&1; then
  visudo -cf Server/operations/shuzijun-sync-transport.sudoers >/dev/null
fi
bash -n Server/tests/fan-api-smoke.sh
bash -n Server/tests/nginx-sensitive-routing-smoke.sh

grep -qFx 'd /var/lib/shuzijun-logs 0700 root root -' \
  Server/operations/shuzijun-private-logs.conf
grep -qFx 'f /var/lib/shuzijun-logs/sync-authority.log 0600 root root -' \
  Server/operations/shuzijun-private-logs.conf
grep -qFx 'f /var/lib/shuzijun-logs/sync-standby.log 0600 root root -' \
  Server/operations/shuzijun-private-logs.conf
grep -qFx 'f /var/lib/shuzijun-logs/snapshot.log 0600 root root -' \
  Server/operations/shuzijun-private-logs.conf
grep -qFx 'CRON_TZ=Asia/Shanghai' Server/operations/tencent-daily-snapshot.cron
grep -qFx '31 3 * * * root umask 077; flock -xn /run/tencent-snapshot.lock -c /usr/local/sbin/tencent-daily-snapshot >>/var/lib/shuzijun-logs/snapshot.log 2>&1' \
  Server/operations/tencent-daily-snapshot.cron
if grep -qE '/var/log/(wp-sync|shuzijun-sync-receiver|tencent-snapshot)\.log' \
  Server/operations/shuzijun-internal-health; then
  fail '内部健康监控不得信任共享 /var/log 同步或快照日志'
fi

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
plugin_implementation=Server/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php
grep -qF "const ACCOUNT_AUTHORITY_ROLE_PATH = '/etc/shuzijun/account-authority-role';" \
  "$plugin_implementation"
grep -qF '$payload === "authority\n"' "$plugin_implementation"
grep -qF 'yishu_account_authority_unavailable' "$plugin_implementation"
legacy_authority_constant='YISHU_ACCOUNT_''AUTHORITY'
if grep -R -I -q -F "$legacy_authority_constant" Server Scripts; then
  fail '检测到已废弃的 PHP authority 常量，必须只使用固定角色 marker'
fi
grep -qF -- '--authority-role authority' Server/operations/README.md
grep -qF -- '--authority-role standby' Server/operations/README.md
grep -qFx 'ExecStart=/usr/bin/flock -n /run/shuzijun-sync/sync.lock /usr/local/sbin/sync-to-backup' \
  Server/operations/shuzijun-sync.service
grep -qFx 'Persistent=true' Server/operations/shuzijun-sync.timer
grep -qFx '    ForceCommand /usr/local/sbin/shuzijun-sync-ssh-gate' \
  Server/operations/shuzijun-sync-transport.sshd
grep -qFx 'shuzijun-sync-transport ALL=(root:root) NOPASSWD: /usr/local/sbin/apply-shuzijun-sync --attest, /usr/local/sbin/apply-shuzijun-sync --protocol, /usr/local/sbin/apply-shuzijun-sync --reconcile-receipt, /usr/local/sbin/apply-shuzijun-sync --ingest' \
  Server/operations/shuzijun-sync-transport.sudoers
if grep -qF 'Cmnd_Alias' Server/operations/shuzijun-sync-transport.sudoers; then
  fail '同步 sudoers 不得使用在重复 includedir 环境中会冲突的别名'
fi
if grep -qF 'NOPASSWD: ALL' Server/operations/shuzijun-sync-transport.sudoers; then
  fail '同步传输账号不得拥有通配 sudo 权限'
fi

printf 'security-check: passed\n'
