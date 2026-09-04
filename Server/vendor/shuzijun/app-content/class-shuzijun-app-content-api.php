<?php

defined('ABSPATH') || exit;

require_once __DIR__ . '/trait-shuzijun-app-collaboration.php';
require_once __DIR__ . '/trait-shuzijun-app-fan-endpoints.php';
require_once __DIR__ . '/trait-shuzijun-app-push-notifications.php';
require_once __DIR__ . '/trait-shuzijun-app-fan-identity.php';
require_once __DIR__ . '/trait-shuzijun-app-content-delivery.php';

final class Shuzijun_App_Content_API {
    const OPTION_CONFIG = 'shuzijun_app_content_config';
    const OPTION_UPDATED = 'shuzijun_app_content_updated_at';
    const CAPABILITY = 'manage_yishu_app_content';
    const FAN_CAPABILITY = 'manage_yishu_fan_accounts';
    const COLLABORATION_CAPABILITY = 'manage_yishu_collaboration_requests';
    const PUSH_CAPABILITY = 'manage_yishu_push_notifications';
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
    const FAN_CONSENT_VERSION = '2026-09-04-approval-v4';
    // Server 1.5.12 is the fixed, reviewed consent-protocol bridge between
    // Build 42 (v3) and Build 45 (v4). Remove v3 from new submissions in
    // server 1.5.13 after Build 42 is expired; never turn this into a remote
    // option or filter.
    const FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS = array(
        '2026-09-02-approval-v3',
        '2026-09-04-approval-v4',
    );
    const FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS = array(
        '2026-08-31-approval-v2',
        '2026-09-02-approval-v3',
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
    const PUSH_SCHEMA_OPTION = 'yishu_push_schema_version';
    const PUSH_SCHEMA_VERSION = 2;
    const PUSH_TOPIC = 'cn.com.shuzijun.yishu';
    const PUSH_PRODUCTION_HOST = 'https://api.push.apple.com';
    const PUSH_OUTBOX_HOOK = 'yishu_process_push_outbox';
    const PUSH_SWEEP_HOOK = 'yishu_sweep_push_outbox';
    const PUSH_OUTBOX_MAX_ATTEMPTS = 7;
    const PUSH_OUTBOX_LEASE_SECONDS = 180;
    const PUSH_APNS_EXPIRATION_SECONDS = 86400;
    const PUSH_MAX_RECIPIENTS = 100;
    const PUSH_MAX_DEVICES_PER_USER = 16;
    const PUSH_LEGACY_SESSION_PAGE_SIZE = 128;
    const PUSH_LEGACY_SESSION_SCAN_LIMIT = 4096;
    const PUSH_RETENTION_SECONDS = 2592000;
    const PUSH_DEVICE_TTL = 7776000;
    private static $fan_session_context = null;
    private static $apns_provider_token_cache = null;
    private static $push_schema_verified = null;

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

    /** New acknowledgements must exactly match one reviewed bridge version. */
    public static function fan_new_consent_version_is_accepted($version) {
        return is_string($version)
            && in_array(
                $version,
                self::FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS,
                true
            );
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
            add_action('init', array(__CLASS__, 'ensure_push_storage'), 22);
            add_action(self::PUSH_OUTBOX_HOOK, array(__CLASS__, 'process_push_outbox'), 10, 1);
            add_action(self::PUSH_SWEEP_HOOK, array(__CLASS__, 'sweep_push_outbox'), 10, 0);
            add_action('init', array(__CLASS__, 'ensure_push_outbox_schedule'), 44);
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
            if (!$role->has_cap(self::PUSH_CAPABILITY)) { $role->add_cap(self::PUSH_CAPABILITY, true); }
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
        if ($administrator && !$administrator->has_cap(self::PUSH_CAPABILITY)) {
            $administrator->add_cap(self::PUSH_CAPABILITY, true);
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
                || user_can($user, self::PUSH_CAPABILITY)
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

        // This read-only declaration is always present so released Apps can
        // fail closed without guessing from a 404. It never enables Phase 1:
        // both flags remain false until the internal fuse, explicit feature
        // and mail readiness constants, authority marker and storage agree.
        register_rest_route('shuzijun/v1', '/app-capabilities', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'app_capabilities'),
            'permission_callback' => array(__CLASS__, 'can_read_app_capabilities'),
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

        register_rest_route('shuzijun/v1', '/fan/push-device', array(
            array(
                'methods' => WP_REST_Server::CREATABLE,
                'callback' => array(__CLASS__, 'register_fan_push_device'),
                'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session'),
            ),
            array(
                'methods' => 'DELETE',
                'callback' => array(__CLASS__, 'unregister_fan_push_device'),
                'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session'),
            ),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/push-notifications', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_targeted_push_notification'),
            'permission_callback' => array(__CLASS__, 'can_manage_push'),
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

    public static function can_read_app_capabilities(WP_REST_Request $request) {
        $authorization = trim((string) $request->get_header('authorization'));
        if (preg_match('/^Bearer\\s+[A-Za-z0-9_-]{43,512}$/', $authorization)) {
            // Fan clients retain the exact approved-account/content gate.
            self::$fan_session_context = null;
            return self::can_access_app_content($request);
        }
        if (preg_match('/^Basic\\s+[A-Za-z0-9+\\/=]{8,4096}$/', $authorization)) {
            // This read-only endpoint may be used by any App administrator;
            // each returned mutation capability is still calculated separately.
            return self::authenticate_manager_for_capability($request, self::PUSH_CAPABILITY)
                || self::authenticate_manager_for_capability($request, self::FAN_CAPABILITY)
                || self::authenticate_manager_for_capability($request, self::CAPABILITY)
                || self::authenticate_manager_for_capability(
                    $request,
                    self::COLLABORATION_CAPABILITY
                );
        }
        return false;
    }

    public static function app_capabilities() {
        $collaboration_enabled = self::collaboration_phase1_enabled()
            && self::account_authority_enabled()
            && self::collaboration_storage_ready()
            && self::collaboration_mail_transport_ready();
        $push_enabled = self::push_service_ready();
        $response = rest_ensure_response(array(
            'collaborationSubmissionEnabled' => $collaboration_enabled,
            'collaborationInboxEnabled' => $collaboration_enabled,
            'pushNotificationsEnabled' => $push_enabled,
            'canSendPushNotifications' => $push_enabled
                && current_user_can(self::PUSH_CAPABILITY),
        ));
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        return $response;
    }

    public static function can_manage_fans($request = null) {
        return self::can_manage_capability($request, self::FAN_CAPABILITY, 'yishu_fan_admin_rate_');
    }

    public static function can_manage_collaboration($request = null) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()) { return false; }
        return self::can_manage_capability(
            $request,
            self::COLLABORATION_CAPABILITY,
            'yishu_collaboration_admin_rate_'
        );
    }

    public static function can_manage_push($request = null) {
        $access = self::can_manage_capability(
            $request,
            self::PUSH_CAPABILITY,
            'yishu_push_admin_rate_'
        );
        if ($access === true || is_wp_error($access)) { return $access; }
        if (self::authenticate_manager_for_capability($request, self::FAN_CAPABILITY)) {
            return new WP_Error(
                'push_capability_required',
                '当前管理员尚未获得推送权限。',
                array('status' => 403)
            );
        }
        return false;
    }

    public static function can_submit_collaboration(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()) { return false; }
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

    use Shuzijun_App_Collaboration;
    use Shuzijun_App_Fan_Endpoints;
    use Shuzijun_App_Push_Notifications;
    use Shuzijun_App_Fan_Identity;
    use Shuzijun_App_Content_Delivery;
}
