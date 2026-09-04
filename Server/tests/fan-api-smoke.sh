#!/usr/bin/env bash
set -euo pipefail

api_root="${1:-https://shuzijun.com.cn/wp-json/shuzijun/v1}"
wordpress_root="${2:-/var/www/html/shuzijun.com.cn}"
api_host="${api_root#*://}"
api_host="${api_host%%/*}"
if [[ ! "$api_host" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo 'fan-api-smoke: invalid API host' >&2
  exit 1
fi
test_dir=$(mktemp -d /tmp/yishu-fan-api-smoke.XXXXXX)
umask 077
install_id=$(cat /proc/sys/kernel/random/uuid)
second_install_id=$(cat /proc/sys/kernel/random/uuid)
invitation_install_id=$(cat /proc/sys/kernel/random/uuid)
deletion_invitation_install_id=$(cat /proc/sys/kernel/random/uuid)
apple_install_id=$(cat /proc/sys/kernel/random/uuid)
empty_v3_install_id=$(cat /proc/sys/kernel/random/uuid)
transition_v2_install_id=$(cat /proc/sys/kernel/random/uuid)
unknown_consent_install_id=$(cat /proc/sys/kernel/random/uuid)
suffix=$(openssl rand -hex 6)
douyin_id="codex_test_${suffix}"
password="Fan-${suffix}-2026!"
empty_v3_password="Empty-${suffix}-2026!"
transition_v2_password="V2-${suffix}-2026!"
unknown_consent_password="Unknown-${suffix}-2026!"
transition_v2_douyin_id="codex_v2_${suffix}"
unknown_consent_douyin_id="codex_unknown_${suffix}"
invitation_douyin_id="codex_invite_${suffix}"
invitation_fault_douyin_id="codex_fault_${suffix}"
invitation_new_password="Inv-${suffix}-New-2026!"
token=''
token_hash=''
second_token=''
invitation_token=''
invitation_user_uuid=''
invitation_identity_code=''
invitation_placeholder=''
cleanup_invitation_user_uuid=''
cleanup_invitation_placeholder=''
deletion_invitation_user_uuid=''
app_password_name="codex-fan-smoke-${suffix}"
app_password_uuid=''
apple_challenge_option=''
curl_common=(--silent --show-error --http1.1 --retry 2 --retry-delay 1 --retry-all-errors)

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
  if [[ -n "$second_token" ]]; then
    curl "${curl_common[@]}" --output /dev/null \
      --request POST \
      --header "Authorization: Bearer ${second_token}" \
      --header "X-Yishu-Install-ID: ${second_install_id}" \
      "${api_root}/fan/logout" || true
  fi

  local user_ids user_id cleanup_douyin_id cleanup_user_uuid cleanup_token cleanup_token_hash
  local registration_file
  for cleanup_douyin_id in "$douyin_id" "$transition_v2_douyin_id" "$unknown_consent_douyin_id"; do
    user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
      --meta_key=_yishu_fan_douyin_id --meta_value="$cleanup_douyin_id" \
      --field=ID 2>/dev/null || true)
    for user_id in $user_ids; do
      if [[ "$user_id" =~ ^[0-9]+$ ]]; then
        sudo -u www-data wp --path="$wordpress_root" user delete \
          "$user_id" --yes >/dev/null 2>&1 || true
      fi
    done
  done

  # Recover any unexpected synthetic UUID/token from the negative registration
  # response files so a contract regression cannot leave test state behind.
  for registration_file in \
      "$test_dir/empty-v4-register.json" \
      "$test_dir/transition-v2-register.json" \
      "$test_dir/unknown-consent-register.json"; do
    [[ -f "$registration_file" ]] || continue
    cleanup_user_uuid=$(jq -r '.profile.userID // empty' "$registration_file" 2>/dev/null || true)
    if [[ "$cleanup_user_uuid" =~ ^[a-f0-9-]{36}$ ]]; then
      user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
        --meta_key=_yishu_fan_uuid --meta_value="$cleanup_user_uuid" \
        --field=ID 2>/dev/null || true)
      for user_id in $user_ids; do
        if [[ "$user_id" =~ ^[0-9]+$ ]]; then
          sudo -u www-data wp --path="$wordpress_root" user delete \
            "$user_id" --yes >/dev/null 2>&1 || true
        fi
      done
    fi
    cleanup_token=$(jq -r '.token // empty' "$registration_file" 2>/dev/null || true)
    if [[ "$cleanup_token" =~ ^[A-Za-z0-9_-]{43,128}$ ]]; then
      cleanup_token_hash=$(printf '%s' "$cleanup_token" | sha256sum | awk '{print $1}')
      sudo -u www-data wp --path="$wordpress_root" option delete \
        "yishu_fan_session_${cleanup_token_hash}" >/dev/null 2>&1 || true
    fi
  done

  if [[ "$invitation_user_uuid" =~ ^[a-f0-9-]{36}$ ]]; then
    local invitation_user_ids
    invitation_user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
      --meta_key=_yishu_fan_uuid --meta_value="$invitation_user_uuid" --field=ID 2>/dev/null || true)
    for user_id in $invitation_user_ids; do
      if [[ "$user_id" =~ ^[0-9]+$ ]]; then
        sudo -u www-data wp --path="$wordpress_root" user delete "$user_id" --yes >/dev/null 2>&1 || true
      fi
    done
  fi
  if [[ "$cleanup_invitation_user_uuid" =~ ^[a-f0-9-]{36}$ ]]; then
    local cleanup_invitation_user_ids
    cleanup_invitation_user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
      --meta_key=_yishu_fan_uuid --meta_value="$cleanup_invitation_user_uuid" --field=ID 2>/dev/null || true)
    for user_id in $cleanup_invitation_user_ids; do
      if [[ "$user_id" =~ ^[0-9]+$ ]]; then
        sudo -u www-data wp --path="$wordpress_root" user delete "$user_id" --yes >/dev/null 2>&1 || true
      fi
    done
  fi
  if [[ "$deletion_invitation_user_uuid" =~ ^[a-f0-9-]{36}$ ]]; then
    local deletion_invitation_user_ids
    deletion_invitation_user_ids=$(sudo -u www-data wp --path="$wordpress_root" user list \
      --meta_key=_yishu_fan_uuid --meta_value="$deletion_invitation_user_uuid" --field=ID 2>/dev/null || true)
    for user_id in $deletion_invitation_user_ids; do
      if [[ "$user_id" =~ ^[0-9]+$ ]]; then
        sudo -u www-data wp --path="$wordpress_root" user delete "$user_id" --yes >/dev/null 2>&1 || true
      fi
    done
  fi

  local option_hash invitation_value
  for invitation_value in "$douyin_id" "$transition_v2_douyin_id" \
      "$unknown_consent_douyin_id" "$invitation_douyin_id" \
      "$invitation_fault_douyin_id" "$invitation_placeholder" \
      "$cleanup_invitation_placeholder"; do
    if [[ -n "$invitation_value" ]]; then
      option_hash=$(printf '%s' "$invitation_value" | sha256sum | awk '{print $1}')
      sudo -u www-data wp --path="$wordpress_root" option delete \
        "yishu_fan_douyin_${option_hash}" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$invitation_identity_code" ]]; then
    local invitation_failure_hash
    invitation_failure_hash=$(printf '%s' "$invitation_identity_code" | sha256sum | awk '{print $1}')
    sudo -u www-data wp --path="$wordpress_root" transient delete \
      "yishu_fan_invite_login_failure_${invitation_failure_hash}" >/dev/null 2>&1 || true
  fi

  if [[ "$apple_challenge_option" =~ ^yishu_fan_apple_challenge_[a-f0-9]{64}$ ]]; then
    sudo -u www-data wp --path="$wordpress_root" option delete \
      "$apple_challenge_option" >/dev/null 2>&1 || true
  fi

  revoke_temporary_app_password

  if [[ -n "$test_dir" && "$test_dir" =~ ^/tmp/yishu-fan-api-smoke\.[A-Za-z0-9]+$ \
      && -d "$test_dir" ]]; then
    rm -rf -- "$test_dir"
  fi
}
trap cleanup EXIT

