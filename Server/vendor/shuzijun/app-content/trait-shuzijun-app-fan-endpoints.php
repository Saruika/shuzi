<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Fan_Endpoints {
    public static function permission_catalog() {
        return array(
            array(
                'code' => 'gallery_full',
                'title' => '完整相册',
                'description' => '允许账号查看完整照片作品。',
            ),
            array(
                'code' => 'video_view',
                'title' => '影视内容',
                'description' => '允许账号查看 Showreel 与影视内容。',
            ),
            array(
                'code' => 'early_access',
                'title' => '提前观看',
                'description' => '可用于新作品、新功能或活动的定向内测。',
            ),
        );
    }

    public static function register_fan(WP_REST_Request $request) {
        $install_id = self::request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }

        $network_limit = self::rate_limit(
            'fan_register_net',
            self::request_network_fingerprint(),
            10,
            HOUR_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $install_limit = self::rate_limit('fan_register_install', $install_id, 3, DAY_IN_SECONDS);
        if (is_wp_error($install_limit)) { return $install_limit; }

        $display_name = sanitize_text_field((string) $request->get_param('displayName'));
        $douyin_id = self::normalize_required_douyin_id($request->get_param('douyinID'));
        if (is_wp_error($douyin_id)) { return $douyin_id; }
        $password = (string) $request->get_param('password');
        $consent_version = $request->get_param('consentVersion');
        if (!self::fan_new_consent_version_is_accepted($consent_version)) {
            return new WP_Error('fan_consent_required', '请先阅读并确认账号资料的使用说明。', array('status' => 400));
        }
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        $password_error = self::validate_fan_password($password);
        if (is_wp_error($password_error)) { return $password_error; }
        if ($douyin_id !== '') {
            $douyin_users = get_users(array(
                'number' => 1,
                'fields' => 'ids',
                'meta_key' => self::FAN_META_DOUYIN_ID,
                'meta_value' => $douyin_id,
            ));
            if ($douyin_users) {
                return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
            }
        }

        $identity_code = self::generate_unique_identity_code();
        if (is_wp_error($identity_code)) { return $identity_code; }
        $douyin_reservation = $douyin_id !== ''
            ? self::douyin_reservation_name($douyin_id)
            : '';
        if ($douyin_reservation !== ''
            && !add_option($douyin_reservation, 'pending', '', false)) {
            return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
        }
        try {
            $login = 'fan_' . bin2hex(random_bytes(16));
        } catch (Exception $error) {
            if ($douyin_reservation !== '') { delete_option($douyin_reservation); }
            return new WP_Error('fan_registration_unavailable', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }
        $user_id = wp_insert_user(array(
            'user_login' => $login,
            'user_pass' => $password,
            'display_name' => $display_name,
            'role' => 'subscriber',
        ));
        if (is_wp_error($user_id)) {
            if ($douyin_reservation !== '') { delete_option($douyin_reservation); }
            return new WP_Error('fan_registration_failed', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }

        $uuid = wp_generate_uuid4();
        $saved = update_user_meta($user_id, self::FAN_META_UUID, $uuid)
            && update_user_meta($user_id, self::FAN_META_CODE, $identity_code)
            && update_user_meta($user_id, self::FAN_META_DOUYIN_ID, $douyin_id)
            && update_user_meta($user_id, self::FAN_META_PERMISSIONS, array('gallery_full', 'video_view'))
            && update_user_meta($user_id, self::FAN_META_STATUS, 'pending')
            && update_user_meta($user_id, self::FAN_META_CREDENTIAL_EPOCH, 1)
            && update_user_meta($user_id, self::FAN_META_ACCOUNT_SOURCE, 'password')
            && update_user_meta($user_id, self::FAN_META_CONSENT, array(
                'version' => $consent_version,
                'acceptedAt' => gmdate('c'),
            ));
        if (!$saved) {
            self::remove_fan_user((int) $user_id, $douyin_reservation);
            return new WP_Error('fan_registration_failed', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }
        if ($douyin_reservation !== '') {
            update_option($douyin_reservation, (int) $user_id, false);
        }

        $session = self::issue_fan_session((int) $user_id, $install_id, 'normal');
        if (is_wp_error($session)) {
            self::remove_fan_user((int) $user_id, $douyin_reservation);
            return $session;
        }
        return self::fan_auth_response((int) $user_id, $session, 201);
    }

    public static function login_fan(WP_REST_Request $request) {
        $install_id = self::request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $identity_code = self::normalize_identity_code($request->get_param('identityCode'));
        $password = (string) $request->get_param('password');
        if (!$identity_code || !$password || strlen($password) > 512) {
            return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
        }

        $network_limit = self::rate_limit(
            'fan_login_net',
            self::request_network_fingerprint(),
            60,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $users = get_users(array(
            'number' => 2,
            'fields' => 'all',
            'meta_key' => self::FAN_META_CODE,
            'meta_value' => $identity_code,
        ));
        $user = count($users) === 1 ? $users[0] : null;
        $raw_invitation = $user instanceof WP_User
            ? self::fan_meta_from_database((int) $user->ID, self::FAN_META_INVITATION, null)
            : null;
        $has_invitation = !empty($raw_invitation);
        if ($has_invitation && $user instanceof WP_User) {
            return self::login_invited_fan($user, $identity_code, $password, $install_id);
        }
        $raw_recovery = $user instanceof WP_User
            ? self::fan_meta_from_database((int) $user->ID, self::FAN_META_PASSWORD_RECOVERY, null)
            : null;
        if (!empty($raw_recovery) && $user instanceof WP_User) {
            return self::login_recovering_fan($user, $identity_code, $password, $install_id);
        }

        $failure_identity = self::request_network_fingerprint() . '|' . $identity_code;
        $failure_bucket = 'fan_login_failure';
        $failure_check = self::check_failure_limit(
            $failure_bucket,
            $failure_identity,
            10
        );
        if (is_wp_error($failure_check)) { return $failure_check; }
        if (!$user instanceof WP_User) {
            $failure = self::record_failure(
                $failure_bucket,
                $failure_identity,
                15 * MINUTE_IN_SECONDS
            );
            if (is_wp_error($failure)) { return $failure; }
            return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
        }
        $user_id = (int) $user->ID;
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            // Recheck setup markers after acquiring the account lock. Otherwise
            // a password reset racing a normal login could issue a fresh token
            // after the old password had already been accepted.
            if (!empty(self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null))
                || !empty(self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null))
                || (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_ACCOUNT_SOURCE,
                    'password'
                ) === 'apple'
                || !self::fan_password_matches_database($user_id, $password)) {
                $failure = self::record_failure(
                    $failure_bucket,
                    $failure_identity,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
            }
            self::clear_failure_limit($failure_bucket, $failure_identity);
            $session = self::issue_fan_session($user_id, $install_id, 'normal');
            if (is_wp_error($session)) { return $session; }
            return self::fan_auth_response($user_id, $session);
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function can_create_fan_apple_challenge(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $purpose = sanitize_key((string) $request->get_param('purpose'));
        if ($purpose === 'sign_in') { return true; }
        if ($purpose !== 'delete_account') {
            return new WP_Error(
                'fan_apple_challenge_invalid',
                'Apple 登录请求无效。',
                array('status' => 400)
            );
        }
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $scope = (string) ($context['scope'] ?? '');
        $user_id = (int) ($context['userID'] ?? 0);
        if (!in_array($scope, array('normal', 'apple_onboarding'), true)
            || self::fan_account_source($user_id) !== 'apple'
            || !self::valid_apple_sub_hash(self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_SUB_HASH,
                ''
            ))) {
            return new WP_Error(
                'fan_apple_reauthentication_required',
                '请重新使用 Apple ID 验证后删除账号。',
                array('status' => 403)
            );
        }
        self::$fan_session_context = $context;
        return true;
    }

    public static function create_fan_apple_challenge(WP_REST_Request $request) {
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $purpose = sanitize_key((string) $request->get_param('purpose'));
        if (!in_array($purpose, array('sign_in', 'delete_account'), true)) {
            return new WP_Error(
                'fan_apple_challenge_invalid',
                'Apple 登录请求无效。',
                array('status' => 400)
            );
        }
        $network_limit = self::rate_limit(
            'fan_apple_challenge_net',
            self::request_network_fingerprint(),
            20,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $install_limit = self::rate_limit(
            'fan_apple_challenge_install',
            $install_id,
            10,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($install_limit)) { return $install_limit; }

        $context = self::$fan_session_context;
        if ($purpose === 'delete_account' && (!is_array($context)
            || empty($context['userID']) || empty($context['sessionID']))) {
            return new WP_Error(
                'fan_apple_reauthentication_required',
                '请先登录当前 Apple 账号。',
                array('status' => 403)
            );
        }
        try {
            $challenge_id = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
            $nonce = bin2hex(random_bytes(32));
            $state = rtrim(strtr(base64_encode(random_bytes(24)), '+/', '-_'), '=');
            $generation = bin2hex(random_bytes(16));
        } catch (Exception $error) {
            return new WP_Error(
                'fan_apple_challenge_unavailable',
                '暂时无法开始 Apple 登录，请稍后重试。',
                array('status' => 503)
            );
        }
        $created_at = time();
        $expires = $created_at + self::FAN_APPLE_CHALLENGE_TTL;
        $record = array(
            'version' => 1,
            'purpose' => $purpose,
            'nonceHash' => hash('sha256', $nonce),
            'stateHash' => hash('sha256', $state),
            'installHash' => hash('sha256', $install_id),
            'networkHash' => self::request_network_fingerprint(),
            'createdAt' => $created_at,
            'expires' => $expires,
            'generation' => $generation,
            'userID' => $purpose === 'delete_account' ? (int) $context['userID'] : 0,
            'sessionID' => $purpose === 'delete_account' ? (string) $context['sessionID'] : '',
            'credentialEpoch' => $purpose === 'delete_account'
                ? (int) ($context['credentialEpoch'] ?? 0)
                : 0,
        );
        $option_name = self::apple_challenge_option_name($challenge_id);
        if (!add_option($option_name, $record, '', false)) {
            return new WP_Error(
                'fan_apple_challenge_unavailable',
                '暂时无法开始 Apple 登录，请稍后重试。',
                array('status' => 503)
            );
        }
        $scheduled = wp_schedule_single_event(
            $expires + 60,
            'yishu_cleanup_fan_apple_challenge',
            array($option_name, $generation),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            delete_option($option_name);
            return new WP_Error(
                'fan_apple_challenge_unavailable',
                '暂时无法开始 Apple 登录，请稍后重试。',
                array('status' => 503)
            );
        }
        $response = new WP_REST_Response(array(
            'challengeID' => $challenge_id,
            'nonce' => $nonce,
            'state' => $state,
            'purpose' => $purpose,
            'expiresAt' => gmdate('c', $expires),
        ), 201);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        return $response;
    }

    public static function authenticate_fan_with_apple(WP_REST_Request $request) {
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $input = self::apple_credential_request($request, false);
        if (is_wp_error($input)) { return $input; }
        $network_limit = self::rate_limit(
            'fan_apple_auth_net',
            self::request_network_fingerprint(),
            30,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $install_limit = self::rate_limit(
            'fan_apple_auth_install',
            $install_id,
            10,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($install_limit)) { return $install_limit; }

        $challenge = self::consume_fan_apple_challenge(
            $input['challengeID'],
            $input['state'],
            $install_id,
            'sign_in'
        );
        if (is_wp_error($challenge)) { return $challenge; }
        $credential = self::verify_and_exchange_apple_credential(
            $input['identityToken'],
            $input['authorizationCode'],
            (string) $challenge['nonceHash']
        );
        if (is_wp_error($credential)) { return $credential; }
        return self::login_or_create_apple_fan(
            $credential,
            $install_id
        );
    }

    private static function login_invited_fan(WP_User $user, $identity_code, $password, $install_id) {
        $user_id = (int) $user->ID;
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            // Serialize the account-global counter so concurrent requests
            // cannot race past the five-failure limit.
            $failure_check = self::check_failure_limit(
                'fan_invite_login_failure',
                $identity_code,
                5
            );
            if (is_wp_error($failure_check)) { return $failure_check; }
            $fresh_invitation = self::fan_meta_from_database(
                $user_id,
                self::FAN_META_INVITATION,
                null
            );
            if (empty($fresh_invitation)
                || !self::fan_password_matches_database($user_id, $password)) {
                $failure = self::record_failure(
                    'fan_invite_login_failure',
                    $identity_code,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
            }
            self::clear_failure_limit('fan_invite_login_failure', $identity_code);

            $invitation = self::normalize_fan_invitation($fresh_invitation);
            if (is_wp_error($invitation)) { return $invitation; }
            if ((int) $invitation['expiresTimestamp'] <= time()) {
                $reservation = self::douyin_reservation_name(
                    (string) get_user_meta($user_id, self::FAN_META_DOUYIN_ID, true)
                );
                if (!self::remove_fan_user($user_id, $reservation)) {
                    return new WP_Error(
                        'fan_invitation_cleanup_failed',
                        '临时账号已过期，但暂时无法完成清理。',
                        array('status' => 503)
                    );
                }
                return new WP_Error(
                    'fan_invitation_expired',
                    '临时账号已过期，请联系管理员重新创建。',
                    array('status' => 410)
                );
            }
            $session = self::issue_fan_session(
                $user_id,
                $install_id,
                'onboarding',
                self::FAN_ONBOARDING_SESSION_TTL
            );
            if (is_wp_error($session)) { return $session; }
            return self::fan_auth_response($user_id, $session);
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    private static function login_recovering_fan(WP_User $user, $identity_code, $password, $install_id) {
        $user_id = (int) $user->ID;
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $failure_check = self::check_failure_limit(
                'fan_recovery_login_failure',
                $identity_code,
                5
            );
            if (is_wp_error($failure_check)) { return $failure_check; }
            if (!self::fan_password_matches_database($user_id, $password)) {
                $failure = self::record_failure(
                    'fan_recovery_login_failure',
                    $identity_code,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
            }
            // Validate the secret before revealing whether this identity has a
            // live, expired or malformed recovery marker.
            $recovery = self::normalize_fan_password_recovery(
                self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null)
            );
            if (is_wp_error($recovery)) { return $recovery; }
            if ((int) $recovery['expiresTimestamp'] <= time()) {
                return new WP_Error(
                    'fan_password_recovery_expired',
                    '密码恢复凭据已过期，请联系管理员重新生成。',
                    array('status' => 410)
                );
            }
            $request_install_hash = hash('sha256', strtolower((string) $install_id));
            if (!empty($recovery['claimedInstallHash'])) {
                if (empty($recovery['claimedInstallHash'])
                    || !hash_equals(
                        (string) $recovery['claimedInstallHash'],
                        $request_install_hash
                    )) {
                    return new WP_Error(
                        'fan_login_invalid',
                        '身份码或密码不正确。',
                        array('status' => 401)
                    );
                }
                if (!empty($recovery['claimedSessionID'])) {
                    // A lost HTTP response may leave the legitimate installation
                    // without the first token. Reissue only to that same hashed
                    // installation and invalidate the prior recovery session.
                    self::revoke_fan_session_by_public_id(
                        $user_id,
                        (string) $recovery['claimedSessionID']
                    );
                }
            } else {
                try {
                    $claim_nonce = bin2hex(random_bytes(16));
                } catch (Exception $error) {
                    return new WP_Error(
                        'fan_password_recovery_unavailable',
                        '暂时无法安全绑定恢复会话，请联系管理员重新生成。',
                        array('status' => 503)
                    );
                }
                // Persist an installation-bound nonce before issuing any
                // token. A crash can leave only this harmless preliminary
                // claim; the same installation may retry, while another one
                // cannot steal the credential.
                $recovery['claimedAt'] = gmdate('c');
                $recovery['claimedInstallHash'] = $request_install_hash;
                $recovery['claimNonce'] = $claim_nonce;
                $recovery['claimedSessionID'] = '';
                unset($recovery['createdTimestamp'], $recovery['expiresTimestamp']);
                if (!self::update_user_meta_verified(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY,
                    $recovery
                )) {
                    return new WP_Error(
                        'fan_password_recovery_unavailable',
                        '暂时无法安全绑定恢复会话，请联系管理员重新生成。',
                        array('status' => 503)
                    );
                }
            }
            self::clear_failure_limit('fan_recovery_login_failure', $identity_code);
            $session = self::issue_fan_session(
                $user_id,
                $install_id,
                'password_recovery',
                self::FAN_PASSWORD_RECOVERY_SESSION_TTL
            );
            if (is_wp_error($session)) { return $session; }
            $recovery['claimedAt'] = gmdate('c');
            $recovery['claimedInstallHash'] = $request_install_hash;
            $recovery['claimedSessionID'] = (string) $session['sessionID'];
            unset($recovery['createdTimestamp'], $recovery['expiresTimestamp']);
            if (!self::update_user_meta_verified(
                $user_id,
                self::FAN_META_PASSWORD_RECOVERY,
                $recovery
            )) {
                self::revoke_fan_session($user_id, (string) $session['tokenHash']);
                return new WP_Error(
                    'fan_password_recovery_unavailable',
                    '暂时无法安全绑定恢复会话，请联系管理员重新生成。',
                    array('status' => 503)
                );
            }
            return self::fan_auth_response($user_id, $session);
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function can_access_fan_session(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_complete_fan_invitation(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        if (($context['scope'] ?? '') !== 'onboarding') {
            return new WP_Error(
                'fan_onboarding_session_required',
                '请先使用临时密码登录。',
                array('status' => 403)
            );
        }
        $user_id = (int) $context['userID'];
        $invitation = self::normalize_fan_invitation(
            get_user_meta($user_id, self::FAN_META_INVITATION, true)
        );
        if (is_wp_error($invitation)) { return $invitation; }
        if ((string) get_user_meta($user_id, self::FAN_META_STATUS, true) !== 'pending'
            || empty($invitation['preapproved'])) {
            return new WP_Error(
                'fan_invitation_unavailable',
                '临时账号当前不能完成设置。',
                array('status' => 403)
            );
        }
        if ((int) $invitation['expiresTimestamp'] <= time()) {
            return new WP_Error(
                'fan_invitation_expired',
                '临时账号已过期，请联系管理员重新创建。',
                array('status' => 410)
            );
        }
        $context['invitation'] = $invitation;
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_access_normal_fan_session(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $user_id = (int) $context['userID'];
        if (($context['scope'] ?? '') !== 'normal'
            || !empty(self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null))
            || !empty(self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null))
            || !empty(self::fan_meta_from_database($user_id, self::FAN_META_APPLE_SETUP, null))) {
            return new WP_Error(
                'fan_normal_session_required',
                '请先完成账号安全设置。',
                array('status' => 403)
            );
        }
        if (!self::fan_has_required_douyin_id($user_id)) {
            return new WP_Error(
                'fan_douyin_id_required',
                '请先在账号页补全抖音 ID。',
                array('status' => 403)
            );
        }
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_complete_fan_password_recovery(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        if (($context['scope'] ?? '') !== 'password_recovery') {
            return new WP_Error(
                'fan_password_recovery_session_required',
                '请先使用密码恢复凭据登录。',
                array('status' => 403)
            );
        }
        $recovery = self::normalize_fan_password_recovery(
            self::fan_meta_from_database(
                (int) $context['userID'],
                self::FAN_META_PASSWORD_RECOVERY,
                null
            )
        );
        if (is_wp_error($recovery)) { return $recovery; }
        if ((int) $recovery['expiresTimestamp'] <= time()) {
            return new WP_Error(
                'fan_password_recovery_expired',
                '密码恢复凭据已过期，请联系管理员重新生成。',
                array('status' => 410)
            );
        }
        if (empty($recovery['claimedSessionID'])
            || empty($recovery['claimedInstallHash'])
            || empty($recovery['claimNonce'])
            || !hash_equals(
                (string) $recovery['claimedSessionID'],
                (string) ($context['sessionID'] ?? '')
            )
            || !hash_equals(
                (string) $recovery['claimedInstallHash'],
                (string) ($context['installHash'] ?? '')
            )) {
            return new WP_Error(
                'fan_password_recovery_session_required',
                '密码恢复会话已失效，请联系管理员重新生成。',
                array('status' => 403)
            );
        }
        $context['passwordRecovery'] = $recovery;
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_complete_fan_apple_registration(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $user_id = (int) ($context['userID'] ?? 0);
        $scope = (string) ($context['scope'] ?? '');
        $source = self::fan_account_source($user_id);
        if ($scope === 'normal' && !self::fan_has_required_douyin_id($user_id)) {
            if ($source === 'apple'
                && (($context['authMethod'] ?? '') !== 'apple'
                    || (int) ($context['recentAuthUntil'] ?? 0) < time())) {
                return new WP_Error(
                    'fan_apple_profile_required',
                    '请重新使用 Apple ID 验证后补全抖音 ID。',
                    array('status' => 403)
                );
            }
            $context['douyinProfileUpgrade'] = true;
            self::$fan_session_context = $context;
            return true;
        }
        if ($scope !== 'apple_onboarding' || $source !== 'apple') {
            return new WP_Error(
                'fan_apple_profile_required',
                '当前账号不需要补全抖音 ID。',
                array('status' => 403)
            );
        }
        $setup = self::normalize_fan_apple_setup(self::fan_meta_from_database(
            $user_id,
            self::FAN_META_APPLE_SETUP,
            null
        ));
        if (is_wp_error($setup)) { return $setup; }
        $context['appleSetupGeneration'] = (string) $setup['generation'];
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_delete_fan_apple_account(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $user_id = (int) ($context['userID'] ?? 0);
        $scope = (string) ($context['scope'] ?? '');
        if (!in_array($scope, array('normal', 'apple_onboarding'), true)
            || self::fan_account_source($user_id) !== 'apple'
            || !self::valid_apple_sub_hash(self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_SUB_HASH,
                ''
            ))) {
            return new WP_Error(
                'fan_apple_reauthentication_required',
                '请重新使用 Apple ID 验证后删除账号。',
                array('status' => 403)
            );
        }
        self::$fan_session_context = $context;
        return true;
    }

    public static function complete_fan_apple_registration(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context)) {
            return new WP_Error('fan_apple_profile_required', '请先使用 Apple ID 登录。', array('status' => 403));
        }
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $display_name = sanitize_text_field((string) $request->get_param('displayName'));
        $douyin_id = self::normalize_required_douyin_id($request->get_param('douyinID'));
        if (is_wp_error($douyin_id)) { return $douyin_id; }
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        $consent_version = $request->get_param('consentVersion');
        if (!self::fan_new_consent_version_is_accepted($consent_version)) {
            return new WP_Error('fan_consent_required', '请先阅读并确认账号资料的使用说明。', array('status' => 400));
        }
        if (!empty($context['douyinProfileUpgrade'])
            && ($context['scope'] ?? '') === 'normal') {
            return self::complete_fan_douyin_profile_upgrade(
                $request,
                $context,
                $install_id,
                $display_name,
                $douyin_id,
                $consent_version
            );
        }
        if (($context['scope'] ?? '') !== 'apple_onboarding') {
            return new WP_Error(
                'fan_apple_profile_required',
                '当前账号不需要补全抖音 ID。',
                array('status' => 403)
            );
        }
        $network_limit = self::rate_limit(
            'fan_apple_profile_net',
            self::request_network_fingerprint(),
            20,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }

        $generated_identity_code = self::generate_unique_identity_code();
        if (is_wp_error($generated_identity_code)) { return $generated_identity_code; }

        $user_id = (int) ($context['userID'] ?? 0);
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        $transaction_started = false;
        $transaction_committed = false;
        $reservation = self::douyin_reservation_name($douyin_id);
        try {
            if (!self::fan_session_context_is_current_from_database($context, 'apple_onboarding')) {
                return new WP_Error('fan_apple_profile_required', 'Apple 登录会话已失效。', array('status' => 403));
            }
            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || $wpdb->query('START TRANSACTION') === false) {
                return new WP_Error('fan_apple_transaction_unavailable', '账号安全事务暂时不可用。', array('status' => 503));
            }
            $transaction_started = true;
            $setup = self::normalize_fan_apple_setup(self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_SETUP,
                null,
                true
            ));
            $sub_hash = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_SUB_HASH,
                '',
                true
            );
            $source = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_ACCOUNT_SOURCE,
                '',
                true
            );
            if (is_wp_error($setup)
                || !hash_equals(
                    (string) ($context['appleSetupGeneration'] ?? ''),
                    (string) ($setup['generation'] ?? '')
                )
                || $source !== 'apple' || !self::valid_apple_sub_hash($sub_hash)) {
                return new WP_Error('fan_apple_profile_required', 'Apple 账号状态已变更，请重新登录。', array('status' => 403));
            }
            $is_douyin_migration = !empty($setup['douyinMigration']);
            $permissions = array('gallery_full', 'video_view');
            $status = 'pending';
            if ($is_douyin_migration) {
                $permissions = self::sanitize_fan_permissions(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_PERMISSIONS,
                    array(),
                    true
                ));
                $status = sanitize_key((string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_STATUS,
                    '',
                    true
                ));
                if (is_wp_error($permissions)
                    || !in_array($status, array('pending', 'active', 'rejected', 'suspended'), true)) {
                    return new WP_Error(
                        'fan_apple_profile_required',
                        'Apple 账号权限或状态无法安全迁移。',
                        array('status' => 409)
                    );
                }
            }
            $duplicate_id = (int) $wpdb->get_var($wpdb->prepare(
                "SELECT user_id FROM {$wpdb->usermeta} WHERE meta_key = %s AND meta_value = %s AND user_id <> %d LIMIT 1",
                self::FAN_META_DOUYIN_ID,
                $douyin_id,
                $user_id
            ));
            if ($duplicate_id > 0) {
                return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请使用原账号或联系管理员。', array('status' => 409));
            }
            $inserted = $wpdb->query($wpdb->prepare(
                "INSERT IGNORE INTO {$wpdb->options} (option_name, option_value, autoload) VALUES (%s, %s, 'no')",
                $reservation,
                (string) $user_id
            ));
            if ($inserted === false
                || self::reservation_owner_from_database($reservation) !== $user_id) {
                return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请使用原账号或联系管理员。', array('status' => 409));
            }
            $current_epoch = (int) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                0,
                true
            );
            $current_identity_code = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CODE,
                '',
                true
            );
            $identity_code = $current_identity_code !== ''
                ? self::normalize_identity_code($current_identity_code)
                : $generated_identity_code;
            $saved = $current_epoch > 0
                && $identity_code !== ''
                && self::set_fan_meta_in_transaction($user_id, self::FAN_META_CODE, $identity_code)
                && self::set_fan_meta_in_transaction($user_id, self::FAN_META_DOUYIN_ID, $douyin_id)
                && self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_PERMISSIONS,
                    $permissions
                )
                && self::set_fan_meta_in_transaction($user_id, self::FAN_META_STATUS, $status)
                && self::set_fan_meta_in_transaction($user_id, self::FAN_META_CONSENT, array(
                    'version' => $consent_version,
                    'acceptedAt' => gmdate('c'),
                    'source' => 'apple_registration',
                ))
                && self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_CREDENTIAL_EPOCH,
                    $current_epoch + 1
                )
                && self::delete_fan_meta_in_transaction($user_id, self::FAN_META_APPLE_SETUP);
            $display_saved = $wpdb->update(
                $wpdb->users,
                array('display_name' => $display_name),
                array('ID' => $user_id),
                array('%s'),
                array('%d')
            );
            if (!$saved || $display_saved === false || $wpdb->query('COMMIT') === false) {
                return new WP_Error('fan_apple_profile_failed', '暂时无法保存 Apple 账号资料。', array('status' => 503));
            }
            $transaction_committed = true;
            self::clear_fan_option_caches(array($reservation));
            clean_user_cache($user_id);
            wp_cache_delete($user_id, 'user_meta');
            self::record_fan_auth_audit($user_id, 'apple_registration_completed');
            self::revoke_all_fan_sessions($user_id);
            $session = self::issue_fan_session(
                $user_id,
                $install_id,
                'normal',
                self::FAN_SESSION_TTL,
                array('authMethod' => 'apple', 'recentAuthUntil' => time() + self::FAN_APPLE_RECENT_AUTH_TTL)
            );
            if (is_wp_error($session)) { return $session; }
            self::$fan_session_context = $session;
            return self::fan_auth_response($user_id, $session);
        } finally {
            global $wpdb;
            if ($transaction_started && !$transaction_committed && isset($wpdb)
                && method_exists($wpdb, 'query')) {
                $wpdb->query('ROLLBACK');
                self::clear_fan_option_caches(array($reservation));
                clean_user_cache($user_id);
                wp_cache_delete($user_id, 'user_meta');
            }
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    private static function complete_fan_douyin_profile_upgrade(
        WP_REST_Request $request,
        $context,
        $install_id,
        $display_name,
        $douyin_id,
        $consent_version
    ) {
        $network_limit = self::rate_limit(
            'fan_douyin_upgrade_net',
            self::request_network_fingerprint(),
            20,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }

        $user_id = (int) ($context['userID'] ?? 0);
        $source = self::fan_account_source($user_id);
        $current_password = (string) $request->get_param('currentPassword');
        if ($source !== 'apple' && (!$current_password || strlen($current_password) > 512)) {
            return new WP_Error(
                'fan_login_invalid',
                '请输入当前密码后补全抖音 ID。',
                array('status' => 401)
            );
        }

        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        $transaction_started = false;
        $transaction_committed = false;
        $reservation = self::douyin_reservation_name($douyin_id);
        $previous_reservation = '';
        try {
            if (!self::fan_session_context_is_current_from_database($context, 'normal')
                || !empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_INVITATION,
                    null,
                    true
                ))
                || !empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY,
                    null,
                    true
                ))) {
                return new WP_Error(
                    'fan_account_setup_required',
                    '账号状态已变更，请重新登录后再补全资料。',
                    array('status' => 409)
                );
            }
            if ($source === 'apple') {
                if (($context['authMethod'] ?? '') !== 'apple'
                    || (int) ($context['recentAuthUntil'] ?? 0) < time()) {
                    return new WP_Error(
                        'fan_apple_profile_required',
                        '请重新使用 Apple ID 验证后补全抖音 ID。',
                        array('status' => 403)
                    );
                }
            } elseif (!self::fan_password_matches_database(
                $user_id,
                $current_password,
                true
            )) {
                return new WP_Error(
                    'fan_login_invalid',
                    '当前密码不正确。',
                    array('status' => 401)
                );
            }

            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || $wpdb->query('START TRANSACTION') === false) {
                return new WP_Error(
                    'fan_douyin_upgrade_unavailable',
                    '账号资料事务暂时不可用。',
                    array('status' => 503)
                );
            }
            $transaction_started = true;
            $stored_douyin_id = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                '',
                true
            );
            $normalized_stored_douyin_id = self::normalize_douyin_id($stored_douyin_id);
            if ($normalized_stored_douyin_id !== ''
                && hash_equals($stored_douyin_id, $normalized_stored_douyin_id)
                && !self::is_invitation_douyin_id($stored_douyin_id)) {
                return new WP_Error(
                    'fan_douyin_upgrade_not_required',
                    '当前账号已绑定抖音 ID。',
                    array('status' => 409)
                );
            }
            if ($stored_douyin_id !== '') {
                $previous_reservation = self::douyin_reservation_name($stored_douyin_id);
            }
            $duplicate_id = (int) $wpdb->get_var($wpdb->prepare(
                "SELECT user_id FROM {$wpdb->usermeta} WHERE meta_key = %s AND meta_value = %s AND user_id <> %d LIMIT 1",
                self::FAN_META_DOUYIN_ID,
                $douyin_id,
                $user_id
            ));
            if ($duplicate_id > 0) {
                return new WP_Error(
                    'fan_douyin_id_exists',
                    '该抖音 ID 已登记，请使用原账号或联系管理员。',
                    array('status' => 409)
                );
            }
            $inserted = $wpdb->query($wpdb->prepare(
                "INSERT IGNORE INTO {$wpdb->options} (option_name, option_value, autoload) VALUES (%s, %s, 'no')",
                $reservation,
                (string) $user_id
            ));
            if ($inserted === false
                || self::reservation_owner_from_database($reservation) !== $user_id) {
                return new WP_Error(
                    'fan_douyin_id_exists',
                    '该抖音 ID 已登记，请使用原账号或联系管理员。',
                    array('status' => 409)
                );
            }
            $current_epoch = (int) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                0,
                true
            );
            $saved = $current_epoch > 0
                && self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_DOUYIN_ID,
                    $douyin_id
                )
                && self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_CONSENT,
                    array(
                        'version' => $consent_version,
                        'acceptedAt' => gmdate('c'),
                        'source' => 'douyin_profile_upgrade',
                    )
                )
                && self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_CREDENTIAL_EPOCH,
                    $current_epoch + 1
                );
            $display_saved = $wpdb->update(
                $wpdb->users,
                array('display_name' => $display_name),
                array('ID' => $user_id),
                array('%s'),
                array('%d')
            );
            if (!$saved || $display_saved === false || $wpdb->query('COMMIT') === false) {
                return new WP_Error(
                    'fan_douyin_upgrade_unavailable',
                    '暂时无法保存抖音 ID，请稍后重试。',
                    array('status' => 503)
                );
            }
            $transaction_committed = true;
            self::clear_fan_option_caches(array_filter(array(
                $reservation,
                $previous_reservation,
            )));
            clean_user_cache($user_id);
            wp_cache_delete($user_id, 'user_meta');
            if ($previous_reservation !== ''
                && self::reservation_owner_from_database($previous_reservation) === $user_id) {
                delete_option($previous_reservation);
            }
            self::revoke_all_fan_sessions($user_id);
            $security_context = $source === 'apple'
                ? array(
                    'authMethod' => 'apple',
                    'recentAuthUntil' => time() + self::FAN_APPLE_RECENT_AUTH_TTL,
                )
                : array('authMethod' => 'password');
            $session = self::issue_fan_session(
                $user_id,
                $install_id,
                'normal',
                self::FAN_SESSION_TTL,
                $security_context
            );
            if (is_wp_error($session)) { return $session; }
            self::$fan_session_context = $session;
            return self::fan_auth_response($user_id, $session);
        } finally {
            global $wpdb;
            if ($transaction_started && !$transaction_committed && isset($wpdb)
                && method_exists($wpdb, 'query')) {
                $wpdb->query('ROLLBACK');
                self::clear_fan_option_caches(array_filter(array(
                    $reservation,
                    $previous_reservation,
                )));
                clean_user_cache($user_id);
                wp_cache_delete($user_id, 'user_meta');
            }
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function delete_fan_apple_account(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID'])) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $input = self::apple_credential_request($request, true);
        if (is_wp_error($input)) { return $input; }
        $network_limit = self::rate_limit(
            'fan_apple_delete_net',
            self::request_network_fingerprint(),
            10,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $user_id = (int) $context['userID'];
        $failure_limit = self::check_failure_limit('fan_apple_delete_failure', (string) $user_id, 5);
        if (is_wp_error($failure_limit)) { return $failure_limit; }

        $challenge = self::consume_fan_apple_challenge(
            $input['challengeID'],
            $input['state'],
            $install_id,
            'delete_account'
        );
        if (is_wp_error($challenge)
            || (int) ($challenge['userID'] ?? 0) !== $user_id
            || !hash_equals((string) ($challenge['sessionID'] ?? ''), (string) ($context['sessionID'] ?? ''))
            || (int) ($challenge['credentialEpoch'] ?? 0) !== (int) ($context['credentialEpoch'] ?? 0)) {
            self::record_failure('fan_apple_delete_failure', (string) $user_id, 15 * MINUTE_IN_SECONDS);
            return new WP_Error('fan_apple_reauthentication_required', '请重新使用 Apple ID 验证后删除账号。', array('status' => 403));
        }
        $credential = self::verify_and_exchange_apple_credential(
            $input['identityToken'],
            $input['authorizationCode'],
            (string) $challenge['nonceHash']
        );
        if (is_wp_error($credential)) {
            self::record_failure('fan_apple_delete_failure', (string) $user_id, 15 * MINUTE_IN_SECONDS);
            return $credential;
        }

        $credential_subject_hash = (string) ($credential['subjectHash'] ?? '');
        if (!self::valid_apple_sub_hash($credential_subject_hash)) {
            return new WP_Error('fan_apple_reauthentication_required', '当前 Apple 账号与登录账号不一致。', array('status' => 403));
        }
        $subject_lock = self::acquire_named_fan_lock('apple_sub', $credential_subject_hash);
        if (is_wp_error($subject_lock)) { return $subject_lock; }
        try {
            $lock_owner = self::acquire_fan_lock($user_id);
            if (is_wp_error($lock_owner)) { return $lock_owner; }
            try {
            $scope = (string) ($context['scope'] ?? '');
            $stored_sub_hash = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_SUB_HASH,
                ''
            );
            if (!in_array($scope, array('normal', 'apple_onboarding'), true)
                || !self::fan_session_context_is_current_from_database($context, $scope)
                || self::fan_account_source($user_id) !== 'apple'
                || !self::valid_apple_sub_hash($stored_sub_hash)
                || !hash_equals($stored_sub_hash, $credential_subject_hash)
                || (int) ($context['credentialEpoch'] ?? 0)
                    !== (int) self::fan_meta_from_database(
                        $user_id,
                        self::FAN_META_CREDENTIAL_EPOCH,
                        0
                    )) {
                self::record_failure('fan_apple_delete_failure', (string) $user_id, 15 * MINUTE_IN_SECONDS);
                return new WP_Error('fan_apple_reauthentication_required', '当前 Apple 账号与登录账号不一致。', array('status' => 403));
            }

            $tombstone = self::persist_apple_subject_tombstone_under_lock(
                $credential_subject_hash,
                time()
            );
            if (is_wp_error($tombstone)) { return $tombstone; }

            $stored_encrypted = self::fan_meta_from_database(
                $user_id,
                self::FAN_META_APPLE_REFRESH_TOKEN,
                null
            );
            $pending_revocations = array();
            $seen_tokens = array();

            // The fresh token is already in memory, so try Apple's revoke
            // endpoint before depending on local encryption or queue storage.
            // A revoke/queue infrastructure failure must never prevent the
            // user from deleting their local account and personal data.
            $fresh_refresh_token = (string) ($credential['refreshToken'] ?? '');
            if ($fresh_refresh_token !== '') {
                $fingerprint = hash('sha256', $fresh_refresh_token);
                $seen_tokens[$fingerprint] = true;
                if (!self::revoke_apple_refresh_token($fresh_refresh_token)) {
                    $fresh_encrypted = self::encrypt_apple_refresh_token($fresh_refresh_token);
                    if (self::valid_encrypted_apple_refresh_token($fresh_encrypted)) {
                        $pending_revocations[] = $fresh_encrypted;
                    } else {
                        do_action('yishu_fan_security_audit', 'apple_revocation_queue_unavailable');
                    }
                }
                if (function_exists('sodium_memzero')) { sodium_memzero($fresh_refresh_token); }
            }

            foreach (array($stored_encrypted) as $encrypted) {
                if (!self::valid_encrypted_apple_refresh_token($encrypted)) { continue; }
                $refresh_token = self::decrypt_apple_refresh_token($encrypted);
                if ($refresh_token === '') {
                    $pending_revocations[] = $encrypted;
                    continue;
                }
                $fingerprint = hash('sha256', $refresh_token);
                if (isset($seen_tokens[$fingerprint])) {
                    if (function_exists('sodium_memzero')) { sodium_memzero($refresh_token); }
                    continue;
                }
                $seen_tokens[$fingerprint] = true;
                if (!self::revoke_apple_refresh_token($refresh_token)) {
                    $pending_revocations[] = $encrypted;
                }
                if (function_exists('sodium_memzero')) { sodium_memzero($refresh_token); }
            }

            $queued_revocations = array();
            foreach ($pending_revocations as $encrypted) {
                $job_name = self::queue_fan_apple_revocation($encrypted);
                if (!is_string($job_name)) {
                    // Account deletion must not depend on Apple's revoke
                    // service or the anonymous retry infrastructure. Never
                    // include the token or an account identifier in this event.
                    do_action('yishu_fan_security_audit', 'apple_revocation_queue_unavailable');
                    continue;
                }
                $queued_revocations[] = $job_name;
            }

            $douyin_id = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                ''
            );
            $reservation = $douyin_id ? self::douyin_reservation_name($douyin_id) : '';
            if (!self::remove_fan_user($user_id, $reservation)) {
                foreach ($queued_revocations as $job_name) {
                    delete_option((string) $job_name);
                }
                return new WP_Error('fan_delete_failed', '暂时无法删除账号，请稍后重试。', array('status' => 503));
            }
            self::clear_failure_limit('fan_apple_delete_failure', (string) $user_id);
            self::$fan_session_context = null;
            $response = rest_ensure_response(array('ok' => true));
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            $response->header('Pragma', 'no-cache');
            return $response;
            } finally {
                self::release_fan_lock($user_id, $lock_owner);
            }
        } finally {
            self::release_named_fan_lock($subject_lock);
        }
    }

    public static function handle_fan_apple_notification(WP_REST_Request $request) {
        $limit = self::rate_limit(
            'fan_apple_notification_net',
            self::request_network_fingerprint(),
            120,
            15 * MINUTE_IN_SECONDS
        );
        $payload = trim((string) $request->get_param('payload'));
        if (strlen($payload) < 100 || strlen($payload) > 32768
            || substr_count($payload, '.') !== 2) {
            return is_wp_error($limit)
                ? $limit
                : new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 400));
        }
        if (self::apple_test_mode_enabled()) {
            $claims = apply_filters('yishu_fan_apple_notification_verifier', null, $payload);
        } else {
            $claims = null;
        }
        if ($claims === null) {
            $claims = self::decode_apple_rs256_token(
                $payload,
                'fan_apple_notification_invalid',
                !is_wp_error($limit)
            );
        }
        if (is_wp_error($claims) || !is_array($claims)) {
            return is_wp_error($limit)
                ? $limit
                : (is_wp_error($claims)
                ? $claims
                : new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401)));
        }
        $now = time();
        $normalized = self::normalize_fan_apple_notification_claims($claims, $now);
        if (is_wp_error($normalized)) {
            return is_wp_error($limit) ? $limit : $normalized;
        }
        // A valid Apple-signed event must always reach the durable inbox.
        // Network throttling is only a defense against invalid/unverifiable
        // traffic because Apple does not guarantee S2S redelivery.
        $jti = (string) $normalized['jti'];
        $normalized_events = (array) $normalized['events'];
        $event_option = self::FAN_APPLE_EVENT_OPTION_PREFIX . hash(
            'sha256',
            self::FAN_APPLE_ISSUER . '|' . self::FAN_APPLE_CLIENT_ID . '|' . $jti
        );
        $event_lock = self::acquire_named_fan_lock('apple_event', $event_option);
        if (is_wp_error($event_lock)) {
            // A duplicate delivery may race the request that is already
            // durably writing this same jti. If the inbox exists, acknowledge
            // it; subject processing no longer depends on this HTTP request.
            $existing = self::normalize_fan_apple_event_record(
                self::fan_option_from_database($event_option, null)
            );
            if (!is_wp_error($existing)) {
                self::schedule_fan_apple_event_record($event_option, $existing);
                return rest_ensure_response(array('ok' => true));
            }
            return $event_lock;
        }
        try {
            $existing_raw = self::fan_option_from_database($event_option, null);
            if ($existing_raw !== null) {
                $existing = self::normalize_fan_apple_event_record($existing_raw);
                if (is_wp_error($existing)) { return $existing; }
                self::schedule_fan_apple_event_record($event_option, $existing);
                return rest_ensure_response(array('ok' => true));
            }
            try {
                $generation = bin2hex(random_bytes(16));
            } catch (Throwable $error) {
                return new WP_Error('fan_apple_notification_unavailable', '暂时无法完成 Apple 通知处理。', array('status' => 503));
            }
            $relevant_events = array_values(array_filter(
                $normalized_events,
                static function ($event) {
                    return is_array($event) && in_array(
                        (string) ($event['type'] ?? ''),
                        array('consent-revoked', 'account-deleted'),
                        true
                    );
                }
            ));
            $record = $relevant_events
                ? array(
                    'version' => 1,
                    'status' => 'pending',
                    'receivedAt' => $now,
                    'events' => $relevant_events,
                    'attempts' => 0,
                    'nextAttempt' => $now,
                    'generation' => $generation,
                )
                : array(
                    'version' => 1,
                    'status' => 'processed',
                    'processedAt' => $now,
                    'expires' => $now + 30 * DAY_IN_SECONDS,
                    'generation' => $generation,
                );
            if (!add_option($event_option, $record, '', false)) {
                return new WP_Error('fan_apple_notification_unavailable', '暂时无法完成 Apple 通知处理。', array('status' => 503));
            }
            self::clear_fan_option_caches(array($event_option));
            $stored = self::normalize_fan_apple_event_record(
                self::fan_option_from_database($event_option, null)
            );
            if (is_wp_error($stored)
                || !hash_equals($generation, (string) ($stored['generation'] ?? ''))) {
                return new WP_Error('fan_apple_notification_unavailable', '暂时无法持久保存 Apple 通知。', array('status' => 503));
            }
            if (!self::schedule_fan_apple_event_record($event_option, $stored)) {
                // The verified event is already durable. The init sweeper
                // repairs scheduling; never rely on Apple redelivery.
                do_action('yishu_fan_security_audit', 'apple_event_schedule_unavailable');
            }
            $response = rest_ensure_response(array('ok' => true));
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            return $response;
        } finally {
            self::release_named_fan_lock($event_lock);
        }
    }

    private static function remove_fan_for_apple_subject_hash($subject_hash, $event_time) {
        $reservation = self::apple_subject_reservation_name($subject_hash);
        if (!$reservation) {
            return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
        }
        $subject_lock = self::acquire_named_fan_lock('apple_sub', $subject_hash);
        if (is_wp_error($subject_lock)) { return $subject_lock; }
        try {
            // Persist the per-sub revocation boundary before deleting. A
            // credential verified earlier but waiting on this lock then sees
            // the tombstone and cannot recreate the account unless both Apple
            // identity tokens were issued strictly after the signed event.
            $tombstone = self::persist_apple_subject_tombstone_under_lock(
                $subject_hash,
                (int) $event_time
            );
            if (is_wp_error($tombstone)) { return $tombstone; }
            $user_id = self::resolve_apple_subject_owner_under_lock(
                $subject_hash,
                $reservation
            );
            if (is_wp_error($user_id)) { return $user_id; }
            if ($user_id <= 0) { return true; }
            $user_lock = self::acquire_fan_lock($user_id);
            if (is_wp_error($user_lock)) { return $user_lock; }
            try {
                $stored_hash = (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_APPLE_SUB_HASH,
                    ''
                );
                if (self::fan_account_source($user_id) !== 'apple'
                    || !hash_equals((string) $subject_hash, $stored_hash)) {
                    return new WP_Error('fan_apple_notification_conflict', 'Apple 账号状态不一致。', array('status' => 409));
                }
                $last_auth_iat = (int) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_APPLE_AUTH_IAT,
                    0
                );
                if (!self::apple_event_should_remove_owner($last_auth_iat, $event_time)) {
                    // This account was authenticated or recreated with a
                    // credential issued after the signed Apple event. Keep it;
                    // retries or out-of-order older events remain idempotent.
                    return true;
                }
                $douyin_id = (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_DOUYIN_ID,
                    ''
                );
                $douyin_reservation = $douyin_id
                    ? self::douyin_reservation_name($douyin_id)
                    : '';
                return self::remove_fan_user($user_id, $douyin_reservation)
                    ? true
                    : new WP_Error('fan_apple_notification_unavailable', '暂时无法处理 Apple 账号通知。', array('status' => 503));
            } finally {
                self::release_fan_lock($user_id, $user_lock);
            }
        } finally {
            self::release_named_fan_lock($subject_lock);
        }
    }

    private static function apple_event_should_remove_owner($last_auth_iat, $event_time) {
        return (int) $last_auth_iat <= 0
            || (int) $last_auth_iat <= (int) $event_time;
    }

    public static function can_delete_fan_account(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $scope = (string) ($context['scope'] ?? '');
        $user_id = (int) ($context['userID'] ?? 0);
        if (self::fan_account_source($user_id) === 'apple') {
            return new WP_Error(
                'fan_apple_reauthentication_required',
                'Apple 账号必须重新使用 Apple ID 验证后删除。',
                array('status' => 403)
            );
        }
        if (!in_array($scope, array('normal', 'onboarding', 'password_recovery'), true)
            || $user_id <= 0) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        if ($scope === 'normal') {
            if (!empty(self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null))
                || !empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY,
                    null
                ))) {
                return new WP_Error(
                    'fan_delete_session_invalid',
                    '账号安全状态已变更，请重新登录后再试。',
                    array('status' => 403)
                );
            }
        } elseif ($scope === 'onboarding') {
            $invitation = self::normalize_fan_invitation(
                self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null)
            );
            if (is_wp_error($invitation) || (int) $invitation['expiresTimestamp'] <= time()) {
                return new WP_Error(
                    'fan_invitation_expired',
                    '临时账号已过期，请联系管理员。',
                    array('status' => 410)
                );
            }
            $context['deleteMarkerGeneration'] = (string) $invitation['generation'];
        } else {
            $recovery = self::normalize_fan_password_recovery(
                self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null)
            );
            if (is_wp_error($recovery) || (int) $recovery['expiresTimestamp'] <= time()) {
                return new WP_Error(
                    'fan_password_recovery_expired',
                    '密码恢复凭据已过期，请联系管理员重新生成。',
                    array('status' => 410)
                );
            }
            if (empty($recovery['claimedSessionID'])
                || empty($recovery['claimedInstallHash'])
                || !hash_equals(
                    (string) $recovery['claimedSessionID'],
                    (string) ($context['sessionID'] ?? '')
                )
                || !hash_equals(
                    (string) $recovery['claimedInstallHash'],
                    (string) ($context['installHash'] ?? '')
                )) {
                return new WP_Error(
                    'fan_delete_session_invalid',
                    '密码恢复会话已失效，请重新登录后再试。',
                    array('status' => 403)
                );
            }
            $context['deleteMarkerGeneration'] = (string) $recovery['generation'];
        }
        self::$fan_session_context = $context;
        return true;
    }

    public static function can_access_app_content(WP_REST_Request $request) {
        // An App-bound administrator is still a fan account: approval, Douyin
        // setup and session revocation must never be bypassed by its role.
        // Preserve the separate legacy WordPress administrator login path.
        if (!preg_match('/^Bearer(?:\\s|$)/i', trim((string) $request->get_header('authorization')))
            && self::authenticate_content_manager($request)) { return true; }

        return self::can_access_approved_fan_content($request);
    }

    private static function can_access_approved_fan_content(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        if (($context['scope'] ?? '') !== 'normal'
            || !empty(get_user_meta((int) $context['userID'], self::FAN_META_INVITATION, true))
            || !empty(get_user_meta((int) $context['userID'], self::FAN_META_PASSWORD_RECOVERY, true))
            || !empty(get_user_meta((int) $context['userID'], self::FAN_META_APPLE_SETUP, true))) {
            return new WP_Error(
                'fan_account_setup_required',
                '请先完成账号资料、密码和隐私同意设置。',
                array('status' => 403)
            );
        }
        if (!self::fan_has_required_douyin_id((int) $context['userID'])) {
            return new WP_Error(
                'fan_douyin_id_required',
                '请先在账号页补全抖音 ID。',
                array('status' => 403)
            );
        }
        $status = (string) get_user_meta((int) $context['userID'], self::FAN_META_STATUS, true);
        if ($status !== 'active') {
            $errors = array(
                'pending' => array('fan_approval_pending', '注册申请正在等待管理员审批。'),
                'rejected' => array('fan_approval_rejected', '注册申请未通过审批。'),
                'suspended' => array('fan_account_suspended', '账号访问已暂停，请联系管理员。'),
            );
            $error = isset($errors[$status])
                ? $errors[$status]
                : array('fan_approval_required', '账号尚未获得 App 访问授权。');
            return new WP_Error($error[0], $error[1], array('status' => 403));
        }
        $context['permissions'] = self::fan_permissions_for_user((int) $context['userID']);
        self::$fan_session_context = $context;
        return true;
    }

    public static function fan_session() {
        $context = self::$fan_session_context;
        if (!is_array($context)) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        if (($context['scope'] ?? '') === 'apple_onboarding') {
            $registration = self::fan_apple_onboarding_payload(
                (int) $context['userID'],
                $context
            );
            if (is_wp_error($registration)) { return $registration; }
            $payload = array('appleRegistration' => $registration);
        } else {
            $payload = array('profile' => self::fan_profile((int) $context['userID'], $context));
        }
        $response = rest_ensure_response($payload);
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function logout_fan() {
        $context = self::$fan_session_context;
        if (is_array($context) && !empty($context['tokenHash'])) {
            // revoke_fan_session first writes the persistent unbound tombstone,
            // cancels this binding generation and only then removes the device.
            // A direct device-first delete here would invert the worker's lock
            // order and could deadlock a concurrent delivery.
            self::revoke_fan_session((int) $context['userID'], (string) $context['tokenHash']);
        }
        self::$fan_session_context = null;
        $response = rest_ensure_response(array('ok' => true));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function delete_fan_account(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID'])) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $header_install_id = self::request_install_id($request);
        if (is_wp_error($header_install_id)) { return $header_install_id; }
        $body_install_id = strtolower(trim((string) $request->get_param('installID')));
        if (!$body_install_id || !hash_equals($header_install_id, $body_install_id)) {
            return new WP_Error(
                'fan_install_id_invalid',
                '安装记录无效，请重启 App 后再试。',
                array('status' => 400)
            );
        }
        $current_password = (string) $request->get_param('currentPassword');
        if ((string) $request->get_param('confirmation') !== 'DELETE_ACCOUNT'
            || !$current_password || strlen($current_password) > 512) {
            return new WP_Error('fan_delete_confirmation_required', '请确认后再删除账号。', array('status' => 400));
        }
        $network_limit = self::rate_limit(
            'fan_delete_net',
            self::request_network_fingerprint(),
            10,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $user_id = (int) $context['userID'];
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $scope = (string) ($context['scope'] ?? '');
            if (!self::fan_session_context_is_current_from_database($context, $scope)) {
                return new WP_Error(
                    'fan_delete_session_invalid',
                    '登录状态已变更，请重新登录后再试。',
                    array('status' => 403)
                );
            }
            $failure_check = self::check_failure_limit(
                'fan_delete_failure',
                (string) $user_id,
                5
            );
            if (is_wp_error($failure_check)) { return $failure_check; }
            $marker_valid = false;
            if ($scope === 'normal') {
                $marker_valid = empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_INVITATION,
                    null
                )) && empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY,
                    null
                ));
            } elseif ($scope === 'onboarding') {
                $invitation = self::normalize_fan_invitation(
                    self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null)
                );
                $marker_valid = !is_wp_error($invitation)
                    && (int) $invitation['expiresTimestamp'] > time()
                    && (string) self::fan_meta_from_database(
                        $user_id,
                        self::FAN_META_STATUS,
                        ''
                    ) === 'pending'
                    && hash_equals(
                        (string) $invitation['generation'],
                        (string) ($context['deleteMarkerGeneration'] ?? '')
                    );
            } elseif ($scope === 'password_recovery') {
                $recovery = self::normalize_fan_password_recovery(
                    self::fan_meta_from_database(
                        $user_id,
                        self::FAN_META_PASSWORD_RECOVERY,
                        null
                    )
                );
                $marker_valid = !is_wp_error($recovery)
                    && (int) $recovery['expiresTimestamp'] > time()
                    && !empty($recovery['claimNonce'])
                    && hash_equals(
                        (string) $recovery['generation'],
                        (string) ($context['deleteMarkerGeneration'] ?? '')
                    )
                    && hash_equals(
                        (string) $recovery['claimedSessionID'],
                        (string) ($context['sessionID'] ?? '')
                    )
                    && hash_equals(
                        (string) $recovery['claimedInstallHash'],
                        (string) ($context['installHash'] ?? '')
                    );
            }
            if (!$marker_valid
                || !self::fan_password_matches_database($user_id, $current_password)) {
                $failure = self::record_failure(
                    'fan_delete_failure',
                    (string) $user_id,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error(
                    'fan_login_invalid',
                    '当前密码不正确。',
                    array('status' => 401)
                );
            }
            self::clear_failure_limit('fan_delete_failure', (string) $user_id);
            $douyin_id = (string) get_user_meta($user_id, self::FAN_META_DOUYIN_ID, true);
            $reservation = $douyin_id ? self::douyin_reservation_name($douyin_id) : '';
            if (!self::remove_fan_user($user_id, $reservation)) {
                return new WP_Error('fan_delete_failed', '暂时无法删除账号，请稍后重试。', array('status' => 503));
            }
            self::$fan_session_context = null;
            $response = rest_ensure_response(array('ok' => true));
            $response->header('Cache-Control', 'private, no-store');
            return $response;
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function create_fan_invitations(WP_REST_Request $request) {
        $raw_count = $request->get_param('count');
        $count = is_scalar($raw_count) ? filter_var($raw_count, FILTER_VALIDATE_INT) : false;
        if ($count === false || $count < 1 || $count > 5) {
            return new WP_Error(
                'fan_invitation_count_invalid',
                '每次只能创建 1–5 个临时账号。',
                array('status' => 400)
            );
        }

        $created = array();
        $result = array();
        for ($index = 0; $index < $count; $index++) {
            $invitation = self::create_single_fan_invitation(get_current_user_id());
            if (is_wp_error($invitation)) {
                foreach ($created as $record) {
                    self::remove_fan_user((int) $record['userID'], (string) $record['reservation']);
                }
                return $invitation;
            }
            $created[] = array(
                'userID' => (int) $invitation['internalUserID'],
                'reservation' => (string) $invitation['reservation'],
            );
            $result[] = array(
                'userID' => (string) $invitation['userID'],
                'identityCode' => (string) $invitation['identityCode'],
                'temporaryPassword' => (string) $invitation['temporaryPassword'],
                'expiresAt' => (string) $invitation['expiresAt'],
                'requiresAccountSetup' => true,
            );
        }

        $response = new WP_REST_Response(array('invitations' => $result), 201);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        return $response;
    }

    public static function complete_fan_invitation(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID'])
            || ($context['scope'] ?? '') !== 'onboarding') {
            return new WP_Error(
                'fan_onboarding_session_required',
                '请先使用临时密码登录。',
                array('status' => 403)
            );
        }
        $header_install_id = self::request_install_id($request);
        if (is_wp_error($header_install_id)) { return $header_install_id; }
        $body_install_id = strtolower(trim((string) $request->get_param('installID')));
        if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $body_install_id)
            || !hash_equals($header_install_id, $body_install_id)) {
            return new WP_Error('fan_install_id_invalid', '安装记录无效，请重启 App 后再试。', array('status' => 400));
        }

        $display_name = sanitize_text_field((string) $request->get_param('displayName'));
        $douyin_id = self::normalize_required_douyin_id($request->get_param('douyinID'));
        if (is_wp_error($douyin_id)) { return $douyin_id; }
        $current_password = (string) $request->get_param('currentPassword');
        $new_password = (string) $request->get_param('newPassword');
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        $consent_version = $request->get_param('consentVersion');
        if (!self::fan_new_consent_version_is_accepted($consent_version)) {
            return new WP_Error('fan_consent_required', '请先阅读并确认账号资料的使用说明。', array('status' => 400));
        }
        $password_error = self::validate_fan_password($new_password);
        if (is_wp_error($password_error)) { return $password_error; }
        if (!$current_password || strlen($current_password) > 512
            || hash_equals($current_password, $new_password)) {
            return new WP_Error(
                'fan_new_password_required',
                '新密码必须与临时密码不同。',
                array('status' => 400)
            );
        }

        $user_id = (int) $context['userID'];
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        $transaction_started = false;
        $transaction_committed = false;
        $real_reservation = '';
        $placeholder_reservation = '';
        try {
            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || $wpdb->query('START TRANSACTION') === false) {
                return new WP_Error(
                    'fan_invitation_transaction_unavailable',
                    '账号安全事务暂时不可用。',
                    array('status' => 503)
                );
            }
            $transaction_started = true;
            $invitation = self::normalize_fan_invitation(
                self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null, true)
            );
            if (is_wp_error($invitation)
                || (int) $invitation['expiresTimestamp'] <= time()
                || empty($invitation['preapproved'])
                || (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_STATUS,
                    '',
                    true
                ) !== 'pending') {
                return new WP_Error(
                    'fan_invitation_unavailable',
                    '临时账号已过期或当前不能完成设置。',
                    array('status' => 410)
                );
            }
            if (!self::fan_password_matches_database($user_id, $current_password, true)) {
                return new WP_Error('fan_login_invalid', '身份码或密码不正确。', array('status' => 401));
            }
            $placeholder = (string) $invitation['placeholderDouyinID'];
            $current_douyin_id = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                '',
                true
            );
            if ($current_douyin_id !== $placeholder && $current_douyin_id !== $douyin_id) {
                return new WP_Error(
                    'fan_invitation_state_invalid',
                    '临时账号状态不一致，请联系管理员。',
                    array('status' => 409)
                );
            }

            if ($douyin_id !== '') {
                $duplicate_id = (int) $wpdb->get_var($wpdb->prepare(
                    "SELECT user_id FROM {$wpdb->usermeta} WHERE meta_key = %s AND meta_value = %s AND user_id <> %d LIMIT 1",
                    self::FAN_META_DOUYIN_ID,
                    $douyin_id,
                    $user_id
                ));
                if ($duplicate_id > 0) {
                    return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
                }

                $real_reservation = self::douyin_reservation_name($douyin_id);
                $reservation_inserted = $wpdb->query($wpdb->prepare(
                    "INSERT IGNORE INTO {$wpdb->options} (option_name, option_value, autoload) VALUES (%s, %s, 'no')",
                    $real_reservation,
                    (string) $user_id
                ));
                if ($reservation_inserted === false
                    || self::reservation_owner_from_database($real_reservation) !== $user_id) {
                    return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
                }
            }

            $profile_saved = self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                $douyin_id
            ) && self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_CONSENT,
                array(
                    'version' => $consent_version,
                    'acceptedAt' => gmdate('c'),
                    'source' => 'invitation_completion',
                )
            );
            $display_name_saved = $wpdb->update(
                $wpdb->users,
                array('display_name' => $display_name),
                array('ID' => $user_id),
                array('%s'),
                array('%d')
            );
            if (!$profile_saved || $display_name_saved === false) {
                return new WP_Error('fan_invitation_completion_failed', '暂时无法完成账号设置，请稍后重试。', array('status' => 503));
            }
            if (!self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_STATUS,
                'active'
            )) {
                return new WP_Error('fan_invitation_completion_failed', '暂时无法完成账号设置，请稍后重试。', array('status' => 503));
            }
            $current_epoch = (int) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                0,
                true
            );
            if ($current_epoch <= 0 || !self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                $current_epoch + 1
            )) {
                return new WP_Error(
                    'fan_credential_update_failed',
                    '暂时无法保存账号安全状态。',
                    array('status' => 503)
                );
            }

            $new_password_hash = wp_hash_password($new_password);
            $password_saved = $wpdb->update(
                $wpdb->users,
                array('user_pass' => $new_password_hash, 'user_activation_key' => ''),
                array('ID' => $user_id),
                array('%s', '%s'),
                array('%d')
            );
            if ($password_saved === false
                || !wp_check_password($new_password, $new_password_hash, $user_id)
                || !self::delete_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_INVITATION
                )) {
                return new WP_Error('fan_invitation_completion_failed', '暂时无法完成账号设置，请稍后重试。', array('status' => 503));
            }

            $placeholder_reservation = self::douyin_reservation_name($placeholder);
            if (self::reservation_owner_from_database($placeholder_reservation) === $user_id) {
                $placeholder_deleted = $wpdb->delete(
                    $wpdb->options,
                    array('option_name' => $placeholder_reservation),
                    array('%s')
                );
                if ($placeholder_deleted === false) {
                    return new WP_Error(
                        'fan_invitation_reservation_failed',
                        '暂时无法安全保存账号资料。',
                        array('status' => 503)
                    );
                }
            }
            if (self::reservation_owner_from_database($placeholder_reservation) === $user_id
                || ($real_reservation !== ''
                    && self::reservation_owner_from_database($real_reservation) !== $user_id)) {
                return new WP_Error(
                    'fan_invitation_reservation_failed',
                    '暂时无法安全保存账号资料。',
                    array('status' => 503)
                );
            }
            if ($wpdb->query('COMMIT') === false) {
                return new WP_Error(
                    'fan_invitation_completion_failed',
                    '暂时无法完成账号设置，请稍后重试。',
                    array('status' => 503)
                );
            }
            $transaction_committed = true;
            clean_user_cache($user_id);
            wp_cache_delete($user_id, 'user_meta');
            self::clear_fan_option_caches(array($real_reservation, $placeholder_reservation));
            // The committed credential epoch already rejects every old token;
            // remove their records immediately as a second layer.
            self::revoke_all_fan_sessions($user_id);
            $session = self::issue_fan_session($user_id, $header_install_id, 'normal');
            if (is_wp_error($session)) { return $session; }
            return self::fan_auth_response($user_id, $session);
        } finally {
            if ($transaction_started && !$transaction_committed) {
                $wpdb->query('ROLLBACK');
                clean_user_cache($user_id);
                wp_cache_delete($user_id, 'user_meta');
                self::clear_fan_option_caches(array($real_reservation, $placeholder_reservation));
            }
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function create_fan_password_recovery(WP_REST_Request $request) {
        $user = self::find_fan_user_by_uuid((string) $request['uuid']);
        if (is_wp_error($user)) { return $user; }
        $user_id = (int) $user->ID;
        if (self::fan_account_source($user_id) === 'apple') {
            return new WP_Error(
                'fan_password_recovery_not_supported',
                'Apple 账号请使用“通过 Apple 登录”恢复访问。',
                array('status' => 409)
            );
        }
        $limit = self::rate_limit(
            'fan_admin_password_recovery',
            get_current_user_id() . '|' . $user_id,
            5,
            HOUR_IN_SECONDS
        );
        if (is_wp_error($limit)) { return $limit; }

        $temporary_password = self::generate_temporary_password();
        if (is_wp_error($temporary_password)) { return $temporary_password; }
        try {
            $generation = bin2hex(random_bytes(16));
        } catch (Exception $error) {
            return new WP_Error(
                'fan_password_recovery_unavailable',
                '暂时无法生成安全恢复凭据。',
                array('status' => 503)
            );
        }
        $created_timestamp = time();
        $expires_timestamp = $created_timestamp + self::FAN_PASSWORD_RECOVERY_TTL;
        $recovery = array(
            'createdAt' => gmdate('c', $created_timestamp),
            'expiresAt' => gmdate('c', $expires_timestamp),
            'createdBy' => get_current_user_id(),
            'generation' => $generation,
        );

        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        $transaction_started = false;
        $transaction_committed = false;
        try {
            global $wpdb;
            if (!empty(self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null))) {
                return new WP_Error(
                    'fan_account_setup_required',
                    '临时邀请账号必须先由本人完成首次设置。',
                    array('status' => 409)
                );
            }
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || $wpdb->query('START TRANSACTION') === false) {
                return new WP_Error(
                    'fan_password_recovery_unavailable',
                    '账号安全事务暂时不可用。',
                    array('status' => 503)
                );
            }
            $transaction_started = true;
            $uuid = (string) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_UUID,
                '',
                true
            );
            if ($uuid !== strtolower((string) $request['uuid'])
                || !empty(self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_INVITATION,
                    null,
                    true
                ))) {
                return new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
            }
            $current_epoch = (int) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                0,
                true
            );
            $password_hash = wp_hash_password((string) $temporary_password);
            $password_saved = $wpdb->update(
                $wpdb->users,
                array('user_pass' => $password_hash, 'user_activation_key' => ''),
                array('ID' => $user_id),
                array('%s', '%s'),
                array('%d')
            );
            if ($current_epoch <= 0 || $password_saved === false
                || !wp_check_password((string) $temporary_password, $password_hash, $user_id)
                || !self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY,
                    $recovery
                )
                || !self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_CREDENTIAL_EPOCH,
                    $current_epoch + 1
                )) {
                return new WP_Error(
                    'fan_password_recovery_unavailable',
                    '暂时无法安全更新账号凭据。',
                    array('status' => 503)
                );
            }
            if ($wpdb->query('COMMIT') === false) {
                return new WP_Error(
                    'fan_password_recovery_unavailable',
                    '暂时无法安全更新账号凭据。',
                    array('status' => 503)
                );
            }
            $transaction_committed = true;
            clean_user_cache($user_id);
            wp_cache_delete($user_id, 'user_meta');
            // The epoch change rejects all previous tokens before their option
            // records are removed, so reset creation is fail closed.
            self::revoke_all_fan_sessions($user_id);
            $response = new WP_REST_Response(array(
                'passwordRecovery' => array(
                    'userID' => (string) get_user_meta($user_id, self::FAN_META_UUID, true),
                    'identityCode' => (string) get_user_meta($user_id, self::FAN_META_CODE, true),
                    'temporaryPassword' => (string) $temporary_password,
                    'expiresAt' => (string) $recovery['expiresAt'],
                    'requiresPasswordChange' => true,
                ),
            ), 201);
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            $response->header('Pragma', 'no-cache');
            return $response;
        } finally {
            if ($transaction_started && !$transaction_committed) {
                $wpdb->query('ROLLBACK');
                clean_user_cache($user_id);
                wp_cache_delete($user_id, 'user_meta');
            }
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function complete_fan_password_recovery(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID'])
            || ($context['scope'] ?? '') !== 'password_recovery'
            || empty($context['passwordRecovery']['generation'])) {
            return new WP_Error(
                'fan_password_recovery_session_required',
                '请先使用密码恢复凭据登录。',
                array('status' => 403)
            );
        }
        $input = self::password_change_input($request);
        if (is_wp_error($input)) { return $input; }
        $user_id = (int) $context['userID'];
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $failure_check = self::check_failure_limit(
                'fan_recovery_complete_failure',
                (string) $user_id,
                5
            );
            if (is_wp_error($failure_check)) { return $failure_check; }
            $recovery = self::normalize_fan_password_recovery(
                self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null)
            );
            if (is_wp_error($recovery)
                || !hash_equals(
                    (string) $context['passwordRecovery']['generation'],
                    (string) ($recovery['generation'] ?? '')
                )
                || (int) ($recovery['expiresTimestamp'] ?? 0) <= time()) {
                return new WP_Error(
                    'fan_password_recovery_expired',
                    '密码恢复凭据已过期，请联系管理员重新生成。',
                    array('status' => 410)
                );
            }
            if (empty($recovery['claimedSessionID'])
                || empty($recovery['claimedInstallHash'])
                || empty($recovery['claimNonce'])
                || !hash_equals(
                    (string) $recovery['claimedSessionID'],
                    (string) ($context['sessionID'] ?? '')
                )
                || !hash_equals(
                    (string) $recovery['claimedInstallHash'],
                    (string) ($context['installHash'] ?? '')
                )
                || !self::fan_session_context_is_current_from_database(
                    $context,
                    'password_recovery'
                )) {
                return new WP_Error(
                    'fan_password_recovery_session_required',
                    '密码恢复会话已失效，请使用当前恢复凭据重新登录。',
                    array('status' => 403)
                );
            }
            if (!self::fan_password_matches_database($user_id, $input['currentPassword'])) {
                $failure = self::record_failure(
                    'fan_recovery_complete_failure',
                    (string) $user_id,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error('fan_login_invalid', '当前临时密码不正确。', array('status' => 401));
            }
            self::clear_failure_limit('fan_recovery_complete_failure', (string) $user_id);
            $changed = self::commit_fan_password_change(
                $user_id,
                $input['currentPassword'],
                $input['newPassword'],
                (string) $recovery['generation']
            );
            if (is_wp_error($changed)) { return $changed; }
            self::revoke_all_fan_sessions($user_id);
            $session = self::issue_fan_session($user_id, $input['installID'], 'normal');
            if (is_wp_error($session)) { return $session; }
            return self::fan_auth_response($user_id, $session);
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function change_fan_password(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID'])
            || ($context['scope'] ?? '') !== 'normal') {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $network_limit = self::rate_limit(
            'fan_password_change_net',
            self::request_network_fingerprint(),
            20,
            15 * MINUTE_IN_SECONDS
        );
        if (is_wp_error($network_limit)) { return $network_limit; }
        $input = self::password_change_input($request);
        if (is_wp_error($input)) { return $input; }
        $user_id = (int) $context['userID'];
        if (self::fan_account_source($user_id) === 'apple') {
            return new WP_Error(
                'fan_password_change_not_supported',
                'Apple 账号不使用 App 密码。',
                array('status' => 409)
            );
        }
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $failure_check = self::check_failure_limit(
                'fan_password_change_failure',
                (string) $user_id,
                5
            );
            if (is_wp_error($failure_check)) { return $failure_check; }
            if (!empty(self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null))
                || !empty(self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null))) {
                return new WP_Error(
                    'fan_normal_session_required',
                    '请先完成账号安全设置。',
                    array('status' => 403)
                );
            }
            if (!self::fan_password_matches_database($user_id, $input['currentPassword'])) {
                $failure = self::record_failure(
                    'fan_password_change_failure',
                    (string) $user_id,
                    15 * MINUTE_IN_SECONDS
                );
                if (is_wp_error($failure)) { return $failure; }
                return new WP_Error('fan_login_invalid', '当前密码不正确。', array('status' => 401));
            }
            self::clear_failure_limit('fan_password_change_failure', (string) $user_id);
            $changed = self::commit_fan_password_change(
                $user_id,
                $input['currentPassword'],
                $input['newPassword']
            );
            if (is_wp_error($changed)) { return $changed; }
            self::revoke_all_fan_sessions($user_id);
            $session = self::issue_fan_session($user_id, $input['installID'], 'normal');
            if (is_wp_error($session)) { return $session; }
            return self::fan_auth_response($user_id, $session);
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function list_fan_sessions() {
        $context = self::$fan_session_context;
        if (!is_array($context) || empty($context['userID']) || empty($context['tokenHash'])) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $user_id = (int) $context['userID'];
        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $sessions = self::fan_session_directory(
                $user_id,
                (string) $context['tokenHash']
            );
            if (is_wp_error($sessions)) { return $sessions; }
            $response = rest_ensure_response(array('sessions' => $sessions));
            $response->header('Cache-Control', 'private, no-store');
            return $response;
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function revoke_other_fan_session(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        $session_id = strtolower(trim((string) $request->get_param('sessionID')));
        if (!is_array($context) || empty($context['userID']) || empty($context['tokenHash'])) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        if (!preg_match('/^[a-f0-9]{32}$/', $session_id)) {
            return new WP_Error('fan_session_target_invalid', '会话记录无效。', array('status' => 400));
        }
        $user_id = (int) $context['userID'];
        $current_id = isset($context['sessionID'])
            && preg_match('/^[a-f0-9]{32}$/', (string) $context['sessionID'])
            ? (string) $context['sessionID']
            : self::fan_public_session_id((string) $context['tokenHash']);
        if (hash_equals($current_id, $session_id)) {
            return new WP_Error(
                'fan_current_session_cannot_be_revoked',
                '当前设备请使用退出登录。',
                array('status' => 409)
            );
        }
        $limit = self::rate_limit(
            'fan_session_revoke',
            $user_id . '|' . self::request_network_fingerprint(),
            30,
            HOUR_IN_SECONDS
        );
        if (is_wp_error($limit)) { return $limit; }

        $lock_owner = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_owner)) { return $lock_owner; }
        try {
            $sessions = get_user_meta($user_id, self::FAN_META_SESSIONS, true);
            $sessions = is_array($sessions) ? $sessions : array();
            $target_hash = '';
            foreach ($sessions as $session) {
                if (!is_array($session) || empty($session['hash'])) { continue; }
                $hash = strtolower((string) $session['hash']);
                if (!preg_match('/^[a-f0-9]{64}$/', $hash)) { continue; }
                $public_id = isset($session['sessionID'])
                    && preg_match('/^[a-f0-9]{32}$/', (string) $session['sessionID'])
                    ? (string) $session['sessionID']
                    : self::fan_public_session_id($hash);
                if (hash_equals($public_id, $session_id)) {
                    $target_hash = $hash;
                    break;
                }
            }
            if (!$target_hash) {
                return new WP_Error('fan_session_target_not_found', '会话已失效或不存在。', array('status' => 404));
            }
            self::revoke_fan_session($user_id, $target_hash);
            $directory = self::fan_session_directory(
                $user_id,
                (string) $context['tokenHash']
            );
            if (is_wp_error($directory)) { return $directory; }
            $response = rest_ensure_response(array('ok' => true, 'sessions' => $directory));
            $response->header('Cache-Control', 'private, no-store');
            return $response;
        } finally {
            self::release_fan_lock($user_id, $lock_owner);
        }
    }

    public static function list_fans(WP_REST_Request $request) {
        $search = sanitize_text_field((string) $request->get_param('search'));
        if (self::text_length($search) > 80) {
            return new WP_Error(
                'fan_search_invalid',
                '搜索内容不能超过 80 个字符。',
                array('status' => 400)
            );
        }
        $raw_page = filter_var($request->get_param('page'), FILTER_VALIDATE_INT);
        $raw_per_page = filter_var($request->get_param('perPage'), FILTER_VALIDATE_INT);
        $page = $raw_page !== false && $raw_page >= 1 ? min(10000, (int) $raw_page) : 1;
        $per_page = $raw_per_page !== false && $raw_per_page >= 1
            ? min(100, (int) $raw_per_page)
            : 100;
        $query = array(
            'number' => $per_page + 1,
            'offset' => ($page - 1) * $per_page,
            'orderby' => 'registered',
            'order' => 'DESC',
            'fields' => 'all',
            'meta_key' => self::FAN_META_UUID,
        );
        if ($search !== '') {
            global $wpdb;
            if (!isset($wpdb->users, $wpdb->usermeta)
                || !method_exists($wpdb, 'prepare')
                || !method_exists($wpdb, 'esc_like')
                || !method_exists($wpdb, 'get_col')) {
                return new WP_Error(
                    'fan_list_unavailable',
                    '用户列表暂时不可用，请稍后重试。',
                    array('status' => 503)
                );
            }
            $conditions = array('u.display_name LIKE %s');
            $arguments = array(
                self::FAN_META_UUID,
                '%' . $wpdb->esc_like($search) . '%',
            );
            $identity = self::normalize_identity_code($search);
            if ($identity !== '') {
                $conditions[] = 'EXISTS (
                    SELECT 1 FROM ' . $wpdb->usermeta . ' identity_meta
                    WHERE identity_meta.user_id = u.ID
                      AND identity_meta.meta_key = %s
                      AND identity_meta.meta_value = %s
                )';
                $arguments[] = self::FAN_META_CODE;
                $arguments[] = $identity;
            }
            $douyin = self::normalize_douyin_id($search);
            if ($douyin !== '') {
                $conditions[] = 'EXISTS (
                    SELECT 1 FROM ' . $wpdb->usermeta . ' douyin_meta
                    WHERE douyin_meta.user_id = u.ID
                      AND douyin_meta.meta_key = %s
                      AND douyin_meta.meta_value = %s
                )';
                $arguments[] = self::FAN_META_DOUYIN_ID;
                $arguments[] = $douyin;
            }
            $arguments[] = $per_page + 1;
            $arguments[] = ($page - 1) * $per_page;
            $sql = 'SELECT u.ID FROM ' . $wpdb->users . ' u
                WHERE EXISTS (
                    SELECT 1 FROM ' . $wpdb->usermeta . ' fan_meta
                    WHERE fan_meta.user_id = u.ID AND fan_meta.meta_key = %s
                )
                AND (' . implode(' OR ', $conditions) . ')
                ORDER BY u.user_registered DESC, u.ID DESC
                LIMIT %d OFFSET %d';
            $ids = $wpdb->get_col($wpdb->prepare($sql, $arguments));
            if (!is_array($ids) || !empty($wpdb->last_error)) {
                return new WP_Error(
                    'fan_list_unavailable',
                    '用户列表暂时不可用，请稍后重试。',
                    array('status' => 503)
                );
            }
            $users = array_values(array_filter(array_map('get_userdata', $ids)));
        } else {
            $users = get_users($query);
        }
        $result = array();
        $seen = array();
        foreach ($users as $user) {
            if (!$user instanceof WP_User || isset($seen[(int) $user->ID])) { continue; }
            $profile = self::fan_admin_profile($user);
            $seen[(int) $user->ID] = true;
            $result[] = $profile;
        }
        $has_more = count($result) > $per_page;
        $result = array_slice($result, 0, $per_page);
        $response = rest_ensure_response(array(
            'users' => $result,
            'permissionCatalog' => self::permission_catalog(),
            'page' => $page,
            'perPage' => $per_page,
            'hasMore' => $has_more,
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function update_fan_access(WP_REST_Request $request) {
        $uuid = strtolower((string) $request['uuid']);
        if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $uuid)) {
            return new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
        }
        $users = get_users(array(
            'number' => 2,
            'fields' => 'all',
            'meta_key' => self::FAN_META_UUID,
            'meta_value' => $uuid,
        ));
        if (count($users) !== 1 || !$users[0] instanceof WP_User) {
            return new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
        }
        $user = $users[0];
        $lock_owner = self::acquire_fan_lock((int) $user->ID);
        if (is_wp_error($lock_owner)) { return $lock_owner; }

        try {
            $permissions = null;
            $status = null;
            if ($request->has_param('permissions')) {
                $permissions = self::sanitize_fan_permissions($request->get_param('permissions'));
                if (is_wp_error($permissions)) { return $permissions; }
            }
            if ($request->has_param('status')) {
                $status = sanitize_key((string) $request->get_param('status'));
                if (!in_array($status, array('pending', 'active', 'rejected', 'suspended'), true)) {
                    return new WP_Error('fan_status_invalid', '账号状态无效。', array('status' => 400));
                }
            }
            if ($status === 'active'
                && !empty(get_user_meta((int) $user->ID, self::FAN_META_INVITATION, true))) {
                return new WP_Error(
                    'fan_account_setup_required',
                    '用户必须先使用临时密码完成昵称、新密码和隐私同意设置。',
                    array('status' => 409)
                );
            }
            if ($status === 'active') {
                $apple_setup = get_user_meta((int) $user->ID, self::FAN_META_APPLE_SETUP, true);
                $source = self::fan_account_source((int) $user->ID);
                $stored_douyin_id = (string) get_user_meta(
                    (int) $user->ID,
                    self::FAN_META_DOUYIN_ID,
                    true
                );
                $normalized_douyin_id = self::normalize_required_douyin_id($stored_douyin_id);
                $douyin_id_is_valid = !is_wp_error($normalized_douyin_id)
                    && $normalized_douyin_id === $stored_douyin_id;
                $consent = get_user_meta((int) $user->ID, self::FAN_META_CONSENT, true);
                if (!empty($apple_setup)
                    || !$douyin_id_is_valid
                    || ($source === 'apple'
                        && !self::fan_stored_consent_is_accepted($consent))) {
                    return new WP_Error(
                        'fan_account_setup_required',
                        '用户必须先完成昵称、抖音 ID 和隐私同意设置。',
                        array('status' => 409)
                    );
                }
            }
            if (is_array($permissions)) {
                if (!self::update_user_meta_verified($user->ID, self::FAN_META_PERMISSIONS, $permissions)) {
                    return new WP_Error('fan_update_failed', '暂时无法更新用户权限。', array('status' => 503));
                }
            }
            if ($status !== null) {
                $previous_status = (string) get_user_meta($user->ID, self::FAN_META_STATUS, true);
                if (!self::update_user_meta_verified($user->ID, self::FAN_META_STATUS, $status)) {
                    return new WP_Error('fan_update_failed', '暂时无法更新用户状态。', array('status' => 503));
                }
                if ($status !== $previous_status) {
                    update_user_meta($user->ID, self::FAN_META_REVIEW, array(
                        'status' => $status,
                        'reviewedAt' => gmdate('c'),
                        'reviewedBy' => get_current_user_id(),
                    ));
                }
                if ($status !== $previous_status && in_array($status, array('rejected', 'suspended'), true)) {
                    $epoch = self::advance_fan_credential_epoch((int) $user->ID);
                    self::revoke_all_fan_sessions((int) $user->ID);
                    if (is_wp_error($epoch)) { return $epoch; }
                }
            }
            $response = rest_ensure_response(array('user' => self::fan_admin_profile($user)));
            $response->header('Cache-Control', 'private, no-store');
            return $response;
        } finally {
            self::release_fan_lock((int) $user->ID, $lock_owner);
        }
    }

    private static function administrator_actor_has_full_app_capabilities($user) {
        if (!$user instanceof WP_User) { return false; }
        $required = array(self::CAPABILITY, self::FAN_CAPABILITY, self::PUSH_CAPABILITY);
        if (self::collaboration_phase1_enabled()) { $required[] = self::COLLABORATION_CAPABILITY; }
        foreach ($required as $capability) {
            if (!user_can($user, $capability)) { return false; }
        }
        return true;
    }

    public static function can_manage_fan_administrators(WP_REST_Request $request) {
        $access = self::can_manage_fans($request);
        if ($access !== true) { return $access; }
        return self::account_authority_enabled()
            && self::administrator_actor_has_full_app_capabilities(wp_get_current_user());
    }

    // This changes only the App role, never arbitrary WordPress roles/caps.
    // The shared actor/target locks also serialize against account suspension,
    // deletion and password recovery. A stale UI must reload before overwriting.
    public static function update_fan_administrator(WP_REST_Request $request) {
        global $wpdb;
        if (!self::account_authority_enabled()
            || !self::authenticate_manager_for_capability($request, self::FAN_CAPABILITY)
            || !self::administrator_actor_has_full_app_capabilities(wp_get_current_user())) {
            return new WP_Error('fan_admin_forbidden', '只有完整的 App 管理员可以分配管理员身份。', array('status' => 403));
        }
        $actor_id = get_current_user_id();
        $desired = $request->get_param('administrator');
        $expected = $request->get_param('expectedAdministrator');
        $expected_revision = $request->get_param('expectedRevision');
        if (!is_bool($desired) || !is_bool($expected) || !is_int($expected_revision) || $expected_revision < 0) {
            return new WP_Error('fan_admin_input_invalid', '请明确选择管理员身份并刷新当前状态。', array('status' => 400));
        }
        $uuid = $request->get_url_params()['uuid'] ?? null;
        if (!is_string($uuid) || !preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $uuid)) {
            return new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
        }
        $users = get_users(array('number' => 2, 'fields' => 'all',
            'meta_key' => self::FAN_META_UUID, 'meta_value' => $uuid));
        if (count($users) !== 1 || !$users[0] instanceof WP_User) {
            return new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
        }
        $target_id = (int) $users[0]->ID;
        if ($target_id === $actor_id) {
            return new WP_Error('fan_admin_self_change', '请由另一位管理员修改你的管理员身份。', array('status' => 409));
        }
        $locks = array();
        $transaction = false;
        $committed = false;
        $failure = new WP_Error('fan_admin_update_failed', '管理员身份暂时无法更新，请刷新后重试。', array('status' => 503));
        try {
            $lock_ids = array(0, $actor_id, $target_id);
            sort($lock_ids, SORT_NUMERIC);
            foreach ($lock_ids as $lock_id) {
                $owner = self::acquire_fan_lock($lock_id);
                if (is_wp_error($owner)) { return $owner; }
                $locks[$lock_id] = $owner;
            }
            // Discard request-local and persistent WP caches after acquiring
            // the locks; a revoked actor must not reuse its earlier WP_User.
            clean_user_cache($actor_id);
            clean_user_cache($target_id);
            wp_set_current_user(0);
            // A legacy cookie was already authenticated by WordPress before
            // entry. Preserve that identity, but reload its current caps.
            if (trim((string) $request->get_header('authorization')) === '') {
                wp_set_current_user($actor_id);
            }
            if (!self::account_authority_enabled()
                || !self::authenticate_manager_for_capability($request, self::FAN_CAPABILITY)
                || get_current_user_id() !== $actor_id
                || !self::administrator_actor_has_full_app_capabilities(wp_get_current_user())) {
                return new WP_Error('fan_admin_forbidden', '管理员身份已变更，请重新登录。', array('status' => 403));
            }
            $target = get_userdata($target_id);
            if (!$target instanceof WP_User
                || get_user_meta($target_id, self::FAN_META_UUID, true) !== $uuid) { return $failure; }
            if ($desired && ((string) get_user_meta($target_id, self::FAN_META_STATUS, true) !== 'active'
                || !self::fan_has_required_douyin_id($target_id)
                || !empty(get_user_meta($target_id, self::FAN_META_INVITATION, true))
                || !empty(get_user_meta($target_id, self::FAN_META_PASSWORD_RECOVERY, true))
                || !empty(get_user_meta($target_id, self::FAN_META_APPLE_SETUP, true))
                || (self::fan_account_source($target_id) === 'apple'
                    && !self::fan_stored_consent_is_accepted(get_user_meta($target_id, self::FAN_META_CONSENT, true))))) {
                return new WP_Error('fan_admin_setup_required', '只能为已完成资料并审批通过的用户授予管理员身份。', array('status' => 409));
            }
            // Never silently grant site-wide powers if another plugin changed
            // the shared App role. Revocation remains possible in that case.
            if ($desired) {
                $role = get_role(self::ROLE);
                $allowed = array('read', 'upload_files', self::CAPABILITY, self::FAN_CAPABILITY,
                    self::PUSH_CAPABILITY, self::COLLABORATION_CAPABILITY);
                if (!$role || array_diff(array_keys($role->capabilities), $allowed)) { return $failure; }
                foreach (array('read', 'upload_files', self::CAPABILITY, self::FAN_CAPABILITY, self::PUSH_CAPABILITY) as $cap) {
                    if (!$role->has_cap($cap)) { return $failure; }
                }
                if (self::collaboration_phase1_enabled() && !$role->has_cap(self::COLLABORATION_CAPABILITY)) { return $failure; }
            }
            $engines = $wpdb->get_col($wpdb->prepare(
                'SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s, %s)',
                $wpdb->users, $wpdb->usermeta
            ));
            if (!is_array($engines) || count($engines) !== 2 || array_filter($engines, function ($engine) { return strtoupper((string) $engine) !== 'INNODB'; })
                || $wpdb->query('START TRANSACTION') === false) { return $failure; }
            $transaction = true;
            $cap_key = $wpdb->get_blog_prefix() . 'capabilities';
            foreach (array($cap_key, self::FAN_META_ADMIN_BINDING_AUDIT, self::FAN_META_ADMIN_BINDING_REVISION) as $meta_key) {
                $rows = $wpdb->get_results($wpdb->prepare(
                    "SELECT umeta_id FROM {$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s FOR UPDATE",
                    $target_id, $meta_key
                ));
                if (!is_array($rows) || count($rows) > 1 || !empty($wpdb->last_error)) { return $failure; }
            }
            $caps = self::fan_meta_from_database($target_id, $cap_key, array(), true);
            if (!is_array($caps) || !empty($wpdb->last_error)) { return $failure; }
            $previous = array_key_exists(self::ROLE, $caps);
            $stored_revision = self::fan_meta_from_database($target_id, self::FAN_META_ADMIN_BINDING_REVISION, 0, true);
            $revision = filter_var($stored_revision, FILTER_VALIDATE_INT, array('options' => array('min_range' => 0)));
            if ((!is_int($stored_revision) && !is_string($stored_revision)) || $revision === false || !empty($wpdb->last_error)) { return $failure; }
            if ($previous !== $expected || $revision !== $expected_revision) {
                return new WP_Error('fan_admin_conflict', '管理员身份已被其他操作修改，请刷新后重试。', array('status' => 409));
            }
            if ($desired && array_diff(array_keys($caps), array('subscriber', self::ROLE))) {
                return new WP_Error('fan_admin_role_conflict', '该用户存在独立的网站权限，请先核对账号。', array('status' => 409));
            }
            if ($previous !== $desired) {
                if ($revision >= PHP_INT_MAX) { return $failure; }
                ++$revision;
                if ($desired) { $caps[self::ROLE] = true; } else { unset($caps[self::ROLE]); }
                $audit = self::fan_meta_from_database($target_id, self::FAN_META_ADMIN_BINDING_AUDIT, array(), true);
                if (!is_array($audit) || !empty($wpdb->last_error)) { return $failure; }
                $audit[] = array('administrator' => $desired, 'previousAdministrator' => $previous,
                    'actorID' => $actor_id, 'revision' => $revision, 'at' => gmdate('c'));
                // Update the role and its bounded audit atomically, without
                // exposing an uncommitted role via WordPress object caching.
                if (!self::set_fan_meta_in_transaction($target_id, $cap_key, $caps)
                    || !self::set_fan_meta_in_transaction($target_id, self::FAN_META_ADMIN_BINDING_AUDIT, array_slice($audit, -50))
                    || !self::set_fan_meta_in_transaction($target_id, self::FAN_META_ADMIN_BINDING_REVISION, $revision)) { return $failure; }
            }
            if ($wpdb->query('COMMIT') === false) { return $failure; }
            $committed = true;
            clean_user_cache($target_id);
            $fresh = get_userdata($target_id);
            if (!$fresh instanceof WP_User || in_array(self::ROLE, (array) $fresh->roles, true) !== $desired) { return $failure; }
            $response = rest_ensure_response(array('user' => self::fan_admin_profile($fresh)));
            $response->header('Cache-Control', 'private, no-store');
            return $response;
        } finally {
            if ($transaction && !$committed) { $wpdb->query('ROLLBACK'); }
            clean_user_cache($target_id);
            foreach (array_reverse($locks, true) as $lock_id => $owner) {
                self::release_fan_lock($lock_id, $owner);
            }
        }
    }

    private static function authenticate_content_manager($request) {
        return self::authenticate_manager_for_capability($request, self::CAPABILITY);
    }

    private static function authenticate_manager_for_capability($request, $capability) {
        if ($request instanceof WP_REST_Request
            && preg_match('/^Bearer(?:\\s|$)/i', trim((string) $request->get_header('authorization')))) {
            // Authenticate the installed App session before checking roles,
            // even if another callback already populated the WP current user.
            // This path never accepts a role or target identity from the client.
            $access = self::can_access_approved_fan_content($request);
            if ($access !== true) {
                self::$fan_session_context = null;
                wp_set_current_user(0);
                return false;
            }
            $user = get_userdata((int) self::$fan_session_context['userID']);
            return $user instanceof WP_User
                && in_array(self::ROLE, (array) $user->roles, true)
                && in_array($capability, array(
                    self::CAPABILITY, self::FAN_CAPABILITY,
                    self::PUSH_CAPABILITY, self::COLLABORATION_CAPABILITY,
                ), true)
                && user_can($user, $capability);
        }
        // A fan account must use its installation-bound App session, even if
        // it also has a WP cookie or Application Password. Otherwise those
        // older credentials could bypass approval/setup/session revocation.
        if ((!$request instanceof WP_REST_Request
                || trim((string) $request->get_header('authorization')) === '')
            && self::legacy_manager_user_is_allowed(wp_get_current_user(), $capability)) {
            return true;
        }
        if (!$request instanceof WP_REST_Request) { return false; }

        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Basic\\s+([A-Za-z0-9+\\/=]{8,4096})$/', $authorization, $matches)) {
            return false;
        }
        $decoded = base64_decode($matches[1], true);
        if ($decoded === false || strlen($decoded) > 4096 || strpos($decoded, ':') === false) {
            return false;
        }
        list($username, $password) = explode(':', $decoded, 2);
        if (!$username || !$password || strlen($username) > 120 || strlen($password) > 256) {
            return false;
        }
        // A security plugin disables Application Passwords globally. Enable
        // verification only for this capability-scoped check, then immediately
        // restore the site's global policy.
        add_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        $user = wp_authenticate_application_password(null, $username, $password);
        remove_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        if (!self::legacy_manager_user_is_allowed($user, $capability)) {
            return false;
        }
        wp_set_current_user($user->ID);
        return true;
    }

    private static function legacy_manager_user_is_allowed($user, $capability) {
        return $user instanceof WP_User
            && !get_user_meta((int) $user->ID, self::FAN_META_UUID, true)
            && user_can($user, $capability);
    }

}
