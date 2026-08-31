#!/usr/bin/env bash
set -euo pipefail

api_root="${1:-https://www.shuzijun.com.cn/wp-json/shuzijun/v1}"
wordpress_root="${2:-/var/www/html/shuzijun.com.cn}"
test_dir=$(mktemp -d)
install_id=$(cat /proc/sys/kernel/random/uuid)
suffix=$(openssl rand -hex 6)
douyin_id="codex_test_${suffix}"
password="Fan-${suffix}-2026!"
token=''
token_hash=''
app_password_name="codex-fan-smoke-${suffix}"
app_password_uuid=''

revoke_temporary_app_password() {
  local target_uuid="$app_password_uuid"
  if [[ -z "$target_uuid" ]]; then
    target_uuid=$(sudo -u www-data wp --path="$wordpress_root" user application-password list \
      yishu_app_manager --fields=uuid,name --format=json 2>/dev/null \
      | jq -r --arg name "$app_password_name" '.[] | select(.name == $name) | .uuid' \
      | head -n 1 || true)
  fi
  if [[ "$target_uuid" =~ ^[a-f0-9-]{36}$ ]]; then
    sudo -u www-data wp --path="$wordpress_root" user application-password delete \
      yishu_app_manager "$target_uuid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$token" ]]; then
    curl --silent --show-error --output /dev/null \
      --request POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Bearer ${token}" \
      --header "X-Yishu-Install-ID: ${install_id}" \
      --data '{"confirmation":"DELETE_ACCOUNT"}' \
      "${api_root}/fan/delete" || true
  fi

  local user_ids
  user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
    --meta_key=_yishu_fan_douyin_id --meta_value="$douyin_id" --field=ID 2>/dev/null || true)
  for user_id in $user_ids; do
    if [[ "$user_id" =~ ^[0-9]+$ ]]; then
      sudo -u www-data wp --path="$wordpress_root" user delete "$user_id" --yes >/dev/null 2>&1 || true
    fi
  done

  local option_hash
  option_hash=$(printf '%s' "$douyin_id" | sha256sum | awk '{print $1}')
  sudo -u www-data wp --path="$wordpress_root" option delete \
    "yishu_fan_douyin_${option_hash}" >/dev/null 2>&1 || true

  revoke_temporary_app_password

  rm -f "$test_dir/register.json" "$test_dir/session.json" \
    "$test_dir/login.json" "$test_dir/deleted-login.json" \
    "$test_dir/admin-list.json" "$test_dir/admin-update.json" \
    "$test_dir/suspended-update.json" "$test_dir/revoked-session.json" \
    "$test_dir/suspended-login.json" "$test_dir/admin.netrc"
  rmdir "$test_dir" 2>/dev/null || true
}
trap cleanup EXIT

register_status=$(curl --silent --show-error --output "$test_dir/register.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg displayName '接口验收用户' \
    --arg douyinID "$douyin_id" \
    --arg password "$password" \
    --arg installID "$install_id" \
    --arg consentVersion '2026-08-31' \
    '{displayName:$displayName,douyinID:$douyinID,password:$password,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/register")
[[ "$register_status" == '201' ]]
jq -e --arg douyinID "$douyin_id" '
  (.token | test("^[A-Za-z0-9_-]{43,128}$")) and
  (.profile.identityCode | test("^HS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$")) and
  (.profile.douyinID == $douyinID) and
  (.profile.permissions == ["gallery_full", "video_view"])