apple_challenge_status=$(curl "${curl_common[@]}" \
  --dump-header "$test_dir/apple-challenge.headers" \
  --output "$test_dir/apple-challenge.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${apple_install_id}" \
  --data "$(jq -nc --arg installID "$apple_install_id" \
    '{purpose:"sign_in",installID:$installID}')" \
  "${api_root}/fan/apple-challenge")
[[ "$apple_challenge_status" == '201' ]]
grep -Eiq '^cache-control:.*no-store' "$test_dir/apple-challenge.headers"
grep -Eiq '^cache-control:.*max-age=0' "$test_dir/apple-challenge.headers"
grep -Eiq '^pragma:[[:space:]]*no-cache' "$test_dir/apple-challenge.headers"
jq -e '
  (.challengeID | test("^[A-Za-z0-9_-]{43}$")) and
  (.nonce | test("^[a-f0-9]{64}$")) and
  (.state | test("^[A-Za-z0-9_-]{32}$")) and
  .purpose == "sign_in" and (.expiresAt | type == "string")
' "$test_dir/apple-challenge.json" >/dev/null
apple_challenge_id=$(jq -r '.challengeID' "$test_dir/apple-challenge.json")
apple_challenge_state=$(jq -r '.state' "$test_dir/apple-challenge.json")
apple_challenge_hash=$(printf '%s' "$apple_challenge_id" | sha256sum | awk '{print $1}')
apple_state_hash=$(printf '%s' "$apple_challenge_state" | sha256sum | awk '{print $1}')
apple_install_hash=$(printf '%s' "$apple_install_id" | sha256sum | awk '{print $1}')
apple_challenge_option="yishu_fan_apple_challenge_${apple_challenge_hash}"
sudo -u www-data wp --path="$wordpress_root" option get \
  "$apple_challenge_option" --format=json > "$test_dir/apple-challenge-meta.json"
jq -e --arg challengeID "$apple_challenge_id" --arg state "$apple_challenge_state" \
  --arg stateHash "$apple_state_hash" --arg installHash "$apple_install_hash" '
  .purpose == "sign_in" and
  (.nonceHash | test("^[a-f0-9]{64}$")) and
  (.stateHash == $stateHash) and
  (.installHash == $installHash) and
  (tostring | contains($challengeID) | not) and
  (tostring | contains($state) | not) and
  (has("nonce") | not)
' "$test_dir/apple-challenge-meta.json" >/dev/null

fake_identity_token="$(printf 'a%.0s' {1..40}).$(printf 'b%.0s' {1..40}).$(printf 'c%.0s' {1..40})"
apple_invalid_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/apple-invalid.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${apple_install_id}" \
  --data "$(jq -nc \
    --arg identityToken "$fake_identity_token" \
    --arg authorizationCode 'invalid-test-code' \
    --arg challengeID "$apple_challenge_id" \
    --arg state "$apple_challenge_state" \
    --arg installID "$apple_install_id" \
    '{identityToken:$identityToken,authorizationCode:$authorizationCode,challengeID:$challengeID,state:$state,installID:$installID}')" \
  "${api_root}/fan/apple-auth")
[[ "$apple_invalid_status" == '401' ]]
jq -e '.code == "fan_apple_credential_invalid"' "$test_dir/apple-invalid.json" >/dev/null
apple_challenge_option=''
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_apple_challenge_${apple_challenge_hash}" >/dev/null 2>&1; then
  echo 'fan-api-smoke: consumed Apple challenge remained in storage' >&2
  exit 1
fi
apple_replay_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/apple-replay.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${apple_install_id}" \
  --data "$(jq -nc \
    --arg identityToken "$fake_identity_token" \
    --arg authorizationCode 'invalid-test-code' \
    --arg challengeID "$apple_challenge_id" \
    --arg state "$apple_challenge_state" \
    --arg installID "$apple_install_id" \
    '{identityToken:$identityToken,authorizationCode:$authorizationCode,challengeID:$challengeID,state:$state,installID:$installID}')" \
  "${api_root}/fan/apple-auth")
[[ "$apple_replay_status" == '401' ]]
jq -e '.code == "fan_apple_challenge_invalid"' "$test_dir/apple-replay.json" >/dev/null
unset fake_identity_token apple_challenge_state
echo 'fan-api-smoke: Apple challenge hash-only storage, fail-closed verification and replay rejection passed'

unknown_consent_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/unknown-consent-register.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${unknown_consent_install_id}" \
  --data "$(jq -nc \
    --arg displayName '同意版本拒绝验收' \
    --arg douyinID "$unknown_consent_douyin_id" \
    --arg password "$unknown_consent_password" \
    --arg installID "$unknown_consent_install_id" \
    --arg consentVersion '2099-01-01-approval-v999' \
    '{displayName:$displayName,douyinID:$douyinID,password:$password,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/register")
if [[ "$unknown_consent_status" != '400' ]]; then
  unknown_consent_error=$(jq -r '.code // "unknown"' \
    "$test_dir/unknown-consent-register.json" 2>/dev/null || true)
  echo "fan-api-smoke: unknown consent was not rejected status=${unknown_consent_status} code=${unknown_consent_error:-unknown}" >&2
  exit 1
fi
jq -e '.code == "fan_consent_required"' \
  "$test_dir/unknown-consent-register.json" >/dev/null
unknown_consent_remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_douyin_id --meta_value="$unknown_consent_douyin_id" \
  --field=ID 2>/dev/null || true)
[[ -z "$unknown_consent_remaining" ]]
unknown_consent_reservation_hash=$(printf '%s' "$unknown_consent_douyin_id" \
  | sha256sum | awk '{print $1}')
if sudo -u www-data wp --path="$wordpress_root" option get \
    "yishu_fan_douyin_${unknown_consent_reservation_hash}" >/dev/null 2>&1; then
  echo 'fan-api-smoke: rejected unknown consent left a Douyin reservation' >&2
  exit 1
fi
echo 'fan-api-smoke: unknown consent version failed closed without account state'

empty_v3_register_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/empty-v4-register.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${empty_v3_install_id}" \
  --data "$(jq -nc \
    --arg displayName '空抖音验收用户' \
    --arg douyinID '' \
    --arg password "$empty_v3_password" \
    --arg installID "$empty_v3_install_id" \
    --arg consentVersion '2026-09-04-approval-v4' \
    '{displayName:$displayName,douyinID:$douyinID,password:$password,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/register")
if [[ "$empty_v3_register_status" != '400' ]]; then
  empty_v3_error=$(jq -r '.code // "unknown"' \
    "$test_dir/empty-v4-register.json" 2>/dev/null || true)
  echo "fan-api-smoke: empty-Douyin v4 registration was not rejected status=${empty_v3_register_status} code=${empty_v3_error:-unknown}" >&2
  exit 1
fi
jq -e '.code == "fan_douyin_id_invalid"' \
  "$test_dir/empty-v4-register.json" >/dev/null
empty_v3_remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --search="空抖音验收用户" --field=ID 2>/dev/null || true)
[[ -z "$empty_v3_remaining" ]]
empty_v3_password=''
echo 'fan-api-smoke: v4 empty-Douyin registration failed closed without account state'

