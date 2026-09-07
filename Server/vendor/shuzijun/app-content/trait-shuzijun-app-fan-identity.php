<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Fan_Identity {
    private static $fan_user_deletion_prepared = array();
    private static $fan_user_deletion_locks = array();
    private static $fan_user_deletion_release_hooks_registered = false;

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

    public static function normalize_required_douyin_id($value) {
        if (!is_scalar($value)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '请填写 2–50 位抖音 ID，不要填链接。',
                array('status' => 400)
            );
        }
        $douyin_id = self::normalize_douyin_id($value);
        if ($douyin_id === '' || self::is_invitation_douyin_id($douyin_id)) {
            return new WP_Error(
                'fan_douyin_id_invalid',
                '请填写 2–50 位抖音 ID，不要填链接。',
                array('status' => 400)
            );
        }
        return $douyin_id;
    }

    private static function fan_has_required_douyin_id($user_id) {
        $stored = (string) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_DOUYIN_ID,
            ''
        );
        $normalized = self::normalize_douyin_id($stored);
        return $normalized !== ''
            && hash_equals($stored, $normalized)
            && !self::is_invitation_douyin_id($stored);
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
        // This trait lives two directories below Composer's vendor root.
        // Resolve from the module location so splitting the legacy single-file
        // plugin cannot silently point Apple authentication at a nested,
        // non-existent vendor directory.
        $autoload = dirname(__DIR__, 2) . '/autoload.php';
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
            || !isset($value['createdAt']) || !is_scalar($value['createdAt'])
            || (isset($value['douyinMigration']) && !is_bool($value['douyinMigration']))) {
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
            'douyinMigration' => !empty($value['douyinMigration']),
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
                    if (empty($setup) && !self::fan_has_required_douyin_id($owner)) {
                        try {
                            $migration_generation = bin2hex(random_bytes(16));
                        } catch (Throwable $error) {
                            return new WP_Error(
                                'fan_apple_profile_required',
                                'Apple 账号资料需要升级，请稍后再试。',
                                array('status' => 503)
                            );
                        }
                        $setup = array(
                            'version' => 1,
                            'generation' => $migration_generation,
                            'createdAt' => gmdate('c'),
                            'douyinMigration' => true,
                        );
                        if (!self::update_user_meta_verified(
                            $owner,
                            self::FAN_META_APPLE_SETUP,
                            $setup
                        )) {
                            return new WP_Error(
                                'fan_apple_profile_required',
                                'Apple 账号资料需要升级，请稍后再试。',
                                array('status' => 503)
                            );
                        }
                        // Existing normal sessions must stop serving content as
                        // soon as the required identity upgrade begins.
                        self::revoke_all_fan_sessions($owner);
                    }
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

    private static function fan_apple_onboarding_payload($user_id, $session) {
        $setup = self::normalize_fan_apple_setup(self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_APPLE_SETUP,
            null
        ));
        if (is_wp_error($setup)) { return $setup; }
        $is_douyin_migration = !empty($setup['douyinMigration']);
        $payload = array(
            'expiresAt' => gmdate('c', (int) $session['expires']),
            'isDouyinMigration' => $is_douyin_migration,
            'displayName' => '',
            'preservedStatus' => null,
        );
        if (!$is_douyin_migration) { return $payload; }

        $user = get_userdata((int) $user_id);
        $preserved_status = sanitize_key((string) self::fan_meta_from_database(
            (int) $user_id,
            self::FAN_META_STATUS,
            ''
        ));
        if (!($user instanceof WP_User)
            || is_wp_error(self::validate_fan_display_name((string) $user->display_name))
            || !in_array($preserved_status, array('pending', 'active', 'rejected', 'suspended'), true)) {
            return new WP_Error(
                'fan_apple_profile_required',
                'Apple 账号资料无法安全迁移，请联系管理员。',
                array('status' => 409)
            );
        }
        $payload['displayName'] = (string) $user->display_name;
        $payload['preservedStatus'] = $preserved_status;
        return $payload;
    }

    private static function fan_apple_onboarding_response($user_id, $session, $status = 200) {
        $registration = self::fan_apple_onboarding_payload((int) $user_id, $session);
        if (is_wp_error($registration)) { return $registration; }
        $response = new WP_REST_Response(array(
            'token' => (string) $session['token'],
            'appleRegistration' => $registration,
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
        $douyin_id = self::normalize_required_douyin_id($stored_douyin_id);
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

    /**
     * Detach published editorial work before core selects this author's posts
     * for deletion. Never reassign the entire account: unused private uploads
     * must still be removed by WordPress, including their generated sizes.
     */
    private static function retain_published_work_for_deleting_user($user_id) {
        global $wpdb;
        $owned = $wpdb->get_results($wpdb->prepare(
            "SELECT ID, post_type, post_status, post_parent FROM {$wpdb->posts}
             WHERE post_author = %d AND post_type IN ('portfolio', 'attachment')",
            $user_id
        ));
        if ($wpdb->last_error !== '' || !is_array($owned)) { return false; }
        if (!$owned) { return self::detach_deleted_editor_metadata($user_id); }

        // Read the complete publication set, not the paginated App feed. A
        // shared photo can belong to a different album than its post_parent.
        $published = $wpdb->get_results(
            "SELECT p.ID, p.post_type, m.meta_key, m.meta_value FROM {$wpdb->posts} p
             LEFT JOIN {$wpdb->postmeta} m ON m.post_id = p.ID
             AND m.meta_key IN ('_portfolio_gallery', '_thumbnail_id')
             WHERE p.post_status = 'publish' AND p.post_type <> 'attachment'"
        );
        if ($wpdb->last_error !== '' || !is_array($published)) { return false; }
        $referenced = array();
        $fallback_albums = array();
        foreach ($published as $row) {
            if ($row->post_type === 'portfolio' && !isset($fallback_albums[(int) $row->ID])) {
                $fallback_albums[(int) $row->ID] = true;
            }
            if ($row->meta_key === '_thumbnail_id') {
                $referenced[(int) $row->meta_value] = true;
            } elseif ($row->post_type === 'portfolio' && $row->meta_key === '_portfolio_gallery') {
                $gallery = json_decode((string) $row->meta_value, true);
                if (is_array($gallery) && $gallery) {
                    $fallback_albums[(int) $row->ID] = false;
                    foreach ($gallery as $id) { $referenced[absint($id)] = true; }
                }
            }
        }

        // An SQL failure must not look like an empty configuration and allow
        // deletion. Include stored/scheduled as well as fallback media; do not
        // accidentally revive a previously removed photo during this cleanup.
        $raw_config = $wpdb->get_var($wpdb->prepare(
            "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s", self::OPTION_CONFIG
        ));
        if ($wpdb->last_error !== '') { return false; }
        $stored = $raw_config === null ? array() : maybe_unserialize($raw_config);
        if (!is_array($stored)) { return false; }
        $paths = array();
        foreach (array($stored, self::config()) as $config) {
            $urls = (array) ($config['heroImages'] ?? array());
            $urls[] = $config['aboutPortraitURL'] ?? null;
            foreach ((array) ($config['launchPosters'] ?? array()) as $poster) {
                if (is_array($poster)) { $urls[] = $poster['imageURL'] ?? null; }
            }
            foreach (array('videoURL', 'posterURL') as $key) { $urls[] = $config['showreel'][$key] ?? null; }
            foreach ((array) ($config['dramas'] ?? array()) as $drama) {
                if (is_array($drama)) { $urls[] = $drama['imageURL'] ?? null; }
            }
            foreach ($urls as $url) {
                $path = self::editorial_media_retention_path($url);
                if ($path !== '') { $paths[$path] = true; }
            }
        }

        // Decide every retained ID before changing ownership. Derivatives use
        // the same upload directory as their original; compare whole paths,
        // never basenames or substring matches across unrelated uploads.
        $retain = array();
        foreach ($owned as $post) {
            $id = (int) $post->ID;
            if ($post->post_type === 'portfolio') {
                if ($post->post_status === 'publish') { $retain[] = $id; }
                continue;
            }
            $used = isset($referenced[$id]) || !empty($fallback_albums[(int) $post->post_parent]);
            if (!$used && $paths) {
                $metadata_rows = $wpdb->get_results($wpdb->prepare(
                    "SELECT meta_key, meta_value FROM {$wpdb->postmeta} WHERE post_id = %d
                     AND meta_key IN ('_wp_attachment_metadata', '_wp_attached_file')", $id
                ));
                if ($wpdb->last_error !== '' || !is_array($metadata_rows)) { return false; }
                // Warm no caches from a potentially failed metadata query.
                $original_path = self::editorial_media_retention_path(wp_get_attachment_url($id));
                if ($wpdb->last_error !== '') { return false; }
                if ($original_path !== '') {
                    $used = isset($paths[$original_path]);
                    $directory = dirname($original_path);
                    foreach ($metadata_rows as $row) {
                        if ($row->meta_key !== '_wp_attachment_metadata') { continue; }
                        $metadata = maybe_unserialize($row->meta_value);
                        if (!is_array($metadata)) { continue; }
                        $files = array($metadata['original_image'] ?? '');
                        foreach ((array) ($metadata['sizes'] ?? array()) as $size) {
                            if (is_array($size)) { $files[] = $size['file'] ?? ''; }
                        }
                        foreach ($files as $file) {
                            if (is_string($file) && $file !== '' && basename($file) === $file
                                && isset($paths[$directory . '/' . $file])) { $used = true; }
                        }
                    }
                }
            }
            if ($used) { $retain[] = $id; }
        }
        foreach ($retain as $id) {
            // Compare author as well as ID: never take ownership from another
            // editor if a concurrent operation already changed this record.
            $changed = $wpdb->update($wpdb->posts, array('post_author' => 0),
                array('ID' => $id, 'post_author' => $user_id), array('%d'), array('%d', '%d'));
            if ($changed === false) { return false; }
            clean_post_cache($id);
        }
        // Theme portfolios do not advertise author support. Explicitly include
        // them in core cleanup so unpublished drafts do not retain personal
        // author links. Published records now have author 0 and are not selected.
        add_filter('post_types_to_delete_with_user', array(__CLASS__, 'include_editorial_drafts_in_user_deletion'), 10, 2);
        return self::detach_deleted_editor_metadata($user_id);
    }

    private static function detach_deleted_editor_metadata($user_id) {
        global $wpdb;
        $edited_ids = $wpdb->get_col($wpdb->prepare(
            "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key = '_edit_last' AND meta_value = %s",
            (string) $user_id
        ));
        if ($wpdb->last_error !== '' || !is_array($edited_ids)) { return false; }
        if ($wpdb->query($wpdb->prepare(
            "DELETE FROM {$wpdb->postmeta} WHERE meta_key = '_edit_last' AND meta_value = %s", (string) $user_id
        )) === false) { return false; }
        foreach ($edited_ids as $id) { clean_post_cache((int) $id); }
        return true;
    }

    private static function editorial_media_retention_path($url) {
        if (!is_string($url) || !self::trusted_media_url($url)) { return ''; }
        $path = wp_parse_url($url, PHP_URL_PATH);
        return is_string($path) ? rawurldecode($path) : '';
    }

    public static function include_editorial_drafts_in_user_deletion($types, $user_id) {
        return array_values(array_unique(array_merge((array) $types, array('portfolio'))));
    }

    private static function remove_fan_user($user_id, $douyin_reservation = '') {
        $user_id = (int) $user_id;
        if ($user_id <= 0
            || !self::purge_collaboration_data_for_fan_user($user_id)
            || !self::purge_push_data_for_fan_user($user_id)
            || !self::retain_published_work_for_deleting_user($user_id)) {
            return false;
        }
        // The App deletion paths already hold the per-user lock. Mark the
        // successful purge so WordPress's delete_user hook does not acquire the
        // same named lock recursively; the outer caller keeps it until this
        // function returns.
        self::$fan_user_deletion_prepared[$user_id] = true;
        try {
            self::revoke_all_fan_sessions($user_id);
            if (!function_exists('wp_delete_user')) {
                require_once ABSPATH . 'wp-admin/includes/user.php';
            }
            if (!function_exists('wp_delete_user') || !wp_delete_user($user_id)) {
                return false;
            }
            if ($douyin_reservation) { delete_option((string) $douyin_reservation); }
            return true;
        } finally {
            unset(self::$fan_user_deletion_prepared[$user_id]);
        }
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
        $context['tokenHash'] = $token_hash;
        // A normal login is also an atomic push-ownership transition. This is
        // deliberately done before the token is returned, so an App killed
        // before registering APNs still cannot leave the previous account
        // reachable on this installation.
        if ($scope === 'normal'
            && !self::advance_push_install_ownership_for_session($context)) {
            self::revoke_fan_session((int) $user_id, $token_hash);
            return new WP_Error(
                'fan_session_unavailable',
                '暂时无法创建安全会话，请稍后重试。',
                array('status' => 503)
            );
        }
        wp_schedule_single_event($expires + 60, 'yishu_cleanup_fan_session', array($token_hash, (int) $user_id));
        $context['token'] = $token;
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
        $required_scope = '',
        $for_update = false
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
        $locking_clause = $for_update ? ' FOR UPDATE' : '';
        $serialized_session = $wpdb->get_var($wpdb->prepare(
            "SELECT option_value FROM {$wpdb->options} WHERE option_name = %s LIMIT 1{$locking_clause}",
            self::FAN_SESSION_OPTION_PREFIX . $token_hash
        ));
        if (!is_string($serialized_session) || !empty($wpdb->last_error)) { return false; }
        $fresh_session = maybe_unserialize($serialized_session);
        $credential_epoch = (int) self::fan_meta_from_database(
            $user_id,
            self::FAN_META_CREDENTIAL_EPOCH,
            0,
            (bool) $for_update
        );
        if (!empty($wpdb->last_error)) { return false; }
        return is_array($fresh_session)
            && (int) ($fresh_session['userID'] ?? 0) === $user_id
            // Before scopes existed, authenticated password sessions were
            // normal sessions. Preserve that exact legacy default while an
            // explicitly empty, null or unknown scope still fails closed.
            && (array_key_exists('scope', $fresh_session)
                ? $fresh_session['scope']
                : 'normal') === $required_scope
            && (int) ($fresh_session['expires'] ?? 0) > time()
            // Match authenticate_fan_session(): legacy normal sessions issued
            // before credential epochs existed belong to epoch 1 only. Any
            // later password/security transition advances the account epoch
            // and therefore still invalidates them.
            && (int) ($fresh_session['credentialEpoch'] ?? 1)
                === ($credential_epoch > 0 ? $credential_epoch : 1)
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
        $revoked_context = get_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash, null);
        if (is_array($revoked_context)) {
            $revoked_context['tokenHash'] = $token_hash;
            self::tombstone_push_install_session($revoked_context);
        }
        delete_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash);
        $sessions = get_user_meta((int) $user_id, self::FAN_META_SESSIONS, true);
        $sessions = is_array($sessions) ? $sessions : array();
        $sessions = array_values(array_filter($sessions, function ($session) use ($token_hash) {
            return is_array($session) && isset($session['hash'])
                && preg_match('/^[a-f0-9]{64}$/', (string) $session['hash'])
                && !hash_equals((string) $session['hash'], $token_hash);
        }));
        update_user_meta((int) $user_id, self::FAN_META_SESSIONS, $sessions);
        $install_hash = is_array($revoked_context)
            ? strtolower((string) ($revoked_context['installHash'] ?? ''))
            : '';
        if (preg_match('/^[a-f0-9]{64}$/', $install_hash) !== 1) { return; }
        // Do not unbind a device merely because an older session on the same
        // installation expired while a newer normal session remains valid.
        foreach ($sessions as $remaining) {
            $remaining_hash = is_array($remaining)
                ? strtolower((string) ($remaining['hash'] ?? ''))
                : '';
            if (preg_match('/^[a-f0-9]{64}$/', $remaining_hash) !== 1) { continue; }
            $remaining_context = get_option(
                self::FAN_SESSION_OPTION_PREFIX . $remaining_hash,
                null
            );
            if (is_array($remaining_context)
                && (int) ($remaining_context['expires'] ?? 0) > time()
                && hash_equals(
                    $install_hash,
                    (string) ($remaining_context['installHash'] ?? '')
                )) {
                return;
            }
        }
        self::remove_fan_push_device_for_install_hash((int) $user_id, $install_hash);
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
                    self::revoke_fan_session((int) $user_id, (string) $session['hash']);
                }
            }
        }
        self::remove_all_fan_push_devices((int) $user_id);
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
        if ($user_id <= 0) { return; }

        // App-owned deletion already purged under its outer per-user lock.
        // Core/admin deletion does not provide an abort filter, so delete_user
        // (which WordPress fires before deleting posts, meta or the user row)
        // must acquire and retain that lock until deleted_user fires.
        if (empty(self::$fan_user_deletion_prepared[$user_id])
            && !isset(self::$fan_user_deletion_locks[$user_id])) {
            $lock_owner = self::acquire_fan_lock($user_id);
            if (is_wp_error($lock_owner)) {
                self::abort_fan_user_deletion('account_deletion_lock_unavailable');
            }
            self::$fan_user_deletion_locks[$user_id] = $lock_owner;
            self::register_fan_user_deletion_release_hooks();
            if (!self::purge_collaboration_data_for_fan_user($user_id)
                || !self::purge_push_data_for_fan_user($user_id)) {
                self::release_fan_user_deletion_lock($user_id);
                self::abort_fan_user_deletion('account_deletion_cleanup_failed');
            }
        }

        // A damaged/missing fan UUID must not bypass collaboration cleanup.
        if (empty(self::$fan_user_deletion_prepared[$user_id])
            && !self::retain_published_work_for_deleting_user($user_id)) {
            self::release_fan_user_deletion_lock($user_id);
            self::abort_fan_user_deletion('account_deletion_editorial_retention_failed');
        }

        // A damaged/missing fan UUID must not bypass editorial retention either.
        // Once physical-table cleanup is proven, non-fan users need no further
        // plugin-specific metadata work.
        if (!get_user_meta($user_id, self::FAN_META_UUID, true)) { return; }
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

    public static function finalize_fan_user_deletion($user_id) {
        self::release_fan_user_deletion_lock((int) $user_id);
    }

    public static function release_pending_fan_user_deletion_locks() {
        foreach (array_keys(self::$fan_user_deletion_locks) as $user_id) {
            self::release_fan_user_deletion_lock((int) $user_id);
        }
    }

    private static function register_fan_user_deletion_release_hooks() {
        if (self::$fan_user_deletion_release_hooks_registered) { return; }
        // Register lazily from the pre-delete hook so no class/bootstrap change
        // is required. shutdown is a final safety net if a later delete_user
        // callback aborts before WordPress emits deleted_user.
        add_action('deleted_user', array(__CLASS__, 'finalize_fan_user_deletion'), 10, 1);
        add_action('shutdown', array(__CLASS__, 'release_pending_fan_user_deletion_locks'), PHP_INT_MAX, 0);
        self::$fan_user_deletion_release_hooks_registered = true;
    }

    private static function release_fan_user_deletion_lock($user_id) {
        $user_id = (int) $user_id;
        if (!isset(self::$fan_user_deletion_locks[$user_id])) { return; }
        $lock_owner = self::$fan_user_deletion_locks[$user_id];
        unset(self::$fan_user_deletion_locks[$user_id]);
        self::release_fan_lock($user_id, $lock_owner);
    }

    private static function abort_fan_user_deletion($audit_event) {
        do_action('yishu_fan_security_audit', sanitize_key((string) $audit_event));
        $message = '为防止遗留个人资料或设备推送记录，本次删除已安全中止，请稍后重试。';
        if (function_exists('wp_die')) {
            wp_die($message, '暂时无法删除用户', array('response' => 503));
        }
        // do_action() cannot return a veto. Throwing here is the fail-closed
        // fallback and still occurs before WordPress starts irreversible work.
        throw new RuntimeException('fan_user_deletion_privacy_cleanup_failed');
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
            'requiresAppleRegistration' => $source === 'apple'
                && (!empty($setup) || !self::fan_has_required_douyin_id((int) $user_id)),
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
            'administratorBound' => $user instanceof WP_User && in_array(self::ROLE, (array) $user->roles, true),
            'administratorRevision' => max(0, (int) get_user_meta($user_id, self::FAN_META_ADMIN_BINDING_REVISION, true)),
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
            'administratorBound' => in_array(self::ROLE, (array) $user->roles, true),
            'administratorRevision' => max(0, (int) get_user_meta($user->ID, self::FAN_META_ADMIN_BINDING_REVISION, true)),
            'reviewedAt' => $reviewed_at ? gmdate('c', $reviewed_at) : null,
        ), self::fan_invitation_profile_fields((int) $user->ID),
            self::fan_password_recovery_profile_fields((int) $user->ID),
            self::fan_apple_profile_fields((int) $user->ID));
    }

}
