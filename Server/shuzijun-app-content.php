<?php
/**
 * Plugin Name: Shuzijun App Content API
 * Description: Versioned access-controlled content feed and least-privilege mobile publishing API for the Yi Shu app.
 * Version: 1.5.7
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

final class Shuzijun_App_Content_API {
    const OPTION_CONFIG = 'shuzijun_app_content_config';
    const OPTION_UPDATED = 'shuzijun_app_content_updated_at';
    const CAPABILITY = 'manage_yishu_app_content';
    const FAN_CAPABILITY = 'manage_yishu_fan_accounts';
    const ROLE = 'yishu_content_manager';
    const FREE_PREVIEW_COUNT = 3;
    const FULL_GALLERY_FOR_APP = true;
    const FAN_META_UUID = '_yishu_fan_uuid';
    const FAN_META_CODE = '_yishu_fan_identity_code';
    const FAN_META_DOUYIN_ID = '_yishu_fan_douyin_id';
    const FAN_META_PERMISSIONS = '_yishu_fan_permissions';
    const FAN_META_STATUS = '_yishu_fan_status';
    const FAN_META_CONSENT = '_yishu_fan_consent';
    const FAN_META_INSTALLATIONS = '_yishu_fan_installations';
    const FAN_META_SESSIONS = '_yishu_fan_sessions';
    const FAN_META_REVIEW = '_yishu_fan_review';
    const FAN_META_INVITATION = '_yishu_fan_invitation';
    const FAN_META_PASSWORD_RECOVERY = '_yishu_fan_password_recovery';
    const FAN_META_CREDENTIAL_EPOCH = '_yishu_fan_credential_epoch';
    const FAN_CONSENT_VERSION = '2026-08-31-approval-v2';
    const FAN_DOUYIN_OPTION_PREFIX = 'yishu_fan_douyin_';
    const FAN_SESSION_OPTION_PREFIX = 'yishu_fan_session_';
    const FAN_SESSION_TTL = 2592000;
    const FAN_ONBOARDING_SESSION_TTL = 600;
    const FAN_PASSWORD_RECOVERY_SESSION_TTL = 600;
    const FAN_PASSWORD_RECOVERY_TTL = 900;
    const FAN_INVITATION_TTL = 86400;
    const FAN_MAX_INSTALLATIONS = 16;
    const FAN_MAX_SESSIONS = 8;
    private static $fan_session_context = null;

    public static function init() {
        add_action('init', array(__CLASS__, 'ensure_roles'), 20);
        add_action('rest_api_init', array(__CLASS__, 'register_routes'));
        add_action('save_post_portfolio', array(__CLASS__, 'portfolio_changed'), 20, 3);
        add_action('template_redirect', array(__CLASS__, 'block_public_portfolio_pages'), 1);
        add_action('pre_get_posts', array(__CLASS__, 'hide_public_portfolio_queries'));
        add_action('wp_head', array(__CLASS__, 'hide_public_portfolio_section'));
        add_action('yishu_cleanup_fan_session', array(__CLASS__, 'cleanup_fan_session'), 10, 2);
        add_action('yishu_cleanup_fan_invitation', array(__CLASS__, 'cleanup_fan_invitation'), 10, 4);
        add_action('delete_user', array(__CLASS__, 'prepare_fan_user_deletion'), 10, 1);
        add_filter('rest_post_dispatch', array(__CLASS__, 'secure_rest_response'), 10, 3);
        add_filter('rest_pre_dispatch', array(__CLASS__, 'block_public_catalog_routes'), 10, 3);
        add_filter('wp_sitemaps_post_types', array(__CLASS__, 'remove_portfolios_from_sitemaps'));
        add_filter('theme_mod_hero_cta', array(__CLASS__, 'public_hero_cta'));
        add_filter('theme_mod_hero_cta_link', array(__CLASS__, 'public_hero_cta_link'));
        add_filter('wp_authenticate_user', array(__CLASS__, 'block_fan_wordpress_login'), 99, 2);

        // Application Passwords are revocable, per-client credentials intended
        // for HTTPS REST clients. Keep the site's global disable policy and
        // restrict the dedicated content credential to this plugin's routes.
        add_filter('wp_is_application_passwords_available_for_user', array(__CLASS__, 'application_passwords_for_user'), 20, 2);
    }

    public static function ensure_roles() {
        $role = get_role(self::ROLE);
        if (!$role) {
            add_role(self::ROLE, '易姝 App 内容管理员', array(
                'read' => true,
                'upload_files' => true,
                self::CAPABILITY => true,
                self::FAN_CAPABILITY => true,
            ));
            $role = get_role(self::ROLE);
        }
        if ($role) {
            if (!$role->has_cap('read')) { $role->add_cap('read', true); }
            if (!$role->has_cap('upload_files')) { $role->add_cap('upload_files', true); }
            if (!$role->has_cap(self::CAPABILITY)) { $role->add_cap(self::CAPABILITY, true); }
            if (!$role->has_cap(self::FAN_CAPABILITY)) { $role->add_cap(self::FAN_CAPABILITY, true); }
        }
        $administrator = get_role('administrator');
        if ($administrator && !$administrator->has_cap(self::CAPABILITY)) {
            $administrator->add_cap(self::CAPABILITY, true);
        }
        if ($administrator && !$administrator->has_cap(self::FAN_CAPABILITY)) {
            $administrator->add_cap(self::FAN_CAPABILITY, true);
        }
    }

    public static function application_passwords_for_user($available, $user) {
        return $user instanceof WP_User
            && (user_can($user, self::CAPABILITY) || user_can($user, self::FAN_CAPABILITY));
    }

    public static function block_fan_wordpress_login($user, $password = '') {
        if ($user instanceof WP_User
            && !empty(get_user_meta((int) $user->ID, self::FAN_META_UUID, true))) {
            return new WP_Error(
                'fan_wordpress_login_restricted',
                '粉丝账号只能在 App 内登录。',
                array('status' => 403)
            );
        }
        return $user;
    }

    public static function register_routes() {
        register_rest_route('shuzijun/v1', '/app-content', array(
            array(
                'methods' => WP_REST_Server::READABLE,
                'callback' => array(__CLASS__, 'get_content'),
                'permission_callback' => array(__CLASS__, 'can_access_app_content'),
            ),
            array(
                'methods' => WP_REST_Server::EDITABLE,
                'callback' => array(__CLASS__, 'update_content'),
                'permission_callback' => array(__CLASS__, 'can_manage'),
            ),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/session', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'session'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));

        register_rest_route('shuzijun/v1', '/fan/register', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'register_fan'),
            'permission_callback' => '__return_true',
        ));

        register_rest_route('shuzijun/v1', '/fan/login', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'login_fan'),
            'permission_callback' => '__return_true',
        ));

        register_rest_route('shuzijun/v1', '/fan/session', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'fan_session'),
            'permission_callback' => array(__CLASS__, 'can_access_fan_session'),
        ));

        register_rest_route('shuzijun/v1', '/fan/logout', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'logout_fan'),
            'permission_callback' => array(__CLASS__, 'can_access_fan_session'),
        ));

        register_rest_route('shuzijun/v1', '/fan/delete', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'delete_fan_account'),
            'permission_callback' => array(__CLASS__, 'can_delete_fan_account'),
        ));

        register_rest_route('shuzijun/v1', '/fan/complete-invitation', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'complete_fan_invitation'),
            'permission_callback' => array(__CLASS__, 'can_complete_fan_invitation'),
        ));

        register_rest_route('shuzijun/v1', '/fan/complete-password-recovery', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'complete_fan_password_recovery'),
            'permission_callback' => array(__CLASS__, 'can_complete_fan_password_recovery'),
        ));

        register_rest_route('shuzijun/v1', '/fan/change-password', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'change_fan_password'),
            'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session'),
        ));

        register_rest_route('shuzijun/v1', '/fan/sessions', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'list_fan_sessions'),
            'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session'),
        ));

        register_rest_route('shuzijun/v1', '/fan/sessions/revoke', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'revoke_other_fan_session'),
            'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session'),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/fans', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'list_fans'),
            'permission_callback' => array(__CLASS__, 'can_manage_fans'),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/fans/invitations', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_fan_invitations'),
            'permission_callback' => array(__CLASS__, 'can_manage_fans'),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/fans/(?P<uuid>[a-f0-9-]{36})/password-recovery', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_fan_password_recovery'),
            'permission_callback' => array(__CLASS__, 'can_manage_fans'),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/fans/(?P<uuid>[a-f0-9-]{36})', array(
            'methods' => WP_REST_Server::EDITABLE,
            'callback' => array(__CLASS__, 'update_fan_access'),
            'permission_callback' => array(__CLASS__, 'can_manage_fans'),
        ));

        register_rest_route('shuzijun/v1', '/app-content/premium', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'get_premium_content'),
            'permission_callback' => array(__CLASS__, 'can_access_premium'),
        ));

        register_rest_route('shuzijun/v1', '/app-content/portfolio/(?P<id>\d+)/gallery', array(
            'methods' => WP_REST_Server::EDITABLE,
            'callback' => array(__CLASS__, 'update_gallery'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
            'args' => array(
                'id' => array('required' => true, 'sanitize_callback' => 'absint'),
            ),
        ));

        register_rest_route('shuzijun/v1', '/app-content/portfolio', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_portfolio'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
    }

    public static function can_manage($request = null) {
        return self::can_manage_capability($request, self::CAPABILITY, 'yishu_app_rate_');
    }

    public static function can_manage_fans($request = null) {
        return self::can_manage_capability($request, self::FAN_CAPABILITY, 'yishu_fan_admin_rate_');
    }

    private static function can_manage_capability($request, $capability, $rate_prefix) {
        if (!self::authenticate_manager_for_capability($request, $capability)) { return false; }
        if (!$request instanceof WP_REST_Request || $request->get_method() === 'GET') { return true; }

        // Bound authenticated mutation bursts by WordPress user, not by a
        // spoofable forwarding IP. Normal app publishing is far below this.
        $key = (string) $rate_prefix . get_current_user_id();
        $count = (int) get_transient($key);
        if ($count >= 120) {
            return new WP_Error(
                'yishu_rate_limited',
                '操作过于频繁，请稍后再试。',
                array('status' => 429)
            );
        }
        set_transient($key, $count + 1, MINUTE_IN_SECONDS);
        return true;
    }

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
        $douyin_id = self::normalize_douyin_id($request->get_param('douyinID'));
        $password = (string) $request->get_param('password');
        if ((string) $request->get_param('consentVersion') !== self::FAN_CONSENT_VERSION) {
            return new WP_Error('fan_consent_required', '请先阅读并确认账号资料的使用说明。', array('status' => 400));
        }
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        $password_error = self::validate_fan_password($password);
        if (is_wp_error($password_error)) { return $password_error; }
        if (!$douyin_id || self::is_invitation_douyin_id($douyin_id)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '请填写 2–50 位的抖音 ID，不要填链接。',
                array('status' => 400)
            );
        }
        $douyin_users = get_users(array(
            'number' => 1,
            'fields' => 'ids',
            'meta_key' => self::FAN_META_DOUYIN_ID,
            'meta_value' => $douyin_id,
        ));
        if ($douyin_users) {
            return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
        }

        $identity_code = self::generate_unique_identity_code();
        if (is_wp_error($identity_code)) { return $identity_code; }
        $douyin_reservation = self::FAN_DOUYIN_OPTION_PREFIX . hash('sha256', $douyin_id);
        if (!add_option($douyin_reservation, 'pending', '', false)) {
            return new WP_Error('fan_douyin_id_exists', '该抖音 ID 已登记，请直接登录或联系管理员。', array('status' => 409));
        }
        try {
            $login = 'fan_' . bin2hex(random_bytes(16));
        } catch (Exception $error) {
            delete_option($douyin_reservation);
            return new WP_Error('fan_registration_unavailable', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }
        $user_id = wp_insert_user(array(
            'user_login' => $login,
            'user_pass' => $password,
            'display_name' => $display_name,
            'role' => 'subscriber',
        ));
        if (is_wp_error($user_id)) {
            delete_option($douyin_reservation);
            return new WP_Error('fan_registration_failed', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }

        $uuid = wp_generate_uuid4();
        $saved = update_user_meta($user_id, self::FAN_META_UUID, $uuid)
            && update_user_meta($user_id, self::FAN_META_CODE, $identity_code)
            && update_user_meta($user_id, self::FAN_META_DOUYIN_ID, $douyin_id)
            && update_user_meta($user_id, self::FAN_META_PERMISSIONS, array('gallery_full', 'video_view'))
            && update_user_meta($user_id, self::FAN_META_STATUS, 'pending')
            && update_user_meta($user_id, self::FAN_META_CREDENTIAL_EPOCH, 1)
            && update_user_meta($user_id, self::FAN_META_CONSENT, array(
                'version' => self::FAN_CONSENT_VERSION,
                'acceptedAt' => gmdate('c'),
            ));
        if (!$saved) {
            self::remove_fan_user((int) $user_id, $douyin_reservation);
            return new WP_Error('fan_registration_failed', '暂时无法完成注册，请稍后重试。', array('status' => 503));
        }
        update_option($douyin_reservation, (int) $user_id, false);

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
            || !empty(self::fan_meta_from_database($user_id, self::FAN_META_PASSWORD_RECOVERY, null))) {
            return new WP_Error(
                'fan_normal_session_required',
                '请先完成账号安全设置。',
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

    public static function can_delete_fan_account(WP_REST_Request $request) {
        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        $scope = (string) ($context['scope'] ?? '');
        $user_id = (int) ($context['userID'] ?? 0);
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
        if (self::authenticate_content_manager($request)) { return true; }

        self::$fan_session_context = null;
        $context = self::authenticate_fan_session($request);
        if (is_wp_error($context)) { return $context; }
        if (($context['scope'] ?? '') !== 'normal'
            || !empty(get_user_meta((int) $context['userID'], self::FAN_META_INVITATION, true))
            || !empty(get_user_meta((int) $context['userID'], self::FAN_META_PASSWORD_RECOVERY, true))) {
            return new WP_Error(
                'fan_account_setup_required',
                '请先完成密码、抖音 ID 和隐私同意设置。',
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
        $response = rest_ensure_response(array(
            'profile' => self::fan_profile((int) $context['userID'], $context),
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function logout_fan() {
        $context = self::$fan_session_context;
        if (is_array($context) && !empty($context['tokenHash'])) {
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
        $douyin_id = self::normalize_douyin_id($request->get_param('douyinID'));
        $current_password = (string) $request->get_param('currentPassword');
        $new_password = (string) $request->get_param('newPassword');
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        if (!$douyin_id || self::is_invitation_douyin_id($douyin_id)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '请填写 2–50 位的真实抖音 ID，不要填链接。',
                array('status' => 400)
            );
        }
        if ((string) $request->get_param('consentVersion') !== self::FAN_CONSENT_VERSION) {
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

            $profile_saved = self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                $douyin_id
            ) && self::set_fan_meta_in_transaction(
                $user_id,
                self::FAN_META_CONSENT,
                array(
                    'version' => self::FAN_CONSENT_VERSION,
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
                        '暂时无法安全保存抖音 ID。',
                        array('status' => 503)
                    );
                }
            }
            if (self::reservation_owner_from_database($placeholder_reservation) === $user_id
                || self::reservation_owner_from_database($real_reservation) !== $user_id) {
                return new WP_Error(
                    'fan_invitation_reservation_failed',
                    '暂时无法安全保存抖音 ID。',
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
        $search = self::text_length($search) > 80 ? '' : $search;
        $users = get_users(array(
            'number' => 100,
            'orderby' => 'registered',
            'order' => 'DESC',
            'fields' => 'all',
            'meta_key' => self::FAN_META_UUID,
        ));
        $result = array();
        $normalized_search = self::normalize_identity_code($search);
        foreach ($users as $user) {
            if (!$user instanceof WP_User) { continue; }
            $profile = self::fan_admin_profile($user);
            if ($search && $normalized_search !== $profile['identityCode']
                && stripos($profile['displayName'], $search) === false
                && stripos($profile['douyinID'], $search) === false) {
                continue;
            }
            $result[] = $profile;
        }
        $response = rest_ensure_response(array(
            'users' => $result,
            'permissionCatalog' => self::permission_catalog(),
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
                    '用户必须先使用临时密码完成密码、抖音 ID 和隐私同意设置。',
                    array('status' => 409)
                );
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

    private static function authenticate_content_manager($request) {
        return self::authenticate_manager_for_capability($request, self::CAPABILITY);
    }

    private static function authenticate_manager_for_capability($request, $capability) {
        if (current_user_can($capability)) { return true; }
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
        if (is_wp_error($user) || !$user instanceof WP_User || !user_can($user, $capability)) {
            return false;
        }
        wp_set_current_user($user->ID);
        return true;
    }

    public static function normalize_identity_code($value) {
        if (!is_scalar($value)) { return ''; }
        $compact = strtoupper((string) preg_replace('/[\s-]+/u', '', trim((string) $value)));
        if (strpos($compact, 'HS') === 0) { $compact = substr($compact, 2); }
        if (!preg_match('/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/', $compact)) { return ''; }
        return 'HS-' . substr($compact, 0, 4) . '-' . substr($compact, 4, 4);
    }

    public static function normalize_douyin_id($value) {
        if (!is_scalar($value)) { return ''; }
        $candidate = sanitize_text_field((string) $value);
        $candidate = ltrim(trim($candidate), '@');
        if (function_exists('mb_strtolower')) {
            $candidate = mb_strtolower($candidate, 'UTF-8');
        } else {
            $candidate = strtolower($candidate);
        }
        if (self::text_length($candidate) < 2 || self::text_length($candidate) > 50
            || !preg_match('/^[\p{L}\p{N}._-]+$/u', $candidate)) {
            return '';
        }
        return $candidate;
    }

    private static function is_invitation_douyin_id($value) {
        return is_string($value) && preg_match('/^invite_[a-f0-9]{24}$/', $value) === 1;
    }

    private static function find_fan_user_by_uuid($value) {
        $uuid = strtolower(trim((string) $value));
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
        return $users[0];
    }

    private static function douyin_reservation_name($douyin_id) {
        return self::FAN_DOUYIN_OPTION_PREFIX . hash('sha256', (string) $douyin_id);
    }

    private static function reservation_owner_from_database($option_name) {
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return 0;
        }
        $value = $wpdb->get_var($wpdb->prepare(
            "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s LIMIT 1",
            (string) $option_name
        ));
        return is_scalar($value) ? (int) maybe_unserialize($value) : 0;
    }

    private static function clear_fan_option_caches($option_names) {
        $option_names = array_values(array_filter(array_map('strval', (array) $option_names)));
        foreach ($option_names as $option_name) {
            wp_cache_delete($option_name, 'options');
        }
        // Invalidate aggregate snapshots instead of read-modify-writing them;
        // replacing a stale snapshot could erase another request's updates.
        wp_cache_delete('notoptions', 'options');
        wp_cache_delete('alloptions', 'options');
    }

    private static function fan_meta_from_database($user_id, $meta_key, $default = '', $for_update = false) {
        global $wpdb;
        if (!isset($wpdb->usermeta) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return $default;
        }
        $locking_clause = $for_update ? ' FOR UPDATE' : '';
        $value = $wpdb->get_var($wpdb->prepare(
            "SELECT meta_value FROM {$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s ORDER BY umeta_id ASC LIMIT 1{$locking_clause}",
            (int) $user_id,
            (string) $meta_key
        ));
        return $value === null ? $default : maybe_unserialize($value);
    }

    private static function set_fan_meta_in_transaction($user_id, $meta_key, $value) {
        global $wpdb;
        $meta_id = (int) $wpdb->get_var($wpdb->prepare(
            "SELECT umeta_id FROM {$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s ORDER BY umeta_id ASC LIMIT 1 FOR UPDATE",
            (int) $user_id,
            (string) $meta_key
        ));
        $serialized = maybe_serialize($value);
        if ($meta_id > 0) {
            $updated = $wpdb->update(
                $wpdb->usermeta,
                array('meta_value' => $serialized),
                array('umeta_id' => $meta_id),
                array('%s'),
                array('%d')
            );
            return $updated !== false;
        }
        return $wpdb->insert(
            $wpdb->usermeta,
            array(
                'user_id' => (int) $user_id,
                'meta_key' => (string) $meta_key,
                'meta_value' => $serialized,
            ),
            array('%d', '%s', '%s')
        ) !== false;
    }

    private static function delete_fan_meta_in_transaction($user_id, $meta_key) {
        global $wpdb;
        $deleted = $wpdb->delete(
            $wpdb->usermeta,
            array('user_id' => (int) $user_id, 'meta_key' => (string) $meta_key),
            array('%d', '%s')
        );
        return $deleted !== false && $deleted > 0;
    }

    private static function fan_password_matches_database($user_id, $password, $for_update = false) {
        global $wpdb;
        if (!isset($wpdb->users) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $locking_clause = $for_update ? ' FOR UPDATE' : '';
        $password_hash = $wpdb->get_var($wpdb->prepare(
            "SELECT user_pass FROM {$wpdb->users} WHERE ID = %d LIMIT 1{$locking_clause}",
            (int) $user_id
        ));
        return is_string($password_hash)
            && $password_hash !== ''
            && wp_check_password((string) $password, $password_hash, (int) $user_id);
    }

    private static function normalize_fan_invitation($value) {
        if (!is_array($value)) {
            return new WP_Error(
                'fan_invitation_unavailable',
                '临时账号信息已失效，请联系管理员。',
                array('status' => 410)
            );
        }
        $created_at = isset($value['createdAt']) && is_scalar($value['createdAt'])
            ? strtotime((string) $value['createdAt'])
            : false;
        $expires_at = isset($value['expiresAt']) && is_scalar($value['expiresAt'])
            ? strtotime((string) $value['expiresAt'])
            : false;
        $created_by = isset($value['createdBy']) ? (int) $value['createdBy'] : 0;
        $generation = isset($value['generation']) ? (string) $value['generation'] : '';
        $placeholder = isset($value['placeholderDouyinID'])
            ? (string) $value['placeholderDouyinID']
            : '';
        if ($created_at === false || $expires_at === false || $created_at <= 0
            || $expires_at <= $created_at || $expires_at - $created_at > self::FAN_INVITATION_TTL
            || $created_by <= 0 || empty($value['preapproved'])
            || !preg_match('/^[a-f0-9]{32}$/', $generation)
            || !self::is_invitation_douyin_id($placeholder)) {
            return new WP_Error(
                'fan_invitation_invalid',
                '临时账号信息无效，请联系管理员。',
                array('status' => 503)
            );
        }
        return array(
            'createdAt' => gmdate('c', $created_at),
            'expiresAt' => gmdate('c', $expires_at),
            'createdTimestamp' => $created_at,
            'expiresTimestamp' => $expires_at,
            'createdBy' => $created_by,
            'generation' => $generation,
            'preapproved' => true,
            'placeholderDouyinID' => $placeholder,
        );
    }

    private static function normalize_fan_password_recovery($value) {
        if (!is_array($value)) {
            return new WP_Error(
                'fan_password_recovery_unavailable',
                '密码恢复凭据已失效，请联系管理员。',
                array('status' => 410)
            );
        }
        $created_at = isset($value['createdAt']) && is_scalar($value['createdAt'])
            ? strtotime((string) $value['createdAt'])
            : false;
        $expires_at = isset($value['expiresAt']) && is_scalar($value['expiresAt'])
            ? strtotime((string) $value['expiresAt'])
            : false;
        $created_by = isset($value['createdBy']) ? (int) $value['createdBy'] : 0;
        $generation = isset($value['generation']) ? (string) $value['generation'] : '';
        $claimed_at = isset($value['claimedAt']) && is_scalar($value['claimedAt'])
            ? strtotime((string) $value['claimedAt'])
            : false;
        $claimed_install_hash = isset($value['claimedInstallHash'])
            ? strtolower((string) $value['claimedInstallHash'])
            : '';
        $claim_nonce = isset($value['claimNonce'])
            ? strtolower((string) $value['claimNonce'])
            : '';
        $claimed_session_id = isset($value['claimedSessionID'])
            ? strtolower((string) $value['claimedSessionID'])
            : '';
        $has_claim = $claimed_at !== false || $claimed_install_hash !== ''
            || $claim_nonce !== '' || $claimed_session_id !== '';
        if ($created_at === false || $expires_at === false || $created_at <= 0
            || $expires_at <= $created_at
            || $expires_at - $created_at > self::FAN_PASSWORD_RECOVERY_TTL
            || $created_by <= 0 || !preg_match('/^[a-f0-9]{32}$/', $generation)
            || ($has_claim && ($claimed_at === false
                || $claimed_at < $created_at || $claimed_at > $expires_at
                || !preg_match('/^[a-f0-9]{64}$/', $claimed_install_hash)
                || !preg_match('/^[a-f0-9]{32}$/', $claim_nonce)
                || ($claimed_session_id !== ''
                    && !preg_match('/^[a-f0-9]{32}$/', $claimed_session_id))))) {
            return new WP_Error(
                'fan_password_recovery_invalid',
                '密码恢复凭据无效，请联系管理员。',
                array('status' => 503)
            );
        }
        return array(
            'createdAt' => gmdate('c', $created_at),
            'expiresAt' => gmdate('c', $expires_at),
            'createdTimestamp' => $created_at,
            'expiresTimestamp' => $expires_at,
            'createdBy' => $created_by,
            'generation' => $generation,
            'claimedAt' => $has_claim ? gmdate('c', $claimed_at) : null,
            'claimedInstallHash' => $has_claim ? $claimed_install_hash : '',
            'claimNonce' => $has_claim ? $claim_nonce : '',
            'claimedSessionID' => $has_claim ? $claimed_session_id : '',
        );
    }

    private static function password_change_input(WP_REST_Request $request) {
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
        $new_password = (string) $request->get_param('newPassword');
        if (!$current_password || strlen($current_password) > 512) {
            return new WP_Error('fan_login_invalid', '当前密码不正确。', array('status' => 401));
        }
        $password_error = self::validate_fan_password($new_password);
        if (is_wp_error($password_error)) { return $password_error; }
        if (hash_equals($current_password, $new_password)) {
            return new WP_Error(
                'fan_new_password_must_differ',
                '新密码必须与当前密码不同。',
                array('status' => 400)
            );
        }
        return array(
            'installID' => $header_install_id,
            'currentPassword' => $current_password,
            'newPassword' => $new_password,
        );
    }

    private static function commit_fan_password_change(
        $user_id,
        $current_password,
        $new_password,
        $recovery_generation = ''
    ) {
        global $wpdb;
        $transaction_started = false;
        $transaction_committed = false;
        try {
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || $wpdb->query('START TRANSACTION') === false) {
                return new WP_Error(
                    'fan_password_change_unavailable',
                    '账号安全事务暂时不可用。',
                    array('status' => 503)
                );
            }
            $transaction_started = true;
            if (!self::fan_password_matches_database($user_id, $current_password, true)) {
                return new WP_Error('fan_login_invalid', '当前密码不正确。', array('status' => 401));
            }
            if ($recovery_generation !== '') {
                $recovery = self::normalize_fan_password_recovery(
                    self::fan_meta_from_database(
                        $user_id,
                        self::FAN_META_PASSWORD_RECOVERY,
                        null,
                        true
                    )
                );
                if (is_wp_error($recovery)
                    || !hash_equals((string) $recovery['generation'], (string) $recovery_generation)
                    || (int) $recovery['expiresTimestamp'] <= time()) {
                    return new WP_Error(
                        'fan_password_recovery_expired',
                        '密码恢复凭据已过期，请联系管理员重新生成。',
                        array('status' => 410)
                    );
                }
            } elseif (!empty(self::fan_meta_from_database(
                $user_id,
                self::FAN_META_INVITATION,
                null,
                true
            )) || !empty(self::fan_meta_from_database(
                $user_id,
                self::FAN_META_PASSWORD_RECOVERY,
                null,
                true
            ))) {
                return new WP_Error(
                    'fan_normal_session_required',
                    '请先完成账号安全设置。',
                    array('status' => 403)
                );
            }
            $current_epoch = (int) self::fan_meta_from_database(
                $user_id,
                self::FAN_META_CREDENTIAL_EPOCH,
                0,
                true
            );
            $password_hash = wp_hash_password((string) $new_password);
            $password_saved = $wpdb->update(
                $wpdb->users,
                array('user_pass' => $password_hash, 'user_activation_key' => ''),
                array('ID' => (int) $user_id),
                array('%s', '%s'),
                array('%d')
            );
            $recovery_deleted = $recovery_generation === ''
                || self::delete_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_PASSWORD_RECOVERY
                );
            if ($current_epoch <= 0 || $password_saved === false || !$recovery_deleted
                || !wp_check_password((string) $new_password, $password_hash, (int) $user_id)
                || !self::set_fan_meta_in_transaction(
                    $user_id,
                    self::FAN_META_CREDENTIAL_EPOCH,
                    $current_epoch + 1
                )) {
                return new WP_Error(
                    'fan_password_change_unavailable',
                    '暂时无法安全更新密码。',
                    array('status' => 503)
                );
            }
            if ($wpdb->query('COMMIT') === false) {
                return new WP_Error(
                    'fan_password_change_unavailable',
                    '暂时无法安全更新密码。',
                    array('status' => 503)
                );
            }
            $transaction_committed = true;
            clean_user_cache((int) $user_id);
            wp_cache_delete((int) $user_id, 'user_meta');
            return true;
        } finally {
            if ($transaction_started && !$transaction_committed) {
                $wpdb->query('ROLLBACK');
                clean_user_cache((int) $user_id);
                wp_cache_delete((int) $user_id, 'user_meta');
            }
        }
    }

    private static function generate_temporary_password() {
        try {
            $random = rtrim(strtr(base64_encode(random_bytes(18)), '+/', '-_'), '=');
        } catch (Exception $error) {
            return new WP_Error(
                'fan_invitation_unavailable',
                '暂时无法生成安全的临时密码。',
                array('status' => 503)
            );
        }
        return 'Tmp-' . $random . '-9!';
    }

    private static function reserve_invitation_douyin_id() {
        try {
            for ($attempt = 0; $attempt < 24; $attempt++) {
                $placeholder = 'invite_' . bin2hex(random_bytes(12));
                $existing = get_users(array(
                    'number' => 1,
                    'fields' => 'ids',
                    'meta_key' => self::FAN_META_DOUYIN_ID,
                    'meta_value' => $placeholder,
                ));
                if ($existing) { continue; }
                $reservation = self::douyin_reservation_name($placeholder);
                if (add_option($reservation, 'pending', '', false)) {
                    return array('douyinID' => $placeholder, 'reservation' => $reservation);
                }
            }
        } catch (Exception $error) {
            // Return the generic availability error below.
        }
        return new WP_Error(
            'fan_invitation_unavailable',
            '暂时无法生成唯一的临时账号。',
            array('status' => 503)
        );
    }

    private static function create_single_fan_invitation($created_by) {
        $identity_code = self::generate_unique_identity_code();
        if (is_wp_error($identity_code)) { return $identity_code; }
        $temporary_password = self::generate_temporary_password();
        if (is_wp_error($temporary_password)) { return $temporary_password; }
        $placeholder = self::reserve_invitation_douyin_id();
        if (is_wp_error($placeholder)) { return $placeholder; }
        try {
            $login = 'fan_' . bin2hex(random_bytes(16));
            $generation = bin2hex(random_bytes(16));
        } catch (Exception $error) {
            delete_option((string) $placeholder['reservation']);
            return new WP_Error('fan_invitation_unavailable', '暂时无法创建临时账号。', array('status' => 503));
        }

        $created_timestamp = time();
        $expires_timestamp = $created_timestamp + self::FAN_INVITATION_TTL;
        $created_at = gmdate('c', $created_timestamp);
        $expires_at = gmdate('c', $expires_timestamp);
        $display_name = '受邀粉丝 ' . substr(str_replace('-', '', $identity_code), -4);
        $user_id = wp_insert_user(array(
            'user_login' => $login,
            'user_pass' => $temporary_password,
            'display_name' => $display_name,
            'role' => 'subscriber',
        ));
        if (is_wp_error($user_id)) {
            delete_option((string) $placeholder['reservation']);
            return new WP_Error('fan_invitation_unavailable', '暂时无法创建临时账号。', array('status' => 503));
        }

        $uuid = wp_generate_uuid4();
        $saved = self::update_user_meta_verified($user_id, self::FAN_META_UUID, $uuid)
            && self::update_user_meta_verified($user_id, self::FAN_META_CODE, $identity_code)
            && self::update_user_meta_verified(
                $user_id,
                self::FAN_META_DOUYIN_ID,
                (string) $placeholder['douyinID']
            )
            && self::update_user_meta_verified(
                $user_id,
                self::FAN_META_PERMISSIONS,
                array('gallery_full', 'video_view')
            )
            && self::update_user_meta_verified($user_id, self::FAN_META_STATUS, 'pending')
            && self::update_user_meta_verified($user_id, self::FAN_META_CREDENTIAL_EPOCH, 1)
            && self::update_user_meta_verified($user_id, self::FAN_META_INVITATION, array(
                'createdAt' => $created_at,
                'expiresAt' => $expires_at,
                'createdBy' => (int) $created_by,
                'generation' => $generation,
                'preapproved' => true,
                'placeholderDouyinID' => (string) $placeholder['douyinID'],
            ))
            && self::update_user_meta_verified($user_id, self::FAN_META_REVIEW, array(
                'status' => 'preapproved',
                'reviewedAt' => $created_at,
                'reviewedBy' => (int) $created_by,
            ));
        if (!$saved || (!update_option((string) $placeholder['reservation'], (int) $user_id, false)
            && (int) get_option((string) $placeholder['reservation'], 0) !== (int) $user_id)) {
            self::remove_fan_user((int) $user_id, (string) $placeholder['reservation']);
            return new WP_Error('fan_invitation_unavailable', '暂时无法创建临时账号。', array('status' => 503));
        }
        $cleanup_scheduled = wp_schedule_single_event(
            $expires_timestamp + 60,
            'yishu_cleanup_fan_invitation',
            array((int) $user_id, $generation, (string) $placeholder['douyinID'], $expires_timestamp),
            true
        );
        if (is_wp_error($cleanup_scheduled) || !$cleanup_scheduled) {
            self::remove_fan_user((int) $user_id, (string) $placeholder['reservation']);
            return new WP_Error('fan_invitation_unavailable', '暂时无法安排临时账号过期清理。', array('status' => 503));
        }
        return array(
            'internalUserID' => (int) $user_id,
            'reservation' => (string) $placeholder['reservation'],
            'userID' => (string) $uuid,
            'identityCode' => (string) $identity_code,
            'temporaryPassword' => (string) $temporary_password,
            'expiresAt' => $expires_at,
        );
    }

    private static function update_user_meta_verified($user_id, $key, $value) {
        $updated = update_user_meta((int) $user_id, (string) $key, $value);
        return $updated !== false || get_user_meta((int) $user_id, (string) $key, true) === $value;
    }

    private static function fan_credential_epoch($user_id) {
        global $wpdb;
        $epoch = (int) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_CREDENTIAL_EPOCH,
            0
        );
        if (!empty($wpdb->last_error)) { return 0; }
        return $epoch > 0 ? $epoch : 1;
    }

    private static function advance_fan_credential_epoch($user_id) {
        $current_epoch = self::fan_credential_epoch((int) $user_id);
        if ($current_epoch <= 0) {
            return new WP_Error('fan_credential_update_failed', '暂时无法保存账号安全状态。', array('status' => 503));
        }
        $epoch = $current_epoch + 1;
        if (!self::update_user_meta_verified((int) $user_id, self::FAN_META_CREDENTIAL_EPOCH, $epoch)) {
            return new WP_Error('fan_credential_update_failed', '暂时无法保存账号安全状态。', array('status' => 503));
        }
        return $epoch;
    }

    private static function failure_transient_name($bucket, $identity) {
        return 'yishu_' . sanitize_key($bucket) . '_' . hash('sha256', (string) $identity);
    }

    private static function check_failure_limit($bucket, $identity, $limit) {
        $count = (int) get_transient(self::failure_transient_name($bucket, $identity));
        if ($count >= (int) $limit) {
            return new WP_Error('fan_rate_limited', '尝试次数过多，请稍后再试。', array('status' => 429));
        }
        return true;
    }

    private static function record_failure($bucket, $identity, $window) {
        $key = self::failure_transient_name($bucket, $identity);
        $count = (int) get_transient($key);
        if (!set_transient($key, $count + 1, max(60, (int) $window))) {
            return new WP_Error('fan_rate_limit_unavailable', '账号服务暂时不可用，请稍后重试。', array('status' => 503));
        }
        return true;
    }

    private static function clear_failure_limit($bucket, $identity) {
        delete_transient(self::failure_transient_name($bucket, $identity));
    }

    private static function acquire_fan_lock($user_id) {
        global $wpdb;
        if (!isset($wpdb) || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return new WP_Error('fan_setup_busy', '账号安全锁暂时不可用。', array('status' => 503));
        }
        $name = 'yishu_fan_' . substr(
            hash('sha256', home_url('/') . '|' . (int) $user_id),
            0,
            48
        );
        $acquired = $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 0)', $name));
        if ((string) $acquired === '1') { return $name; }
        return new WP_Error('fan_setup_busy', '账号正在处理中，请稍后重试。', array('status' => 409));
    }

    private static function release_fan_lock($user_id, $lock_name) {
        global $wpdb;
        if (!is_string($lock_name) || !preg_match('/^yishu_fan_[a-f0-9]{48}$/', $lock_name)
            || !isset($wpdb) || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return;
        }
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_name));
    }

    private static function validate_fan_display_name($display_name) {
        $length = self::text_length($display_name);
        if ($length < 1 || $length > 30) {
            return new WP_Error('fan_display_name_invalid', '昵称需要 1–30 个字符。', array('status' => 400));
        }
        return true;
    }

    private static function validate_fan_password($password) {
        if (!is_string($password) || strlen($password) > 512 || self::text_length($password) < 10
            || self::text_length($password) > 128 || trim($password) !== $password) {
            return new WP_Error('fan_password_weak', '密码需要 10–128 位，且首尾不能有空格。', array('status' => 400));
        }
        $categories = 0;
        if (preg_match('/[\p{L}]/u', $password)) { $categories++; }
        if (preg_match('/[0-9]/', $password)) { $categories++; }
        if (preg_match('/[^\p{L}0-9\s]/u', $password)) { $categories++; }
        if ($categories < 2) {
            return new WP_Error('fan_password_weak', '密码请至少同时包含字母或文字、数字、符号中的两类。', array('status' => 400));
        }
        return true;
    }

    private static function sanitize_fan_permissions($permissions) {
        if (!is_array($permissions) || count($permissions) > 20) {
            return new WP_Error('fan_permissions_invalid', '权限列表无效。', array('status' => 400));
        }
        $allowed = array_column(self::permission_catalog(), 'code');
        $result = array();
        foreach ($permissions as $permission) {
            if (!is_scalar($permission)) {
                return new WP_Error('fan_permissions_invalid', '权限列表无效。', array('status' => 400));
            }
            $permission = sanitize_key((string) $permission);
            if (!in_array($permission, $allowed, true)) {
                return new WP_Error('fan_permission_unknown', '包含不支持的权限。', array('status' => 400));
            }
            $result[] = $permission;
        }
        return array_values(array_unique($result));
    }

    private static function request_install_id(WP_REST_Request $request) {
        $install_id = trim((string) $request->get_header('x-yishu-install-id'));
        if (!$install_id) { $install_id = trim((string) $request->get_param('installID')); }
        $install_id = strtolower($install_id);
        if (!preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $install_id)) {
            return new WP_Error('fan_install_id_invalid', '安装记录无效，请重启 App 后再试。', array('status' => 400));
        }
        return $install_id;
    }

    private static function request_network_fingerprint() {
        $remote = isset($_SERVER['REMOTE_ADDR']) ? trim((string) $_SERVER['REMOTE_ADDR']) : '';
        $trusted_proxies = array('127.0.0.1', '::1', '129.226.202.207');
        if (in_array($remote, $trusted_proxies, true)) {
            $forwarded = isset($_SERVER['HTTP_X_YISHU_CLIENT_IP'])
                ? trim((string) $_SERVER['HTTP_X_YISHU_CLIENT_IP'])
                : '';
            if ($forwarded && filter_var($forwarded, FILTER_VALIDATE_IP) !== false) {
                $remote = $forwarded;
            }
        }
        if (!$remote || filter_var($remote, FILTER_VALIDATE_IP) === false) {
            $remote = 'unknown';
        }
        return hash('sha256', $remote . '|' . home_url('/'));
    }

    private static function fan_permissions_for_user($user_id) {
        $permissions = get_user_meta((int) $user_id, self::FAN_META_PERMISSIONS, true);
        $permissions = self::sanitize_fan_permissions(is_array($permissions) ? $permissions : array());
        return is_wp_error($permissions) ? array() : $permissions;
    }

    private static function remove_fan_user($user_id, $douyin_reservation = '') {
        self::revoke_all_fan_sessions((int) $user_id);
        if (!function_exists('wp_delete_user')) {
            require_once ABSPATH . 'wp-admin/includes/user.php';
        }
        if (!function_exists('wp_delete_user') || !wp_delete_user((int) $user_id)) {
            return false;
        }
        if ($douyin_reservation) { delete_option((string) $douyin_reservation); }
        return true;
    }

    private static function rate_limit($bucket, $identity, $limit, $window) {
        $key = 'yishu_' . sanitize_key($bucket) . '_' . hash('sha256', (string) $identity);
        $count = (int) get_transient($key);
        if ($count >= (int) $limit) {
            return new WP_Error('fan_rate_limited', '尝试次数过多，请稍后再试。', array('status' => 429));
        }
        if (!set_transient($key, $count + 1, max(60, (int) $window))) {
            return new WP_Error('fan_rate_limit_unavailable', '账号服务暂时不可用，请稍后重试。', array('status' => 503));
        }
        return true;
    }

    private static function generate_unique_identity_code() {
        $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
        $length = strlen($alphabet);
        try {
            for ($attempt = 0; $attempt < 24; $attempt++) {
                $bytes = random_bytes(8);
                $raw = '';
                for ($index = 0; $index < 8; $index++) {
                    $raw .= $alphabet[ord($bytes[$index]) % $length];
                }
                $code = self::normalize_identity_code($raw);
                $existing = get_users(array(
                    'number' => 1,
                    'fields' => 'ids',
                    'meta_key' => self::FAN_META_CODE,
                    'meta_value' => $code,
                ));
                if (!$existing) { return $code; }
            }
        } catch (Exception $error) {
            // Fall through to the generic availability response below.
        }
        return new WP_Error('fan_identity_unavailable', '暂时无法生成身份码，请稍后重试。', array('status' => 503));
    }

    private static function generate_install_code() {
        $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
        $length = strlen($alphabet);
        $bytes = random_bytes(6);
        $raw = '';
        for ($index = 0; $index < 6; $index++) {
            $raw .= $alphabet[ord($bytes[$index]) % $length];
        }
        return 'IN-' . substr($raw, 0, 3) . '-' . substr($raw, 3, 3);
    }

    private static function resolve_install_code($user_id, $install_id) {
        $install_hash = hash('sha256', strtolower((string) $install_id));
        $records = get_user_meta((int) $user_id, self::FAN_META_INSTALLATIONS, true);
        $records = is_array($records) ? $records : array();
        $now = time();
        $valid = array();
        foreach ($records as $record) {
            if (!is_array($record) || empty($record['hash']) || empty($record['code'])) { continue; }
            if (!preg_match('/^[a-f0-9]{64}$/', (string) $record['hash'])
                || !preg_match('/^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$/', (string) $record['code'])) {
                continue;
            }
            $valid[] = $record;
        }
        foreach ($valid as $index => $record) {
            if (hash_equals((string) $record['hash'], $install_hash)) {
                $valid[$index]['lastSeen'] = $now;
                update_user_meta((int) $user_id, self::FAN_META_INSTALLATIONS, $valid);
                return (string) $record['code'];
            }
        }

        $code = '';
        $in_use = array();
        try {
            for ($attempt = 0; $attempt < 12; $attempt++) {
                $code = self::generate_install_code();
                $in_use = array_filter($valid, function ($record) use ($code) {
                    return isset($record['code']) && hash_equals((string) $record['code'], $code);
                });
                if (!$in_use) { break; }
            }
        } catch (Exception $error) {
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        if (empty($code) || $in_use) {
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        $valid[] = array(
            'hash' => $install_hash,
            'code' => $code,
            'createdAt' => $now,
            'lastSeen' => $now,
        );
        usort($valid, function ($left, $right) {
            return (int) ($right['lastSeen'] ?? 0) <=> (int) ($left['lastSeen'] ?? 0);
        });
        $valid = array_slice($valid, 0, self::FAN_MAX_INSTALLATIONS);
        if (update_user_meta((int) $user_id, self::FAN_META_INSTALLATIONS, $valid) === false) {
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        return $code;
    }

    private static function issue_fan_session(
        $user_id,
        $install_id,
        $scope = 'normal',
        $ttl = self::FAN_SESSION_TTL
    ) {
        if (!in_array($scope, array('normal', 'onboarding', 'password_recovery'), true)) {
            return new WP_Error('fan_session_scope_invalid', '暂时无法创建安全会话。', array('status' => 503));
        }
        $maximum_ttl = $scope === 'onboarding'
            ? self::FAN_ONBOARDING_SESSION_TTL
            : ($scope === 'password_recovery'
                ? self::FAN_PASSWORD_RECOVERY_SESSION_TTL
                : self::FAN_SESSION_TTL);
        $ttl = (int) $ttl;
        if ($ttl <= 0 || $ttl > $maximum_ttl) {
            return new WP_Error('fan_session_ttl_invalid', '暂时无法创建安全会话。', array('status' => 503));
        }
        $install_code = self::resolve_install_code((int) $user_id, $install_id);
        if (is_wp_error($install_code)) { return $install_code; }
        $expires = time() + $ttl;
        $credential_epoch = self::fan_credential_epoch((int) $user_id);
        if ($credential_epoch <= 0) {
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        $token = '';
        $token_hash = '';
        $session_id = '';
        $context = array();
        try {
            for ($attempt = 0; $attempt < 4; $attempt++) {
                $token = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
                $token_hash = hash('sha256', $token);
                $session_id = bin2hex(random_bytes(16));
                $context = array(
                    'userID' => (int) $user_id,
                    'installHash' => hash('sha256', strtolower($install_id)),
                    'installCode' => $install_code,
                    'sessionID' => $session_id,
                    'createdAt' => time(),
                    'expires' => $expires,
                    'scope' => $scope,
                    'credentialEpoch' => $credential_epoch,
                );
                if (add_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash, $context, '', false)) {
                    break;
                }
                $token = '';
                $token_hash = '';
                $session_id = '';
            }
        } catch (Exception $error) {
            $token = '';
            $token_hash = '';
            $session_id = '';
        }
        if (!$token || !$token_hash || !$session_id) {
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        if (!self::record_fan_session((int) $user_id, $token_hash, $context)) {
            delete_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash);
            return new WP_Error('fan_session_unavailable', '暂时无法创建安全会话，请稍后重试。', array('status' => 503));
        }
        wp_schedule_single_event($expires + 60, 'yishu_cleanup_fan_session', array($token_hash, (int) $user_id));
        $context['token'] = $token;
        $context['tokenHash'] = $token_hash;
        return $context;
    }

    private static function authenticate_fan_session(WP_REST_Request $request) {
        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Bearer\s+([A-Za-z0-9_-]{43,128})$/', $authorization, $matches)) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $install_id = self::request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $token_hash = hash('sha256', $matches[1]);
        $context = get_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash, null);
        if (!is_array($context) || empty($context['userID']) || empty($context['expires'])
            || (int) $context['expires'] <= time() || empty($context['installHash'])
            || !hash_equals((string) $context['installHash'], hash('sha256', $install_id))) {
            if (is_array($context) && !empty($context['userID'])) {
                self::revoke_fan_session((int) $context['userID'], $token_hash);
            } else {
                delete_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash);
            }
            return new WP_Error('fan_session_invalid', '登录已失效，请重新登录。', array('status' => 401));
        }
        $user = get_userdata((int) $context['userID']);
        if (!$user instanceof WP_User || !get_user_meta($user->ID, self::FAN_META_UUID, true)) {
            self::revoke_fan_session((int) $context['userID'], $token_hash);
            return new WP_Error('fan_session_invalid', '登录已失效，请重新登录。', array('status' => 401));
        }
        // Tokens issued before credential epochs were introduced remain valid
        // only for accounts that are still on their initial epoch. Every
        // security-sensitive account transition advances the epoch.
        $scope = isset($context['scope']) ? (string) $context['scope'] : 'normal';
        $credential_epoch = isset($context['credentialEpoch'])
            ? (int) $context['credentialEpoch']
            : 1;
        if (!in_array($scope, array('normal', 'onboarding', 'password_recovery'), true)
            || $credential_epoch <= 0
            || $credential_epoch !== self::fan_credential_epoch((int) $user->ID)) {
            self::revoke_fan_session((int) $context['userID'], $token_hash);
            return new WP_Error('fan_session_invalid', '登录已失效，请重新登录。', array('status' => 401));
        }
        wp_set_current_user($user->ID);
        $context['scope'] = $scope;
        $context['credentialEpoch'] = $credential_epoch;
        $context['tokenHash'] = $token_hash;
        return $context;
    }

    private static function fan_session_context_is_current_from_database(
        $context,
        $required_scope = ''
    ) {
        if (!is_array($context)) { return false; }
        $token_hash = strtolower((string) ($context['tokenHash'] ?? ''));
        $user_id = (int) ($context['userID'] ?? 0);
        $required_scope = (string) $required_scope;
        if ($user_id <= 0 || !preg_match('/^[a-f0-9]{64}$/', $token_hash)
            || !in_array(
                $required_scope,
                array('normal', 'onboarding', 'password_recovery'),
                true
            )) {
            return false;
        }
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $serialized_session = $wpdb->get_var($wpdb->prepare(
            "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s LIMIT 1",
            self::FAN_SESSION_OPTION_PREFIX . $token_hash
        ));
        if (!is_string($serialized_session)) { return false; }
        $fresh_session = maybe_unserialize($serialized_session);
        return is_array($fresh_session)
            && (int) ($fresh_session['userID'] ?? 0) === $user_id
            && (string) ($fresh_session['scope'] ?? '') === $required_scope
            && (int) ($fresh_session['expires'] ?? 0) > time()
            // Match authenticate_fan_session(): legacy normal sessions issued
            // before credential epochs existed belong to epoch 1 only. Any
            // later password/security transition advances the account epoch
            // and therefore still invalidates them.
            && (int) ($fresh_session['credentialEpoch'] ?? 1)
                === self::fan_credential_epoch($user_id)
            && hash_equals(
                (string) ($fresh_session['sessionID'] ?? ''),
                (string) ($context['sessionID'] ?? '')
            )
            && hash_equals(
                (string) ($fresh_session['installHash'] ?? ''),
                (string) ($context['installHash'] ?? '')
            );
    }

    private static function record_fan_session($user_id, $token_hash, $context) {
        if (!is_array($context) || empty($context['expires']) || empty($context['sessionID'])
            || empty($context['installCode']) || empty($context['installHash'])
            || !preg_match('/^[a-f0-9]{32}$/', (string) $context['sessionID'])) {
            return false;
        }
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        $sessions = is_array($sessions) ? $sessions : array();
        $now = time();
        $valid = array();
        foreach ($sessions as $session) {
            if (!is_array($session) || empty($session['hash']) || empty($session['expires'])) { continue; }
            $hash = (string) $session['hash'];
            if (!preg_match('/^[a-f0-9]{64}$/', $hash)) { continue; }
            if ((int) $session['expires'] <= $now) {
                delete_option(self::FAN_SESSION_OPTION_PREFIX . $hash);
                continue;
            }
            $valid[] = array(
                'hash' => $hash,
                'expires' => (int) $session['expires'],
                'sessionID' => isset($session['sessionID'])
                    && preg_match('/^[a-f0-9]{32}$/', (string) $session['sessionID'])
                    ? (string) $session['sessionID']
                    : self::fan_public_session_id($hash),
                'installCode' => isset($session['installCode'])
                    ? (string) $session['installCode']
                    : '',
                'createdAt' => isset($session['createdAt'])
                    ? (int) $session['createdAt']
                    : max(1, (int) $session['expires'] - self::FAN_SESSION_TTL),
            );
        }
        usort($valid, function ($left, $right) {
            return (int) $right['expires'] <=> (int) $left['expires'];
        });
        while (count($valid) >= self::FAN_MAX_SESSIONS) {
            $revoked = array_pop($valid);
            delete_option(self::FAN_SESSION_OPTION_PREFIX . $revoked['hash']);
        }
        $valid[] = array(
            'hash' => (string) $token_hash,
            'expires' => (int) $context['expires'],
            'sessionID' => (string) $context['sessionID'],
            'installCode' => (string) $context['installCode'],
            'createdAt' => (int) $context['createdAt'],
        );
        return update_user_meta((int) $user_id, self::FAN_META_SESSIONS, $valid) !== false;
    }

    private static function fan_public_session_id($token_hash) {
        $token_hash = strtolower((string) $token_hash);
        if (!preg_match('/^[a-f0-9]{64}$/', $token_hash)) { return ''; }
        return substr(hash_hmac('sha256', $token_hash, wp_salt('auth')), 0, 32);
    }

    private static function fan_session_directory($user_id, $current_token_hash) {
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        $sessions = is_array($sessions) ? $sessions : array();
        $now = time();
        $current_epoch = self::fan_credential_epoch((int) $user_id);
        if ($current_epoch <= 0) {
            return new WP_Error('fan_session_unavailable', '暂时无法读取安全会话。', array('status' => 503));
        }
        $result = array();
        foreach ($sessions as $session) {
            if (!is_array($session) || empty($session['hash']) || empty($session['expires'])) { continue; }
            $hash = strtolower((string) $session['hash']);
            if (!preg_match('/^[a-f0-9]{64}$/', $hash) || (int) $session['expires'] <= $now) {
                continue;
            }
            $context = get_option(self::FAN_SESSION_OPTION_PREFIX . $hash, null);
            if (!is_array($context) || (int) ($context['userID'] ?? 0) !== (int) $user_id
                || (int) ($context['expires'] ?? 0) <= $now
                || (int) ($context['credentialEpoch'] ?? 1) !== $current_epoch
                || (string) ($context['scope'] ?? 'normal') !== 'normal') {
                continue;
            }
            $session_id = isset($context['sessionID'])
                && preg_match('/^[a-f0-9]{32}$/', (string) $context['sessionID'])
                ? (string) $context['sessionID']
                : self::fan_public_session_id($hash);
            $install_code = isset($context['installCode'])
                ? (string) $context['installCode']
                : (string) ($session['installCode'] ?? '');
            $created_at = isset($context['createdAt'])
                ? (int) $context['createdAt']
                : (isset($session['createdAt'])
                    ? (int) $session['createdAt']
                    : max(1, (int) $context['expires'] - self::FAN_SESSION_TTL));
            if (!preg_match('/^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$/', $install_code)
                || !$session_id || $created_at <= 0 || $created_at > (int) $context['expires']) {
                continue;
            }
            $result[] = array(
                'sessionID' => $session_id,
                'installationCode' => $install_code,
                'createdAt' => gmdate('c', $created_at),
                'expiresAt' => gmdate('c', (int) $context['expires']),
                'isCurrent' => hash_equals($hash, (string) $current_token_hash),
            );
        }
        usort($result, function ($left, $right) {
            return strcmp((string) $right['createdAt'], (string) $left['createdAt']);
        });
        $current_count = count(array_filter($result, function ($session) {
            return !empty($session['isCurrent']);
        }));
        if ($current_count !== 1 || count($result) > self::FAN_MAX_SESSIONS) {
            return new WP_Error('fan_session_unavailable', '暂时无法读取安全会话。', array('status' => 503));
        }
        return $result;
    }

    private static function revoke_fan_session($user_id, $token_hash) {
        $token_hash = strtolower((string) $token_hash);
        if (!preg_match('/^[a-f0-9]{64}$/', $token_hash)) { return; }
        delete_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash);
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        if (!is_array($sessions)) { return; }
        $sessions = array_values(array_filter($sessions, function ($session) use ($token_hash) {
            return is_array($session) && isset($session['hash'])
                && preg_match('/^[a-f0-9]{64}$/', (string) $session['hash'])
                && !hash_equals((string) $session['hash'], $token_hash);
        }));
        update_user_meta((int) $user_id, self::FAN_META_SESSIONS, $sessions);
    }

    private static function revoke_fan_session_by_public_id($user_id, $session_id) {
        $session_id = strtolower((string) $session_id);
        if (!preg_match('/^[a-f0-9]{32}$/', $session_id)) { return; }
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        if (!is_array($sessions)) { return; }
        foreach ($sessions as $session) {
            if (!is_array($session) || empty($session['hash'])) { continue; }
            $hash = strtolower((string) $session['hash']);
            if (!preg_match('/^[a-f0-9]{64}$/', $hash)) { continue; }
            $public_id = isset($session['sessionID'])
                && preg_match('/^[a-f0-9]{32}$/', (string) $session['sessionID'])
                ? strtolower((string) $session['sessionID'])
                : self::fan_public_session_id($hash);
            if (hash_equals($public_id, $session_id)) {
                self::revoke_fan_session((int) $user_id, $hash);
                return;
            }
        }
    }

    private static function revoke_all_fan_sessions($user_id) {
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        if (is_array($sessions)) {
            foreach ($sessions as $session) {
                if (is_array($session) && isset($session['hash'])
                    && preg_match('/^[a-f0-9]{64}$/', (string) $session['hash'])) {
                    delete_option(self::FAN_SESSION_OPTION_PREFIX . (string) $session['hash']);
                }
            }
        }
        delete_user_meta((int) $user_id, self::FAN_META_SESSIONS);
    }

    public static function cleanup_fan_session($token_hash, $user_id) {
        $token_hash = strtolower((string) $token_hash);
        if (!preg_match('/^[a-f0-9]{64}$/', $token_hash)) { return; }
        $context = get_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash, null);
        if (!is_array($context) || empty($context['expires']) || (int) $context['expires'] <= time()) {
            self::revoke_fan_session((int) $user_id, $token_hash);
        }
    }

    public static function cleanup_fan_invitation(
        $user_id,
        $generation,
        $placeholder,
        $expires_timestamp
    ) {
        $user_id = (int) $user_id;
        $generation = (string) $generation;
        $placeholder = (string) $placeholder;
        $expires_timestamp = (int) $expires_timestamp;
        if ($user_id <= 0 || !preg_match('/^[a-f0-9]{32}$/', $generation)
            || !self::is_invitation_douyin_id($placeholder) || $expires_timestamp <= 0) {
            return;
        }
        $lock_name = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock_name)) {
            wp_schedule_single_event(
                time() + 300,
                'yishu_cleanup_fan_invitation',
                array($user_id, $generation, $placeholder, $expires_timestamp)
            );
            return;
        }
        try {
            global $wpdb;
            $user_exists = (int) $wpdb->get_var($wpdb->prepare(
                "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1",
                $user_id
            ));
            $invitation = self::normalize_fan_invitation(
                self::fan_meta_from_database($user_id, self::FAN_META_INVITATION, null)
            );
            if ($user_exists !== $user_id || is_wp_error($invitation)
                || !hash_equals((string) $invitation['generation'], $generation)
                || !hash_equals((string) $invitation['placeholderDouyinID'], $placeholder)
                || (int) $invitation['expiresTimestamp'] !== $expires_timestamp
                || (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_DOUYIN_ID,
                    ''
                ) !== $placeholder
                || (string) self::fan_meta_from_database(
                    $user_id,
                    self::FAN_META_STATUS,
                    ''
                ) === 'active') {
                return;
            }
            if ($expires_timestamp > time()) {
                wp_schedule_single_event(
                    $expires_timestamp + 60,
                    'yishu_cleanup_fan_invitation',
                    array($user_id, $generation, $placeholder, $expires_timestamp)
                );
                return;
            }
            if (!self::remove_fan_user($user_id, self::douyin_reservation_name($placeholder))) {
                wp_schedule_single_event(
                    time() + 300,
                    'yishu_cleanup_fan_invitation',
                    array($user_id, $generation, $placeholder, $expires_timestamp)
                );
            }
        } finally {
            self::release_fan_lock($user_id, $lock_name);
        }
    }

    public static function prepare_fan_user_deletion($user_id) {
        $user_id = (int) $user_id;
        if ($user_id <= 0 || !get_user_meta($user_id, self::FAN_META_UUID, true)) { return; }
        self::revoke_all_fan_sessions($user_id);
        $douyin_id = (string) get_user_meta($user_id, self::FAN_META_DOUYIN_ID, true);
        if ($douyin_id) {
            delete_option(self::douyin_reservation_name($douyin_id));
        }
        $invitation = get_user_meta($user_id, self::FAN_META_INVITATION, true);
        if (is_array($invitation) && isset($invitation['placeholderDouyinID'])
            && self::is_invitation_douyin_id((string) $invitation['placeholderDouyinID'])) {
            delete_option(self::douyin_reservation_name((string) $invitation['placeholderDouyinID']));
        }
    }

    private static function fan_invitation_profile_fields($user_id) {
        $raw_invitation = get_user_meta((int) $user_id, self::FAN_META_INVITATION, true);
        if (empty($raw_invitation)) {
            return array(
                'requiresAccountSetup' => false,
                'invitationExpiresAt' => null,
            );
        }
        $invitation = self::normalize_fan_invitation($raw_invitation);
        return array(
            // Malformed invitation metadata fails closed: the account cannot
            // silently become a normal content session.
            'requiresAccountSetup' => true,
            'invitationExpiresAt' => is_wp_error($invitation)
                ? null
                : (string) $invitation['expiresAt'],
        );
    }

    private static function fan_password_recovery_profile_fields($user_id) {
        $raw_recovery = get_user_meta(
            (int) $user_id,
            self::FAN_META_PASSWORD_RECOVERY,
            true
        );
        if (empty($raw_recovery)) {
            return array(
                'requiresPasswordChange' => false,
                'passwordRecoveryExpiresAt' => null,
            );
        }
        $recovery = self::normalize_fan_password_recovery($raw_recovery);
        return array(
            // A malformed marker remains a forced-password-change state. This
            // prevents corrupted metadata from restoring normal content access.
            'requiresPasswordChange' => true,
            'passwordRecoveryExpiresAt' => is_wp_error($recovery)
                ? null
                : (string) $recovery['expiresAt'],
        );
    }

    private static function fan_profile($user_id, $context) {
        $user = get_userdata((int) $user_id);
        $permissions = get_user_meta($user_id, self::FAN_META_PERMISSIONS, true);
        $permissions = self::sanitize_fan_permissions(is_array($permissions) ? $permissions : array());
        if (is_wp_error($permissions)) { $permissions = array(); }
        return array_merge(array(
            'userID' => (string) get_user_meta($user_id, self::FAN_META_UUID, true),
            'identityCode' => (string) get_user_meta($user_id, self::FAN_META_CODE, true),
            'displayName' => $user instanceof WP_User ? (string) $user->display_name : '',
            'douyinID' => (string) get_user_meta($user_id, self::FAN_META_DOUYIN_ID, true),
            'installationCode' => isset($context['installCode']) ? (string) $context['installCode'] : '',
            'permissions' => $permissions,
            'status' => (string) get_user_meta($user_id, self::FAN_META_STATUS, true),
            'sessionExpiresAt' => gmdate('c', (int) $context['expires']),
        ), self::fan_invitation_profile_fields((int) $user_id),
            self::fan_password_recovery_profile_fields((int) $user_id));
    }

    private static function fan_auth_response($user_id, $session, $status = 200) {
        $response = new WP_REST_Response(array(
            'token' => (string) $session['token'],
            'profile' => self::fan_profile((int) $user_id, $session),
        ), (int) $status);
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    private static function fan_admin_profile(WP_User $user) {
        $permissions = get_user_meta($user->ID, self::FAN_META_PERMISSIONS, true);
        $permissions = self::sanitize_fan_permissions(is_array($permissions) ? $permissions : array());
        if (is_wp_error($permissions)) { $permissions = array(); }
        $registered = strtotime($user->user_registered . ' UTC');
        $review = get_user_meta($user->ID, self::FAN_META_REVIEW, true);
        $reviewed_at = is_array($review) && !empty($review['reviewedAt'])
            ? strtotime((string) $review['reviewedAt'])
            : false;
        return array_merge(array(
            'userID' => (string) get_user_meta($user->ID, self::FAN_META_UUID, true),
            'identityCode' => (string) get_user_meta($user->ID, self::FAN_META_CODE, true),
            'displayName' => (string) $user->display_name,
            'douyinID' => (string) get_user_meta($user->ID, self::FAN_META_DOUYIN_ID, true),
            'permissions' => $permissions,
            'status' => (string) get_user_meta($user->ID, self::FAN_META_STATUS, true),
            'registeredAt' => gmdate('c', $registered ? $registered : time()),
            'reviewedAt' => $reviewed_at ? gmdate('c', $reviewed_at) : null,
        ), self::fan_invitation_profile_fields((int) $user->ID),
            self::fan_password_recovery_profile_fields((int) $user->ID));
    }

    public static function secure_rest_response($result, $server, $request) {
        if (!$request instanceof WP_REST_Request || strpos($request->get_route(), '/shuzijun/v1/') !== 0) {
            return $result;
        }
        $response = is_wp_error($result)
            ? rest_convert_error_to_response($result)
            : rest_ensure_response($result);
        $response->header('X-Content-Type-Options', 'nosniff');
        $response->header('X-Frame-Options', 'DENY');
        $response->header('Referrer-Policy', 'no-referrer');
        $response->header('X-Robots-Tag', 'noindex, nofollow');
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        if ($request->get_route() === '/shuzijun/v1/app-content') {
            $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        }
        return $response;
    }

    public static function block_public_catalog_routes($result, $server, $request) {
        if ($result !== null || !$request instanceof WP_REST_Request
            || self::authenticate_content_manager($request)) {
            return $result;
        }
        $route = $request->get_route();
        if (preg_match('#^/wp/v2/(portfolio|media)(?:/|$)#', $route)) {
            return new WP_Error('rest_no_route', '未找到匹配 URL 和请求方式的路由。', array('status' => 404));
        }
        return $result;
    }

    public static function block_public_portfolio_pages() {
        if (current_user_can(self::CAPABILITY)) { return; }
        // Attachment pages reveal the original upload URL and can remain in
        // search indexes even after a portfolio page is removed. The website
        // does not use attachment pages, so fail closed for all visitors.
        if (!is_singular('portfolio') && !is_post_type_archive('portfolio') && !is_attachment()) {
            return;
        }
        global $wp_query;
        $wp_query->set_404();
        status_header(404);
        nocache_headers();
        wp_die(
            esc_html__('此内容仅在易姝 App 内提供。', 'shuzijun'),
            esc_html__('页面不可用', 'shuzijun'),
            array('response' => 404)
        );
    }

    public static function remove_portfolios_from_sitemaps($post_types) {
        unset($post_types['portfolio']);
        return $post_types;
    }

    public static function hide_public_portfolio_queries($query) {
        if (is_admin() || current_user_can(self::CAPABILITY)
            || (defined('REST_REQUEST') && REST_REQUEST)) {
            return;
        }
        $post_type = $query->get('post_type');
        $is_portfolio_query = $post_type === 'portfolio'
            || (is_array($post_type) && in_array('portfolio', $post_type, true));
        if ($is_portfolio_query) {
            $query->set('post__in', array(0));
        }
    }

    public static function hide_public_portfolio_section() {
        if (current_user_can(self::CAPABILITY)) { return; }
        echo '<style id="yishu-private-portfolio">#portfolio{display:none!important}</style>';
    }

    public static function public_hero_cta($value) {
        return current_user_can(self::CAPABILITY) ? $value : '合作邀约';
    }

    public static function public_hero_cta_link($value) {
        return current_user_can(self::CAPABILITY) ? $value : '#contact';
    }

    public static function can_access_premium(WP_REST_Request $request) {
        if (self::authenticate_content_manager($request)) { return true; }

        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Bearer\\s+([A-Za-z0-9._-]+)$/', $authorization, $matches)) {
            return new WP_Error('premium_credential_required', '需要有效的 Apple 订阅凭证。', array('status' => 401));
        }
        $jws = $matches[1];
        if (strlen($jws) < 100 || strlen($jws) > 16384) {
            return new WP_Error('premium_credential_invalid', 'Apple 订阅凭证无效。', array('status' => 401));
        }
        $cache_key = 'yishu_entitlement_' . hash('sha256', $jws);
        if (get_transient($cache_key) === 'active') { return true; }

        if (!defined('YISHU_ENTITLEMENT_VERIFIER_URL') || !defined('YISHU_ENTITLEMENT_VERIFIER_TOKEN')) {
            return new WP_Error('premium_verifier_unavailable', '订阅校验服务尚未完成配置。', array('status' => 503));
        }
        $verifier_url = esc_url_raw((string) YISHU_ENTITLEMENT_VERIFIER_URL, array('https', 'http'));
        $verifier_host = strtolower((string) wp_parse_url($verifier_url, PHP_URL_HOST));
        $is_local_verifier = in_array($verifier_host, array('127.0.0.1', 'localhost', '::1'), true);
        if (!$verifier_url || (wp_parse_url($verifier_url, PHP_URL_SCHEME) !== 'https' && !$is_local_verifier)) {
            return new WP_Error('premium_verifier_insecure', '订阅校验服务配置不安全。', array('status' => 503));
        }

        $verification = wp_remote_post($verifier_url, array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array(
                'Content-Type' => 'application/json',
                'Accept' => 'application/json',
                'X-Yishu-Internal-Token' => (string) YISHU_ENTITLEMENT_VERIFIER_TOKEN,
            ),
            'body' => wp_json_encode(array('transactionJWS' => $jws)),
        ));
        if (is_wp_error($verification)) {
            return new WP_Error('premium_verifier_unavailable', '暂时无法校验订阅。', array('status' => 503));
        }
        $status = (int) wp_remote_retrieve_response_code($verification);
        $payload = json_decode((string) wp_remote_retrieve_body($verification), true);
        if ($status !== 200 || !is_array($payload) || empty($payload['active'])) {
            return new WP_Error('premium_entitlement_inactive', '订阅已失效或未通过校验。', array('status' => 403));
        }
        set_transient($cache_key, 'active', 5 * MINUTE_IN_SECONDS);
        return true;
    }

    public static function session() {
        $user = wp_get_current_user();
        $response = rest_ensure_response(array(
            'authenticated' => true,
            'username' => $user->user_login,
            'displayName' => $user->display_name,
            'role' => self::ROLE,
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function get_content($request = null) {
        if (self::authenticate_content_manager($request)) {
            $manifest = self::manifest('admin');
        } else {
            $context = self::$fan_session_context;
            $permissions = is_array($context) && isset($context['permissions'])
                ? (array) $context['permissions']
                : array();
            $manifest = self::manifest('app', $permissions);
        }
        $response = rest_ensure_response($manifest);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        $response->header('Pragma', 'no-cache');
        return $response;
    }

    public static function get_premium_content() {
        $response = rest_ensure_response(self::manifest('premium'));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function update_content(WP_REST_Request $request) {
        $current = self::config();
        $incoming_heroes = $request->get_param('heroImages');
        $incoming_about_portrait = $request->get_param('aboutPortraitURL');
        $incoming_launch_posters = $request->get_param('launchPosters');
        $incoming_showreel = $request->get_param('showreel');
        $incoming_dramas = $request->get_param('dramas');

        if (is_array($incoming_heroes)) {
            $heroes = self::sanitize_image_urls($incoming_heroes, 5);
            if (is_wp_error($heroes)) { return $heroes; }
            $current['heroImages'] = $heroes;
        }
        if ($request->has_param('aboutPortraitURL')) {
            $about_portrait = self::sanitize_optional_media_url($incoming_about_portrait);
            if (is_wp_error($about_portrait)) { return $about_portrait; }
            $current['aboutPortraitURL'] = $about_portrait;
        }
        if (is_array($incoming_launch_posters)) {
            $launch_posters = self::sanitize_launch_posters($incoming_launch_posters);
            if (is_wp_error($launch_posters)) { return $launch_posters; }
            $current['launchPosters'] = $launch_posters;
        }
        if (is_array($incoming_showreel)) {
            $showreel = self::sanitize_showreel($incoming_showreel, $current['showreel']);
            if (is_wp_error($showreel)) { return $showreel; }
            $current['showreel'] = $showreel;
        }
        if (is_array($incoming_dramas)) {
            $dramas = self::sanitize_dramas($incoming_dramas);
            if (is_wp_error($dramas)) { return $dramas; }
            $current['dramas'] = $dramas;
        }

        update_option(self::OPTION_CONFIG, $current, false);
        self::mark_updated();
        $response = rest_ensure_response(self::manifest('admin'));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function update_gallery(WP_REST_Request $request) {
        $portfolio_id = absint($request['id']);
        if (get_post_type($portfolio_id) !== 'portfolio') {
            return new WP_Error('portfolio_not_found', '作品集不存在。', array('status' => 404));
        }

        $media_ids = $request->get_param('mediaIDs');
        if (!is_array($media_ids)) {
            return new WP_Error('invalid_media_ids', 'mediaIDs 必须是数组。', array('status' => 400));
        }
        $media_ids = array_values(array_unique(array_filter(array_map('absint', $media_ids))));
        if (count($media_ids) > 300) {
            return new WP_Error('too_many_media', '单个相册最多 300 张照片。', array('status' => 413));
        }
        $current_user_id = get_current_user_id();
        foreach ($media_ids as $media_id) {
            $attachment = get_post($media_id);
            if (!$attachment instanceof WP_Post
                || $attachment->post_type !== 'attachment'
                || $attachment->post_status === 'trash'
                || !wp_attachment_is_image($media_id)) {
                return new WP_Error('invalid_media', '相册只能包含有效图片。', array('status' => 400));
            }
            $already_attached = (int) $attachment->post_parent === $portfolio_id;
            $owns_attachment = (int) $attachment->post_author === $current_user_id;
            if (!$already_attached && !$owns_attachment && !current_user_can('edit_others_posts')) {
                return new WP_Error('media_not_owned', '不能将其他用户的媒体加入相册。', array('status' => 403));
            }
        }

        $previous_ids = json_decode((string) get_post_meta($portfolio_id, '_portfolio_gallery', true), true);
        $previous_ids = array_values(array_unique(array_filter(array_map('absint', (array) $previous_ids))));
        update_post_meta($portfolio_id, '_portfolio_gallery', wp_json_encode($media_ids));
        foreach ($media_ids as $media_id) {
            wp_update_post(array('ID' => $media_id, 'post_parent' => $portfolio_id));
        }
        foreach (array_diff($previous_ids, $media_ids) as $removed_id) {
            if ((int) wp_get_post_parent_id($removed_id) === $portfolio_id) {
                wp_update_post(array('ID' => $removed_id, 'post_parent' => 0));
            }
        }
        self::mark_updated();
        clean_post_cache($portfolio_id);

        $response = rest_ensure_response(array(
            'ok' => true,
            'portfolioID' => $portfolio_id,
            'mediaIDs' => $media_ids,
            'content' => self::manifest('admin'),
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function create_portfolio(WP_REST_Request $request) {
        $title = sanitize_text_field((string) $request->get_param('title'));
        $subtitle = sanitize_text_field((string) $request->get_param('subtitle'));
        $eyebrow = sanitize_text_field((string) $request->get_param('eyebrow'));

        if (!$title) {
            return new WP_Error('portfolio_title_required', '请填写相册名称。', array('status' => 400));
        }
        if (self::text_length($title) > 120 || self::text_length($subtitle) > 240 || self::text_length($eyebrow) > 120) {
            return new WP_Error('portfolio_text_too_long', '相册名称或介绍过长。', array('status' => 400));
        }

        $counts = wp_count_posts('portfolio');
        if ($counts && isset($counts->publish) && (int) $counts->publish >= 100) {
            return new WP_Error('portfolio_limit_reached', '相册数量已达上限。', array('status' => 409));
        }

        $slug = sanitize_title($title);
        if ($slug && get_page_by_path($slug, OBJECT, 'portfolio')) {
            return new WP_Error('portfolio_exists', '同名相册已经存在。', array('status' => 409));
        }

        $portfolio_id = wp_insert_post(array(
            'post_type' => 'portfolio',
            'post_status' => 'publish',
            'post_title' => $title,
            'post_name' => $slug,
            'post_content' => '',
        ), true);
        if (is_wp_error($portfolio_id)) { return $portfolio_id; }

        update_post_meta($portfolio_id, '_app_title', $title);
        update_post_meta($portfolio_id, '_app_subtitle', $subtitle ?: '易姝影像作品');
        update_post_meta($portfolio_id, '_app_eyebrow', $eyebrow ?: 'PORTFOLIO');
        update_post_meta($portfolio_id, '_portfolio_gallery', wp_json_encode(array()));
        self::mark_updated();
        clean_post_cache($portfolio_id);

        $response = new WP_REST_Response(array(
            'ok' => true,
            'portfolioID' => (int) $portfolio_id,
            'content' => self::manifest('admin'),
        ), 201);
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function portfolio_changed($post_id, $post, $update) {
        if (wp_is_post_revision($post_id) || wp_is_post_autosave($post_id)) { return; }
        if ($post instanceof WP_Post && $post->post_status === 'publish') {
            self::mark_updated();
        }
    }

    private static function mark_updated() {
        update_option(self::OPTION_UPDATED, time(), false);
    }

    private static function manifest($audience = 'public', $permissions = array()) {
        $config = self::config();
        $updated = (int) get_option(self::OPTION_UPDATED, 0);
        if ($updated < 1) { $updated = time(); }
        $is_unrestricted = in_array($audience, array('admin', 'premium'), true);
        $can_view_full_gallery = $is_unrestricted
            || ($audience === 'app' && in_array('gallery_full', (array) $permissions, true));
        $can_view_video = $is_unrestricted
            || ($audience === 'app' && in_array('video_view', (array) $permissions, true));
        $portfolio_audience = $can_view_full_gallery ? $audience : 'public';
        return array(
            'schemaVersion' => 1,
            'updatedAt' => gmdate('c', $updated),
            'heroImages' => $config['heroImages'],
            'aboutPortraitURL' => $config['aboutPortraitURL'],
            'launchPosters' => $config['launchPosters'],
            'showreel' => $can_view_video ? $config['showreel'] : null,
            'dramas' => $can_view_video ? $config['dramas'] : array(),
            'portfolios' => self::portfolios($portfolio_audience),
        );
    }

    private static function config() {
        $stored = get_option(self::OPTION_CONFIG, array());
        if (!is_array($stored)) { $stored = array(); }
        $defaults = self::default_config();

        // Options can outlive several plugin versions or be changed directly
        // in the database. Revalidate every stored field before publishing it;
        // an invalid section falls back independently instead of poisoning the
        // complete manifest consumed by the App.
        $heroes = isset($stored['heroImages']) && is_array($stored['heroImages'])
            ? self::sanitize_image_urls($stored['heroImages'], 5)
            : $defaults['heroImages'];
        if (is_wp_error($heroes)) { $heroes = $defaults['heroImages']; }

        $about_portrait = array_key_exists('aboutPortraitURL', $stored)
            ? self::sanitize_optional_media_url($stored['aboutPortraitURL'])
            : $defaults['aboutPortraitURL'];
        if (is_wp_error($about_portrait)) { $about_portrait = $defaults['aboutPortraitURL']; }

        $launch_posters = isset($stored['launchPosters']) && is_array($stored['launchPosters'])
            ? self::sanitize_launch_posters($stored['launchPosters'])
            : $defaults['launchPosters'];
        if (is_wp_error($launch_posters)) { $launch_posters = $defaults['launchPosters']; }

        $showreel_value = isset($stored['showreel']) && is_array($stored['showreel'])
            ? array_merge($defaults['showreel'], $stored['showreel'])
            : $defaults['showreel'];
        $showreel = self::sanitize_showreel($showreel_value, $defaults['showreel']);
        if (is_wp_error($showreel)) { $showreel = $defaults['showreel']; }

        $dramas = isset($stored['dramas']) && is_array($stored['dramas'])
            ? self::sanitize_dramas($stored['dramas'])
            : $defaults['dramas'];
        if (is_wp_error($dramas)) { $dramas = $defaults['dramas']; }

        return array(
            'heroImages' => $heroes,
            'aboutPortraitURL' => $about_portrait,
            'launchPosters' => $launch_posters,
            'showreel' => $showreel,
            'dramas' => $dramas,
        );
    }

    private static function default_config() {
        $hongguo = 'https://novelquickapp.com/s/wHlfrwqog1g/';
        return array(
            'heroImages' => array(
                'https://img.shuzijun.com.cn/images/hero-mobile-1.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-2.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-3.webp',
            ),
            'aboutPortraitURL' => null,
            'launchPosters' => array(
                array(
                    'id' => 'evergreen',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-launch-qipao-ivory-20260830.jpg',
                    'eyebrow' => 'YI SHU',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
            ),
            'showreel' => array(
                'eyebrow' => 'ACTOR SHOWREEL · 2026',
                'title' => '21 秒演员展映',
                'summary' => '温柔 · 克制 · 东方韵味',
                'durationLabel' => '00:21',
                'videoURL' => home_url('/wp-content/uploads/showreel/hls-20260826a/master.m3u8'),
                'posterURL' => home_url('/wp-content/uploads/showreel/yishu-showreel-poster.jpg?v=20260825e'),
                'tags' => array('古装', '情绪表达', '镜头表现'),
            ),
            'dramas' => array(
                array('id'=>'jingchunye','title'=>'京春夜','imageURL'=>'https://img.shuzijun.com.cn/images/drama-jingchunye.webp','destinationURL'=>$hongguo),
                array('id'=>'wangshengjiudian','title'=>'往生酒店','imageURL'=>'https://img.shuzijun.com.cn/images/drama-wangshengjiudian.webp','destinationURL'=>$hongguo),
                array('id'=>'nianxiadidi','title'=>'年下弟弟俯首称臣','imageURL'=>'https://img.shuzijun.com.cn/images/drama-nianxiadidi.webp','destinationURL'=>$hongguo),
                array('id'=>'xinhunye','title'=>'新婚夜，我和姐姐上错婚车嫁对郎','imageURL'=>'https://img.shuzijun.com.cn/images/drama-xinhunye.webp','destinationURL'=>$hongguo),
                array('id'=>'ouyangxiu','title'=>'遇见，我的欧阳修大人','imageURL'=>'https://img.shuzijun.com.cn/images/drama-ouyangxiu.webp','destinationURL'=>$hongguo),
            ),
        );
    }

    private static function portfolios($audience = 'public') {
        $posts = get_posts(array(
            'post_type' => 'portfolio',
            'post_status' => 'publish',
            'posts_per_page' => 100,
            'orderby' => 'date',
            'order' => 'ASC',
            'no_found_rows' => true,
        ));
        $result = array();
        foreach ($posts as $post) {
            $gallery = json_decode((string) get_post_meta($post->ID, '_portfolio_gallery', true), true);
            if (!is_array($gallery) || !$gallery) {
                $gallery = get_children(array(
                    'post_parent' => $post->ID,
                    'post_type' => 'attachment',
                    'post_mime_type' => 'image',
                    'orderby' => 'ID',
                    'order' => 'ASC',
                    'fields' => 'ids',
                ));
            }
            $images = array();
            foreach (array_values(array_unique(array_filter(array_map('absint', (array) $gallery)))) as $media_id) {
                if (!wp_attachment_is_image($media_id)) { continue; }
                $full = wp_get_attachment_image_url($media_id, 'full');
                $display = wp_get_attachment_image_url($media_id, 'large');
                if (!$full || !self::trusted_media_url($full)) { continue; }
                $attachment_meta = wp_get_attachment_metadata($media_id);
                $attached_file = (string) get_post_meta($media_id, '_wp_attached_file', true);
                $metadata_file = is_array($attachment_meta) && !empty($attachment_meta['file'])
                    ? (string) $attachment_meta['file']
                    : '';
                $large_meta = is_array($attachment_meta) && isset($attachment_meta['sizes']['large'])
                    ? $attachment_meta['sizes']['large']
                    : null;
                if ($attached_file && $metadata_file && basename($attached_file) !== basename($metadata_file)) {
                    $display = $full;
                } elseif (
                    is_array($large_meta)
                    && !empty($attachment_meta['width'])
                    && !empty($attachment_meta['height'])
                    && !empty($large_meta['width'])
                    && !empty($large_meta['height'])
                ) {
                    $full_is_landscape = $attachment_meta['width'] > $attachment_meta['height'];
                    $large_is_landscape = $large_meta['width'] > $large_meta['height'];
                    if ($full_is_landscape !== $large_is_landscape) {
                        $display = $full;
                    }
                }
                $images[] = array(
                    'id' => $media_id,
                    'url' => self::trusted_media_url($display) ? $display : $full,
                    'fullSizeURL' => $full,
                    'altText' => get_post_meta($media_id, '_wp_attachment_image_alt', true) ?: get_the_title($post),
                );
            }
            $total_image_count = count($images);
            // The public website and generic WordPress routes stay closed. The
            // App feed currently exposes the complete gallery while paid
            // subscriptions are paused for TestFlight product testing.
            if ($audience === 'public') {
                $images = array_slice($images, 0, self::FREE_PREVIEW_COUNT);
            } elseif ($audience === 'premium') {
                $protected_images = array();
                foreach ($images as $image) {
                    $display = apply_filters(
                        'shuzijun_app_protected_media_url',
                        '',
                        $image['url'],
                        $image['id'],
                        'display'
                    );
                    $full = apply_filters(
                        'shuzijun_app_protected_media_url',
                        '',
                        $image['fullSizeURL'],
                        $image['id'],
                        'full'
                    );
                    if (!self::trusted_media_url($display) || !self::trusted_media_url($full)) { continue; }
                    $image['url'] = $display;
                    $image['fullSizeURL'] = $full;
                    $protected_images[] = $image;
                }
                $images = $protected_images;
            }
            $metadata = self::portfolio_metadata($post);
            $result[] = array(
                'id' => (int) $post->ID,
                'title' => $metadata['title'],
                'subtitle' => $metadata['subtitle'],
                'eyebrow' => $metadata['eyebrow'],
                'slug' => $post->post_name,
                'websiteURL' => get_permalink($post),
                'coverURL' => $images ? $images[0]['url'] : null,
                'totalImageCount' => $total_image_count,
                'images' => $images,
            );
        }
        return $result;
    }

    private static function portfolio_metadata(WP_Post $post) {
        $title = wp_strip_all_tags(get_the_title($post));
        if (strpos($title, '婚纱') !== false) {
            $fallback = array('title'=>'婚纱','subtitle'=>'在柔光里，留下誓约般的静谧','eyebrow'=>'WEDDING · PORTRAIT');
        } elseif (strpos($title, '新中式') !== false) {
            $fallback = array('title'=>'新中式','subtitle'=>'古意与当代表达之间的留白','eyebrow'=>'NEW CHINESE · EDITORIAL');
        } elseif (strpos($title, '旗袍') !== false) {
            $fallback = array('title'=>'旗袍','subtitle'=>'庭院、窗影与东方美学','eyebrow'=>'QIPAO · STORY');
        } else {
            $fallback = array('title'=>$title,'subtitle'=>'易姝影像作品','eyebrow'=>'PORTFOLIO');
        }
        return array(
            'title' => sanitize_text_field(get_post_meta($post->ID, '_app_title', true) ?: $fallback['title']),
            'subtitle' => sanitize_text_field(get_post_meta($post->ID, '_app_subtitle', true) ?: $fallback['subtitle']),
            'eyebrow' => sanitize_text_field(get_post_meta($post->ID, '_app_eyebrow', true) ?: $fallback['eyebrow']),
        );
    }

    private static function sanitize_showreel($value, $fallback) {
        $video = self::trusted_media_url(isset($value['videoURL']) ? $value['videoURL'] : '');
        $poster = self::trusted_media_url(isset($value['posterURL']) ? $value['posterURL'] : '');
        if (!$video || !$poster) {
            return new WP_Error('invalid_showreel_url', 'Showreel 和海报必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
        }
        $tags = isset($value['tags']) && is_array($value['tags']) ? $value['tags'] : $fallback['tags'];
        $sanitized_tags = array();
        foreach (array_slice(array_values($tags), 0, 8) as $tag) {
            if (!is_scalar($tag)) {
                return new WP_Error('invalid_showreel_tag', 'Showreel 标签格式无效。', array('status' => 400));
            }
            $tag = sanitize_text_field($tag);
            if (self::text_length($tag) > 80) {
                return new WP_Error('showreel_tag_too_long', 'Showreel 标签过长。', array('status' => 400));
            }
            if ($tag !== '' && !in_array($tag, $sanitized_tags, true)) {
                $sanitized_tags[] = $tag;
            }
        }
        $eyebrow = sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : $fallback['eyebrow']);
        $title = sanitize_text_field(isset($value['title']) ? $value['title'] : $fallback['title']);
        $summary = sanitize_text_field(isset($value['summary']) ? $value['summary'] : $fallback['summary']);
        $duration = sanitize_text_field(isset($value['durationLabel']) ? $value['durationLabel'] : $fallback['durationLabel']);
        if (self::text_length($eyebrow) > 120 || self::text_length($title) > 160
            || self::text_length($summary) > 500 || self::text_length($duration) > 20) {
            return new WP_Error('showreel_text_too_long', 'Showreel 文案过长。', array('status' => 400));
        }
        return array(
            'eyebrow' => $eyebrow,
            'title' => $title,
            'summary' => $summary,
            'durationLabel' => $duration,
            'videoURL' => $video,
            'posterURL' => $poster,
            'tags' => $sanitized_tags,
        );
    }

    private static function sanitize_launch_posters($values) {
        if (count($values) > 12) {
            return new WP_Error('too_many_launch_posters', '开屏海报最多 12 张。', array('status' => 400));
        }
        $result = array();
        $seen_ids = array();
        foreach (array_slice(array_values($values), 0, 12) as $index => $value) {
            if (!is_array($value)) {
                return new WP_Error('invalid_launch_poster', '开屏海报格式无效。', array('status' => 400));
            }
            foreach (array('id', 'imageURL', 'eyebrow', 'title', 'subtitle', 'startsAt', 'endsAt') as $field) {
                if (isset($value[$field]) && !is_scalar($value[$field])) {
                    return new WP_Error('invalid_launch_poster', '开屏海报字段格式无效。', array('status' => 400));
                }
            }
            if (isset($value['displaySeconds'])
                && (!is_scalar($value['displaySeconds']) || !is_numeric($value['displaySeconds']))) {
                return new WP_Error('invalid_launch_poster', '开屏海报展示时长格式无效。', array('status' => 400));
            }
            $image = self::trusted_media_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $eyebrow = sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : '');
            $subtitle = sanitize_text_field(isset($value['subtitle']) ? $value['subtitle'] : '');
            $starts_at = isset($value['startsAt']) ? strtotime((string) $value['startsAt']) : false;
            $ends_at = isset($value['endsAt']) ? strtotime((string) $value['endsAt']) : false;
            if (!$image || !$title || self::text_length($title) > 160
                || self::text_length($eyebrow) > 120 || self::text_length($subtitle) > 240
                || $starts_at === false || $ends_at === false || $starts_at >= $ends_at) {
                return new WP_Error(
                    'invalid_launch_poster',
                    '每张开屏海报都需要图片、标题和有效的起止日期。',
                    array('status' => 400)
                );
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'launch-poster-' . ($index + 1); }
            if (self::text_length($id) > 80 || isset($seen_ids[$id])) {
                return new WP_Error('duplicate_launch_poster', '开屏海报 ID 必须唯一且不超过 80 个字符。', array('status' => 400));
            }
            $seen_ids[$id] = true;
            $display_seconds = isset($value['displaySeconds']) ? floatval($value['displaySeconds']) : 2.5;
            if (!is_finite($display_seconds)) { $display_seconds = 2.5; }
            $result[] = array(
                'id' => $id,
                'isEnabled' => isset($value['isEnabled']) ? rest_sanitize_boolean($value['isEnabled']) : true,
                'imageURL' => $image,
                'eyebrow' => $eyebrow,
                'title' => $title,
                'subtitle' => $subtitle,
                'startsAt' => gmdate('c', $starts_at),
                'endsAt' => gmdate('c', $ends_at),
                'displaySeconds' => max(1.5, min(5.0, $display_seconds)),
            );
        }
        return $result;
    }

    private static function sanitize_dramas($values) {
        if (count($values) > 50) {
            return new WP_Error('too_many_dramas', '影视履历最多 50 条。', array('status' => 400));
        }
        $result = array();
        $seen_ids = array();
        foreach (array_slice(array_values($values), 0, 50) as $index => $value) {
            if (!is_array($value)) {
                return new WP_Error('invalid_drama', '影视履历格式无效。', array('status' => 400));
            }
            foreach (array('id', 'title', 'imageURL', 'destinationURL') as $field) {
                if (isset($value[$field]) && !is_scalar($value[$field])) {
                    return new WP_Error('invalid_drama', '影视履历字段格式无效。', array('status' => 400));
                }
            }
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $image = self::trusted_media_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $destination = self::trusted_destination_url(isset($value['destinationURL']) ? $value['destinationURL'] : '');
            if (!$title || self::text_length($title) > 200 || !$image || !$destination) {
                return new WP_Error('invalid_drama', '每部短剧都需要合规标题、受信任海报和 HTTPS 跳转地址。', array('status' => 400));
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'drama-' . ($index + 1); }
            if (self::text_length($id) > 80 || isset($seen_ids[$id])) {
                return new WP_Error('duplicate_drama', '影视履历 ID 必须唯一且不超过 80 个字符。', array('status' => 400));
            }
            $seen_ids[$id] = true;
            $result[] = array('id'=>$id, 'title'=>$title, 'imageURL'=>$image, 'destinationURL'=>$destination);
        }
        return $result;
    }

    private static function sanitize_image_urls($values, $maximum) {
        if (count($values) > $maximum) {
            return new WP_Error('too_many_image_urls', '主页封面数量超过上限。', array('status' => 400));
        }
        $result = array();
        foreach (array_slice(array_values($values), 0, $maximum) as $value) {
            $url = self::trusted_media_url($value);
            if (!$url) {
                return new WP_Error('invalid_image_url', '主页封面必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
            }
            if (!in_array($url, $result, true)) { $result[] = $url; }
        }
        if (!$result) {
            return new WP_Error('missing_hero_image', '至少保留一张主页封面。', array('status' => 400));
        }
        return $result;
    }

    private static function https_url($value) {
        if (!is_string($value)) { return ''; }
        if (strlen((string) $value) > 2048) { return ''; }
        $url = esc_url_raw((string) $value, array('https'));
        if (wp_parse_url($url, PHP_URL_SCHEME) !== 'https') { return ''; }
        if (wp_parse_url($url, PHP_URL_USER) || wp_parse_url($url, PHP_URL_PASS)) { return ''; }
        if (wp_parse_url($url, PHP_URL_FRAGMENT)) { return ''; }
        $port = wp_parse_url($url, PHP_URL_PORT);
        return !$port || (int) $port === 443 ? $url : '';
    }

    private static function sanitize_optional_media_url($value) {
        if ($value === null || $value === '') { return null; }
        if (!is_string($value)) {
            return new WP_Error('invalid_about_portrait', '关于页照片格式无效。', array('status' => 400));
        }
        $url = self::trusted_media_url($value);
        if (!$url) {
            return new WP_Error('invalid_about_portrait', '关于页照片必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
        }
        return $url;
    }

    private static function trusted_media_url($value) {
        $url = self::https_url($value);
        if (!$url) { return ''; }
        $host = strtolower((string) wp_parse_url($url, PHP_URL_HOST));
        $home_host = strtolower((string) wp_parse_url(home_url('/'), PHP_URL_HOST));
        $hosts = array_filter(array_unique(array(
            $home_host,
            'shuzijun.com.cn',
            'www.shuzijun.com.cn',
            'img.shuzijun.com.cn',
        )));
        $hosts = apply_filters('shuzijun_app_allowed_media_hosts', $hosts);
        $hosts = array_map('strtolower', array_map('strval', (array) $hosts));
        return in_array($host, $hosts, true) ? $url : '';
    }

    private static function trusted_destination_url($value) {
        $url = self::https_url($value);
        if (!$url) { return ''; }
        $host = strtolower((string) wp_parse_url($url, PHP_URL_HOST));
        $hosts = array(
            'novelquickapp.com',
            'www.novelquickapp.com',
            'xhslink.com',
            'www.xhslink.com',
            'v.douyin.com',
            'www.douyin.com',
            'www.xiaohongshu.com',
        );
        $hosts = apply_filters('shuzijun_app_allowed_destination_hosts', $hosts);
        $hosts = array_map('strtolower', array_map('strval', (array) $hosts));
        return in_array($host, $hosts, true) ? $url : '';
    }

    private static function text_length($value) {
        return function_exists('mb_strlen') ? mb_strlen((string) $value, 'UTF-8') : strlen((string) $value);
    }
}

Shuzijun_App_Content_API::init();