transition_v2_register_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/transition-v2-register.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${transition_v2_install_id}" \
  --data "$(jq -nc \
    --arg displayName 'Build 40 过渡验收用户' \
    --arg douyinID "$transition_v2_douyin_id" \
    --arg password "$transition_v2_password" \
    --arg installID "$transition_v2_install_id" \
    --arg consentVersion '2026-08-31-approval-v2' \
    '{displayName:$displayName,douyinID:$douyinID,password:$password,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/register")
if [[ "$transition_v2_register_status" != '400' ]]; then
  transition_v2_error=$(jq -r '.code // "unknown"' \
    "$test_dir/transition-v2-register.json" 2>/dev/null || true)
  echo "fan-api-smoke: legacy v2 new acknowledgement was not rejected status=${transition_v2_register_status} code=${transition_v2_error:-unknown}" >&2
  exit 1
fi
jq -e '.code == "fan_consent_required"' \
  "$test_dir/transition-v2-register.json" >/dev/null
transition_v2_remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_douyin_id --meta_value="$transition_v2_douyin_id" \
  --field=ID 2>/dev/null || true)
[[ -z "$transition_v2_remaining" ]]
transition_v2_reservation_hash=$(printf '%s' "$transition_v2_douyin_id" \
  | sha256sum | awk '{print $1}')
if sudo -u www-data wp --path="$wordpress_root" option get \
    "yishu_fan_douyin_${transition_v2_reservation_hash}" >/dev/null 2>&1; then
  echo 'fan-api-smoke: transition v2 deletion left a Douyin reservation' >&2
  exit 1
fi
transition_v2_password=''
unknown_consent_password=''
echo 'fan-api-smoke: legacy v2 new acknowledgement failed closed without account state'

register_status=$(curl "${curl_common[@]}" --output "$test_dir/register.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg displayName '接口验收用户' \
    --arg douyinID "$douyin_id" \
    --arg password "$password" \
    --arg installID "$install_id" \
    --arg consentVersion '2026-09-04-approval-v4' \
    '{displayName:$displayName,douyinID:$douyinID,password:$password,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/register")
if [[ "$register_status" != '201' ]]; then
  register_error=$(jq -r '.code // "unknown"' "$test_dir/register.json" 2>/dev/null || true)
  echo "fan-api-smoke: registration failed status=${register_status} code=${register_error:-unknown}" >&2
  exit 1
fi
if ! jq -e --arg douyinID "$douyin_id" '
  (.token | test("^[A-Za-z0-9_-]{43,128}$")) and
  (.profile.identityCode | test("^HS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$")) and
  (.profile.douyinID == $douyinID) and
  (.profile.permissions == ["gallery_full", "video_view"]) and
  (.profile.status == "pending")
' "$test_dir/register.json" >/dev/null; then
  echo 'fan-api-smoke: registration response contract failed' >&2
  exit 1
fi
token=$(jq -r '.token' "$test_dir/register.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
identity_code=$(jq -r '.profile.identityCode' "$test_dir/register.json")
installation_code=$(jq -r '.profile.installationCode' "$test_dir/register.json")
[[ "$installation_code" =~ ^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$ ]]
sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null
anonymous_content_status=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' \
  "${api_root}/app-content")
if [[ "$anonymous_content_status" != '401' ]]; then
  echo "fan-api-smoke: anonymous content gate failed status=${anonymous_content_status}" >&2
  exit 1
fi
pending_content_status=$(curl "${curl_common[@]}" --output "$test_dir/pending-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
pending_error=$(jq -r '.code // "unknown"' "$test_dir/pending-content.json" 2>/dev/null || true)
if [[ "$pending_content_status" != '403' || "$pending_error" != 'fan_approval_pending' ]]; then
  echo "fan-api-smoke: pending content gate failed status=${pending_content_status} code=${pending_error:-unknown}" >&2
  exit 1
fi
echo 'fan-api-smoke: pending registration gate passed'

app_password_payload=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_user_by('login', 'yishu_app_manager'); \$result = WP_Application_Passwords::create_new_application_password(\$user->ID, array('name' => '${app_password_name}')); if (is_wp_error(\$result)) { exit(2); } echo wp_json_encode(array('uuid' => \$result[1]['uuid'], 'password' => \$result[0]));")
app_password=$(printf '%s' "$app_password_payload" | jq -r '.password')
app_password_uuid=$(printf '%s' "$app_password_payload" | jq -r '.uuid')
[[ "$app_password_uuid" =~ ^[a-f0-9-]{36}$ ]]
umask 077
printf 'machine %s\nlogin yishu_app_manager\npassword %s\n' \
  "$api_host" "$app_password" > "$test_dir/admin.netrc"

admin_list_status=$(curl "${curl_common[@]}" --output "$test_dir/admin-list.json" \
  --write-out '%{http_code}' \
  --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans")
[[ "$admin_list_status" == '200' ]]
jq -e --arg identityCode "$identity_code" --arg douyinID "$douyin_id" '
  any(.users[]; .identityCode == $identityCode and .douyinID == $douyinID and .status == "pending") and
  ([.permissionCatalog[].code] | sort == ["early_access", "gallery_full", "video_view"])
' "$test_dir/admin-list.json" >/dev/null
user_uuid=$(jq -r --arg identityCode "$identity_code" \
  '.users[] | select(.identityCode == $identityCode) | .userID' \
  "$test_dir/admin-list.json")
[[ "$user_uuid" =~ ^[a-f0-9-]{36}$ ]]

anonymous_admin_update_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/anonymous-admin-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","video_view"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$anonymous_admin_update_status" == '401' ]]

fan_admin_update_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/fan-admin-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data '{"permissions":["gallery_full","video_view"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$fan_admin_update_status" == '401' ]]

unchanged_status=$(curl "${curl_common[@]}" --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans" \
  | jq -r --arg identityCode "$identity_code" \
    '.users[] | select(.identityCode == $identityCode) | .status')
[[ "$unchanged_status" == 'pending' ]]
echo 'fan-api-smoke: anonymous and fan administrator mutations rejected'

invitation_anonymous_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-anonymous.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"count":1}' \
  "${api_root}/app-admin/fans/invitations")
[[ "$invitation_anonymous_status" == '401' ]]

invitation_count_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-count.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"count":6}' \
  "${api_root}/app-admin/fans/invitations")
[[ "$invitation_count_status" == '400' ]]
jq -e '.code == "fan_invitation_count_invalid"' \
  "$test_dir/invitation-count.json" >/dev/null

