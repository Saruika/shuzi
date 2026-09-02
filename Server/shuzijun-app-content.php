<?php
/**
 * Plugin Name: Shuzijun App Content API
 * Description: Versioned access-controlled content feed and least-privilege mobile publishing API for the Yi Shu app.
 * Version: 1.5.10
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

final class Shuzijun_App_Content_API {
    const OPTION_CONFIG = 'shuzijun_app_content_config';
    const OPTION_UPDATED = 'shuzijun_app_content_updated_at';
    const CAPABILITY = 'manage_yishu_app_content';
    const FAN_CAPABILITY = 'manage_yishu_fan_accounts';
    const COLLABORATION_CAPABILITY = 'manage_yishu_collaboration_requests';
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
    const FAN_META_ACCOUNT_SOURCE = '_yishu_fan_account_source';
    const FAN_META_APPLE_SUB_HASH = '_yishu_fan_apple_sub_hash';
    const FAN_META_APPLE_SETUP = '_yishu_fan_apple_setup';
    const FAN_META_APPLE_REFRESH_TOKEN = '_yishu_fan_apple_refresh_token';
    const FAN_META_APPLE_AUTH_IAT = '_yishu_fan_apple_auth_iat';
    const FAN_META_AUTH_AUDIT = '_yishu_fan_auth_audit';
    const FAN_CONSENT_VERSION = '2026-09-02-approval-v3';
    const FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS = array(
        '2026-08-31-approval-v2',
    );
    const FAN_DOUYIN_OPTION_PREFIX = 'yishu_fan_douyin_';
    const FAN_SESSION_OPTION_PREFIX = 'yishu_fan_session_';
    const FAN_APPLE_OPTION_PREFIX = 'yishu_fan_apple_';
    const FAN_APPLE_CHALLENGE_OPTION_PREFIX = 'yishu_fan_apple_challenge_';
    const FAN_APPLE_REVOCATION_OPTION_PREFIX = 'yishu_fan_apple_revocation_';
    const FAN_APPLE_REVOCATION_CURSOR_OPTION = 'yishu_fan_apple_revoke_cursor_v1';
    const FAN_APPLE_EVENT_OPTION_PREFIX = 'yishu_fan_apple_event_';
    const FAN_APPLE_EVENT_CURSOR_OPTION = 'yishu_fan_cursor_apple_event_v1';
    const FAN_APPLE_TOMBSTONE_OPTION_PREFIX = 'yishu_fan_apple_revoked_';
    const FAN_APPLE_TOMBSTONE_CURSOR_OPTION = 'yishu_fan_cursor_apple_tombstone_v1';
    const FAN_SESSION_TTL = 2592000;
    const FAN_ONBOARDING_SESSION_TTL = 600;
    const FAN_PASSWORD_RECOVERY_SESSION_TTL = 600;
    const FAN_PASSWORD_RECOVERY_TTL = 900;
    const FAN_APPLE_CHALLENGE_TTL = 300;
    const FAN_APPLE_ONBOARDING_SESSION_TTL = 600;
    const FAN_APPLE_PENDING_ACCOUNT_TTL = 600;
    const FAN_APPLE_RECENT_AUTH_TTL = 600;
    const FAN_APPLE_REVOCATION_TTL = 604800;
    const FAN_APPLE_REVOCATION_MAX_ATTEMPTS = 8;
    const FAN_APPLE_TOMBSTONE_TTL = 2592000;
    const FAN_APPLE_ISSUER = 'https://appleid.apple.com';
    const FAN_APPLE_CLIENT_ID = 'cn.com.shuzijun.yishu';
    const FAN_APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
    const ACCOUNT_AUTHORITY_ROLE_PATH = '/etc/shuzijun/account-authority-role';
    // Build 41 ships the dormant collaboration implementation with an
    // irreversible release-level fuse. An external wp-config constant is only
    // a future second gate; it cannot activate code from this release.
    const COLLABORATION_PHASE1_RELEASE_FUSE = false;
    const FAN_INVITATION_TTL = 86400;
    const FAN_MAX_INSTALLATIONS = 16;
    const FAN_MAX_SESSIONS = 8;
    const COLLABORATION_SCHEMA_OPTION = 'yishu_collaboration_schema_version';
    const COLLABORATION_SCHEMA_VERSION = 1;
    const COLLABORATION_EMAIL = '369476120@qq.com';
    const COLLABORATION_OUTBOX_HOOK = 'yishu_process_collaboration_outbox';
    const COLLABORATION_SWEEP_HOOK = 'yishu_sweep_collaboration_outbox';
    const COLLABORATION_OUTBOX_MAX_ATTEMPTS = 5;
    const COLLABORATION_OUTBOX_LEASE_SECONDS = 300;
    private static $fan_session_context = null;

    /**
     * Phase 1 is intentionally unavailable in Build 41 even if an external
     * configuration defines the future strict-boolean opt-in. Do not replace
     * either gate with an option, request value, environment variable or
     * filter: the incomplete privacy/database work must not be remotely enabled.
     */
    public static function collaboration_phase1_enabled() {
        return self::COLLABORATION_PHASE1_RELEASE_FUSE === true
            && defined('YISHU_ENABLE_COLLABORATION_PHASE1')
            && constant('YISHU_ENABLE_COLLABORATION_PHASE1') === true;
    }

    /** Return whether a submitted version exactly matches the current policy. */
    public static function fan_consent_version_is_current($version) {
        return is_string($version)
            && hash_equals(self::FAN_CONSENT_VERSION, $version);
    }

    /**
     * Release 1.5.10 is the bounded Build 40/41 rollout bridge: a new
     * acknowledgement may use the current v3 or an exact allowlisted v2.
     * Missing, malformed and unknown versions still fail closed. A later
     * release must remove this new-acknowledgement bridge after Build 40 is
     * retired, without rewriting the version the client actually submitted.
     */
    public static function fan_new_consent_version_is_accepted($version) {
        if (self::fan_consent_version_is_current($version)) { return true; }
        return is_string($version)
            && in_array($version, self::FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS, true);
    }

    /**
     * Existing accounts may retain an explicitly allowlisted historical
     * acknowledgement. This compatibility path prevents an App/server
     * rollout from invalidating already approved accounts while still
     * failing closed for missing, malformed or unknown consent records.
     */
    public static function fan_stored_consent_is_accepted($consent) {
        if (!is_array($consent)) { return false; }
        $version = $consent['version'] ?? null;
        if (self::fan_consent_version_is_current($version)) { return true; }
        return is_string($version)
            && in_array($version, self::FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS, true);
    }

    public static function init() {
        add_action('rest_api_init', array(__CLASS__, 'register_routes'));
        add_action('template_redirect', array(__CLASS__, 'block_public_portfolio_pages'), 1);
        add_action('pre_get_posts', array(__CLASS__, 'hide_public_portfolio_queries'));
        add_action('wp_head', array(__CLASS__, 'hide_public_portfolio_section'));
        // Account state is single-writer. Only the node whose root-owned fixed
        // role marker says `authority` may register asynchronous mutations. A
        // copied database, site configuration, hostname or forwarding header can never
        // promote a standby node.
        if (self::account_authority_enabled()) {
            add_action('init', array(__CLASS__, 'ensure_roles'), 20);
            add_action('save_post_portfolio', array(__CLASS__, 'portfolio_changed'), 20, 3);
            add_action('yishu_cleanup_fan_session', array(__CLASS__, 'cleanup_fan_session'), 10, 2);
            add_action('yishu_cleanup_fan_invitation', array(__CLASS__, 'cleanup_fan_invitation'), 10, 4);
            add_action('yishu_cleanup_fan_apple_challenge', array(__CLASS__, 'cleanup_fan_apple_challenge'), 10, 2);
            add_action('yishu_cleanup_fan_apple_pending_account', array(__CLASS__, 'cleanup_fan_apple_pending_account'), 10, 2);
            add_action('yishu_retry_fan_apple_revocation', array(__CLASS__, 'retry_fan_apple_revocation'), 10, 2);
            add_action('yishu_cleanup_fan_apple_event', array(__CLASS__, 'cleanup_fan_apple_event'), 10, 2);
            add_action('yishu_process_fan_apple_event', array(__CLASS__, 'process_fan_apple_event'), 10, 2);
            add_action('yishu_cleanup_fan_apple_tombstone', array(__CLASS__, 'cleanup_fan_apple_tombstone'), 10, 2);
            add_action('init', array(__CLASS__, 'ensure_fan_apple_revocation_schedule'), 40);
            add_action('init', array(__CLASS__, 'ensure_fan_apple_event_schedule'), 41);
            add_action('init', array(__CLASS__, 'ensure_fan_apple_tombstone_schedule'), 42);
            if (self::collaboration_phase1_enabled()) {
                add_action('init', array(__CLASS__, 'ensure_collaboration_storage'), 21);
                add_action(self::COLLABORATION_OUTBOX_HOOK, array(__CLASS__, 'process_collaboration_outbox'), 10, 1);
                add_action(self::COLLABORATION_SWEEP_HOOK, array(__CLASS__, 'sweep_collaboration_outbox'), 10, 0);
                add_action('init', array(__CLASS__, 'ensure_collaboration_outbox_schedule'), 43);
            }
            add_action('delete_user', array(__CLASS__, 'prepare_fan_user_deletion'), 10, 1);
        }
        add_filter('rest_post_dispatch', array(__CLASS__, 'secure_rest_response'), 10, 3);
        add_filter('rest_pre_dispatch', array(__CLASS__, 'enforce_account_authority'), 0, 3);
        add_filter('rest_pre_dispatch', array(__CLASS__, 'block_public_catalog_routes'), 10, 3);
        add_filter('wp_sitemaps_post_types', array(__CLASS__, 'remove_portfolios_from_sitemaps'));
        add_filter('theme_mod_hero_cta', array(__CLASS__, 'public_hero_cta'));
        add_filter('theme_mod_hero_cta_link', array(__CLASS__, 'public_hero_cta_link'));
        add_filter('wp_authenticate_user', array(__CLASS__, 'block_fan_wordpress_login'), 99, 2);

        // Application Passwords are revocable, per-client credentials intended
        // for HTTPS REST clients. Keep the site's global disable policy and
        // restrict dedicated administrator credentials to this plugin's caps.
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
            if (self::collaboration_phase1_enabled()
                && !$role->has_cap(self::COLLABORATION_CAPABILITY)) {
                $role->add_cap(self::COLLABORATION_CAPABILITY, true);
            }
        }
        $administrator = get_role('administrator');
        if ($administrator && !$administrator->has_cap(self::CAPABILITY)) {
            $administrator->add_cap(self::CAPABILITY, true);
        }
        if ($administrator && !$administrator->has_cap(self::FAN_CAPABILITY)) {
            $administrator->add_cap(self::FAN_CAPABILITY, true);
        }
        if (self::collaboration_phase1_enabled()
            && $administrator
            && !$administrator->has_cap(self::COLLABORATION_CAPABILITY)) {
            $administrator->add_cap(self::COLLABORATION_CAPABILITY, true);
        }
    }

    public static function application_passwords_for_user($available, $user) {
        return $user instanceof WP_User
            && (user_can($user, self::CAPABILITY)
                || user_can($user, self::FAN_CAPABILITY)
                || (self::collaboration_phase1_enabled()
                    && user_can($user, self::COLLABORATION_CAPABILITY)));
    }

    public static function account_authority_enabled() {
        $path = self::ACCOUNT_AUTHORITY_ROLE_PATH;
        $test_override = false;
        if (self::apple_test_mode_enabled()
            && defined('YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH')
            && is_string(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH)) {
            // macOS may expose the temporary directory through `/var` while
            // realpath resolves it through `/private/var`. Resolve both sides
            // before enforcing the test-only containment boundary.
            $test_path = realpath(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH);
            $test_root = realpath(sys_get_temp_dir());
            if (is_string($test_path)
                && is_string($test_root)
                && strpos($test_path, rtrim($test_root, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR) === 0) {
                $path = $test_path;
                $test_override = true;
            }
        }

        if (!$test_override) {
            foreach (array('/etc', '/etc/shuzijun') as $parent) {
                $parent_stat = @lstat($parent);
                if (!is_array($parent_stat)
                    || ($parent_stat['mode'] & 0170000) !== 0040000
                    || (int) ($parent_stat['uid'] ?? -1) !== 0
                    || (int) ($parent_stat['gid'] ?? -1) !== 0
                    || ($parent_stat['mode'] & 0777) !== 0755
                    || is_link($parent)
                    || realpath($parent) !== $parent) {
                    return false;
                }
            }
        }

        clearstatcache(true, $path);
        if (is_link($path) || realpath($path) !== $path) { return false; }
        $before = @lstat($path);
        if (!is_array($before)) { return false; }
        $handle = @fopen($path, 'rb');
        if (!is_resource($handle)) { return false; }
        $opened = fstat($handle);
        $payload = stream_get_contents($handle, 16);
        $extra = fread($handle, 1);
        fclose($handle);
        if (!is_array($opened)
            || ($opened['mode'] & 0170000) !== 0100000
            || (int) ($opened['nlink'] ?? 0) !== 1
            || (int) ($opened['dev'] ?? -1) !== (int) ($before['dev'] ?? -2)
            || (int) ($opened['ino'] ?? -1) !== (int) ($before['ino'] ?? -2)
            || ($opened['mode'] & 0777) !== 0644) {
            return false;
        }
        if ($test_override) {
            if ((int) ($opened['uid'] ?? -1) !== (int) getmyuid()
                || (int) ($opened['gid'] ?? -1) !== (int) getmygid()) {
                return false;
            }
        } elseif ((int) ($opened['uid'] ?? -1) !== 0
            || (int) ($opened['gid'] ?? -1) !== 0) {
            return false;
        }
        return $payload === "authority\n" && $extra === '';
    }

    public static function enforce_account_authority($result, $server, $request) {
        if (!$request instanceof WP_REST_Request
            || strpos((string) $request->get_route(), '/shuzijun/v1/') !== 0
            || self::account_authority_enabled()) {
            return $result;
        }
        // This gate runs after WordPress has normalized pretty and query-form
        // REST requests to the same route, so both /?rest_route= and
        // /index.php?rest_route= fail closed on a standby. Do not infer node
        // authority from Host, REMOTE_ADDR or any client-controlled header.
        return new WP_Error(
            'yishu_account_authority_unavailable',
            '账号服务暂时不可用，请稍后再试。',
            array('status' => 503)
        );
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

        register_rest_route('shuzijun/v1', '/fan/apple-challenge', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_fan_apple_challenge'),
            'permission_callback' => array(__CLASS__, 'can_create_fan_apple_challenge'),
        ));

        register_rest_route('shuzijun/v1', '/fan/apple-auth', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'authenticate_fan_with_apple'),
            'permission_callback' => '__return_true',
        ));

        register_rest_route('shuzijun/v1', '/fan/complete-apple-registration', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'complete_fan_apple_registration'),
            'permission_callback' => array(__CLASS__, 'can_complete_fan_apple_registration'),
        ));

        register_rest_route('shuzijun/v1', '/fan/apple-delete', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'delete_fan_apple_account'),
            'permission_callback' => array(__CLASS__, 'can_delete_fan_apple_account'),
        ));

        register_rest_route('shuzijun/v1', '/fan/apple-notifications', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'handle_fan_apple_notification'),
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

        if (self::collaboration_phase1_enabled()) {
            register_rest_route('shuzijun/v1', '/collaboration-requests', array(
                'methods' => WP_REST_Server::CREATABLE,
                'callback' => array(__CLASS__, 'create_collaboration_request'),
                'permission_callback' => array(__CLASS__, 'can_submit_collaboration'),
            ));

            register_rest_route('shuzijun/v1', '/app-admin/collaboration-requests', array(
                'methods' => WP_REST_Server::READABLE,
                'callback' => array(__CLASS__, 'list_collaboration_requests'),
                'permission_callback' => array(__CLASS__, 'can_manage_collaboration'),
            ));

            register_rest_route(
                'shuzijun/v1',
                '/app-admin/collaboration-requests/(?P<request_id>[a-f0-9-]{36})',
                array(
                    'methods' => WP_REST_Server::EDITABLE,
                    'callback' => array(__CLASS__, 'update_collaboration_request'),
                    'permission_callback' => array(__CLASS__, 'can_manage_collaboration'),
                )
            );
        }

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

    public static function can_manage_collaboration($request = null) {
        if (!self::collaboration_phase1_enabled()) { return false; }
        return self::can_manage_capability(
            $request,
            self::COLLABORATION_CAPABILITY,
            'yishu_collaboration_admin_rate_'
        );
    }

    public static function can_submit_collaboration(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()) { return false; }
        // A content manager is intentionally not a substitute for an approved
        // fan here. Clear any previous request context before delegating to the
        // same account-status gate used by the protected app manifest.
        self::$fan_session_context = null;
        $access = self::can_access_app_content($request);
        if ($access !== true) { return $access; }
        $context = self::$fan_session_context;
        if (!is_array($context)
            || ($context['scope'] ?? '') !== 'normal'
            || (int) ($context['userID'] ?? 0) <= 0) {
            return new WP_Error(
                'collaboration_fan_required',
                '仅已批准的粉丝账号可提交合作邀约。',
                array('status' => 403)
            );
        }
        return true;
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

    public static function ensure_collaboration_storage() {
        if (!self::collaboration_phase1_enabled()
            || !self::account_authority_enabled()) { return false; }
        if ((int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                === self::COLLABORATION_SCHEMA_VERSION
            && self::collaboration_tables_exist()) {
            return true;
        }

        $lock = self::acquire_named_fan_lock('collab_schema', 'version-1');
        if (is_wp_error($lock)) {
            do_action('yishu_collaboration_security_audit', 'schema_lock_unavailable');
            return false;
        }
        try {
            if ((int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                    === self::COLLABORATION_SCHEMA_VERSION
                && self::collaboration_tables_exist()) {
                return true;
            }

            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'get_charset_collate')) { return false; }
            if (!function_exists('dbDelta')) {
                require_once ABSPATH . 'wp-admin/includes/upgrade.php';
            }
            if (!function_exists('dbDelta')) { return false; }

            $tables = self::collaboration_tables();
            if (!$tables) { return false; }
            $charset = $wpdb->get_charset_collate();
            $requests_sql = "CREATE TABLE {$tables['requests']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                public_id char(36) NOT NULL,
                submission_id char(36) NOT NULL,
                fan_user_id bigint(20) unsigned NOT NULL,
                install_hash char(64) NOT NULL,
                network_hash char(64) NOT NULL,
                contact_name varchar(120) NOT NULL,
                contact_method varchar(255) NOT NULL,
                organization varchar(160) NOT NULL DEFAULT '',
                project_type varchar(40) NOT NULL,
                city varchar(120) NOT NULL DEFAULT '',
                preferred_date date NULL,
                budget varchar(120) NOT NULL DEFAULT '',
                details text NOT NULL,
                payload_hash char(64) NOT NULL,
                status varchar(24) NOT NULL DEFAULT 'received',
                status_updated_by bigint(20) unsigned NULL,
                version bigint(20) unsigned NOT NULL DEFAULT 1,
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY public_id (public_id),
                UNIQUE KEY fan_submission (fan_user_id, submission_id),
                KEY status_created (status, created_at),
                KEY fan_created (fan_user_id, created_at)
            ) ENGINE=InnoDB {$charset};";
            $outbox_sql = "CREATE TABLE {$tables['outbox']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                request_id bigint(20) unsigned NOT NULL,
                channel varchar(32) NOT NULL,
                dedupe_key char(64) NOT NULL,
                status varchar(20) NOT NULL DEFAULT 'pending',
                attempts smallint(5) unsigned NOT NULL DEFAULT 0,
                next_attempt_at datetime NOT NULL,
                lease_token char(32) NULL,
                lease_until datetime NULL,
                last_error_code varchar(80) NOT NULL DEFAULT '',
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY dedupe_key (dedupe_key),
                KEY due_jobs (status, next_attempt_at),
                UNIQUE KEY request_channel (request_id, channel)
            ) ENGINE=InnoDB {$charset};";
            $audit_sql = "CREATE TABLE {$tables['audit']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                request_id bigint(20) unsigned NOT NULL,
                actor_type varchar(20) NOT NULL,
                actor_id bigint(20) unsigned NOT NULL DEFAULT 0,
                event varchar(64) NOT NULL,
                result varchar(32) NOT NULL,
                metadata_json text NOT NULL,
                created_at datetime NOT NULL,
                PRIMARY KEY  (id),
                KEY request_created (request_id, created_at),
                KEY event_created (event, created_at)
            ) ENGINE=InnoDB {$charset};";
            dbDelta($requests_sql);
            dbDelta($outbox_sql);
            dbDelta($audit_sql);
            if (!self::collaboration_tables_exist()) {
                do_action('yishu_collaboration_security_audit', 'schema_creation_failed');
                return false;
            }
            $saved = update_option(
                self::COLLABORATION_SCHEMA_OPTION,
                self::COLLABORATION_SCHEMA_VERSION,
                false
            );
            return $saved
                || (int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                    === self::COLLABORATION_SCHEMA_VERSION;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    public static function create_collaboration_request(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()) {
            return self::collaboration_feature_disabled_error();
        }
        $context = self::$fan_session_context;
        if (!is_array($context) || (int) ($context['userID'] ?? 0) <= 0
            || ($context['scope'] ?? '') !== 'normal') {
            return new WP_Error(
                'collaboration_fan_required',
                '请使用已批准的粉丝账号重新登录。',
                array('status' => 403)
            );
        }
        $input = self::sanitize_collaboration_submission($request);
        if (is_wp_error($input)) { return $input; }
        if (!self::collaboration_storage_ready()) {
            return self::collaboration_storage_error();
        }

        $fan_user_id = (int) $context['userID'];
        $existing = self::find_collaboration_submission(
            $fan_user_id,
            (string) $input['submissionID']
        );
        if (is_wp_error($existing)) { return $existing; }
        if (is_array($existing)) {
            return self::collaboration_submission_response($existing, $input['payloadHash'], true);
        }

        $install_id = self::request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        foreach (array(
            array('collaboration_user', (string) $fan_user_id, 12, HOUR_IN_SECONDS),
            array('collaboration_install', $install_id, 12, HOUR_IN_SECONDS),
            array('collaboration_net', self::request_network_fingerprint(), 30, HOUR_IN_SECONDS),
        ) as $rate) {
            $allowed = self::rate_limit($rate[0], $rate[1], $rate[2], $rate[3]);
            if (is_wp_error($allowed)) { return $allowed; }
        }

        $lock = self::acquire_named_fan_lock(
            'collab_submit',
            $fan_user_id . '|' . (string) $input['submissionID']
        );
        if (is_wp_error($lock)) {
            return new WP_Error(
                'collaboration_submission_busy',
                '邀约正在提交，请稍后重试。',
                array('status' => 409)
            );
        }

        try {
            $existing = self::find_collaboration_submission(
                $fan_user_id,
                (string) $input['submissionID']
            );
            if (is_wp_error($existing)) { return $existing; }
            if (is_array($existing)) {
                return self::collaboration_submission_response($existing, $input['payloadHash'], true);
            }

            global $wpdb;
            $tables = self::collaboration_tables();
            if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
                || !method_exists($wpdb, 'insert') || $wpdb->query('START TRANSACTION') === false) {
                return self::collaboration_storage_error();
            }
            $committed = false;
            try {
                $public_id = strtolower((string) wp_generate_uuid4());
                if (!self::is_uuid_v4($public_id)) {
                    throw new RuntimeException('public_id_unavailable');
                }
                $now = gmdate('Y-m-d H:i:s');
                $inserted = $wpdb->insert($tables['requests'], array(
                    'public_id' => $public_id,
                    'submission_id' => (string) $input['submissionID'],
                    'fan_user_id' => $fan_user_id,
                    'install_hash' => hash('sha256', strtolower($install_id)),
                    'network_hash' => self::request_network_fingerprint(),
                    'contact_name' => (string) $input['contactName'],
                    'contact_method' => (string) $input['contactMethod'],
                    'organization' => (string) $input['organization'],
                    'project_type' => (string) $input['projectType'],
                    'city' => (string) $input['city'],
                    'preferred_date' => $input['preferredDate'] ?: null,
                    'budget' => (string) $input['budget'],
                    'details' => (string) $input['details'],
                    'payload_hash' => (string) $input['payloadHash'],
                    'status' => 'received',
                    'status_updated_by' => null,
                    'version' => 1,
                    'created_at' => $now,
                    'updated_at' => $now,
                ), array(
                    '%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s', '%s',
                    '%s', '%s', '%s', '%s', '%s', '%d', '%d', '%s', '%s',
                ));
                if ($inserted !== 1) { throw new RuntimeException('request_insert_failed'); }
                $request_id = (int) $wpdb->insert_id;
                $outbox_inserted = $wpdb->insert($tables['outbox'], array(
                    'request_id' => $request_id,
                    'channel' => 'work_mail',
                    'dedupe_key' => hash('sha256', $public_id . '|work_mail'),
                    'status' => 'pending',
                    'attempts' => 0,
                    'next_attempt_at' => $now,
                    'lease_token' => null,
                    'lease_until' => null,
                    'last_error_code' => '',
                    'created_at' => $now,
                    'updated_at' => $now,
                ), array('%d', '%s', '%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s'));
                if ($outbox_inserted !== 1) { throw new RuntimeException('outbox_insert_failed'); }
                $outbox_id = (int) $wpdb->insert_id;
                if (!self::record_collaboration_audit(
                    $request_id,
                    'fan',
                    $fan_user_id,
                    'request_received',
                    'accepted',
                    array('toStatus' => 'received')
                )) {
                    throw new RuntimeException('audit_insert_failed');
                }
                if ($wpdb->query('COMMIT') === false) {
                    throw new RuntimeException('commit_failed');
                }
                $committed = true;

                self::schedule_collaboration_outbox_job($outbox_id, time() + 5);
                return self::collaboration_submission_response(array(
                    'id' => $request_id,
                    'public_id' => $public_id,
                    'payload_hash' => (string) $input['payloadHash'],
                    'status' => 'received',
                    'created_at' => $now,
                ), $input['payloadHash'], false);
            } catch (Throwable $error) {
                if (!$committed) { $wpdb->query('ROLLBACK'); }
                do_action('yishu_collaboration_security_audit', 'submission_persistence_failed');
                return self::collaboration_storage_error();
            }
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    public static function list_collaboration_requests(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()) {
            return self::collaboration_feature_disabled_error();
        }
        if (!self::collaboration_storage_ready()) { return self::collaboration_storage_error(); }
        $status = sanitize_key((string) $request->get_param('status'));
        if ($status !== '' && !in_array($status, self::collaboration_request_statuses(), true)) {
            return new WP_Error(
                'collaboration_status_invalid',
                '合作邀约状态无效。',
                array('status' => 400)
            );
        }
        $page = min(100000, max(1, (int) $request->get_param('page')));
        $per_page = (int) $request->get_param('perPage');
        $per_page = $per_page > 0 ? min(100, $per_page) : 50;
        $offset = ($page - 1) * $per_page;

        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return self::collaboration_storage_error();
        }
        $select = "SELECT r.*, o.status AS mail_status, o.attempts AS mail_attempts,
                o.last_error_code AS mail_error_code
            FROM {$tables['requests']} r
            LEFT JOIN {$tables['outbox']} o
              ON o.request_id = r.id AND o.channel = 'work_mail'";
        if ($status !== '') {
            $rows = $wpdb->get_results($wpdb->prepare(
                $select . ' WHERE r.status = %s ORDER BY r.created_at DESC, r.id DESC LIMIT %d OFFSET %d',
                $status,
                $per_page,
                $offset
            ), ARRAY_A);
            $total = (int) $wpdb->get_var($wpdb->prepare(
                "SELECT COUNT(*) FROM {$tables['requests']} WHERE status = %s",
                $status
            ));
        } else {
            $rows = $wpdb->get_results($wpdb->prepare(
                $select . ' ORDER BY r.created_at DESC, r.id DESC LIMIT %d OFFSET %d',
                $per_page,
                $offset
            ), ARRAY_A);
            $total = (int) $wpdb->get_var("SELECT COUNT(*) FROM {$tables['requests']}");
        }
        if (!is_array($rows) || !empty($wpdb->last_error)) {
            return self::collaboration_storage_error();
        }
        $items = array();
        foreach ($rows as $row) {
            if (is_array($row)) { $items[] = self::collaboration_admin_record($row); }
        }
        $response = rest_ensure_response(array(
            'requests' => $items,
            'page' => $page,
            'perPage' => $per_page,
            'total' => $total,
            'statuses' => self::collaboration_request_statuses(),
        ));
        self::set_private_no_store_headers($response);
        return $response;
    }

    public static function update_collaboration_request(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()) {
            return self::collaboration_feature_disabled_error();
        }
        if (!self::collaboration_storage_ready()) { return self::collaboration_storage_error(); }
        $public_id = strtolower(trim((string) $request->get_param('request_id')));
        if (!self::is_uuid_v4($public_id)) {
            return new WP_Error('collaboration_not_found', '合作邀约不存在。', array('status' => 404));
        }
        $status = sanitize_key((string) $request->get_param('status'));
        if (!in_array($status, self::collaboration_request_statuses(), true)) {
            return new WP_Error('collaboration_status_invalid', '合作邀约状态无效。', array('status' => 400));
        }
        $raw_version = $request->get_param('version');
        if (!is_scalar($raw_version) || !preg_match('/^[1-9][0-9]{0,18}$/', (string) $raw_version)) {
            return new WP_Error(
                'collaboration_version_required',
                '请刷新合作邀约后再更新。',
                array('status' => 400)
            );
        }
        $expected_version = (int) $raw_version;

        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'update')
            || $wpdb->query('START TRANSACTION') === false) {
            return self::collaboration_storage_error();
        }
        $committed = false;
        try {
            $row = $wpdb->get_row($wpdb->prepare(
                "SELECT * FROM {$tables['requests']} WHERE public_id = %s LIMIT 1 FOR UPDATE",
                $public_id
            ), ARRAY_A);
            if (!is_array($row)) {
                $wpdb->query('ROLLBACK');
                return new WP_Error('collaboration_not_found', '合作邀约不存在。', array('status' => 404));
            }
            if ((int) ($row['version'] ?? 0) !== $expected_version) {
                $wpdb->query('ROLLBACK');
                return new WP_Error(
                    'collaboration_version_conflict',
                    '合作邀约已被其他管理员更新，请刷新后重试。',
                    array('status' => 409)
                );
            }
            $previous_status = (string) $row['status'];
            if ($previous_status === $status) {
                if ($wpdb->query('COMMIT') === false) {
                    throw new RuntimeException('commit_failed');
                }
                $committed = true;
                $row = self::attach_collaboration_delivery($row);
                $response = rest_ensure_response(array(
                    'request' => self::collaboration_admin_record($row),
                ));
                self::set_private_no_store_headers($response);
                return $response;
            }
            $now = gmdate('Y-m-d H:i:s');
            $updated = $wpdb->update($tables['requests'], array(
                'status' => $status,
                'status_updated_by' => (int) get_current_user_id(),
                'version' => $expected_version + 1,
                'updated_at' => $now,
            ), array(
                'id' => (int) $row['id'],
                'version' => $expected_version,
            ), array('%s', '%d', '%d', '%s'), array('%d', '%d'));
            if ($updated !== 1 || !self::record_collaboration_audit(
                (int) $row['id'],
                'administrator',
                (int) get_current_user_id(),
                'request_status_updated',
                'accepted',
                array(
                    'fromStatus' => $previous_status,
                    'toStatus' => $status,
                    'version' => $expected_version + 1,
                )
            )) {
                throw new RuntimeException('status_update_failed');
            }
            if ($wpdb->query('COMMIT') === false) { throw new RuntimeException('commit_failed'); }
            $committed = true;
            $row['status'] = $status;
            $row['status_updated_by'] = (int) get_current_user_id();
            $row['version'] = $expected_version + 1;
            $row['updated_at'] = $now;
            $row = self::attach_collaboration_delivery($row);
            $response = rest_ensure_response(array(
                'request' => self::collaboration_admin_record($row),
            ));
            self::set_private_no_store_headers($response);
            return $response;
        } catch (Throwable $error) {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
            do_action('yishu_collaboration_security_audit', 'status_update_failed');
            return self::collaboration_storage_error();
        }
    }

    public static function ensure_collaboration_outbox_schedule() {
        if (!self::collaboration_phase1_enabled()
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        if (wp_next_scheduled(self::COLLABORATION_SWEEP_HOOK) !== false) { return true; }
        $scheduled = wp_schedule_single_event(
            time() + 300,
            self::COLLABORATION_SWEEP_HOOK,
            array(),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            do_action('yishu_collaboration_security_audit', 'outbox_sweep_schedule_failed');
            return false;
        }
        return true;
    }

    public static function sweep_collaboration_outbox() {
        if (!self::collaboration_phase1_enabled()
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        self::mark_exhausted_collaboration_outbox_jobs($now);
        $ids = $wpdb->get_col($wpdb->prepare(
            "SELECT id FROM {$tables['outbox']}
             WHERE attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))
             ORDER BY next_attempt_at ASC, id ASC LIMIT 20",
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if (is_array($ids)) {
            foreach ($ids as $id) {
                if ((int) $id > 0) { self::process_collaboration_outbox((int) $id); }
            }
        }
        self::ensure_collaboration_outbox_schedule();
        return is_array($ids);
    }

    public static function process_collaboration_outbox($job_id) {
        $job_id = (int) $job_id;
        if (!self::collaboration_phase1_enabled()
            || $job_id <= 0
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        try {
            $lease_token = bin2hex(random_bytes(16));
        } catch (Throwable $error) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        $lease_until = gmdate('Y-m-d H:i:s', time() + self::COLLABORATION_OUTBOX_LEASE_SECONDS);
        $claimed = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'processing', attempts = attempts + 1,
                 lease_token = %s, lease_until = %s, updated_at = %s
             WHERE id = %d AND attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))",
            $lease_token,
            $lease_until,
            $now,
            $job_id,
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if ($claimed !== 1) { return false; }
        $job = $wpdb->get_row($wpdb->prepare(
            "SELECT o.*, r.public_id, r.contact_name, r.contact_method,
                    r.organization, r.project_type, r.city, r.preferred_date,
                    r.budget, r.details
             FROM {$tables['outbox']} o
             INNER JOIN {$tables['requests']} r ON r.id = o.request_id
             WHERE o.id = %d AND o.lease_token = %s LIMIT 1",
            $job_id,
            $lease_token
        ), ARRAY_A);
        if (!is_array($job)) {
            self::fail_collaboration_outbox_job($job_id, $lease_token, 1, 'request_missing');
            return false;
        }

        $sent = false;
        $error_code = 'mail_rejected';
        if ((string) ($job['channel'] ?? '') !== 'work_mail') {
            $error_code = 'channel_invalid';
        } else {
            $recipient = self::collaboration_work_email();
            if (!$recipient) {
                $error_code = 'recipient_unavailable';
            } else {
                try {
                    $sent = wp_mail(
                        $recipient,
                        '易姝合作邀约 #' . (string) $job['public_id'],
                        self::collaboration_mail_body($job),
                        array('Content-Type: text/plain; charset=UTF-8')
                    ) === true;
                } catch (Throwable $error) {
                    $sent = false;
                    $error_code = 'mail_exception';
                }
            }
        }
        if (!$sent) {
            self::fail_collaboration_outbox_job(
                $job_id,
                $lease_token,
                (int) ($job['attempts'] ?? 1),
                $error_code
            );
            return false;
        }

        $updated = $wpdb->update($tables['outbox'], array(
            'status' => 'sent',
            'lease_token' => null,
            'lease_until' => null,
            'last_error_code' => '',
            'updated_at' => gmdate('Y-m-d H:i:s'),
        ), array(
            'id' => $job_id,
            'lease_token' => $lease_token,
        ), array('%s', '%s', '%s', '%s', '%s'), array('%d', '%s'));
        if ($updated !== 1) { return false; }
        self::record_collaboration_audit(
            (int) $job['request_id'],
            'system',
            0,
            'work_mail_accepted',
            'accepted',
            array('channel' => 'work_mail', 'attempt' => (int) $job['attempts'])
        );
        return true;
    }

    private static function collaboration_tables() {
        if (!self::collaboration_phase1_enabled()) { return null; }
        global $wpdb;
        if (!isset($wpdb) || !isset($wpdb->prefix)) { return array(); }
        return array(
            'requests' => $wpdb->prefix . 'yishu_collaboration_requests',
            'outbox' => $wpdb->prefix . 'yishu_collaboration_outbox',
            'audit' => $wpdb->prefix . 'yishu_collaboration_audit',
        );
    }

    private static function collaboration_tables_exist() {
        if (!self::collaboration_phase1_enabled()) { return false; }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return false;
        }
        foreach ($tables as $table) {
            $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
            if (!is_string($found) || !hash_equals($table, $found)) { return false; }
        }
        return true;
    }

    private static function collaboration_storage_ready() {
        return self::collaboration_phase1_enabled()
            && self::account_authority_enabled()
            && (int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                === self::COLLABORATION_SCHEMA_VERSION
            && self::collaboration_tables_exist();
    }

    private static function collaboration_feature_disabled_error() {
        return new WP_Error(
            'collaboration_feature_disabled',
            '合作邀约服务尚未开放。',
            array('status' => 404)
        );
    }

    private static function collaboration_storage_error() {
        return new WP_Error(
            'collaboration_storage_unavailable',
            '合作邀约服务暂时不可用，请稍后重试。',
            array('status' => 503)
        );
    }

    private static function sanitize_collaboration_submission(WP_REST_Request $request) {
        $raw_submission_id = $request->get_param('submissionID');
        $submission_id = is_string($raw_submission_id)
            ? strtolower(trim((string) $raw_submission_id))
            : '';
        if (!self::is_uuid_v4($submission_id)) {
            return new WP_Error(
                'collaboration_submission_id_invalid',
                '提交标识无效，请重新打开页面后再试。',
                array('status' => 400)
            );
        }
        $fields = array();
        foreach (array(
            'contactName' => array(true, 80),
            'contactMethod' => array(true, 160),
            'organization' => array(false, 120),
            'city' => array(false, 80),
            'budget' => array(false, 80),
        ) as $name => $rules) {
            $value = self::normalize_collaboration_single_line(
                $request->get_param($name),
                $rules[0],
                $rules[1]
            );
            if (is_wp_error($value)) { return $value; }
            $fields[$name] = $value;
        }
        $raw_project_type = $request->get_param('projectType');
        $project_type = is_string($raw_project_type)
            ? sanitize_key((string) $raw_project_type)
            : '';
        if (!in_array($project_type, array(
            'drama', 'commercial', 'brand', 'modeling', 'event', 'other',
        ), true)) {
            return new WP_Error(
                'collaboration_project_type_invalid',
                '请选择有效的合作类型。',
                array('status' => 400)
            );
        }
        $preferred_date = self::normalize_collaboration_date(
            $request->get_param('preferredDate')
        );
        if (is_wp_error($preferred_date)) { return $preferred_date; }
        $details = self::normalize_collaboration_details($request->get_param('details'));
        if (is_wp_error($details)) { return $details; }
        $normalized = array(
            'submissionID' => $submission_id,
            'contactName' => $fields['contactName'],
            'contactMethod' => $fields['contactMethod'],
            'organization' => $fields['organization'],
            'projectType' => $project_type,
            'city' => $fields['city'],
            'preferredDate' => $preferred_date,
            'budget' => $fields['budget'],
            'details' => $details,
        );
        $encoded = wp_json_encode($normalized, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if (!is_string($encoded)) {
            return new WP_Error(
                'collaboration_payload_invalid',
                '合作邀约内容无效。',
                array('status' => 400)
            );
        }
        $normalized['payloadHash'] = hash('sha256', $encoded);
        return $normalized;
    }

    private static function normalize_collaboration_single_line($value, $required, $maximum) {
        if ($value === null && !$required) { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段无效。', array('status' => 400));
        }
        $raw = (string) $value;
        if (strlen($raw) > (int) $maximum * 4 + 16 || preg_match('//u', $raw) !== 1
            || preg_match('/[\x00-\x1F\x7F]/', $raw)) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段无效。', array('status' => 400));
        }
        $raw = trim($raw);
        $normalized = sanitize_text_field($raw);
        $length = self::collaboration_text_length($normalized);
        if (($required && $length < 1) || $length > (int) $maximum) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段长度无效。', array('status' => 400));
        }
        return $normalized;
    }

    private static function normalize_collaboration_details($value) {
        if ($value === null) { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_details_invalid', '项目说明无效。', array('status' => 400));
        }
        $raw = (string) $value;
        if (strlen($raw) > 16016 || preg_match('//u', $raw) !== 1) {
            return new WP_Error('collaboration_details_invalid', '项目说明过长或格式无效。', array('status' => 400));
        }
        $raw = str_replace(array("\r\n", "\r"), "\n", $raw);
        if (preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', $raw)) {
            return new WP_Error('collaboration_details_invalid', '项目说明包含无效字符。', array('status' => 400));
        }
        $normalized = trim(strip_tags($raw));
        if (self::collaboration_text_length($normalized) > 4000) {
            return new WP_Error('collaboration_details_invalid', '项目说明不能超过 4000 个字符。', array('status' => 400));
        }
        return $normalized;
    }

    private static function collaboration_text_length($value) {
        if (function_exists('mb_strlen')) { return mb_strlen((string) $value, 'UTF-8'); }
        $count = preg_match_all('/./us', (string) $value, $matches);
        return is_int($count) && $count >= 0 ? $count : strlen((string) $value);
    }

    private static function normalize_collaboration_date($value) {
        if ($value === null || $value === '') { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_date_invalid', '预计日期无效。', array('status' => 400));
        }
        $date = trim((string) $value);
        if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/D', $date, $matches)
            || !checkdate((int) $matches[2], (int) $matches[3], (int) $matches[1])) {
            return new WP_Error('collaboration_date_invalid', '预计日期必须使用 YYYY-MM-DD 格式。', array('status' => 400));
        }
        $timestamp = gmmktime(0, 0, 0, (int) $matches[2], (int) $matches[3], (int) $matches[1]);
        $today = strtotime(gmdate('Y-m-d') . ' 00:00:00 UTC');
        $latest = strtotime('+5 years', $today);
        if ($timestamp < $today - DAY_IN_SECONDS || $timestamp > $latest) {
            return new WP_Error('collaboration_date_invalid', '预计日期不在可接受范围内。', array('status' => 400));
        }
        return $date;
    }

    private static function is_uuid_v4($value) {
        return is_string($value)
            && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $value) === 1;
    }

    private static function find_collaboration_submission($fan_user_id, $submission_id) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'prepare')) {
            return self::collaboration_storage_error();
        }
        $row = $wpdb->get_row($wpdb->prepare(
            "SELECT id, public_id, payload_hash, status, created_at
             FROM {$tables['requests']}
             WHERE fan_user_id = %d AND submission_id = %s LIMIT 1",
            (int) $fan_user_id,
            (string) $submission_id
        ), ARRAY_A);
        if (!empty($wpdb->last_error)) { return self::collaboration_storage_error(); }
        return is_array($row) ? $row : null;
    }

    private static function collaboration_submission_response($row, $payload_hash, $duplicate) {
        if (!is_array($row) || empty($row['public_id']) || empty($row['payload_hash'])
            || !hash_equals((string) $row['payload_hash'], (string) $payload_hash)) {
            return new WP_Error(
                'collaboration_idempotency_conflict',
                '该提交标识已用于其他内容，请重新打开页面后再试。',
                array('status' => 409)
            );
        }
        $response = new WP_REST_Response(array(
            'requestID' => (string) $row['public_id'],
            'status' => (string) ($row['status'] ?? 'received'),
            'receivedAt' => self::collaboration_iso_time((string) ($row['created_at'] ?? '')),
            'duplicate' => (bool) $duplicate,
        ), $duplicate ? 200 : 201);
        self::set_private_no_store_headers($response);
        return $response;
    }

    private static function collaboration_request_statuses() {
        return array('received', 'reviewing', 'contacted', 'closed', 'spam');
    }

    private static function collaboration_admin_record($row) {
        $fan_user_id = (int) ($row['fan_user_id'] ?? 0);
        $fan_uuid = $fan_user_id > 0
            ? strtolower((string) get_user_meta($fan_user_id, self::FAN_META_UUID, true))
            : '';
        return array(
            'requestID' => (string) ($row['public_id'] ?? ''),
            'fanUserID' => self::is_uuid_v4($fan_uuid) ? $fan_uuid : '',
            'contactName' => (string) ($row['contact_name'] ?? ''),
            'contactMethod' => (string) ($row['contact_method'] ?? ''),
            'organization' => (string) ($row['organization'] ?? ''),
            'projectType' => (string) ($row['project_type'] ?? ''),
            'city' => (string) ($row['city'] ?? ''),
            'preferredDate' => (string) ($row['preferred_date'] ?? ''),
            'budget' => (string) ($row['budget'] ?? ''),
            'details' => (string) ($row['details'] ?? ''),
            'status' => (string) ($row['status'] ?? 'received'),
            'version' => max(1, (int) ($row['version'] ?? 1)),
            'receivedAt' => self::collaboration_iso_time((string) ($row['created_at'] ?? '')),
            'updatedAt' => self::collaboration_iso_time((string) ($row['updated_at'] ?? '')),
            'delivery' => array(
                'status' => (string) ($row['mail_status'] ?? 'pending'),
                'attempts' => max(0, (int) ($row['mail_attempts'] ?? 0)),
                'errorCode' => sanitize_key((string) ($row['mail_error_code'] ?? '')),
            ),
        );
    }

    private static function attach_collaboration_delivery($row) {
        if (!is_array($row) || (int) ($row['id'] ?? 0) <= 0) { return $row; }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'prepare')) {
            return $row;
        }
        $delivery = $wpdb->get_row($wpdb->prepare(
            "SELECT status, attempts, last_error_code FROM {$tables['outbox']}
             WHERE request_id = %d AND channel = 'work_mail' LIMIT 1",
            (int) $row['id']
        ), ARRAY_A);
        if (is_array($delivery)) {
            $row['mail_status'] = (string) ($delivery['status'] ?? 'pending');
            $row['mail_attempts'] = (int) ($delivery['attempts'] ?? 0);
            $row['mail_error_code'] = (string) ($delivery['last_error_code'] ?? '');
        }
        return $row;
    }

    private static function collaboration_iso_time($database_time) {
        $database_time = trim((string) $database_time);
        if (!preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/D', $database_time)) {
            return '';
        }
        return str_replace(' ', 'T', $database_time) . 'Z';
    }

    private static function set_private_no_store_headers($response) {
        if ($response instanceof WP_REST_Response) {
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            $response->header('Pragma', 'no-cache');
            $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        }
    }

    private static function sanitize_collaboration_audit_metadata($metadata) {
        if (!is_array($metadata)) { return array(); }
        $allowed = array(
            'fromStatus', 'toStatus', 'channel', 'attempt', 'errorCode', 'version',
        );
        $result = array();
        foreach ($allowed as $key) {
            if (!array_key_exists($key, $metadata) || !is_scalar($metadata[$key])) { continue; }
            if (in_array($key, array('attempt', 'version'), true)) {
                $value = max(0, (int) $metadata[$key]);
            } else {
                $value = sanitize_key((string) $metadata[$key]);
                if ($value === '' || strlen($value) > 80) { continue; }
            }
            $result[$key] = $value;
        }
        return $result;
    }

    private static function record_collaboration_audit(
        $request_id,
        $actor_type,
        $actor_id,
        $event,
        $result,
        $metadata = array()
    ) {
        $actor_type = sanitize_key((string) $actor_type);
        $event = sanitize_key((string) $event);
        $result = sanitize_key((string) $result);
        if ((int) $request_id <= 0
            || !in_array($actor_type, array('fan', 'administrator', 'system'), true)
            || !in_array($event, array(
                'request_received', 'request_status_updated', 'work_mail_accepted',
                'work_mail_schedule_failed', 'work_mail_retry_scheduled', 'work_mail_dead',
            ), true)
            || !in_array($result, array('accepted', 'retry', 'dead'), true)) {
            return false;
        }
        if (!self::collaboration_phase1_enabled()) { return false; }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'insert')) { return false; }
        $encoded = wp_json_encode(self::sanitize_collaboration_audit_metadata($metadata));
        if (!is_string($encoded) || strlen($encoded) > 1024) { return false; }
        return $wpdb->insert($tables['audit'], array(
            'request_id' => (int) $request_id,
            'actor_type' => $actor_type,
            'actor_id' => max(0, (int) $actor_id),
            'event' => $event,
            'result' => $result,
            'metadata_json' => $encoded,
            'created_at' => gmdate('Y-m-d H:i:s'),
        ), array('%d', '%s', '%d', '%s', '%s', '%s', '%s')) === 1;
    }

    private static function schedule_collaboration_outbox_job($job_id, $timestamp) {
        if (!self::collaboration_phase1_enabled()
            || (int) $job_id <= 0
            || !self::account_authority_enabled()) { return false; }
        $scheduled = wp_schedule_single_event(
            max(time() + 1, (int) $timestamp),
            self::COLLABORATION_OUTBOX_HOOK,
            array((int) $job_id),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            // The durable pending row remains the source of truth. The
            // authority-only sweeper will reclaim it without losing the request.
            self::record_collaboration_outbox_audit(
                (int) $job_id,
                'work_mail_schedule_failed',
                'retry',
                array(
                    'channel' => 'work_mail',
                    'attempt' => 0,
                    'errorCode' => 'schedule_unavailable',
                )
            );
            do_action('yishu_collaboration_security_audit', 'outbox_job_schedule_failed');
            return false;
        }
        return true;
    }

    private static function record_collaboration_outbox_audit(
        $job_id,
        $event,
        $result,
        $metadata
    ) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || (int) $job_id <= 0 || !isset($wpdb)
            || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $request_id = (int) $wpdb->get_var($wpdb->prepare(
            "SELECT request_id FROM {$tables['outbox']} WHERE id = %d LIMIT 1",
            (int) $job_id
        ));
        return $request_id > 0 && self::record_collaboration_audit(
            $request_id,
            'system',
            0,
            (string) $event,
            (string) $result,
            $metadata
        );
    }

    private static function collaboration_retry_delay($attempts) {
        $delays = array(60, 300, 1800, 7200);
        $index = max(0, min(count($delays) - 1, (int) $attempts - 1));
        return $delays[$index];
    }

    private static function mark_exhausted_collaboration_outbox_jobs($now) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'query') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $rows = $wpdb->get_results($wpdb->prepare(
            "SELECT id, request_id, attempts FROM {$tables['outbox']}
             WHERE attempts >= %d
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))
             ORDER BY id ASC LIMIT 20",
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            (string) $now
        ), ARRAY_A);
        if (!is_array($rows)) { return false; }
        foreach ($rows as $row) {
            if (!is_array($row) || (int) ($row['id'] ?? 0) <= 0) { continue; }
            $updated = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['outbox']}
                 SET status = 'dead', lease_token = NULL, lease_until = NULL,
                     last_error_code = 'worker_interrupted', updated_at = %s
                 WHERE id = %d AND attempts >= %d
                   AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))",
                (string) $now,
                (int) $row['id'],
                self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
                (string) $now
            ));
            if ($updated === 1) {
                self::record_collaboration_audit(
                    (int) ($row['request_id'] ?? 0),
                    'system',
                    0,
                    'work_mail_dead',
                    'dead',
                    array(
                        'channel' => 'work_mail',
                        'attempt' => (int) ($row['attempts'] ?? 0),
                        'errorCode' => 'worker_interrupted',
                    )
                );
            }
        }
        return true;
    }

    private static function collaboration_outbox_failure_state($attempts) {
        $attempts = max(1, (int) $attempts);
        if ($attempts >= self::COLLABORATION_OUTBOX_MAX_ATTEMPTS) {
            return array('status' => 'dead', 'delay' => 0);
        }
        return array(
            'status' => 'pending',
            'delay' => self::collaboration_retry_delay($attempts),
        );
    }

    private static function fail_collaboration_outbox_job(
        $job_id,
        $lease_token,
        $attempts,
        $error_code
    ) {
        if (!self::collaboration_phase1_enabled()) { return false; }
        global $wpdb;
        $tables = self::collaboration_tables();
        $state = self::collaboration_outbox_failure_state($attempts);
        $error_code = sanitize_key((string) $error_code);
        if (!$tables || !$error_code || strlen($error_code) > 80
            || !isset($wpdb) || !method_exists($wpdb, 'update')) {
            return false;
        }
        $next_timestamp = time() + (int) $state['delay'];
        $updated = $wpdb->update($tables['outbox'], array(
            'status' => (string) $state['status'],
            'next_attempt_at' => gmdate('Y-m-d H:i:s', $next_timestamp),
            'lease_token' => null,
            'lease_until' => null,
            'last_error_code' => $error_code,
            'updated_at' => gmdate('Y-m-d H:i:s'),
        ), array(
            'id' => (int) $job_id,
            'lease_token' => (string) $lease_token,
        ), array('%s', '%s', '%s', '%s', '%s', '%s'), array('%d', '%s'));
        if ($updated !== 1) { return false; }
        $job = $wpdb->get_row($wpdb->prepare(
            "SELECT request_id FROM {$tables['outbox']} WHERE id = %d LIMIT 1",
            (int) $job_id
        ), ARRAY_A);
        if (is_array($job) && (int) ($job['request_id'] ?? 0) > 0) {
            self::record_collaboration_audit(
                (int) $job['request_id'],
                'system',
                0,
                $state['status'] === 'dead' ? 'work_mail_dead' : 'work_mail_retry_scheduled',
                $state['status'] === 'dead' ? 'dead' : 'retry',
                array(
                    'channel' => 'work_mail',
                    'attempt' => (int) $attempts,
                    'errorCode' => $error_code,
                )
            );
        }
        if ($state['status'] === 'pending') {
            self::schedule_collaboration_outbox_job((int) $job_id, $next_timestamp);
        }
        return true;
    }

    private static function collaboration_work_email() {
        $configured = defined('YISHU_COLLABORATION_EMAIL')
            ? constant('YISHU_COLLABORATION_EMAIL')
            : self::COLLABORATION_EMAIL;
        $configured = apply_filters('yishu_collaboration_work_email', $configured);
        if (!is_scalar($configured)) { return ''; }
        $configured = (string) $configured;
        if ($configured === '' || preg_match('/[\r\n]/', $configured)) { return ''; }
        $configured = trim($configured);
        $configured = sanitize_email($configured);
        return $configured && is_email($configured) ? $configured : '';
    }

    private static function collaboration_mail_body($job) {
        $labels = array(
            'drama' => '短剧 / 影视出演',
            'commercial' => '商业拍摄',
            'brand' => '品牌合作',
            'modeling' => '平面 / 模特',
            'event' => '活动出席',
            'other' => '其他合作',
        );
        $project_type = (string) ($job['project_type'] ?? 'other');
        $lines = array(
            '易姝合作邀约',
            '请求编号：' . (string) ($job['public_id'] ?? ''),
            '联系人：' . (string) ($job['contact_name'] ?? ''),
            '联系方式：' . (string) ($job['contact_method'] ?? ''),
            '公司 / 项目：' . (string) ($job['organization'] ?? ''),
            '合作类型：' . (string) ($labels[$project_type] ?? $labels['other']),
            '拍摄城市：' . (string) ($job['city'] ?? ''),
            '预计日期：' . (string) ($job['preferred_date'] ?? ''),
            '预算范围：' . (string) ($job['budget'] ?? ''),
            '',
            '项目说明：',
            (string) ($job['details'] ?? ''),
        );
        return implode("\n", $lines);
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
        $douyin_id = self::normalize_optional_douyin_id($request->get_param('douyinID'));
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
        if (($context['scope'] ?? '') !== 'apple_onboarding'
            || self::fan_account_source($user_id) !== 'apple') {
            return new WP_Error(
                'fan_apple_profile_required',
                '请先使用 Apple ID 登录。',
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
        if (!is_array($context) || ($context['scope'] ?? '') !== 'apple_onboarding') {
            return new WP_Error('fan_apple_profile_required', '请先使用 Apple ID 登录。', array('status' => 403));
        }
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $display_name = sanitize_text_field((string) $request->get_param('displayName'));
        $douyin_id = self::normalize_optional_douyin_id($request->get_param('douyinID'));
        if (is_wp_error($douyin_id)) { return $douyin_id; }
        $display_error = self::validate_fan_display_name($display_name);
        if (is_wp_error($display_error)) { return $display_error; }
        $consent_version = $request->get_param('consentVersion');
        if (!self::fan_new_consent_version_is_accepted($consent_version)) {
            return new WP_Error('fan_consent_required', '请先阅读并确认账号资料的使用说明。', array('status' => 400));
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
        $reservation = $douyin_id !== '' ? self::douyin_reservation_name($douyin_id) : '';
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
            if ($douyin_id !== '') {
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
                    array('gallery_full', 'video_view')
                )
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
            self::clear_fan_option_caches($reservation !== '' ? array($reservation) : array());
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
                self::clear_fan_option_caches($reservation !== '' ? array($reservation) : array());
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
        if (self::authenticate_content_manager($request)) { return true; }

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
            $setup = self::normalize_fan_apple_setup(self::fan_meta_from_database(
                (int) $context['userID'],
                self::FAN_META_APPLE_SETUP,
                null
            ));
            if (is_wp_error($setup)) { return $setup; }
            $payload = array('appleRegistration' => array(
                'expiresAt' => gmdate('c', (int) $context['expires']),
            ));
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
        $douyin_id = self::normalize_optional_douyin_id($request->get_param('douyinID'));
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
                $normalized_douyin_id = self::normalize_optional_douyin_id($stored_douyin_id);
                $douyin_id_is_valid = !is_wp_error($normalized_douyin_id)
                    && $normalized_douyin_id === $stored_douyin_id;
                $consent = get_user_meta((int) $user->ID, self::FAN_META_CONSENT, true);
                if (!empty($apple_setup)
                    || ($source === 'apple' && (!$douyin_id_is_valid
                        || !self::fan_stored_consent_is_accepted($consent)))) {
                    return new WP_Error(
                        'fan_account_setup_required',
                        '用户必须先完成昵称和隐私同意设置。',
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

    public static function normalize_optional_douyin_id($value) {
        if ($value === null) { return ''; }
        if (!is_scalar($value)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '抖音 ID 为选填；如填写，请使用 2–50 位 ID，不要填链接。',
                array('status' => 400)
            );
        }
        if (trim((string) $value) === '') { return ''; }
        $douyin_id = self::normalize_douyin_id($value);
        if ($douyin_id === '' || self::is_invitation_douyin_id($douyin_id)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '抖音 ID 为选填；如填写，请使用 2–50 位 ID，不要填链接。',
                array('status' => 400)
            );
        }
        return $douyin_id;
    }

    private static function matching_request_install_id(WP_REST_Request $request) {
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
        return $header_install_id;
    }

    private static function fan_account_source($user_id) {
        $source = sanitize_key((string) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_ACCOUNT_SOURCE,
            ''
        ));
        return in_array($source, array('password', 'invitation', 'apple'), true)
            ? $source
            : 'password';
    }

    private static function valid_apple_sub_hash($value) {
        return is_string($value) && preg_match('/^[a-f0-9]{64}$/', $value) === 1;
    }

    private static function apple_data_master_key() {
        if (self::apple_test_mode_enabled()) {
            $test_key = apply_filters('yishu_fan_apple_data_key', null);
            if (is_string($test_key) && strlen($test_key) === 32) { return $test_key; }
        }
        if (!defined('YISHU_APPLE_DATA_KEY_PATH')) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录数据密钥尚未配置。',
                array('status' => 503)
            );
        }
        $configured_path = (string) YISHU_APPLE_DATA_KEY_PATH;
        $path = realpath($configured_path);
        $root = realpath(ABSPATH);
        $configured_normalized = function_exists('wp_normalize_path')
            ? wp_normalize_path($configured_path)
            : str_replace('\\', '/', $configured_path);
        $root_normalized = $root && function_exists('wp_normalize_path')
            ? rtrim(wp_normalize_path($root), '/') . '/'
            : ($root ? rtrim(str_replace('\\', '/', $root), '/') . '/' : '');
        if (!$path || !$root || $configured_path === '' || $configured_path[0] !== '/'
            || is_link($configured_path)
            || ($root_normalized !== '' && strpos($configured_normalized, $root_normalized) === 0)
            || strpos($path, $root . DIRECTORY_SEPARATOR) === 0
            || !is_file($path) || !is_readable($path) || filesize($path) > 256) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录数据密钥配置不安全。',
                array('status' => 503)
            );
        }
        $permissions = fileperms($path);
        $encoded = file_get_contents($path);
        $encoded = is_string($encoded) ? trim($encoded) : '';
        if ($permissions === false || (($permissions & 077) !== 0)
            || preg_match('/^[A-Za-z0-9_-]{43}$/D', $encoded) !== 1) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录数据密钥配置不安全。',
                array('status' => 503)
            );
        }
        $decoded = base64_decode(strtr($encoded . '=', '-_', '+/'), true);
        if (!is_string($decoded) || strlen($decoded) !== 32) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录数据密钥配置无效。',
                array('status' => 503)
            );
        }
        return $decoded;
    }

    private static function apple_subject_hash($subject) {
        $subject = is_scalar($subject) ? trim((string) $subject) : '';
        if ($subject === '' || strlen($subject) > 255
            || preg_match('/^[\x21-\x7e]+$/D', $subject) !== 1) {
            return '';
        }
        if (!function_exists('hash_hkdf') || !function_exists('sodium_memzero')) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录数据密钥功能不可用。',
                array('status' => 503)
            );
        }
        $master_key = self::apple_data_master_key();
        if (is_wp_error($master_key)) { return $master_key; }
        $subject_key = hash_hkdf(
            'sha256',
            $master_key,
            32,
            'yishu/apple-subject/v1',
            hash('sha256', self::FAN_APPLE_CLIENT_ID, true)
        );
        sodium_memzero($master_key);
        $subject_hash = hash_hmac(
            'sha256',
            self::FAN_APPLE_ISSUER . "\n" . $subject,
            $subject_key
        );
        sodium_memzero($subject_key);
        return $subject_hash;
    }

    private static function apple_subject_reservation_name($subject_hash) {
        return self::valid_apple_sub_hash($subject_hash)
            ? self::FAN_APPLE_OPTION_PREFIX . $subject_hash
            : '';
    }

    private static function apple_subject_tombstone_name($subject_hash) {
        return self::valid_apple_sub_hash($subject_hash)
            ? self::FAN_APPLE_TOMBSTONE_OPTION_PREFIX . $subject_hash
            : '';
    }

    private static function normalize_apple_subject_tombstone($value) {
        if (!is_array($value)
            || (int) ($value['version'] ?? 0) !== 1
            || !isset($value['eventTime']) || !is_numeric($value['eventTime'])
            || !isset($value['expires']) || !is_numeric($value['expires'])
            || !preg_match('/^[a-f0-9]{32}$/', (string) ($value['generation'] ?? ''))) {
            return new WP_Error(
                'fan_apple_account_conflict',
                'Apple 账号撤销状态暂时无法确认。',
                array('status' => 503)
            );
        }
        $event_time = (int) $value['eventTime'];
        $expires = (int) $value['expires'];
        if ($event_time <= 0 || $event_time > time() + 60
            || $expires <= $event_time
            || $expires > time() + self::FAN_APPLE_TOMBSTONE_TTL + 300) {
            return new WP_Error(
                'fan_apple_account_conflict',
                'Apple 账号撤销状态暂时无法确认。',
                array('status' => 503)
            );
        }
        return array(
            'version' => 1,
            'eventTime' => $event_time,
            'expires' => $expires,
            'generation' => (string) $value['generation'],
        );
    }

    private static function persist_apple_subject_tombstone_under_lock(
        $subject_hash,
        $event_time
    ) {
        $option_name = self::apple_subject_tombstone_name($subject_hash);
        $event_time = (int) $event_time;
        if (!$option_name || $event_time <= 0 || $event_time > time() + 60) {
            return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
        }
        $existing_raw = self::fan_option_from_database($option_name, null);
        $existing = $existing_raw === null
            ? null
            : self::normalize_apple_subject_tombstone($existing_raw);
        if (is_wp_error($existing)) { return $existing; }
        $effective_event_time = is_array($existing)
            ? max($event_time, (int) $existing['eventTime'])
            : $event_time;
        try {
            $generation = bin2hex(random_bytes(16));
        } catch (Throwable $error) {
            return new WP_Error('fan_apple_notification_unavailable', '暂时无法保存 Apple 撤销状态。', array('status' => 503));
        }
        $record = array(
            'version' => 1,
            'eventTime' => $effective_event_time,
            'expires' => time() + self::FAN_APPLE_TOMBSTONE_TTL,
            'generation' => $generation,
        );
        $saved = $existing_raw === null
            ? add_option($option_name, $record, '', false)
            : update_option($option_name, $record, false);
        self::clear_fan_option_caches(array($option_name));
        $stored = self::normalize_apple_subject_tombstone(
            self::fan_option_from_database($option_name, null)
        );
        if (!$saved || is_wp_error($stored)
            || !hash_equals($generation, (string) ($stored['generation'] ?? ''))) {
            return new WP_Error('fan_apple_notification_unavailable', '暂时无法保存 Apple 撤销状态。', array('status' => 503));
        }
        $scheduled = wp_schedule_single_event(
            (int) $record['expires'] + 60,
            'yishu_cleanup_fan_apple_tombstone',
            array($option_name, $generation),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            // The security boundary is already durable. Do not block account
            // deletion because WP-Cron scheduling is temporarily unavailable;
            // the init sweeper repairs the cleanup schedule.
            do_action('yishu_fan_security_audit', 'apple_tombstone_schedule_unavailable');
        }
        return true;
    }

    private static function authorize_apple_subject_after_tombstone_under_lock(
        $subject_hash,
        $credential_issued_at
    ) {
        $option_name = self::apple_subject_tombstone_name($subject_hash);
        $issued_at = (int) $credential_issued_at;
        if (!$option_name || $issued_at <= 0 || $issued_at > time() + 60) {
            return new WP_Error('fan_apple_credential_invalid', 'Apple 验证已失效。', array('status' => 401));
        }
        $raw = self::fan_option_from_database($option_name, null);
        if ($raw === null) { return true; }
        $tombstone = self::normalize_apple_subject_tombstone($raw);
        if (is_wp_error($tombstone)) { return $tombstone; }
        if ((int) $tombstone['expires'] <= time()) {
            $deleted = delete_option($option_name);
            self::clear_fan_option_caches(array($option_name));
            return $deleted && self::fan_option_from_database($option_name, null) === null
                ? true
                : new WP_Error('fan_apple_account_conflict', 'Apple 账号撤销状态暂时无法确认。', array('status' => 503));
        }
        if ($issued_at <= (int) $tombstone['eventTime']) {
            return new WP_Error(
                'fan_apple_authorization_revoked',
                'Apple 授权已被撤销，请重新授权后再试。',
                array('status' => 401)
            );
        }
        // Keep the boundary until its TTL expires. If the first genuinely new
        // authorization removed it, an older request that completed exchange
        // before the event but entered this lock later could still resurrect
        // or sign in to the newly created account.
        return true;
    }

    private static function apple_challenge_option_name($challenge_id) {
        $challenge_id = is_scalar($challenge_id) ? trim((string) $challenge_id) : '';
        if (!preg_match('/^[A-Za-z0-9_-]{43}$/D', $challenge_id)) { return ''; }
        return self::FAN_APPLE_CHALLENGE_OPTION_PREFIX . hash('sha256', $challenge_id);
    }

    private static function apple_credential_request(WP_REST_Request $request, $require_confirmation) {
        $identity_token = trim((string) $request->get_param('identityToken'));
        $authorization_code = trim((string) $request->get_param('authorizationCode'));
        $challenge_id = trim((string) $request->get_param('challengeID'));
        $state = trim((string) $request->get_param('state'));
        if (strlen($identity_token) < 100 || strlen($identity_token) > 16384
            || substr_count($identity_token, '.') !== 2
            || strlen($authorization_code) < 8 || strlen($authorization_code) > 4096
            || preg_match('/^[\x21-\x7e]+$/D', $authorization_code) !== 1
            || !self::apple_challenge_option_name($challenge_id)
            || strlen($state) < 32 || strlen($state) > 128
            || preg_match('/^[A-Za-z0-9_-]+$/D', $state) !== 1
            || ($require_confirmation
                && (string) $request->get_param('confirmation') !== 'DELETE_ACCOUNT')) {
            return new WP_Error(
                'fan_apple_credential_invalid',
                'Apple 验证请求无效。',
                array('status' => 400)
            );
        }
        return array(
            'identityToken' => $identity_token,
            'authorizationCode' => $authorization_code,
            'challengeID' => $challenge_id,
            'state' => $state,
        );
    }

    private static function acquire_named_fan_lock($namespace, $identity) {
        return self::acquire_named_fan_lock_with_timeout($namespace, $identity, 0);
    }

    private static function acquire_named_fan_lock_with_timeout(
        $namespace,
        $identity,
        $timeout_seconds
    ) {
        global $wpdb;
        if (!isset($wpdb) || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return new WP_Error('fan_setup_busy', '账号安全锁暂时不可用。', array('status' => 503));
        }
        $timeout_seconds = max(0, min(10, (int) $timeout_seconds));
        $namespace = preg_replace('/[^a-z0-9_]/', '', strtolower((string) $namespace));
        if (!$namespace) { return new WP_Error('fan_setup_busy', '账号安全锁暂时不可用。', array('status' => 503)); }
        $name = 'yishu_' . substr($namespace, 0, 12) . '_' . substr(
            hash('sha256', home_url('/') . '|' . (string) $identity),
            0,
            44
        );
        $acquired = $wpdb->get_var($wpdb->prepare(
            'SELECT GET_LOCK(%s, %d)',
            $name,
            $timeout_seconds
        ));
        if ((string) $acquired === '1') { return $name; }
        return new WP_Error('fan_setup_busy', '请求正在处理，请稍后重试。', array('status' => 409));
    }

    private static function release_named_fan_lock($lock_name) {
        global $wpdb;
        if (!is_string($lock_name) || !preg_match('/^yishu_[a-z0-9_]{1,12}_[a-f0-9]{44}$/', $lock_name)
            || !isset($wpdb) || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return;
        }
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_name));
    }

    private static function consume_fan_apple_challenge(
        $challenge_id,
        $state,
        $install_id,
        $purpose
    ) {
        $option_name = self::apple_challenge_option_name($challenge_id);
        if (!$option_name || !in_array($purpose, array('sign_in', 'delete_account'), true)) {
            return new WP_Error('fan_apple_challenge_invalid', 'Apple 登录请求已失效。', array('status' => 401));
        }
        $lock_name = self::acquire_named_fan_lock('apple_chal', $option_name);
        if (is_wp_error($lock_name)) { return $lock_name; }
        try {
            global $wpdb;
            $serialized = $wpdb->get_var($wpdb->prepare(
                "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s LIMIT 1",
                $option_name
            ));
            $record = is_string($serialized) ? maybe_unserialize($serialized) : null;
            $deleted = $wpdb->delete(
                $wpdb->options,
                array('option_name' => $option_name),
                array('%s')
            );
            self::clear_fan_option_caches(array($option_name));
            if (!is_array($record) || $deleted === false || $deleted < 1
                || (int) ($record['version'] ?? 0) !== 1
                || (int) ($record['expires'] ?? 0) <= time()
                || (string) ($record['purpose'] ?? '') !== $purpose
                || !preg_match('/^[a-f0-9]{64}$/', (string) ($record['nonceHash'] ?? ''))
                || !preg_match('/^[a-f0-9]{64}$/', (string) ($record['stateHash'] ?? ''))
                || !preg_match('/^[a-f0-9]{64}$/', (string) ($record['installHash'] ?? ''))
                || !hash_equals((string) $record['stateHash'], hash('sha256', (string) $state))
                || !hash_equals((string) $record['installHash'], hash('sha256', (string) $install_id))) {
                return new WP_Error('fan_apple_challenge_invalid', 'Apple 登录请求已失效。', array('status' => 401));
            }
            return $record;
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    private static function load_apple_jwt_library() {
        if (class_exists('Firebase\\JWT\\JWT', false)
            && class_exists('Firebase\\JWT\\JWK', false)) {
            return true;
        }
        $autoload = __DIR__ . '/vendor/autoload.php';
        if (!is_readable($autoload)) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录服务尚未完成安全配置。',
                array('status' => 503)
            );
        }
        require_once $autoload;
        if (!class_exists('Firebase\\JWT\\JWT')
            || !class_exists('Firebase\\JWT\\JWK')) {
            return new WP_Error(
                'fan_apple_configuration_unavailable',
                'Apple 登录服务尚未完成安全配置。',
                array('status' => 503)
            );
        }
        return true;
    }

    private static function apple_test_mode_enabled() {
        return defined('YISHU_APPLE_TEST_MODE') && YISHU_APPLE_TEST_MODE === true
            && defined('WP_ENVIRONMENT_TYPE')
            && in_array((string) WP_ENVIRONMENT_TYPE, array('local', 'development'), true);
    }

    private static function fetch_apple_jwk_keys(
        $force_refresh = false,
        $allow_remote = true
    ) {
        $loaded = self::load_apple_jwt_library();
        if (is_wp_error($loaded)) { return $loaded; }
        $cache_key = 'yishu_fan_apple_jwks_v2';
        $cached_jwks = null;
        $cache_age = PHP_INT_MAX;
        $cache_after_validation = false;
        $test_jwks = self::apple_test_mode_enabled()
            ? apply_filters('yishu_fan_apple_jwks', null, (bool) $force_refresh)
            : null;
        if ($test_jwks !== null) {
            if (!is_array($test_jwks)) {
                return new WP_Error('fan_apple_verifier_unavailable', 'Apple 验签密钥无效。', array('status' => 503));
            }
            $jwks = $test_jwks;
        } else {
            $cached = get_transient($cache_key);
            $cached_at = is_array($cached) ? (int) ($cached['fetchedAt'] ?? 0) : 0;
            $cached_jwks = is_array($cached) && is_array($cached['jwks'] ?? null)
                ? $cached['jwks']
                : null;
            $cache_age = $cached_at > 0 ? time() - $cached_at : PHP_INT_MAX;
            if (!$allow_remote) {
                // A request that already exhausted the unauthenticated S2S
                // limiter may still be a legitimate Apple notification. It
                // can use a valid last-known-good key, but must never turn a
                // forged/unknown kid into an outbound Apple request.
                $jwks = is_array($cached_jwks)
                    && $cache_age >= 0
                    && $cache_age <= DAY_IN_SECONDS
                    ? $cached_jwks
                    : null;
                if (!is_array($jwks)) {
                    return new WP_Error(
                        'fan_apple_verifier_unavailable',
                        '暂时无法验证 Apple 通知，请稍后重试。',
                        array('status' => 503)
                    );
                }
            } else {
                $jwks = !$force_refresh
                    && is_array($cached_jwks)
                    && $cache_age >= 0
                    && $cache_age <= 6 * HOUR_IN_SECONDS
                    ? $cached_jwks
                    : null;
            }
        }
        if ($test_jwks === null && !is_array($jwks)) {
            $response = wp_remote_get(self::FAN_APPLE_JWKS_URL, array(
                'timeout' => 8,
                'redirection' => 0,
                'sslverify' => true,
                'headers' => array('Accept' => 'application/json'),
            ));
            $remote_ok = !is_wp_error($response)
                && (int) wp_remote_retrieve_response_code($response) === 200;
            $body = $remote_ok ? (string) wp_remote_retrieve_body($response) : '';
            $remote_jwks = strlen($body) >= 40 && strlen($body) <= 65536
                ? json_decode($body, true)
                : null;
            if (!is_array($remote_jwks) || empty($remote_jwks['keys'])
                || !is_array($remote_jwks['keys']) || count($remote_jwks['keys']) > 12) {
                // A previously verified key set may bridge a short Apple outage,
                // but never an unknown-kid forced refresh and never past 24h.
                if (!$force_refresh && is_array($cached_jwks)
                    && $cache_age >= 0 && $cache_age <= DAY_IN_SECONDS) {
                    $jwks = $cached_jwks;
                } else {
                    return new WP_Error(
                        'fan_apple_verifier_unavailable',
                        '暂时无法验证 Apple 登录，请稍后重试。',
                        array('status' => 503)
                    );
                }
            } else {
                $jwks = $remote_jwks;
                $cache_after_validation = true;
            }
        }
        $filtered = array('keys' => array());
        $seen = array();
        foreach ((array) ($jwks['keys'] ?? array()) as $key) {
            if (!is_array($key)
                || (string) ($key['kty'] ?? '') !== 'RSA'
                || !in_array((string) ($key['use'] ?? 'sig'), array('', 'sig'), true)
                || !in_array((string) ($key['alg'] ?? 'RS256'), array('', 'RS256'), true)
                || !preg_match('/^[A-Za-z0-9._-]{1,128}$/D', (string) ($key['kid'] ?? ''))
                || !is_string($key['n'] ?? null)
                || !preg_match('/^[A-Za-z0-9_-]{64,2048}$/D', (string) $key['n'])
                || !is_string($key['e'] ?? null)
                || !preg_match('/^[A-Za-z0-9_-]{1,16}$/D', (string) $key['e'])) {
                // Apple may add keys for another algorithm/use in the same
                // document. They are irrelevant to this RS256 verifier and
                // must not poison a previously good cache entry.
                continue;
            }
            if (isset($seen[(string) $key['kid']])) {
                return new WP_Error('fan_apple_verifier_unavailable', 'Apple 验签密钥无效。', array('status' => 503));
            }
            $seen[(string) $key['kid']] = true;
            $filtered['keys'][] = $key;
        }
        if (!$filtered['keys']) {
            return new WP_Error('fan_apple_verifier_unavailable', 'Apple 验签密钥无效。', array('status' => 503));
        }
        try {
            $parsed = \Firebase\JWT\JWK::parseKeySet($filtered, 'RS256');
        } catch (Throwable $error) {
            return new WP_Error('fan_apple_verifier_unavailable', 'Apple 验签密钥无效。', array('status' => 503));
        }
        if ($test_jwks === null && $cache_after_validation
            && !set_transient($cache_key, array(
                'fetchedAt' => time(),
                'jwks' => $filtered,
            ), DAY_IN_SECONDS)) {
            return new WP_Error('fan_apple_verifier_unavailable', '暂时无法安全缓存 Apple 验签密钥。', array('status' => 503));
        }
        return $parsed;
    }

    private static function refresh_apple_jwk_keys_after_unknown_kid() {
        if (self::apple_test_mode_enabled()) {
            return self::fetch_apple_jwk_keys(true);
        }
        $lock = self::acquire_named_fan_lock_with_timeout(
            'apple_jwks',
            self::FAN_APPLE_CLIENT_ID,
            10
        );
        if (is_wp_error($lock)) {
            return new WP_Error('fan_apple_verifier_unavailable', '暂时无法更新 Apple 验签密钥。', array('status' => 503));
        }
        try {
            $state_key = 'yishu_fan_apple_jwks_refresh_state_v1';
            $state = get_transient($state_key);
            $attempted_at = is_array($state) ? (int) ($state['attemptedAt'] ?? 0) : 0;
            if ($attempted_at > 0 && time() - $attempted_at < 300) {
                return !empty($state['success'])
                    ? self::fetch_apple_jwk_keys(false)
                    : new WP_Error('fan_apple_verifier_unavailable', '暂时无法更新 Apple 验签密钥。', array('status' => 503));
            }
            if (!set_transient($state_key, array(
                'attemptedAt' => time(),
                'success' => false,
            ), 300)) {
                return new WP_Error('fan_apple_verifier_unavailable', '暂时无法安全限制 Apple 密钥刷新。', array('status' => 503));
            }
            $keys = self::fetch_apple_jwk_keys(true);
            if (is_wp_error($keys)) { return $keys; }
            if (!set_transient($state_key, array(
                'attemptedAt' => time(),
                'success' => true,
            ), 300)) {
                return new WP_Error('fan_apple_verifier_unavailable', '暂时无法安全限制 Apple 密钥刷新。', array('status' => 503));
            }
            return $keys;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    private static function decode_apple_rs256_token(
        $token,
        $error_code,
        $allow_force_refresh = true
    ) {
        $keys = self::fetch_apple_jwk_keys(false, (bool) $allow_force_refresh);
        if (is_wp_error($keys)) { return $keys; }
        $claims = null;
        // firebase/php-jwt only populates the by-reference header argument
        // when the caller passes a non-null object.
        $headers = new stdClass();
        for ($attempt = 0; $attempt < 2; $attempt++) {
            try {
                \Firebase\JWT\JWT::$leeway = 60;
                $claims = \Firebase\JWT\JWT::decode((string) $token, $keys, $headers);
                break;
            } catch (Throwable $error) {
                $unknown_kid = $error instanceof \UnexpectedValueException
                    && hash_equals(
                        '"kid" invalid, unable to lookup correct key',
                        (string) $error->getMessage()
                    );
                if ($attempt === 0 && $allow_force_refresh && $unknown_kid) {
                    $keys = self::refresh_apple_jwk_keys_after_unknown_kid();
                    if (is_wp_error($keys)) { return $keys; }
                    $headers = new stdClass();
                    continue;
                }
                return new WP_Error((string) $error_code, 'Apple 签名验证失败。', array('status' => 401));
            }
        }
        if (!$claims instanceof stdClass || !$headers instanceof stdClass
            || (string) ($headers->alg ?? '') !== 'RS256'
            || !preg_match('/^[A-Za-z0-9._-]{1,128}$/D', (string) ($headers->kid ?? ''))) {
            return new WP_Error((string) $error_code, 'Apple 签名验证失败。', array('status' => 401));
        }
        return (array) $claims;
    }

    private static function verify_apple_identity_token($identity_token, $expected_nonce_hash = '') {
        if (self::apple_test_mode_enabled()) {
            $test_result = apply_filters(
                'yishu_fan_apple_identity_verifier',
                null,
                (string) $identity_token,
                (string) $expected_nonce_hash
            );
            if ($test_result !== null) {
                return self::normalize_verified_apple_claims($test_result, $expected_nonce_hash);
            }
        }
        $claims = self::decode_apple_rs256_token($identity_token, 'fan_apple_credential_invalid');
        return is_wp_error($claims)
            ? $claims
            : self::normalize_verified_apple_claims($claims, $expected_nonce_hash);
    }

    private static function normalize_verified_apple_claims($claims, $expected_nonce_hash = '') {
        if (!is_array($claims)) {
            return new WP_Error('fan_apple_credential_invalid', 'Apple 验证已失效。', array('status' => 401));
        }
        $subject_hash = self::apple_subject_hash($claims['sub'] ?? '');
        if (is_wp_error($subject_hash)) { return $subject_hash; }
        $audience = $claims['aud'] ?? '';
        $audience_valid = is_string($audience)
            && hash_equals(self::FAN_APPLE_CLIENT_ID, $audience);
        $now = time();
        $nonce = isset($claims['nonce']) && is_scalar($claims['nonce'])
            ? (string) $claims['nonce']
            : '';
        if ((string) ($claims['iss'] ?? '') !== self::FAN_APPLE_ISSUER
            || !$audience_valid
            || !isset($claims['exp']) || !is_numeric($claims['exp'])
            || (int) $claims['exp'] <= $now - 60 || (int) $claims['exp'] > $now + 86400
            || !isset($claims['iat']) || !is_numeric($claims['iat'])
            || (int) $claims['iat'] > $now + 60 || (int) $claims['iat'] < $now - 86400
            || !self::valid_apple_sub_hash($subject_hash)
            || ($expected_nonce_hash !== ''
                && (!preg_match('/^[a-f0-9]{64}$/', (string) $expected_nonce_hash)
                    || !preg_match('/^[a-f0-9]{64}$/', $nonce)
                    || !hash_equals((string) $expected_nonce_hash, strtolower($nonce))))) {
            return new WP_Error('fan_apple_credential_invalid', 'Apple 验证已失效。', array('status' => 401));
        }
        return array(
            'subject' => (string) $claims['sub'],
            'subjectHash' => $subject_hash,
            'issuedAt' => (int) $claims['iat'],
        );
    }

    private static function normalize_fan_apple_notification_claims($claims, $now = null) {
        if (!is_array($claims)) {
            return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
        }
        $now = $now === null ? time() : (int) $now;
        $audience = $claims['aud'] ?? '';
        $jti = isset($claims['jti']) && is_scalar($claims['jti'])
            ? (string) $claims['jti']
            : '';
        if ((string) ($claims['iss'] ?? '') !== self::FAN_APPLE_ISSUER
            || !is_string($audience) || !hash_equals(self::FAN_APPLE_CLIENT_ID, $audience)
            || !isset($claims['iat']) || !is_numeric($claims['iat'])
            || (int) $claims['iat'] > $now + 60 || (int) $claims['iat'] < $now - DAY_IN_SECONDS
            || strlen($jti) < 8 || strlen($jti) > 256
            || preg_match('/^[\x21-\x7e]+$/D', $jti) !== 1) {
            return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
        }
        $events = $claims['events'] ?? null;
        if (is_string($events) && strlen($events) <= 16384) {
            $events = json_decode($events, true);
        }
        if ($events instanceof stdClass) { $events = (array) $events; }
        if (is_array($events) && !array_is_list($events)) { $events = array($events); }
        if (!is_array($events) || !$events || count($events) > 5) {
            return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
        }
        $normalized_events = array();
        foreach ($events as $event) {
            if ($event instanceof stdClass) { $event = (array) $event; }
            if (!is_array($event)) {
                return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
            }
            $type = sanitize_key((string) ($event['type'] ?? ''));
            $sub_hash = self::apple_subject_hash($event['sub'] ?? '');
            if (is_wp_error($sub_hash)) { return $sub_hash; }
            $event_time = isset($event['event_time']) && is_numeric($event['event_time'])
                ? (int) $event['event_time']
                : 0;
            if (!in_array($type, array('email-enabled', 'email-disabled', 'consent-revoked', 'account-deleted'), true)
                || !self::valid_apple_sub_hash($sub_hash)
                || $event_time <= 0 || $event_time > $now + 60
                || $event_time < $now - 7 * DAY_IN_SECONDS) {
                return new WP_Error('fan_apple_notification_invalid', 'Apple 通知无效。', array('status' => 401));
            }
            $normalized_events[] = array(
                'type' => $type,
                'subjectHash' => $sub_hash,
                'eventTime' => $event_time,
            );
        }
        return array('jti' => $jti, 'events' => $normalized_events);
    }

    private static function normalize_fan_apple_event_record($value) {
        if (!is_array($value)
            || (int) ($value['version'] ?? 0) !== 1
            || !preg_match('/^[a-f0-9]{32}$/', (string) ($value['generation'] ?? ''))
            || !in_array((string) ($value['status'] ?? ''), array('pending', 'processed'), true)) {
            return new WP_Error(
                'fan_apple_notification_unavailable',
                'Apple 通知持久状态无效。',
                array('status' => 503)
            );
        }
        $status = (string) $value['status'];
        $generation = (string) $value['generation'];
        if ($status === 'processed') {
            $processed_at = isset($value['processedAt']) && is_numeric($value['processedAt'])
                ? (int) $value['processedAt']
                : 0;
            $expires = isset($value['expires']) && is_numeric($value['expires'])
                ? (int) $value['expires']
                : 0;
            if ($processed_at <= 0 || $processed_at > time() + 60
                || $expires <= $processed_at
                || $expires > $processed_at + 30 * DAY_IN_SECONDS + 300) {
                return new WP_Error('fan_apple_notification_unavailable', 'Apple 通知持久状态无效。', array('status' => 503));
            }
            return array(
                'version' => 1,
                'status' => 'processed',
                'processedAt' => $processed_at,
                'expires' => $expires,
                'generation' => $generation,
            );
        }

        $received_at = isset($value['receivedAt']) && is_numeric($value['receivedAt'])
            ? (int) $value['receivedAt']
            : 0;
        $attempts = isset($value['attempts']) && is_numeric($value['attempts'])
            ? (int) $value['attempts']
            : -1;
        $next_attempt = isset($value['nextAttempt']) && is_numeric($value['nextAttempt'])
            ? (int) $value['nextAttempt']
            : 0;
        $events = $value['events'] ?? null;
        if ($received_at <= 0 || $received_at > time() + 60
            || $attempts < 0 || $attempts > 1000000
            || $next_attempt <= 0 || $next_attempt > time() + 3900 || !is_array($events)
            || !$events || count($events) > 5) {
            return new WP_Error('fan_apple_notification_unavailable', 'Apple 通知持久状态无效。', array('status' => 503));
        }
        $normalized_events = array();
        foreach ($events as $event) {
            if (!is_array($event)
                || !in_array((string) ($event['type'] ?? ''), array('consent-revoked', 'account-deleted'), true)
                || !self::valid_apple_sub_hash((string) ($event['subjectHash'] ?? ''))
                || !isset($event['eventTime']) || !is_numeric($event['eventTime'])) {
                return new WP_Error('fan_apple_notification_unavailable', 'Apple 通知持久状态无效。', array('status' => 503));
            }
            $event_time = (int) $event['eventTime'];
            if ($event_time <= 0 || $event_time > $received_at + 60
                || $event_time < $received_at - 7 * DAY_IN_SECONDS) {
                return new WP_Error('fan_apple_notification_unavailable', 'Apple 通知持久状态无效。', array('status' => 503));
            }
            $normalized_events[] = array(
                'type' => (string) $event['type'],
                'subjectHash' => (string) $event['subjectHash'],
                'eventTime' => $event_time,
            );
        }
        return array(
            'version' => 1,
            'status' => 'pending',
            'receivedAt' => $received_at,
            'events' => $normalized_events,
            'attempts' => $attempts,
            'nextAttempt' => $next_attempt,
            'generation' => $generation,
        );
    }

    private static function schedule_fan_apple_event_record($option_name, $record) {
        if (!preg_match('/^yishu_fan_apple_event_[a-f0-9]{64}$/', (string) $option_name)
            || !is_array($record)
            || !preg_match('/^[a-f0-9]{32}$/', (string) ($record['generation'] ?? ''))) {
            return false;
        }
        $generation = (string) $record['generation'];
        if (($record['status'] ?? '') === 'pending') {
            $hook = 'yishu_process_fan_apple_event';
            $at = max(time() + 5, (int) ($record['nextAttempt'] ?? time() + 5));
        } elseif (($record['status'] ?? '') === 'processed') {
            $hook = 'yishu_cleanup_fan_apple_event';
            $at = max(time() + 5, (int) ($record['expires'] ?? time() + 5) + 60);
        } else {
            return false;
        }
        $args = array((string) $option_name, $generation);
        if (wp_next_scheduled($hook, $args)) { return true; }
        $scheduled = wp_schedule_single_event($at, $hook, $args, true);
        return !is_wp_error($scheduled) && $scheduled;
    }

    private static function apple_private_key() {
        if (!defined('YISHU_APPLE_TEAM_ID') || !defined('YISHU_APPLE_KEY_ID')
            || !defined('YISHU_APPLE_PRIVATE_KEY_PATH')
            || !preg_match('/^[A-Z0-9]{10}$/', (string) YISHU_APPLE_TEAM_ID)
            || !preg_match('/^[A-Z0-9]{10}$/', (string) YISHU_APPLE_KEY_ID)) {
            return new WP_Error('fan_apple_configuration_unavailable', 'Apple 登录密钥尚未配置。', array('status' => 503));
        }
        $configured_path = (string) YISHU_APPLE_PRIVATE_KEY_PATH;
        $path = realpath($configured_path);
        $root = realpath(ABSPATH);
        $configured_normalized = function_exists('wp_normalize_path')
            ? wp_normalize_path($configured_path)
            : str_replace('\\', '/', $configured_path);
        $root_normalized = $root && function_exists('wp_normalize_path')
            ? rtrim(wp_normalize_path($root), '/') . '/'
            : ($root ? rtrim(str_replace('\\', '/', $root), '/') . '/' : '');
        if (!$path || !$root || $configured_path === '' || $configured_path[0] !== '/'
            || is_link($configured_path)
            || ($root_normalized !== '' && strpos($configured_normalized, $root_normalized) === 0)
            || strpos($path, $root . DIRECTORY_SEPARATOR) === 0
            || !is_file($path) || !is_readable($path) || filesize($path) > 16384) {
            return new WP_Error('fan_apple_configuration_unavailable', 'Apple 登录密钥配置不安全。', array('status' => 503));
        }
        $permissions = fileperms($path);
        if ($permissions === false || (($permissions & 077) !== 0)) {
            return new WP_Error('fan_apple_configuration_unavailable', 'Apple 登录密钥权限过宽。', array('status' => 503));
        }
        $private_key = file_get_contents($path);
        if (!is_string($private_key) || strpos($private_key, 'PRIVATE KEY') === false) {
            return new WP_Error('fan_apple_configuration_unavailable', 'Apple 登录密钥无效。', array('status' => 503));
        }
        return $private_key;
    }

    private static function apple_client_secret() {
        $loaded = self::load_apple_jwt_library();
        if (is_wp_error($loaded)) { return $loaded; }
        $private_key = self::apple_private_key();
        if (is_wp_error($private_key)) { return $private_key; }
        $now = time();
        try {
            return \Firebase\JWT\JWT::encode(array(
                'iss' => (string) YISHU_APPLE_TEAM_ID,
                'iat' => $now,
                'exp' => $now + 300,
                'aud' => self::FAN_APPLE_ISSUER,
                'sub' => self::FAN_APPLE_CLIENT_ID,
            ), $private_key, 'ES256', (string) YISHU_APPLE_KEY_ID);
        } catch (Throwable $error) {
            return new WP_Error('fan_apple_configuration_unavailable', 'Apple 登录密钥无法使用。', array('status' => 503));
        }
    }

    private static function exchange_apple_authorization_code($authorization_code) {
        if (self::apple_test_mode_enabled()) {
            $test_result = apply_filters(
                'yishu_fan_apple_code_exchange',
                null,
                (string) $authorization_code
            );
            if ($test_result !== null) {
                return is_array($test_result)
                    ? $test_result
                    : new WP_Error('fan_apple_exchange_failed', 'Apple 授权码无效。', array('status' => 401));
            }
        }
        $client_secret = self::apple_client_secret();
        if (is_wp_error($client_secret)) { return $client_secret; }
        $response = wp_remote_post('https://appleid.apple.com/auth/token', array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array(
                'Accept' => 'application/json',
                'Content-Type' => 'application/x-www-form-urlencoded',
            ),
            'body' => array(
                'client_id' => self::FAN_APPLE_CLIENT_ID,
                'client_secret' => $client_secret,
                'code' => (string) $authorization_code,
                'grant_type' => 'authorization_code',
            ),
        ));
        if (is_wp_error($response)) {
            return new WP_Error('fan_apple_exchange_unavailable', '暂时无法联系 Apple 验证服务。', array('status' => 503));
        }
        $status = (int) wp_remote_retrieve_response_code($response);
        $body = (string) wp_remote_retrieve_body($response);
        $payload = strlen($body) <= 65536 ? json_decode($body, true) : null;
        if ($status !== 200 || !is_array($payload)
            || !is_string($payload['id_token'] ?? null)
            || !is_string($payload['refresh_token'] ?? null)
            || strlen((string) $payload['refresh_token']) < 8
            || strlen((string) $payload['refresh_token']) > 4096) {
            $error_status = $status >= 500 ? 503 : 401;
            return new WP_Error(
                $error_status === 503 ? 'fan_apple_exchange_unavailable' : 'fan_apple_exchange_failed',
                $error_status === 503 ? '暂时无法联系 Apple 验证服务。' : 'Apple 授权码无效。',
                array('status' => $error_status)
            );
        }
        return array(
            'idToken' => (string) $payload['id_token'],
            'refreshToken' => (string) $payload['refresh_token'],
        );
    }

    private static function verify_and_exchange_apple_credential(
        $identity_token,
        $authorization_code,
        $expected_nonce_hash
    ) {
        $client_claims = self::verify_apple_identity_token($identity_token, $expected_nonce_hash);
        if (is_wp_error($client_claims)) { return $client_claims; }
        $exchange = self::exchange_apple_authorization_code($authorization_code);
        if (is_wp_error($exchange)) { return $exchange; }
        $exchanged_claims = self::verify_apple_identity_token(
            (string) ($exchange['idToken'] ?? ''),
            $expected_nonce_hash
        );
        if (is_wp_error($exchanged_claims)
            || !hash_equals(
                (string) $client_claims['subjectHash'],
                (string) ($exchanged_claims['subjectHash'] ?? '')
            )) {
            return new WP_Error('fan_apple_credential_invalid', 'Apple 验证已失效。', array('status' => 401));
        }
        $refresh_token = (string) ($exchange['refreshToken'] ?? '');
        if (strlen($refresh_token) < 8 || strlen($refresh_token) > 4096) {
            return new WP_Error('fan_apple_exchange_failed', 'Apple 授权码无效。', array('status' => 401));
        }
        return array(
            'subjectHash' => (string) $client_claims['subjectHash'],
            // Both signed identity tokens participate in this credential.
            // The older iat is the conservative boundary for S2S revocation
            // tombstones and prevents an already-verified request from
            // resurrecting an account deleted while it waited on the lock.
            'issuedAt' => min(
                (int) ($client_claims['issuedAt'] ?? 0),
                (int) ($exchanged_claims['issuedAt'] ?? 0)
            ),
            'refreshToken' => $refresh_token,
        );
    }

    private static function apple_refresh_encryption_key() {
        if (!function_exists('sodium_crypto_secretbox')
            || !function_exists('sodium_crypto_secretbox_open')
            || !function_exists('sodium_memzero')
            || !function_exists('hash_hkdf')) {
            return new WP_Error(
                'fan_apple_encryption_unavailable',
                'Apple 账号安全存储暂时不可用。',
                array('status' => 503)
            );
        }
        $master_key = self::apple_data_master_key();
        if (is_wp_error($master_key)) { return $master_key; }
        $key = hash_hkdf(
            'sha256',
            $master_key,
            SODIUM_CRYPTO_SECRETBOX_KEYBYTES,
            'yishu/apple-refresh/v1',
            hash('sha256', self::FAN_APPLE_CLIENT_ID, true)
        );
        sodium_memzero($master_key);
        return $key;
    }

    private static function encrypt_apple_refresh_token($refresh_token) {
        $refresh_token = (string) $refresh_token;
        $key = self::apple_refresh_encryption_key();
        if (is_wp_error($key)) { return $key; }
        if (strlen($refresh_token) < 8 || strlen($refresh_token) > 4096) {
            sodium_memzero($key);
            return new WP_Error('fan_apple_encryption_unavailable', 'Apple 账号安全存储暂时不可用。', array('status' => 503));
        }
        try {
            $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            $ciphertext = sodium_crypto_secretbox($refresh_token, $nonce, $key);
            sodium_memzero($key);
            return array(
                'version' => 1,
                'nonce' => rtrim(strtr(base64_encode($nonce), '+/', '-_'), '='),
                'ciphertext' => rtrim(strtr(base64_encode($ciphertext), '+/', '-_'), '='),
            );
        } catch (Throwable $error) {
            if ($key !== '') { sodium_memzero($key); }
            return new WP_Error('fan_apple_encryption_unavailable', 'Apple 账号安全存储暂时不可用。', array('status' => 503));
        }
    }

    private static function decrypt_apple_refresh_token($encrypted) {
        if (!is_array($encrypted) || (int) ($encrypted['version'] ?? 0) !== 1) { return ''; }
        $decode = static function ($value) {
            if (!is_string($value) || !preg_match('/^[A-Za-z0-9_-]+$/D', $value)) { return false; }
            $padding = (4 - (strlen($value) % 4)) % 4;
            return base64_decode(strtr($value . str_repeat('=', $padding), '-_', '+/'), true);
        };
        $nonce = $decode($encrypted['nonce'] ?? '');
        $ciphertext = $decode($encrypted['ciphertext'] ?? '');
        $key = self::apple_refresh_encryption_key();
        if (!is_string($nonce) || strlen($nonce) !== SODIUM_CRYPTO_SECRETBOX_NONCEBYTES
            || !is_string($ciphertext) || strlen($ciphertext) < SODIUM_CRYPTO_SECRETBOX_MACBYTES
            || is_wp_error($key)) {
            if (is_string($key) && $key !== '') { sodium_memzero($key); }
            return '';
        }
        try {
            $plaintext = sodium_crypto_secretbox_open($ciphertext, $nonce, $key);
            sodium_memzero($key);
            return is_string($plaintext) && strlen($plaintext) >= 8 && strlen($plaintext) <= 4096
                ? $plaintext
                : '';
        } catch (Throwable $error) {
            sodium_memzero($key);
            return '';
        }
    }

    private static function normalize_fan_apple_setup($value) {
        if (!is_array($value)
            || (int) ($value['version'] ?? 0) !== 1
            || !preg_match('/^[a-f0-9]{32}$/', (string) ($value['generation'] ?? ''))
            || !isset($value['createdAt']) || !is_scalar($value['createdAt'])) {
            return new WP_Error(
                'fan_apple_profile_required',
                '请重新使用 Apple ID 登录后完成资料。',
                array('status' => 403)
            );
        }
        $created = strtotime((string) $value['createdAt']);
        if ($created === false || $created <= 0 || $created > time() + 60) {
            return new WP_Error('fan_apple_profile_required', '请重新使用 Apple ID 登录。', array('status' => 403));
        }
        return array(
            'version' => 1,
            'generation' => (string) $value['generation'],
            'createdAt' => gmdate('c', $created),
            'createdTimestamp' => $created,
        );
    }

    private static function login_or_create_apple_fan($credential, $install_id) {
        if (!is_array($credential)
            || !self::valid_apple_sub_hash((string) ($credential['subjectHash'] ?? ''))
            || !isset($credential['issuedAt']) || !is_numeric($credential['issuedAt'])
            || (int) $credential['issuedAt'] <= 0
            || (int) $credential['issuedAt'] > time() + 60
            || (int) $credential['issuedAt'] < time() - DAY_IN_SECONDS
            || strlen((string) ($credential['refreshToken'] ?? '')) < 8) {
            return new WP_Error('fan_apple_credential_invalid', 'Apple 验证已失效。', array('status' => 401));
        }
        $subject_hash = (string) $credential['subjectHash'];
        $reservation = self::apple_subject_reservation_name($subject_hash);
        $lock_name = self::acquire_named_fan_lock('apple_sub', $subject_hash);
        if (is_wp_error($lock_name)) { return $lock_name; }
        try {
            $tombstone_check = self::authorize_apple_subject_after_tombstone_under_lock(
                $subject_hash,
                (int) $credential['issuedAt']
            );
            if (is_wp_error($tombstone_check)) { return $tombstone_check; }
            $owner = self::resolve_apple_subject_owner_under_lock($subject_hash, $reservation);
            if (is_wp_error($owner)) { return $owner; }
            if ($owner > 0) {
                $user = get_userdata($owner);
                if (!$user instanceof WP_User
                    || self::fan_account_source($owner) !== 'apple'
                    || !hash_equals(
                        $subject_hash,
                        (string) self::fan_meta_from_database($owner, self::FAN_META_APPLE_SUB_HASH, '')
                    )) {
                    return new WP_Error('fan_apple_account_conflict', 'Apple 账号暂时无法登录。', array('status' => 409));
                }
                $lock_owner = self::acquire_fan_lock($owner);
                if (is_wp_error($lock_owner)) { return $lock_owner; }
                try {
                    if (!self::apple_account_runtime_is_valid($owner)) {
                        return new WP_Error(
                            'fan_apple_account_conflict',
                            'Apple 账号状态暂时无法确认。',
                            array('status' => 409)
                        );
                    }
                    $stored_encrypted = self::fan_meta_from_database(
                        $owner,
                        self::FAN_META_APPLE_REFRESH_TOKEN,
                        null
                    );
                    $stored_refresh_is_usable = false;
                    if (self::valid_encrypted_apple_refresh_token($stored_encrypted)) {
                        // Apple documents that a refresh token remains usable
                        // until the associated authorization is invalidated.
                        // Preserve the first tracked token instead of replacing
                        // it with every interactive authorization response.
                        $stored_refresh = self::decrypt_apple_refresh_token($stored_encrypted);
                        if ($stored_refresh !== '') {
                            $stored_refresh_is_usable = true;
                            sodium_memzero($stored_refresh);
                        }
                    }
                    if (!$stored_refresh_is_usable) {
                        // A freshly verified credential for the same Apple sub
                        // may repair missing/corrupted encrypted revocation
                        // state without weakening subject ownership checks.
                        $encrypted = self::encrypt_apple_refresh_token(
                            (string) $credential['refreshToken']
                        );
                        if (is_wp_error($encrypted)
                            || !self::update_user_meta_verified(
                                $owner,
                                self::FAN_META_APPLE_REFRESH_TOKEN,
                                $encrypted
                            )) {
                            return is_wp_error($encrypted)
                                ? $encrypted
                                : new WP_Error('fan_apple_encryption_unavailable', 'Apple 账号安全存储暂时不可用。', array('status' => 503));
                        }
                    }
                    $previous_auth_iat = (int) self::fan_meta_from_database(
                        $owner,
                        self::FAN_META_APPLE_AUTH_IAT,
                        0
                    );
                    $current_auth_iat = max(
                        $previous_auth_iat,
                        (int) $credential['issuedAt']
                    );
                    if (!self::update_user_meta_verified(
                        $owner,
                        self::FAN_META_APPLE_AUTH_IAT,
                        $current_auth_iat
                    )) {
                        return new WP_Error('fan_apple_audit_unavailable', '暂时无法安全记录 Apple 登录。', array('status' => 503));
                    }
                    if (!self::record_fan_auth_audit($owner, 'apple_sign_in')) {
                        return new WP_Error('fan_apple_audit_unavailable', '暂时无法安全记录 Apple 登录。', array('status' => 503));
                    }
                    $setup = self::fan_meta_from_database($owner, self::FAN_META_APPLE_SETUP, null);
                    $scope = empty($setup) ? 'normal' : 'apple_onboarding';
                    if ($scope === 'apple_onboarding' && is_wp_error(self::normalize_fan_apple_setup($setup))) {
                        return new WP_Error('fan_apple_profile_required', '请联系管理员检查 Apple 账号状态。', array('status' => 409));
                    }
                    if ($scope === 'normal' && !self::apple_registration_is_complete($owner)) {
                        return new WP_Error(
                            'fan_apple_profile_required',
                            'Apple 账号资料或隐私同意状态需要重新确认。',
                            array('status' => 409)
                        );
                    }
                    $session = self::issue_fan_session(
                        $owner,
                        $install_id,
                        $scope,
                        $scope === 'apple_onboarding'
                            ? self::FAN_APPLE_ONBOARDING_SESSION_TTL
                            : self::FAN_SESSION_TTL,
                        array('authMethod' => 'apple', 'recentAuthUntil' => time() + self::FAN_APPLE_RECENT_AUTH_TTL)
                    );
                    if (is_wp_error($session)) { return $session; }
                    return $scope === 'apple_onboarding'
                        ? self::fan_apple_onboarding_response($owner, $session)
                        : self::fan_auth_response($owner, $session);
                } finally {
                    self::release_fan_lock($owner, $lock_owner);
                }
            }
            try {
                $generation = bin2hex(random_bytes(16));
                $random_password = rtrim(strtr(base64_encode(random_bytes(48)), '+/', '-_'), '=') . '-A9!';
            } catch (Throwable $error) {
                return new WP_Error('fan_registration_unavailable', '暂时无法创建 Apple 账号。', array('status' => 503));
            }
            $pending = array(
                'version' => 1,
                'generation' => $generation,
                'createdAt' => time(),
            );
            if (!add_option($reservation, $pending, '', false)) {
                return new WP_Error('fan_apple_account_conflict', 'Apple 账号暂时无法登录。', array('status' => 409));
            }
            $scheduled = wp_schedule_single_event(
                time() + self::FAN_APPLE_PENDING_ACCOUNT_TTL,
                'yishu_cleanup_fan_apple_pending_account',
                array($reservation, $generation),
                true
            );
            if (is_wp_error($scheduled) || !$scheduled) {
                delete_option($reservation);
                return new WP_Error('fan_registration_unavailable', '暂时无法创建 Apple 账号。', array('status' => 503));
            }
            $encrypted = self::encrypt_apple_refresh_token((string) $credential['refreshToken']);
            if (is_wp_error($encrypted)) {
                delete_option($reservation);
                return $encrypted;
            }
            $login = 'fan_apple_' . $generation;
            $user_id = wp_insert_user(array(
                'user_login' => $login,
                'user_pass' => $random_password,
                'display_name' => 'Apple 粉丝',
                'role' => 'subscriber',
            ));
            if (is_wp_error($user_id)) {
                delete_option($reservation);
                return new WP_Error('fan_registration_unavailable', '暂时无法创建 Apple 账号。', array('status' => 503));
            }
            $saved = self::update_user_meta_verified($user_id, self::FAN_META_UUID, wp_generate_uuid4())
                && self::update_user_meta_verified($user_id, self::FAN_META_STATUS, 'pending')
                && self::update_user_meta_verified($user_id, self::FAN_META_CREDENTIAL_EPOCH, 1)
                && self::update_user_meta_verified($user_id, self::FAN_META_ACCOUNT_SOURCE, 'apple')
                && self::update_user_meta_verified($user_id, self::FAN_META_APPLE_SUB_HASH, $subject_hash)
                && self::update_user_meta_verified($user_id, self::FAN_META_APPLE_REFRESH_TOKEN, $encrypted)
                && self::update_user_meta_verified(
                    $user_id,
                    self::FAN_META_APPLE_AUTH_IAT,
                    (int) $credential['issuedAt']
                )
                && self::update_user_meta_verified($user_id, self::FAN_META_APPLE_SETUP, array(
                    'version' => 1,
                    'generation' => $generation,
                    'createdAt' => gmdate('c'),
                ))
                && self::record_fan_auth_audit($user_id, 'apple_account_created');
            if (!$saved || (!update_option($reservation, (int) $user_id, false)
                && self::reservation_owner_from_database($reservation) !== (int) $user_id)) {
                self::remove_fan_user((int) $user_id);
                delete_option($reservation);
                return new WP_Error('fan_registration_unavailable', '暂时无法创建 Apple 账号。', array('status' => 503));
            }
            $session = self::issue_fan_session(
                (int) $user_id,
                $install_id,
                'apple_onboarding',
                self::FAN_APPLE_ONBOARDING_SESSION_TTL,
                array('authMethod' => 'apple', 'recentAuthUntil' => time() + self::FAN_APPLE_RECENT_AUTH_TTL)
            );
            if (is_wp_error($session)) {
                self::remove_fan_user((int) $user_id);
                return $session;
            }
            return self::fan_apple_onboarding_response((int) $user_id, $session, 201);
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    private static function fan_apple_onboarding_response($user_id, $session, $status = 200) {
        $response = new WP_REST_Response(array(
            'token' => (string) $session['token'],
            'appleRegistration' => array(
                'expiresAt' => gmdate('c', (int) $session['expires']),
            ),
        ), (int) $status);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        return $response;
    }

    private static function revoke_apple_refresh_token($refresh_token) {
        $refresh_token = (string) $refresh_token;
        if (strlen($refresh_token) < 8 || strlen($refresh_token) > 4096) { return false; }
        if (self::apple_test_mode_enabled()) {
            $test_result = apply_filters(
                'yishu_fan_apple_token_revoke',
                null,
                $refresh_token
            );
            if ($test_result !== null) { return $test_result === true; }
        }
        $client_secret = self::apple_client_secret();
        if (is_wp_error($client_secret)) { return false; }
        $response = wp_remote_post('https://appleid.apple.com/auth/revoke', array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array(
                'Accept' => 'application/json',
                'Content-Type' => 'application/x-www-form-urlencoded',
            ),
            'body' => array(
                'client_id' => self::FAN_APPLE_CLIENT_ID,
                'client_secret' => $client_secret,
                'token' => $refresh_token,
                'token_type_hint' => 'refresh_token',
            ),
        ));
        return !is_wp_error($response)
            && (int) wp_remote_retrieve_response_code($response) === 200;
    }

    private static function valid_encrypted_apple_refresh_token($encrypted) {
        return is_array($encrypted)
            && (int) ($encrypted['version'] ?? 0) === 1
            && preg_match('/^[A-Za-z0-9_-]{32}$/D', (string) ($encrypted['nonce'] ?? '')) === 1
            && preg_match('/^[A-Za-z0-9_-]{32,8192}$/D', (string) ($encrypted['ciphertext'] ?? '')) === 1;
    }

    private static function queue_fan_apple_revocation($encrypted) {
        if (!self::valid_encrypted_apple_refresh_token($encrypted)) { return false; }
        try {
            $job_id = bin2hex(random_bytes(24));
            $generation = bin2hex(random_bytes(16));
        } catch (Throwable $error) {
            return false;
        }
        $option_name = self::FAN_APPLE_REVOCATION_OPTION_PREFIX . $job_id;
        $now = time();
        $record = array(
            'version' => 1,
            'encryptedRefreshToken' => $encrypted,
            'attempts' => 0,
            'createdAt' => $now,
            'expires' => $now + self::FAN_APPLE_REVOCATION_TTL,
            'nextAttempt' => $now + 60,
            'generation' => $generation,
        );
        if (!add_option($option_name, $record, '', false)) { return false; }
        $scheduled = wp_schedule_single_event(
            $record['nextAttempt'],
            'yishu_retry_fan_apple_revocation',
            array($option_name, $generation),
            true
        );
        // The init sweeper repairs a lost scheduler write. Never attach the
        // anonymous job to a WordPress user, Apple subject or Douyin ID.
        if (is_wp_error($scheduled) || !$scheduled) {
            do_action('yishu_fan_security_audit', 'apple_revocation_schedule_unavailable');
        }
        return $option_name;
    }

    public static function retry_fan_apple_revocation($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_revocation_[a-f0-9]{48}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $lock_name = self::acquire_named_fan_lock('apple_revoke', $option_name);
        if (is_wp_error($lock_name)) { return; }
        try {
            $record = get_option($option_name, null);
            if (!is_array($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            $now = time();
            $attempts = (int) ($record['attempts'] ?? 0);
            if ((int) ($record['expires'] ?? 0) <= $now
                || $attempts >= self::FAN_APPLE_REVOCATION_MAX_ATTEMPTS
                || !self::valid_encrypted_apple_refresh_token($record['encryptedRefreshToken'] ?? null)) {
                delete_option($option_name);
                return;
            }
            $refresh_token = self::decrypt_apple_refresh_token($record['encryptedRefreshToken']);
            if ($refresh_token !== '' && self::revoke_apple_refresh_token($refresh_token)) {
                if (function_exists('sodium_memzero')) { sodium_memzero($refresh_token); }
                delete_option($option_name);
                return;
            }
            if ($refresh_token !== '' && function_exists('sodium_memzero')) { sodium_memzero($refresh_token); }
            $attempts++;
            if ($attempts >= self::FAN_APPLE_REVOCATION_MAX_ATTEMPTS) {
                delete_option($option_name);
                return;
            }
            $delay = min(21600, 60 * (2 ** min($attempts, 8)));
            $record['attempts'] = $attempts;
            $record['nextAttempt'] = min($now + $delay, (int) $record['expires']);
            if (update_option($option_name, $record, false) === false) {
                return;
            }
            wp_schedule_single_event(
                (int) $record['nextAttempt'],
                'yishu_retry_fan_apple_revocation',
                array($option_name, $generation),
                true
            );
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    public static function ensure_fan_apple_revocation_schedule() {
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return;
        }
        $like = $wpdb->esc_like(self::FAN_APPLE_REVOCATION_OPTION_PREFIX) . '%';
        $cursor = (string) get_option(self::FAN_APPLE_REVOCATION_CURSOR_OPTION, '');
        if ($cursor !== ''
            && !preg_match('/^yishu_fan_apple_revocation_[a-f0-9]{48}$/', $cursor)) {
            $cursor = '';
        }
        $option_names = $wpdb->get_col($wpdb->prepare(
            "SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE %s AND option_name > %s ORDER BY option_name ASC LIMIT 50",
            $like,
            $cursor
        ));
        if (!is_array($option_names) || !empty($wpdb->last_error)) { return; }
        $now = time();
        foreach ((array) $option_names as $option_name) {
            if (!preg_match('/^yishu_fan_apple_revocation_[a-f0-9]{48}$/', (string) $option_name)) {
                continue;
            }
            $record = get_option((string) $option_name, null);
            $generation = is_array($record) ? (string) ($record['generation'] ?? '') : '';
            $next = is_array($record) ? (int) ($record['nextAttempt'] ?? 0) : 0;
            $expires = is_array($record) ? (int) ($record['expires'] ?? 0) : 0;
            if (!preg_match('/^[a-f0-9]{32}$/', $generation)
                || !self::valid_encrypted_apple_refresh_token(
                    is_array($record) ? ($record['encryptedRefreshToken'] ?? null) : null
                )
                || $expires <= $now) {
                delete_option((string) $option_name);
                continue;
            }
            if (!wp_next_scheduled('yishu_retry_fan_apple_revocation', array((string) $option_name, $generation))) {
                wp_schedule_single_event(
                    max($now + 5, min($next > 0 ? $next : $now + 5, $expires)),
                    'yishu_retry_fan_apple_revocation',
                    array((string) $option_name, $generation),
                    true
                );
            }
        }
        if (count($option_names) < 50) {
            delete_option(self::FAN_APPLE_REVOCATION_CURSOR_OPTION);
        } else {
            update_option(
                self::FAN_APPLE_REVOCATION_CURSOR_OPTION,
                (string) end($option_names),
                false
            );
        }
    }

    public static function ensure_fan_apple_event_schedule() {
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return;
        }
        $like = $wpdb->esc_like(self::FAN_APPLE_EVENT_OPTION_PREFIX) . '%';
        $cursor = (string) get_option(self::FAN_APPLE_EVENT_CURSOR_OPTION, '');
        if ($cursor !== '' && !preg_match('/^yishu_fan_apple_event_[a-f0-9]{64}$/', $cursor)) {
            $cursor = '';
        }
        $option_names = $wpdb->get_col($wpdb->prepare(
            "SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE %s AND option_name > %s ORDER BY option_name ASC LIMIT 50",
            $like,
            $cursor
        ));
        if (!is_array($option_names) || !empty($wpdb->last_error)) { return; }
        foreach ($option_names as $option_name) {
            if (!preg_match('/^yishu_fan_apple_event_[a-f0-9]{64}$/', (string) $option_name)) {
                continue;
            }
            $record = self::normalize_fan_apple_event_record(
                self::fan_option_from_database((string) $option_name, null)
            );
            if (is_wp_error($record)) {
                do_action('yishu_fan_security_audit', 'apple_event_inbox_invalid');
                continue;
            }
            if (!self::schedule_fan_apple_event_record((string) $option_name, $record)) {
                do_action('yishu_fan_security_audit', 'apple_event_schedule_unavailable');
            }
        }
        if (count($option_names) < 50) {
            delete_option(self::FAN_APPLE_EVENT_CURSOR_OPTION);
        } else {
            update_option(
                self::FAN_APPLE_EVENT_CURSOR_OPTION,
                (string) end($option_names),
                false
            );
        }
    }

    public static function ensure_fan_apple_tombstone_schedule() {
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return;
        }
        $like = $wpdb->esc_like(self::FAN_APPLE_TOMBSTONE_OPTION_PREFIX) . '%';
        $cursor = (string) get_option(self::FAN_APPLE_TOMBSTONE_CURSOR_OPTION, '');
        if ($cursor !== '' && !preg_match('/^yishu_fan_apple_revoked_[a-f0-9]{64}$/', $cursor)) {
            $cursor = '';
        }
        $option_names = $wpdb->get_col($wpdb->prepare(
            "SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE %s AND option_name > %s ORDER BY option_name ASC LIMIT 50",
            $like,
            $cursor
        ));
        if (!is_array($option_names) || !empty($wpdb->last_error)) { return; }
        foreach ($option_names as $option_name) {
            if (!preg_match('/^yishu_fan_apple_revoked_[a-f0-9]{64}$/', (string) $option_name)) {
                continue;
            }
            $record = self::normalize_apple_subject_tombstone(
                self::fan_option_from_database((string) $option_name, null)
            );
            if (is_wp_error($record)) {
                do_action('yishu_fan_security_audit', 'apple_tombstone_invalid');
                continue;
            }
            $args = array((string) $option_name, (string) $record['generation']);
            if (!wp_next_scheduled('yishu_cleanup_fan_apple_tombstone', $args)) {
                $scheduled = wp_schedule_single_event(
                    max(time() + 5, (int) $record['expires'] + 60),
                    'yishu_cleanup_fan_apple_tombstone',
                    $args,
                    true
                );
                if (is_wp_error($scheduled) || !$scheduled) {
                    do_action('yishu_fan_security_audit', 'apple_tombstone_schedule_unavailable');
                }
            }
        }
        if (count($option_names) < 50) {
            delete_option(self::FAN_APPLE_TOMBSTONE_CURSOR_OPTION);
        } else {
            update_option(
                self::FAN_APPLE_TOMBSTONE_CURSOR_OPTION,
                (string) end($option_names),
                false
            );
        }
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
        $value = self::fan_option_from_database((string) $option_name, null);
        return is_scalar($value) ? (int) $value : 0;
    }

    private static function fan_option_from_database($option_name, $default = null) {
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return $default;
        }
        $value = $wpdb->get_var($wpdb->prepare(
            "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s LIMIT 1",
            (string) $option_name
        ));
        return $value === null ? $default : maybe_unserialize($value);
    }

    private static function apple_user_ids_for_subject_hash($subject_hash) {
        global $wpdb;
        if (!self::valid_apple_sub_hash($subject_hash)
            || !isset($wpdb->usermeta) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare')) {
            return new WP_Error(
                'fan_apple_account_conflict',
                'Apple 账号状态暂时无法确认。',
                array('status' => 503)
            );
        }
        $ids = $wpdb->get_col($wpdb->prepare(
            "SELECT DISTINCT user_id FROM {$wpdb->usermeta} WHERE meta_key = %s AND meta_value = %s ORDER BY user_id ASC LIMIT 3",
            self::FAN_META_APPLE_SUB_HASH,
            (string) $subject_hash
        ));
        if (!empty($wpdb->last_error)) {
            return new WP_Error(
                'fan_apple_account_conflict',
                'Apple 账号状态暂时无法确认。',
                array('status' => 503)
            );
        }
        return array_values(array_unique(array_filter(array_map('intval', (array) $ids))));
    }

    private static function valid_apple_subject_owner(
        $user_id,
        $subject_hash,
        $pending_generation = ''
    ) {
        $user = get_userdata((int) $user_id);
        $core_valid = $user instanceof WP_User
            && self::fan_account_source((int) $user_id) === 'apple'
            && hash_equals(
                (string) $subject_hash,
                (string) self::fan_meta_from_database(
                    (int) $user_id,
                    self::FAN_META_APPLE_SUB_HASH,
                    ''
                )
            );
        if (!$core_valid || $pending_generation === '') { return $core_valid; }

        // A reservation that still carries its creation generation represents
        // an interrupted first-registration transaction. Only that exact
        // onboarding marker makes the partial account recoverable. Committed
        // subject ownership must not depend on mutable profile or consent data;
        // Apple S2S deletion must still work after those fields change/corrupt.
        $uuid = (string) self::fan_meta_from_database((int) $user_id, self::FAN_META_UUID, '');
        $status = (string) self::fan_meta_from_database((int) $user_id, self::FAN_META_STATUS, '');
        $epoch = (int) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_CREDENTIAL_EPOCH,
            0
        );
        $encrypted = self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_APPLE_REFRESH_TOKEN,
            null
        );
        $setup = self::normalize_fan_apple_setup(self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_APPLE_SETUP,
            null
        ));
        return preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $uuid) === 1
            && in_array($status, array('pending', 'active', 'rejected', 'suspended'), true)
            && $epoch > 0
            && self::valid_encrypted_apple_refresh_token($encrypted)
            && is_array($setup)
            && hash_equals(
                (string) $pending_generation,
                (string) ($setup['generation'] ?? '')
            );
    }

    private static function apple_account_runtime_is_valid($user_id) {
        $uuid = (string) self::fan_meta_from_database((int) $user_id, self::FAN_META_UUID, '');
        $status = (string) self::fan_meta_from_database((int) $user_id, self::FAN_META_STATUS, '');
        $epoch = (int) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_CREDENTIAL_EPOCH,
            0
        );
        return preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $uuid) === 1
            && in_array($status, array('pending', 'active', 'rejected', 'suspended'), true)
            && $epoch > 0;
    }

    private static function apple_registration_is_complete($user_id) {
        if (!self::apple_account_runtime_is_valid((int) $user_id)) { return false; }
        if (!empty(self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_APPLE_SETUP,
            null
        ))) {
            return false;
        }
        $identity_code = self::normalize_identity_code(self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_CODE,
            ''
        ));
        $stored_douyin_id = (string) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_DOUYIN_ID,
            ''
        );
        $douyin_id = self::normalize_optional_douyin_id($stored_douyin_id);
        $consent = self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_CONSENT,
            null
        );
        return $identity_code !== ''
            && !is_wp_error($douyin_id)
            && $douyin_id === $stored_douyin_id
            && self::fan_stored_consent_is_accepted($consent);
    }

    private static function cleanup_partial_apple_user_for_generation(
        $generation,
        $subject_hash,
        $expected_user_id = 0
    ) {
        if (!preg_match('/^[a-f0-9]{32}$/', (string) $generation)) { return true; }
        $user = get_user_by('login', 'fan_apple_' . (string) $generation);
        if (!$user instanceof WP_User) { return (int) $expected_user_id <= 0; }
        if ((int) $expected_user_id > 0 && (int) $user->ID !== (int) $expected_user_id) {
            return false;
        }
        $stored_hash = (string) self::fan_meta_from_database(
            (int) $user->ID,
            self::FAN_META_APPLE_SUB_HASH,
            ''
        );
        if ($stored_hash !== '' && !hash_equals((string) $subject_hash, $stored_hash)) {
            return false;
        }
        return self::remove_fan_user((int) $user->ID);
    }

    private static function resolve_apple_subject_owner_under_lock($subject_hash, $reservation) {
        $ids = self::apple_user_ids_for_subject_hash($subject_hash);
        if (is_wp_error($ids)) { return $ids; }
        $raw_reservation = self::fan_option_from_database($reservation, null);
        $reserved_owner = is_scalar($raw_reservation) ? (int) $raw_reservation : 0;
        if (count($ids) > 1 || ($reserved_owner > 0 && $ids && $reserved_owner !== (int) $ids[0])) {
            return new WP_Error('fan_apple_account_conflict', 'Apple 账号状态冲突。', array('status' => 409));
        }
        if ($ids) {
            $owner = (int) $ids[0];
            $pending_generation = is_array($raw_reservation)
                ? (string) ($raw_reservation['generation'] ?? '')
                : '';
            if (!self::valid_apple_subject_owner(
                $owner,
                $subject_hash,
                $pending_generation
            )) {
                if (!$pending_generation
                    || !self::cleanup_partial_apple_user_for_generation(
                        $pending_generation,
                        $subject_hash,
                        $owner
                    )) {
                    return new WP_Error('fan_apple_account_conflict', 'Apple 账号状态冲突。', array('status' => 409));
                }
                delete_option($reservation);
                self::clear_fan_option_caches(array($reservation));
                return 0;
            }
            if ($reserved_owner !== $owner) {
                $saved = $raw_reservation === null
                    ? add_option($reservation, $owner, '', false)
                    : update_option($reservation, $owner, false);
                self::clear_fan_option_caches(array($reservation));
                if (!$saved && self::reservation_owner_from_database($reservation) !== $owner) {
                    return new WP_Error('fan_apple_account_conflict', 'Apple 账号状态冲突。', array('status' => 409));
                }
            }
            return $owner;
        }
        if ($reserved_owner > 0) {
            return new WP_Error('fan_apple_account_conflict', 'Apple 账号状态冲突。', array('status' => 409));
        }
        if ($raw_reservation !== null) {
            $generation = is_array($raw_reservation)
                ? (string) ($raw_reservation['generation'] ?? '')
                : '';
            if ($generation !== ''
                && !self::cleanup_partial_apple_user_for_generation($generation, $subject_hash)) {
                return new WP_Error('fan_apple_account_conflict', 'Apple 账号状态冲突。', array('status' => 409));
            }
            delete_option($reservation);
            self::clear_fan_option_caches(array($reservation));
        }
        return 0;
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
            && self::update_user_meta_verified($user_id, self::FAN_META_ACCOUNT_SOURCE, 'invitation')
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

    private static function record_fan_auth_audit($user_id, $event) {
        $event = sanitize_key((string) $event);
        if ((int) $user_id <= 0 || !in_array($event, array(
            'apple_account_created',
            'apple_sign_in',
            'apple_registration_completed',
        ), true)) {
            return false;
        }
        $events = get_user_meta((int) $user_id, self::FAN_META_AUTH_AUDIT, true);
        $events = is_array($events) ? $events : array();
        $events[] = array('event' => $event, 'at' => gmdate('c'));
        $events = array_slice($events, -20);
        return self::update_user_meta_verified((int) $user_id, self::FAN_META_AUTH_AUDIT, $events);
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
        $lock = self::acquire_named_fan_lock('rate_limit', $key);
        if (is_wp_error($lock)) {
            return new WP_Error('fan_rate_limit_unavailable', '账号服务暂时不可用，请稍后重试。', array('status' => 503));
        }
        try {
            $count = (int) get_transient($key);
            if ($count >= (int) $limit) {
                return new WP_Error('fan_rate_limited', '尝试次数过多，请稍后再试。', array('status' => 429));
            }
            if (!set_transient($key, $count + 1, max(60, (int) $window))) {
                return new WP_Error('fan_rate_limit_unavailable', '账号服务暂时不可用，请稍后重试。', array('status' => 503));
            }
            return true;
        } finally {
            self::release_named_fan_lock($lock);
        }
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
        $ttl = self::FAN_SESSION_TTL,
        $security_context = array()
    ) {
        if (!in_array($scope, array('normal', 'onboarding', 'password_recovery', 'apple_onboarding'), true)) {
            return new WP_Error('fan_session_scope_invalid', '暂时无法创建安全会话。', array('status' => 503));
        }
        $maximum_ttl = $scope === 'onboarding'
            ? self::FAN_ONBOARDING_SESSION_TTL
            : ($scope === 'password_recovery'
                ? self::FAN_PASSWORD_RECOVERY_SESSION_TTL
                : ($scope === 'apple_onboarding'
                    ? self::FAN_APPLE_ONBOARDING_SESSION_TTL
                    : self::FAN_SESSION_TTL));
        $ttl = (int) $ttl;
        if ($ttl <= 0 || $ttl > $maximum_ttl) {
            return new WP_Error('fan_session_ttl_invalid', '暂时无法创建安全会话。', array('status' => 503));
        }
        $security_context = is_array($security_context) ? $security_context : array();
        $auth_method = sanitize_key((string) ($security_context['authMethod'] ?? 'password'));
        if (!in_array($auth_method, array('password', 'apple'), true)) {
            return new WP_Error('fan_session_scope_invalid', '暂时无法创建安全会话。', array('status' => 503));
        }
        $recent_auth_until = isset($security_context['recentAuthUntil'])
            ? (int) $security_context['recentAuthUntil']
            : 0;
        if ($recent_auth_until < 0 || $recent_auth_until > time() + self::FAN_APPLE_RECENT_AUTH_TTL + 60) {
            return new WP_Error('fan_session_scope_invalid', '暂时无法创建安全会话。', array('status' => 503));
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
                    'authMethod' => $auth_method,
                    'recentAuthUntil' => $recent_auth_until,
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
        $auth_method = sanitize_key((string) ($context['authMethod'] ?? 'password'));
        $recent_auth_until = (int) ($context['recentAuthUntil'] ?? 0);
        if (!in_array($scope, array('normal', 'onboarding', 'password_recovery', 'apple_onboarding'), true)
            || !in_array($auth_method, array('password', 'apple'), true)
            || ($scope === 'apple_onboarding' && $auth_method !== 'apple')
            || $recent_auth_until < 0
            || $credential_epoch <= 0
            || $credential_epoch !== self::fan_credential_epoch((int) $user->ID)) {
            self::revoke_fan_session((int) $context['userID'], $token_hash);
            return new WP_Error('fan_session_invalid', '登录已失效，请重新登录。', array('status' => 401));
        }
        wp_set_current_user($user->ID);
        $context['scope'] = $scope;
        $context['credentialEpoch'] = $credential_epoch;
        $context['authMethod'] = $auth_method;
        $context['recentAuthUntil'] = $recent_auth_until;
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
                array('normal', 'onboarding', 'password_recovery', 'apple_onboarding'),
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
                (string) ($fresh_session['authMethod'] ?? 'password'),
                (string) ($context['authMethod'] ?? 'password')
            )
            && (int) ($fresh_session['recentAuthUntil'] ?? 0)
                === (int) ($context['recentAuthUntil'] ?? 0)
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

    public static function cleanup_fan_apple_challenge($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_challenge_[a-f0-9]{64}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $lock_name = self::acquire_named_fan_lock('apple_chal', $option_name);
        if (is_wp_error($lock_name)) { return; }
        try {
            $record = get_option($option_name, null);
            if (!is_array($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            $expires = (int) ($record['expires'] ?? 0);
            if ($expires > time()) {
                wp_schedule_single_event(
                    $expires + 60,
                    'yishu_cleanup_fan_apple_challenge',
                    array($option_name, $generation),
                    true
                );
                return;
            }
            delete_option($option_name);
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    public static function cleanup_fan_apple_pending_account($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_[a-f0-9]{64}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $subject_hash = substr($option_name, strlen(self::FAN_APPLE_OPTION_PREFIX));
        if (!self::valid_apple_sub_hash($subject_hash)) { return; }
        $lock_name = self::acquire_named_fan_lock('apple_sub', $subject_hash);
        if (is_wp_error($lock_name)) { return; }
        try {
            $record = self::fan_option_from_database($option_name, null);
            if (!is_array($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            $created_at = (int) ($record['createdAt'] ?? 0);
            $expires = $created_at + self::FAN_APPLE_PENDING_ACCOUNT_TTL;
            if ($created_at > 0 && $expires > time()) {
                wp_schedule_single_event(
                    $expires + 5,
                    'yishu_cleanup_fan_apple_pending_account',
                    array($option_name, $generation),
                    true
                );
                return;
            }
            $resolved = self::resolve_apple_subject_owner_under_lock(
                $subject_hash,
                $option_name
            );
            if (is_wp_error($resolved)) {
                wp_schedule_single_event(
                    time() + 300,
                    'yishu_cleanup_fan_apple_pending_account',
                    array($option_name, $generation),
                    true
                );
            }
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    public static function process_fan_apple_event($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_event_[a-f0-9]{64}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $lock_name = self::acquire_named_fan_lock('apple_event', $option_name);
        if (is_wp_error($lock_name)) {
            wp_schedule_single_event(
                time() + 30,
                'yishu_process_fan_apple_event',
                array($option_name, $generation),
                true
            );
            return;
        }
        try {
            $record = self::normalize_fan_apple_event_record(
                self::fan_option_from_database($option_name, null)
            );
            if (is_wp_error($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            if (($record['status'] ?? '') === 'processed') {
                self::schedule_fan_apple_event_record($option_name, $record);
                return;
            }
            if ((int) $record['nextAttempt'] > time()) {
                self::schedule_fan_apple_event_record($option_name, $record);
                return;
            }
            foreach ((array) $record['events'] as $event) {
                $processed = self::remove_fan_for_apple_subject_hash(
                    (string) $event['subjectHash'],
                    (int) $event['eventTime']
                );
                if (is_wp_error($processed)) {
                    $attempts = min(1000000, (int) $record['attempts'] + 1);
                    $delay = min(3600, max(30, 15 * (2 ** min($attempts, 8))));
                    $record['attempts'] = $attempts;
                    $record['nextAttempt'] = time() + $delay;
                    if (!update_option($option_name, $record, false)) {
                        do_action('yishu_fan_security_audit', 'apple_event_retry_state_unavailable');
                        return;
                    }
                    self::clear_fan_option_caches(array($option_name));
                    self::schedule_fan_apple_event_record($option_name, $record);
                    return;
                }
            }
            $processed_record = array(
                'version' => 1,
                'status' => 'processed',
                'processedAt' => time(),
                'expires' => time() + 30 * DAY_IN_SECONDS,
                'generation' => $generation,
            );
            if (!update_option($option_name, $processed_record, false)) {
                do_action('yishu_fan_security_audit', 'apple_event_processed_state_unavailable');
                return;
            }
            self::clear_fan_option_caches(array($option_name));
            self::schedule_fan_apple_event_record($option_name, $processed_record);
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    public static function cleanup_fan_apple_event($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_event_[a-f0-9]{64}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $lock_name = self::acquire_named_fan_lock('apple_event', $option_name);
        if (is_wp_error($lock_name)) { return; }
        try {
            $record = self::normalize_fan_apple_event_record(
                self::fan_option_from_database($option_name, null)
            );
            if (is_wp_error($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            if (($record['status'] ?? '') === 'pending') {
                self::schedule_fan_apple_event_record($option_name, $record);
                return;
            }
            if ((int) $record['expires'] > time()) {
                self::schedule_fan_apple_event_record($option_name, $record);
                return;
            }
            delete_option($option_name);
            self::clear_fan_option_caches(array($option_name));
        } finally {
            self::release_named_fan_lock($lock_name);
        }
    }

    public static function cleanup_fan_apple_tombstone($option_name, $generation) {
        $option_name = (string) $option_name;
        $generation = (string) $generation;
        if (!preg_match('/^yishu_fan_apple_revoked_[a-f0-9]{64}$/', $option_name)
            || !preg_match('/^[a-f0-9]{32}$/', $generation)) {
            return;
        }
        $subject_hash = substr($option_name, strlen(self::FAN_APPLE_TOMBSTONE_OPTION_PREFIX));
        $lock_name = self::acquire_named_fan_lock('apple_sub', $subject_hash);
        if (is_wp_error($lock_name)) { return; }
        try {
            $record = self::fan_option_from_database($option_name, null);
            if (!is_array($record)
                || !hash_equals((string) ($record['generation'] ?? ''), $generation)) {
                return;
            }
            $tombstone = self::normalize_apple_subject_tombstone($record);
            if (is_wp_error($tombstone)) { return; }
            if ((int) $tombstone['expires'] > time()) {
                wp_schedule_single_event(
                    (int) $tombstone['expires'] + 60,
                    'yishu_cleanup_fan_apple_tombstone',
                    array($option_name, $generation),
                    true
                );
                return;
            }
            delete_option($option_name);
            self::clear_fan_option_caches(array($option_name));
        } finally {
            self::release_named_fan_lock($lock_name);
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
        $apple_sub_hash = (string) get_user_meta($user_id, self::FAN_META_APPLE_SUB_HASH, true);
        if (self::valid_apple_sub_hash($apple_sub_hash)) {
            $apple_reservation = self::apple_subject_reservation_name($apple_sub_hash);
            if (self::reservation_owner_from_database($apple_reservation) === $user_id) {
                delete_option($apple_reservation);
            }
        }
        $douyin_id = (string) get_user_meta($user_id, self::FAN_META_DOUYIN_ID, true);
        if ($douyin_id) {
            delete_option(self::douyin_reservation_name($douyin_id));
        }
        $invitation = get_user_meta($user_id, self::FAN_META_INVITATION, true);
        if (is_array($invitation) && isset($invitation['placeholderDouyinID'])
            && self::is_invitation_douyin_id((string) $invitation['placeholderDouyinID'])) {
            delete_option(self::douyin_reservation_name((string) $invitation['placeholderDouyinID']));
        }
        global $wpdb;
        if (isset($wpdb->options) && method_exists($wpdb, 'get_col')
            && method_exists($wpdb, 'prepare') && method_exists($wpdb, 'esc_like')) {
            $like = $wpdb->esc_like(self::FAN_APPLE_CHALLENGE_OPTION_PREFIX) . '%';
            $challenge_options = $wpdb->get_col($wpdb->prepare(
                "SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE %s ORDER BY option_id ASC LIMIT 100",
                $like
            ));
            foreach ((array) $challenge_options as $option_name) {
                $record = get_option((string) $option_name, null);
                if (is_array($record) && (int) ($record['userID'] ?? 0) === $user_id) {
                    delete_option((string) $option_name);
                }
            }
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

    private static function fan_apple_profile_fields($user_id) {
        $source = self::fan_account_source((int) $user_id);
        $setup = get_user_meta((int) $user_id, self::FAN_META_APPLE_SETUP, true);
        return array(
            'accountSource' => $source,
            'requiresAppleRegistration' => $source === 'apple' && !empty($setup),
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
            self::fan_password_recovery_profile_fields((int) $user_id),
            self::fan_apple_profile_fields((int) $user_id));
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
            self::fan_password_recovery_profile_fields((int) $user->ID),
            self::fan_apple_profile_fields((int) $user->ID));
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

        $stored_launch_posters = isset($stored['launchPosters']) && is_array($stored['launchPosters'])
            ? $stored['launchPosters']
            : null;
        $launch_posters = is_array($stored_launch_posters)
            && !self::is_retired_launch_poster_config($stored_launch_posters)
            ? self::sanitize_launch_posters($stored_launch_posters)
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
                    'id' => 'hanfu-lantern-01',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-01-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
                array(
                    'id' => 'hanfu-lantern-02',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-02-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
                array(
                    'id' => 'hanfu-lantern-03',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-03-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
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

    private static function is_retired_launch_poster_config($values) {
        if (count((array) $values) !== 1 || !is_array($values[0])) { return false; }
        $poster = $values[0];
        return isset($poster['id'], $poster['imageURL'])
            && (string) $poster['id'] === 'evergreen'
            && (string) $poster['imageURL']
                === 'https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-launch-qipao-ivory-20260830.jpg';
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