' "$test_dir/register.json" >/dev/null
token=$(jq -r '.token' "$test_dir/register.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
identity_code=$(jq -r '.profile.identityCode' "$test_dir/register.json")
installation_code=$(jq -r '.profile.installationCode' "$test_dir/register.json")
[[ "$installation_code" =~ ^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$ ]]
sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null
echo 'fan-api-smoke: registration passed'

app_password_payload=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_user_by('login', 'yishu_app_manager'); \$result = WP_Application_Passwords::create_new_application_password(\$user->ID, array('name' => '${app_password_name}')); if (is_wp_error(\$result)) { exit(2); } echo wp_json_encode(array('uuid' => \$result[1]['uuid'], 'password' => \$result[0]));")
app_password=$(printf '%s' "$app_password_payload" | jq -r '.password')
app_password_uuid=$(printf '%s' "$app_password_payload" | jq -r '.uuid')
[[ "$app_password_uuid" =~ ^[a-f0-9-]{36}$ ]]
umask 077
printf 'machine www.shuzijun.com.cn\nlogin yishu_app_manager\npassword %s\n' \
  "$app_password" > "$test_dir/admin.netrc"

admin_list_status=$(curl --silent --show-error --output "$test_dir/admin-list.json" \
  --write-out '%{http_code}' \
  --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans")
[[ "$admin_list_status" == '200' ]]
jq -e --arg identityCode "$identity_code" --arg douyinID "$douyin_id" '
  any(.users[]; .identityCode == $identityCode and .douyinID == $douyinID) and
  ([.permissionCatalog[].code] | sort == ["early_access", "gallery_full", "video_view"])
' "$test_dir/admin-list.json" >/dev/null
user_uuid=$(jq -r --arg identityCode "$identity_code" \
  '.users[] | select(.identityCode == $identityCode) | .userID' \
  "$test_dir/admin-list.json")
[[ "$user_uuid" =~ ^[a-f0-9-]{36}$ ]]

admin_update_status=$(curl --silent --show-error --output "$test_dir/admin-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","early_access"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$admin_update_status" == '200' ]]
jq -e '.user.permissions == ["gallery_full", "early_access"] and .user.status == "active"' \
  "$test_dir/admin-update.json" >/dev/null

session_status=$(curl --silent --show-error --output "$test_dir/session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$session_status" == '200' ]]
jq -e '.profile.permissions == ["gallery_full", "early_access"]' \
  "$test_dir/session.json" >/dev/null
echo 'fan-api-smoke: administrator permission update passed'

logout_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/logout")
[[ "$logout_status" == '200' ]]
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null 2>&1; then
  exit 1
fi
token=''
token_hash=''

login_status=$(curl --silent --show-error --output "$test_dir/login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$login_status" == '200' ]]
token=$(jq -r '.token' "$test_dir/login.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
jq -e --arg installationCode "$installation_code" \
  '.profile.installationCode == $installationCode' "$test_dir/login.json" >/dev/null
sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null
echo 'fan-api-smoke: logout and login passed'

suspend_status=$(curl --silent --show-error --output "$test_dir/suspended-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","early_access"],"status":"suspended"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$suspend_status" == '200' ]]
jq -e '.user.status == "suspended"' "$test_dir/suspended-update.json" >/dev/null

revoked_session_status=$(curl --silent --show-error --output "$test_dir/revoked-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$revoked_session_status" == '401' ]]
token=''
token_hash=''

suspended_login_status=$(curl --silent --show-error --output "$test_dir/suspended-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$suspended_login_status" == '200' ]]
jq -e --arg installationCode "$installation_code" \
  '.profile.status == "suspended" and .profile.installationCode == $installationCode' \
  "$test_dir/suspended-login.json" >/dev/null
token=$(jq -r '.token' "$test_dir/suspended-login.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
echo 'fan-api-smoke: suspended account retained self-service deletion access'

delete_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data '{"confirmation":"DELETE_ACCOUNT"}' \
  "${api_root}/fan/delete")
[[ "$delete_status" == '200' ]]
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null 2>&1; then
  exit 1
fi
token=''
token_hash=''

deleted_login_status=$(curl --silent --show-error --output "$test_dir/deleted-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$deleted_login_status" == '401' ]]
remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_douyin_id --meta_value="$douyin_id" --field=ID 2>/dev/null || true)
[[ -z "$remaining" ]]
echo 'fan-api-smoke: account deletion passed'