invitation_create_status=$(curl "${curl_common[@]}" \
  --dump-header "$test_dir/invitation-create.headers" \
  --output "$test_dir/invitation-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"count":1}' \
  "${api_root}/app-admin/fans/invitations")
[[ "$invitation_create_status" == '201' ]]
if ! grep -Eiq '^cache-control:.*private' \
    "$test_dir/invitation-create.headers" \
  || ! grep -Eiq '^cache-control:.*no-store' \
    "$test_dir/invitation-create.headers" \
  || ! grep -Eiq '^cache-control:.*max-age=0' \
    "$test_dir/invitation-create.headers" \
  || ! grep -Eiq '^pragma:[[:space:]]*no-cache' \
    "$test_dir/invitation-create.headers"; then
  echo 'fan-api-smoke: invitation credential response was cacheable' >&2
  exit 1
fi
jq -e '
  (keys | sort) == ["invitations"] and
  (.invitations | length) == 1 and
  (.invitations[0] | keys | sort) ==
    ["expiresAt", "identityCode", "requiresAccountSetup", "temporaryPassword", "userID"] and
  (.invitations[0].userID | test("^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$")) and
  (.invitations[0].identityCode | test("^HS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$")) and
  (.invitations[0].temporaryPassword | test("^Tmp-[A-Za-z0-9_-]{24}-9!$")) and
  (.invitations[0].expiresAt | type == "string") and
  (.invitations[0].requiresAccountSetup == true)
' "$test_dir/invitation-create.json" >/dev/null
invitation_user_uuid=$(jq -r '.invitations[0].userID' "$test_dir/invitation-create.json")
invitation_identity_code=$(jq -r '.invitations[0].identityCode' "$test_dir/invitation-create.json")
invitation_temporary_password=$(jq -r '.invitations[0].temporaryPassword' "$test_dir/invitation-create.json")
invitation_expires_at=$(jq -r '.invitations[0].expiresAt' "$test_dir/invitation-create.json")
invitation_remaining=$(( $(date --date="$invitation_expires_at" +%s) - $(date +%s) ))
(( invitation_remaining >= 86280 && invitation_remaining <= 86460 ))

deletion_invitation_create_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-invitation-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"count":1}' \
  "${api_root}/app-admin/fans/invitations")
[[ "$deletion_invitation_create_status" == '201' ]]
deletion_invitation_user_uuid=$(jq -r '.invitations[0].userID' \
  "$test_dir/deletion-invitation-create.json")
deletion_invitation_identity_code=$(jq -r '.invitations[0].identityCode' \
  "$test_dir/deletion-invitation-create.json")
deletion_invitation_password=$(jq -r '.invitations[0].temporaryPassword' \
  "$test_dir/deletion-invitation-create.json")
deletion_invitation_login_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-invitation-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${deletion_invitation_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$deletion_invitation_identity_code" \
    --arg password "$deletion_invitation_password" \
    --arg installID "$deletion_invitation_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$deletion_invitation_login_status" == '200' ]]
deletion_invitation_token=$(jq -r '.token' "$test_dir/deletion-invitation-login.json")
deletion_invitation_delete_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-invitation-delete.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${deletion_invitation_token}" \
  --header "X-Yishu-Install-ID: ${deletion_invitation_install_id}" \
  --data "$(jq -nc \
    --arg currentPassword "$deletion_invitation_password" \
    --arg installID "$deletion_invitation_install_id" \
    '{confirmation:"DELETE_ACCOUNT",currentPassword:$currentPassword,installID:$installID}')" \
  "${api_root}/fan/delete")
[[ "$deletion_invitation_delete_status" == '200' ]]
deletion_invitation_remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_uuid --meta_value="$deletion_invitation_user_uuid" --field=ID 2>/dev/null || true)
[[ -z "$deletion_invitation_remaining" ]]
echo 'fan-api-smoke: onboarding account deletion with temporary password passed'

invitation_list_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-list.json" \
  --write-out '%{http_code}' \
  --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans")
[[ "$invitation_list_status" == '200' ]]
jq -e --arg userID "$invitation_user_uuid" --arg expiresAt "$invitation_expires_at" '
  any(.users[];
    .userID == $userID and
    .status == "pending" and
    .requiresAccountSetup == true and
    .invitationExpiresAt == $expiresAt and
    (.douyinID | test("^invite_[a-f0-9]{24}$")) and
    .permissions == ["gallery_full", "video_view"]
  )
' "$test_dir/invitation-list.json" >/dev/null
invitation_placeholder=$(jq -r --arg userID "$invitation_user_uuid" \
  '.users[] | select(.userID == $userID) | .douyinID' \
  "$test_dir/invitation-list.json")
invitation_internal_user_id=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_uuid --meta_value="$invitation_user_uuid" --field=ID)
[[ "$invitation_internal_user_id" =~ ^[0-9]+$ ]]
sudo -u www-data wp --path="$wordpress_root" user meta get \
  "$invitation_internal_user_id" _yishu_fan_invitation --format=json \
  > "$test_dir/invitation-meta.json"
jq -e '
  has("temporaryPassword") | not
' "$test_dir/invitation-meta.json" >/dev/null
jq -e --arg placeholder "$invitation_placeholder" '
  .preapproved == true and
  .placeholderDouyinID == $placeholder and
  (.generation | test("^[a-f0-9]{32}$")) and
  (.createdBy | type == "number") and
  (.createdAt | type == "string") and
  (.expiresAt | type == "string")
' "$test_dir/invitation-meta.json" >/dev/null
invitation_generation=$(jq -r '.generation' "$test_dir/invitation-meta.json")
invitation_expiry_timestamp=$(date --date="$invitation_expires_at" +%s)
invitation_wp_auth_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_userdata(${invitation_internal_user_id}); \$result = apply_filters('wp_authenticate_user', \$user, 'unused'); echo is_wp_error(\$result) ? \$result->get_error_code() : 'allowed';")
[[ "$invitation_wp_auth_state" == 'fan_wordpress_login_restricted' ]]
invitation_app_password_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_userdata(${invitation_internal_user_id}); echo wp_is_application_passwords_available_for_user(\$user) ? 'enabled' : 'disabled';")
[[ "$invitation_app_password_state" == 'disabled' ]]

sudo -u www-data wp --path="$wordpress_root" eval \
  "global \$wpdb; \$name = 'yishu_fan_' . substr(hash('sha256', home_url('/') . '|${invitation_internal_user_id}'), 0, 48); \$got = \$wpdb->get_var(\$wpdb->prepare('SELECT GET_LOCK(%s, 0)', \$name)); if ((string) \$got !== '1') { exit(2); } echo 'locked'; sleep(3); \$wpdb->get_var(\$wpdb->prepare('SELECT RELEASE_LOCK(%s)', \$name));" \
  > "$test_dir/invitation-lock-holder.log" 2>&1 &
invitation_lock_holder_pid=$!
for lock_wait in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'locked' "$test_dir/invitation-lock-holder.log" 2>/dev/null; then break; fi
  sleep 0.1
done
grep -q 'locked' "$test_dir/invitation-lock-holder.log"
invitation_lock_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-lock.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["video_view"]}' \
  "${api_root}/app-admin/fans/${invitation_user_uuid}")
[[ "$invitation_lock_status" == '409' ]]
jq -e '.code == "fan_setup_busy"' "$test_dir/invitation-lock.json" >/dev/null
wait "$invitation_lock_holder_pid"

invitation_fault_hash=$(printf '%s' "$invitation_fault_douyin_id" | sha256sum | awk '{print $1}')
set +e
sudo -u www-data timeout --signal=KILL 2s wp --path="$wordpress_root" eval \
  "global \$wpdb; \$wpdb->query('START TRANSACTION'); \$wpdb->query(\$wpdb->prepare(\"UPDATE {\$wpdb->usermeta} SET meta_value = %s WHERE user_id = %d AND meta_key = %s\", '${invitation_fault_douyin_id}', ${invitation_internal_user_id}, '_yishu_fan_douyin_id')); \$wpdb->query(\$wpdb->prepare(\"UPDATE {\$wpdb->usermeta} SET meta_value = 'active' WHERE user_id = %d AND meta_key = %s\", ${invitation_internal_user_id}, '_yishu_fan_status')); \$wpdb->query(\$wpdb->prepare(\"INSERT INTO {\$wpdb->options} (option_name, option_value, autoload) VALUES (%s, %s, 'no')\", 'yishu_fan_douyin_${invitation_fault_hash}', '${invitation_internal_user_id}')); echo 'staged'; fflush(STDOUT); sleep(30); \$wpdb->query('COMMIT');" \
  > "$test_dir/invitation-transaction-kill.log" 2>&1
invitation_fault_status=$?
set -e
[[ "$invitation_fault_status" != '0' ]]
grep -q 'staged' "$test_dir/invitation-transaction-kill.log"
invitation_rollback_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "global \$wpdb; \$direct_douyin = \$wpdb->get_var(\$wpdb->prepare(\"SELECT meta_value FROM {\$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s LIMIT 1\", ${invitation_internal_user_id}, '_yishu_fan_douyin_id')); \$direct_status = \$wpdb->get_var(\$wpdb->prepare(\"SELECT meta_value FROM {\$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s LIMIT 1\", ${invitation_internal_user_id}, '_yishu_fan_status')); \$reservation = (int) \$wpdb->get_var(\$wpdb->prepare(\"SELECT COUNT(*) FROM {\$wpdb->options} WHERE option_name = %s\", 'yishu_fan_douyin_${invitation_fault_hash}')); echo wp_json_encode(array('directDouyin' => \$direct_douyin, 'cachedDouyin' => get_user_meta(${invitation_internal_user_id}, '_yishu_fan_douyin_id', true), 'directStatus' => \$direct_status, 'cachedStatus' => get_user_meta(${invitation_internal_user_id}, '_yishu_fan_status', true), 'faultReservationCount' => \$reservation));")
printf '%s' "$invitation_rollback_state" | jq -e \
  --arg placeholder "$invitation_placeholder" '
    .directDouyin == $placeholder and
    .cachedDouyin == $placeholder and
    .directStatus == "pending" and
    .cachedStatus == "pending" and
    .faultReservationCount == 0
  ' >/dev/null

invitation_active_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-active.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"status":"active"}' \
  "${api_root}/app-admin/fans/${invitation_user_uuid}")
[[ "$invitation_active_status" == '409' ]]
jq -e '.code == "fan_account_setup_required"' \
  "$test_dir/invitation-active.json" >/dev/null

for attempt in 1 2 3 4 5; do
  invitation_wrong_status=$(curl "${curl_common[@]}" \
    --output "$test_dir/invitation-wrong.json" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "X-Yishu-Install-ID: ${invitation_install_id}" \
    --data "$(jq -nc \
      --arg identityCode "$invitation_identity_code" \
      --arg password 'incorrect-temporary-password' \
      --arg installID "$invitation_install_id" \
      '{identityCode:$identityCode,password:$password,installID:$installID}')" \
    "${api_root}/fan/login")
  [[ "$invitation_wrong_status" == '401' ]]
done
invitation_rate_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-rate.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$invitation_identity_code" \
    --arg password 'incorrect-temporary-password' \
    --arg installID "$invitation_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$invitation_rate_status" == '429' ]]
invitation_failure_hash=$(printf '%s' "$invitation_identity_code" | sha256sum | awk '{print $1}')
sudo -u www-data wp --path="$wordpress_root" transient delete \
  "yishu_fan_invite_login_failure_${invitation_failure_hash}" >/dev/null

invitation_login_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$invitation_identity_code" \
    --arg password "$invitation_temporary_password" \
    --arg installID "$invitation_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$invitation_login_status" == '200' ]]
jq -e --arg userID "$invitation_user_uuid" --arg expiresAt "$invitation_expires_at" '
  (.token | test("^[A-Za-z0-9_-]{43,128}$")) and
  .profile.userID == $userID and
  .profile.status == "pending" and
  .profile.requiresAccountSetup == true and
  .profile.invitationExpiresAt == $expiresAt
' "$test_dir/invitation-login.json" >/dev/null
invitation_token=$(jq -r '.token' "$test_dir/invitation-login.json")
invitation_session_expires_at=$(jq -r '.profile.sessionExpiresAt' "$test_dir/invitation-login.json")
invitation_session_remaining=$(( $(date --date="$invitation_session_expires_at" +%s) - $(date +%s) ))
(( invitation_session_remaining >= 480 && invitation_session_remaining <= 660 ))

invitation_content_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${invitation_token}" \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  "${api_root}/app-content")
[[ "$invitation_content_status" == '403' ]]
jq -e '.code == "fan_account_setup_required"' \
  "$test_dir/invitation-content.json" >/dev/null

invitation_same_password_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-same-password.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${invitation_token}" \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg displayName '邀请验收用户' \
    --arg douyinID "$invitation_douyin_id" \
    --arg currentPassword "$invitation_temporary_password" \
    --arg newPassword "$invitation_temporary_password" \
    --arg installID "$invitation_install_id" \
    --arg consentVersion '2026-09-04-approval-v4' \
    '{displayName:$displayName,douyinID:$douyinID,currentPassword:$currentPassword,newPassword:$newPassword,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/complete-invitation")
[[ "$invitation_same_password_status" == '400' ]]

# Emulate an interrupted legacy completion after the real Douyin meta and
# reservation were written but before the immutable invitation was consumed.
sudo -u www-data wp --path="$wordpress_root" user meta update \
  "$invitation_internal_user_id" _yishu_fan_douyin_id "$invitation_douyin_id" >/dev/null
invitation_recovery_real_hash=$(printf '%s' "$invitation_douyin_id" | sha256sum | awk '{print $1}')
sudo -u www-data wp --path="$wordpress_root" option add \
  "yishu_fan_douyin_${invitation_recovery_real_hash}" "$invitation_internal_user_id" \
  --autoload=no >/dev/null

onboarding_token="$invitation_token"
invitation_complete_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-complete.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${onboarding_token}" \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg displayName '邀请验收用户' \
    --arg douyinID "$invitation_douyin_id" \
    --arg currentPassword "$invitation_temporary_password" \
    --arg newPassword "$invitation_new_password" \
    --arg installID "$invitation_install_id" \
    --arg consentVersion '2026-09-04-approval-v4' \
    '{displayName:$displayName,douyinID:$douyinID,currentPassword:$currentPassword,newPassword:$newPassword,installID:$installID,consentVersion:$consentVersion}')" \
  "${api_root}/fan/complete-invitation")
[[ "$invitation_complete_status" == '200' ]]
jq -e --arg userID "$invitation_user_uuid" --arg douyinID "$invitation_douyin_id" '
  (.token | test("^[A-Za-z0-9_-]{43,128}$")) and
  .profile.userID == $userID and
  .profile.douyinID == $douyinID and
  .profile.status == "active" and
  .profile.requiresAccountSetup == false and
  .profile.invitationExpiresAt == null
' "$test_dir/invitation-complete.json" >/dev/null
invitation_token=$(jq -r '.token' "$test_dir/invitation-complete.json")
stale_invitation_cleanup_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "do_action('yishu_cleanup_fan_invitation', ${invitation_internal_user_id}, '${invitation_generation}', '${invitation_placeholder}', ${invitation_expiry_timestamp}); echo get_userdata(${invitation_internal_user_id}) ? 'exists' : 'deleted';")
[[ "$stale_invitation_cleanup_state" == 'exists' ]]
invitation_completed_wp_auth_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_userdata(${invitation_internal_user_id}); \$result = apply_filters('wp_authenticate_user', \$user, 'unused'); echo is_wp_error(\$result) ? \$result->get_error_code() : 'allowed';")
[[ "$invitation_completed_wp_auth_state" == 'fan_wordpress_login_restricted' ]]
invitation_completed_app_password_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user = get_userdata(${invitation_internal_user_id}); echo wp_is_application_passwords_available_for_user(\$user) ? 'enabled' : 'disabled';")
[[ "$invitation_completed_app_password_state" == 'disabled' ]]

invitation_old_session_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-old-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${onboarding_token}" \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  "${api_root}/fan/session")
[[ "$invitation_old_session_status" == '401' ]]
invitation_old_login_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/invitation-old-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$invitation_identity_code" \
    --arg password "$invitation_temporary_password" \
    --arg installID "$invitation_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$invitation_old_login_status" == '401' ]]
invitation_placeholder_hash=$(printf '%s' "$invitation_placeholder" | sha256sum | awk '{print $1}')
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_douyin_${invitation_placeholder_hash}" >/dev/null 2>&1; then
  echo 'fan-api-smoke: invitation placeholder reservation was not removed' >&2
  exit 1
fi
invitation_real_hash=$(printf '%s' "$invitation_douyin_id" | sha256sum | awk '{print $1}')
invitation_real_owner=$(sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_douyin_${invitation_real_hash}")
[[ "$invitation_real_owner" == "$invitation_internal_user_id" ]]
echo 'fan-api-smoke: administrator invitation and forced setup passed'

deletion_recovery_create_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-recovery-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  "${api_root}/app-admin/fans/${invitation_user_uuid}/password-recovery")
[[ "$deletion_recovery_create_status" == '201' ]]
deletion_recovery_password=$(jq -r '.passwordRecovery.temporaryPassword' \
  "$test_dir/deletion-recovery-create.json")
deletion_recovery_login_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-recovery-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$invitation_identity_code" \
    --arg password "$deletion_recovery_password" \
    --arg installID "$invitation_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$deletion_recovery_login_status" == '200' ]]
deletion_recovery_token=$(jq -r '.token' "$test_dir/deletion-recovery-login.json")
deletion_recovery_delete_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/deletion-recovery-delete.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${deletion_recovery_token}" \
  --header "X-Yishu-Install-ID: ${invitation_install_id}" \
  --data "$(jq -nc \
    --arg currentPassword "$deletion_recovery_password" \
    --arg installID "$invitation_install_id" \
    '{confirmation:"DELETE_ACCOUNT",currentPassword:$currentPassword,installID:$installID}')" \
  "${api_root}/fan/delete")
[[ "$deletion_recovery_delete_status" == '200' ]]
deletion_recovery_remaining=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_uuid --meta_value="$invitation_user_uuid" --field=ID 2>/dev/null || true)
[[ -z "$deletion_recovery_remaining" ]]
invitation_token=''
echo 'fan-api-smoke: password-recovery account deletion with temporary password passed'

cleanup_invitation_create_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/cleanup-invitation-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"count":1}' \
  "${api_root}/app-admin/fans/invitations")
[[ "$cleanup_invitation_create_status" == '201' ]]
cleanup_invitation_user_uuid=$(jq -r '.invitations[0].userID' \
  "$test_dir/cleanup-invitation-create.json")
cleanup_invitation_list_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/cleanup-invitation-list.json" \
  --write-out '%{http_code}' \
  --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans")
[[ "$cleanup_invitation_list_status" == '200' ]]
cleanup_invitation_placeholder=$(jq -r --arg userID "$cleanup_invitation_user_uuid" \
  '.users[] | select(.userID == $userID) | .douyinID' \
  "$test_dir/cleanup-invitation-list.json")
cleanup_invitation_internal_user_id=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_uuid --meta_value="$cleanup_invitation_user_uuid" --field=ID)
[[ "$cleanup_invitation_internal_user_id" =~ ^[0-9]+$ ]]
sudo -u www-data wp --path="$wordpress_root" user meta get \
  "$cleanup_invitation_internal_user_id" _yishu_fan_invitation --format=json \
  > "$test_dir/cleanup-invitation-meta.json"
cleanup_invitation_generation=$(jq -r '.generation' "$test_dir/cleanup-invitation-meta.json")
cleanup_invitation_original_expiry=$(date --date="$(jq -r '.expiresAt' "$test_dir/cleanup-invitation-meta.json")" +%s)
cleanup_invitation_cron=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$args = array(${cleanup_invitation_internal_user_id}, '${cleanup_invitation_generation}', '${cleanup_invitation_placeholder}', ${cleanup_invitation_original_expiry}); echo (int) wp_next_scheduled('yishu_cleanup_fan_invitation', \$args);")
(( cleanup_invitation_cron >= cleanup_invitation_original_expiry ))
cleanup_invitation_state=$(sudo -u www-data wp --path="$wordpress_root" eval \
  "\$user_id = ${cleanup_invitation_internal_user_id}; \$meta = get_user_meta(\$user_id, '_yishu_fan_invitation', true); \$expires = time() - 60; \$meta['createdAt'] = gmdate('c', \$expires - 86400); \$meta['expiresAt'] = gmdate('c', \$expires); if (update_user_meta(\$user_id, '_yishu_fan_invitation', \$meta) === false) { exit(2); } do_action('yishu_cleanup_fan_invitation', \$user_id, '${cleanup_invitation_generation}', '${cleanup_invitation_placeholder}', \$expires); echo get_userdata(\$user_id) ? 'exists' : 'deleted';")
[[ "$cleanup_invitation_state" == 'deleted' ]]
cleanup_invitation_placeholder_hash=$(printf '%s' "$cleanup_invitation_placeholder" | sha256sum | awk '{print $1}')
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_douyin_${cleanup_invitation_placeholder_hash}" >/dev/null 2>&1; then
  echo 'fan-api-smoke: expired invitation reservation was not removed' >&2
  exit 1
fi
echo 'fan-api-smoke: scheduled invitation expiry cleanup passed'

reject_status=$(curl "${curl_common[@]}" --output "$test_dir/rejected-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","video_view"],"status":"rejected"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$reject_status" == '200' ]]
jq -e '.user.status == "rejected" and (.user.reviewedAt | type == "string")' \
  "$test_dir/rejected-update.json" >/dev/null

rejected_session_status=$(curl "${curl_common[@]}" --output "$test_dir/rejected-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$rejected_session_status" == '401' ]]
token=''
token_hash=''

rejected_login_status=$(curl "${curl_common[@]}" --output "$test_dir/rejected-login.json" \
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
[[ "$rejected_login_status" == '200' ]]
jq -e '.profile.status == "rejected" and .profile.requiresAccountSetup == false and .profile.invitationExpiresAt == null' \
  "$test_dir/rejected-login.json" >/dev/null
token=$(jq -r '.token' "$test_dir/rejected-login.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
rejected_content_status=$(curl "${curl_common[@]}" --output "$test_dir/rejected-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
[[ "$rejected_content_status" == '403' ]]
jq -e '.code == "fan_approval_rejected"' "$test_dir/rejected-content.json" >/dev/null

admin_update_status=$(curl "${curl_common[@]}" --output "$test_dir/admin-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","early_access"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$admin_update_status" == '200' ]]
jq -e '.user.permissions == ["gallery_full", "early_access"] and .user.status == "active"' \
  "$test_dir/admin-update.json" >/dev/null

approved_content_status=$(curl "${curl_common[@]}" --output "$test_dir/approved-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
[[ "$approved_content_status" == '200' ]]
jq -e '.schemaVersion == 1 and (.portfolios | length > 0) and
  .showreel == null and (.dramas | length == 0)' \
  "$test_dir/approved-content.json" >/dev/null

permission_update_status=$(curl "${curl_common[@]}" --output "$test_dir/permission-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["video_view"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$permission_update_status" == '200' ]]

permission_content_status=$(curl "${curl_common[@]}" --output "$test_dir/permission-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
[[ "$permission_content_status" == '200' ]]
jq -e '(.showreel | type == "object") and (.dramas | length > 0) and
  all(.portfolios[]; (.images | length) <= 3)' \
  "$test_dir/permission-content.json" >/dev/null

restore_permissions_status=$(curl "${curl_common[@]}" --output "$test_dir/admin-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","early_access"],"status":"active"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$restore_permissions_status" == '200' ]]
echo 'fan-api-smoke: existing token obeys immediate gallery and video permission changes'

session_status=$(curl "${curl_common[@]}" --output "$test_dir/session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$session_status" == '200' ]]
jq -e '.profile.permissions == ["gallery_full", "early_access"] and .profile.status == "active"' \
  "$test_dir/session.json" >/dev/null
echo 'fan-api-smoke: rejection and administrator approval passed'

logout_status=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' \
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

login_status=$(curl "${curl_common[@]}" --output "$test_dir/login.json" \
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

second_login_status=$(curl "${curl_common[@]}" --output "$test_dir/second-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${second_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$password" \
    --arg installID "$second_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$second_login_status" == '200' ]]
second_token=$(jq -r '.token' "$test_dir/second-login.json")
second_installation_code=$(jq -r '.profile.installationCode' "$test_dir/second-login.json")
[[ "$second_installation_code" =~ ^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$ ]]
[[ "$second_installation_code" != "$installation_code" ]]

sessions_status=$(curl "${curl_common[@]}" --output "$test_dir/sessions.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/sessions")
[[ "$sessions_status" == '200' ]]
jq -e --arg currentCode "$installation_code" --arg otherCode "$second_installation_code" '
  (.sessions | length == 2) and
  ([.sessions[].sessionID] | all(test("^[a-f0-9]{32}$"))) and
  ([.sessions[] | select(.isCurrent == true)] | length == 1) and
  any(.sessions[]; .isCurrent == true and .installationCode == $currentCode) and
  any(.sessions[]; .isCurrent == false and .installationCode == $otherCode) and
  (tostring | contains("token") | not) and
  (tostring | contains("tokenHash") | not)
' "$test_dir/sessions.json" >/dev/null
other_session_id=$(jq -r --arg otherCode "$second_installation_code" \
  '.sessions[] | select(.installationCode == $otherCode) | .sessionID' \
  "$test_dir/sessions.json")
[[ "$other_session_id" =~ ^[a-f0-9]{32}$ ]]

session_revoke_status=$(curl "${curl_common[@]}" --output "$test_dir/session-revoke.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc --arg sessionID "$other_session_id" '{sessionID:$sessionID}')" \
  "${api_root}/fan/sessions/revoke")
[[ "$session_revoke_status" == '200' ]]
jq -e --arg sessionID "$other_session_id" '
  .ok == true and (.sessions | length == 1) and
  all(.sessions[]; .sessionID != $sessionID and .isCurrent == true)
' "$test_dir/session-revoke.json" >/dev/null
second_revoked_status=$(curl "${curl_common[@]}" --output "$test_dir/second-revoked.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${second_token}" \
  --header "X-Yishu-Install-ID: ${second_install_id}" \
  "${api_root}/fan/session")
[[ "$second_revoked_status" == '401' ]]
second_token=''
echo 'fan-api-smoke: per-account device list and other-session revocation passed'

changed_password="Changed-${suffix}-2026!"
old_token="$token"
password_change_status=$(curl "${curl_common[@]}" --output "$test_dir/password-change.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg currentPassword "$password" \
    --arg newPassword "$changed_password" \
    --arg installID "$install_id" \
    '{currentPassword:$currentPassword,newPassword:$newPassword,installID:$installID}')" \
  "${api_root}/fan/change-password")
[[ "$password_change_status" == '200' ]]
jq -e --arg oldToken "$old_token" '
  (.token | test("^[A-Za-z0-9_-]{43,128}$")) and .token != $oldToken and
  .profile.requiresPasswordChange == false and .profile.passwordRecoveryExpiresAt == null
' "$test_dir/password-change.json" >/dev/null
token=$(jq -r '.token' "$test_dir/password-change.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
password_old_session_status=$(curl "${curl_common[@]}" --output "$test_dir/password-old-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${old_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$password_old_session_status" == '401' ]]
password_old_login_status=$(curl "${curl_common[@]}" --output "$test_dir/password-old-login.json" \
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
[[ "$password_old_login_status" == '401' ]]
password="$changed_password"
echo 'fan-api-smoke: password change rotated token and revoked old credentials'

recovery_anonymous_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-anonymous.json" \
  --write-out '%{http_code}' \
  --request POST \
  "${api_root}/app-admin/fans/${user_uuid}/password-recovery")
[[ "$recovery_anonymous_status" == '401' ]]
recovery_fan_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-fan.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-admin/fans/${user_uuid}/password-recovery")
[[ "$recovery_fan_status" == '401' ]]

pre_recovery_token="$token"
recovery_create_status=$(curl "${curl_common[@]}" \
  --dump-header "$test_dir/recovery-create.headers" \
  --output "$test_dir/recovery-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  "${api_root}/app-admin/fans/${user_uuid}/password-recovery")
[[ "$recovery_create_status" == '201' ]]
grep -Eiq '^cache-control:.*no-store' "$test_dir/recovery-create.headers"
grep -Eiq '^cache-control:.*max-age=0' "$test_dir/recovery-create.headers"
grep -Eiq '^pragma:[[:space:]]*no-cache' "$test_dir/recovery-create.headers"
jq -e --arg userID "$user_uuid" --arg identityCode "$identity_code" '
  .passwordRecovery.userID == $userID and
  .passwordRecovery.identityCode == $identityCode and
  (.passwordRecovery.temporaryPassword | test("^Tmp-[A-Za-z0-9_-]{24}-9!$")) and
  .passwordRecovery.requiresPasswordChange == true
' "$test_dir/recovery-create.json" >/dev/null
recovery_temporary_password=$(jq -r '.passwordRecovery.temporaryPassword' \
  "$test_dir/recovery-create.json")
recovery_expires_at=$(jq -r '.passwordRecovery.expiresAt' "$test_dir/recovery-create.json")
recovery_remaining=$(( $(date --date="$recovery_expires_at" +%s) - $(date +%s) ))
(( recovery_remaining >= 780 && recovery_remaining <= 960 ))
fan_internal_user_id=$(sudo -u www-data wp --path="$wordpress_root" user list \
  --meta_key=_yishu_fan_uuid --meta_value="$user_uuid" --field=ID)
[[ "$fan_internal_user_id" =~ ^[0-9]+$ ]]
sudo -u www-data wp --path="$wordpress_root" user meta get \
  "$fan_internal_user_id" _yishu_fan_password_recovery --format=json \
  > "$test_dir/recovery-meta.json"
jq -e --arg temporaryPassword "$recovery_temporary_password" '
  (.createdAt | type == "string") and (.expiresAt | type == "string") and
  (.createdBy | type == "number") and (.generation | test("^[a-f0-9]{32}$")) and
  (tostring | contains($temporaryPassword) | not) and
  (has("temporaryPassword") | not)
' "$test_dir/recovery-meta.json" >/dev/null
recovery_old_session_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-old-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${pre_recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$recovery_old_session_status" == '401' ]]

recovery_login_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$recovery_temporary_password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$recovery_login_status" == '200' ]]
jq -e --arg expiresAt "$recovery_expires_at" '
  .profile.requiresAccountSetup == false and
  .profile.requiresPasswordChange == true and
  .profile.passwordRecoveryExpiresAt == $expiresAt
' "$test_dir/recovery-login.json" >/dev/null
recovery_token=$(jq -r '.token' "$test_dir/recovery-login.json")
sudo -u www-data wp --path="$wordpress_root" user meta get \
  "$fan_internal_user_id" _yishu_fan_password_recovery --format=json \
  > "$test_dir/recovery-claimed-meta.json"
jq -e --arg temporaryPassword "$recovery_temporary_password" '
  (.claimedAt | type == "string") and
  (.claimedInstallHash | test("^[a-f0-9]{64}$")) and
  (.claimedSessionID | test("^[a-f0-9]{32}$")) and
  (tostring | contains($temporaryPassword) | not) and
  (has("temporaryPassword") | not)
' "$test_dir/recovery-claimed-meta.json" >/dev/null
recovery_replay_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-replay.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${second_install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$recovery_temporary_password" \
    --arg installID "$second_install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$recovery_replay_status" == '401' ]]
jq -e '.code == "fan_login_invalid"' "$test_dir/recovery-replay.json" >/dev/null
first_recovery_token="$recovery_token"
recovery_same_install_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-same-install.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$recovery_temporary_password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$recovery_same_install_status" == '200' ]]
recovery_token=$(jq -r '.token' "$test_dir/recovery-same-install.json")
[[ "$recovery_token" != "$first_recovery_token" ]]
first_recovery_session_status=$(curl "${curl_common[@]}" \
  --output "$test_dir/recovery-first-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${first_recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$first_recovery_session_status" == '401' ]]
recovery_content_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
[[ "$recovery_content_status" == '403' ]]
jq -e '.code == "fan_account_setup_required"' "$test_dir/recovery-content.json" >/dev/null
recovery_sessions_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-sessions.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/sessions")
[[ "$recovery_sessions_status" == '403' ]]

recovered_password="Recovered-${suffix}-2026!"
recovery_complete_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-complete.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg currentPassword "$recovery_temporary_password" \
    --arg newPassword "$recovered_password" \
    --arg installID "$install_id" \
    '{currentPassword:$currentPassword,newPassword:$newPassword,installID:$installID}')" \
  "${api_root}/fan/complete-password-recovery")
[[ "$recovery_complete_status" == '200' ]]
jq -e --arg oldToken "$recovery_token" '
  .token != $oldToken and .profile.requiresPasswordChange == false and
  .profile.passwordRecoveryExpiresAt == null
' "$test_dir/recovery-complete.json" >/dev/null
token=$(jq -r '.token' "$test_dir/recovery-complete.json")
token_hash=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
recovery_stale_session_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-stale-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${recovery_token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$recovery_stale_session_status" == '401' ]]
recovery_old_login_status=$(curl "${curl_common[@]}" --output "$test_dir/recovery-old-login.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg identityCode "$identity_code" \
    --arg password "$recovery_temporary_password" \
    --arg installID "$install_id" \
    '{identityCode:$identityCode,password:$password,installID:$installID}')" \
  "${api_root}/fan/login")
[[ "$recovery_old_login_status" == '401' ]]
if sudo -u www-data wp --path="$wordpress_root" user meta get \
  "$fan_internal_user_id" _yishu_fan_password_recovery >/dev/null 2>&1; then
  echo 'fan-api-smoke: password recovery marker remained after completion' >&2
  exit 1
fi
password="$recovered_password"
echo 'fan-api-smoke: administrator one-time recovery and forced password rotation passed'

suspend_status=$(curl "${curl_common[@]}" --output "$test_dir/suspended-update.json" \
  --write-out '%{http_code}' \
  --request POST \
  --netrc-file "$test_dir/admin.netrc" \
  --header 'Content-Type: application/json' \
  --data '{"permissions":["gallery_full","early_access"],"status":"suspended"}' \
  "${api_root}/app-admin/fans/${user_uuid}")
[[ "$suspend_status" == '200' ]]
jq -e '.user.status == "suspended"' "$test_dir/suspended-update.json" >/dev/null

revoked_session_status=$(curl "${curl_common[@]}" --output "$test_dir/revoked-session.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/fan/session")
[[ "$revoked_session_status" == '401' ]]
token=''
token_hash=''

suspended_login_status=$(curl "${curl_common[@]}" --output "$test_dir/suspended-login.json" \
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
stopped_content_status=$(curl "${curl_common[@]}" --output "$test_dir/suspended-content.json" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  "${api_root}/app-content")
[[ "$stopped_content_status" == '403' ]]
jq -e '.code == "fan_account_suspended"' "$test_dir/suspended-content.json" >/dev/null
echo 'fan-api-smoke: suspended account retained self-service deletion access'

wrong_delete_status=$(curl "${curl_common[@]}" --output "$test_dir/wrong-delete.json" --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg currentPassword 'definitely-wrong-password' \
    --arg installID "$install_id" \
    '{confirmation:"DELETE_ACCOUNT",currentPassword:$currentPassword,installID:$installID}')" \
  "${api_root}/fan/delete")
[[ "$wrong_delete_status" == '401' ]]
jq -e '.code == "fan_login_invalid"' "$test_dir/wrong-delete.json" >/dev/null

delete_status=$(curl "${curl_common[@]}" --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${token}" \
  --header "X-Yishu-Install-ID: ${install_id}" \
  --data "$(jq -nc \
    --arg currentPassword "$password" \
    --arg installID "$install_id" \
    '{confirmation:"DELETE_ACCOUNT",currentPassword:$currentPassword,installID:$installID}')" \
  "${api_root}/fan/delete")
[[ "$delete_status" == '200' ]]
if sudo -u www-data wp --path="$wordpress_root" option get \
  "yishu_fan_session_${token_hash}" --format=json >/dev/null 2>&1; then
  exit 1
fi
token=''
token_hash=''

deleted_login_status=$(curl "${curl_common[@]}" --output "$test_dir/deleted-login.json" \
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
