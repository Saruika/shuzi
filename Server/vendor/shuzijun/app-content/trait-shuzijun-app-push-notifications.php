<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Push_Notifications {
    public static function ensure_push_storage() {
        if (!self::account_authority_enabled()) { return false; }
        if ((int) get_option(self::PUSH_SCHEMA_OPTION, 0) === self::PUSH_SCHEMA_VERSION
            && self::push_tables_exist()) {
            return true;
        }

        $lock = self::acquire_named_fan_lock('push_schema', 'version-2');
        if (is_wp_error($lock)) {
            do_action('yishu_push_security_audit', 'schema_lock_unavailable');
            return false;
        }
        try {
            if ((int) get_option(self::PUSH_SCHEMA_OPTION, 0) === self::PUSH_SCHEMA_VERSION
                && self::push_tables_exist()) {
                return true;
            }
            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'get_charset_collate')) { return false; }
            if (!function_exists('dbDelta')) {
                require_once ABSPATH . 'wp-admin/includes/upgrade.php';
            }
            if (!function_exists('dbDelta')) { return false; }
            $tables = self::push_table_names();
            if (!$tables) { return false; }
            $charset = $wpdb->get_charset_collate();
            $devices_sql = "CREATE TABLE {$tables['devices']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                fan_user_id bigint(20) unsigned NOT NULL,
                install_hash char(64) NOT NULL,
                session_option_id bigint(20) unsigned NOT NULL DEFAULT 0,
                binding_generation bigint(20) unsigned NOT NULL DEFAULT 0,
                token_hash char(64) NOT NULL,
                token_ciphertext text NOT NULL,
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                expires_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY token_hash (token_hash),
                UNIQUE KEY install_hash (install_hash),
                KEY binding_owner (install_hash, session_option_id, binding_generation),
                KEY user_updated (fan_user_id, updated_at),
                KEY expires_at (expires_at)
            ) ENGINE=InnoDB {$charset};";
            $notifications_sql = "CREATE TABLE {$tables['notifications']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                public_id char(36) NOT NULL,
                idempotency_key char(36) NOT NULL,
                payload_hash char(64) NOT NULL,
                title varchar(240) NOT NULL,
                body varchar(960) NOT NULL,
                sensitive tinyint(1) unsigned NOT NULL DEFAULT 1,
                created_by bigint(20) unsigned NOT NULL,
                recipient_count smallint(5) unsigned NOT NULL DEFAULT 0,
                device_count smallint(5) unsigned NOT NULL DEFAULT 0,
                deliver_before bigint(20) unsigned NOT NULL DEFAULT 0,
                created_at datetime NOT NULL,
                expires_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY public_id (public_id),
                UNIQUE KEY actor_idempotency (created_by, idempotency_key),
                KEY deliver_before (deliver_before),
                KEY expires_at (expires_at)
            ) ENGINE=InnoDB {$charset};";
            $outbox_sql = "CREATE TABLE {$tables['outbox']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                notification_id bigint(20) unsigned NOT NULL,
                fan_user_id bigint(20) unsigned NOT NULL,
                install_hash char(64) NOT NULL DEFAULT '',
                token_hash char(64) NOT NULL,
                binding_generation bigint(20) unsigned NOT NULL DEFAULT 0,
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
                KEY install_jobs (install_hash, binding_generation, status),
                KEY fan_jobs (fan_user_id, status),
                KEY notification_jobs (notification_id, status)
            ) ENGINE=InnoDB {$charset};";
            $recipients_sql = "CREATE TABLE {$tables['recipients']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                notification_id bigint(20) unsigned NOT NULL,
                fan_user_id bigint(20) unsigned NOT NULL,
                created_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY notification_user (notification_id, fan_user_id),
                KEY fan_notifications (fan_user_id, notification_id)
            ) ENGINE=InnoDB {$charset};";
            $install_states_sql = "CREATE TABLE {$tables['install_states']} (
                install_hash char(64) NOT NULL,
                fan_user_id bigint(20) unsigned NOT NULL,
                session_option_id bigint(20) unsigned NOT NULL,
                binding_generation bigint(20) unsigned NOT NULL DEFAULT 0,
                desired_state varchar(12) NOT NULL DEFAULT 'unbound',
                session_expires_at datetime NOT NULL,
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                PRIMARY KEY  (install_hash),
                KEY owner_session (fan_user_id, session_option_id),
                KEY session_expires_at (session_expires_at)
            ) ENGINE=InnoDB {$charset};";
            dbDelta($install_states_sql);
            dbDelta($devices_sql);
            dbDelta($notifications_sql);
            dbDelta($recipients_sql);
            dbDelta($outbox_sql);
            self::$push_schema_verified = null;
            if (!self::push_tables_exist()) {
                do_action('yishu_push_security_audit', 'schema_creation_failed');
                return false;
            }
            $saved = update_option(
                self::PUSH_SCHEMA_OPTION,
                self::PUSH_SCHEMA_VERSION,
                false
            );
            return $saved
                || (int) get_option(self::PUSH_SCHEMA_OPTION, 0) === self::PUSH_SCHEMA_VERSION;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    private static function push_table_names() {
        global $wpdb;
        if (!isset($wpdb) || !isset($wpdb->prefix)) { return array(); }
        return array(
            'devices' => $wpdb->prefix . 'yishu_push_devices',
            'install_states' => $wpdb->prefix . 'yishu_push_install_states',
            'notifications' => $wpdb->prefix . 'yishu_push_notifications',
            'recipients' => $wpdb->prefix . 'yishu_push_recipients',
            'outbox' => $wpdb->prefix . 'yishu_push_outbox',
        );
    }

    private static function push_tables_exist() {
        global $wpdb;
        $tables = self::push_table_names();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return false;
        }
        foreach ($tables as $table) {
            $found = $wpdb->get_var($wpdb->prepare(
                'SHOW TABLES LIKE %s',
                $wpdb->esc_like($table)
            ));
            if (!empty($wpdb->last_error)
                || !is_string($found) || !hash_equals($table, $found)) {
                return false;
            }
        }
        return self::push_schema_matches($tables);
    }

    private static function push_schema_matches($tables) {
        if (self::$push_schema_verified === true) { return true; }
        global $wpdb;
        if (!is_array($tables) || !isset($wpdb)
            || !method_exists($wpdb, 'get_col') || !method_exists($wpdb, 'get_results')) {
            return false;
        }
        $expected_columns = array(
            'devices' => array(
                'id', 'fan_user_id', 'install_hash', 'token_hash',
                'session_option_id', 'binding_generation', 'token_ciphertext',
                'created_at', 'updated_at', 'expires_at',
            ),
            'install_states' => array(
                'install_hash', 'fan_user_id', 'session_option_id',
                'binding_generation', 'desired_state', 'session_expires_at',
                'created_at', 'updated_at',
            ),
            'notifications' => array(
                'id', 'public_id', 'idempotency_key', 'payload_hash', 'title',
                'body', 'sensitive', 'created_by', 'recipient_count',
                'device_count', 'deliver_before', 'created_at', 'expires_at',
            ),
            'recipients' => array('id', 'notification_id', 'fan_user_id', 'created_at'),
            'outbox' => array(
                'id', 'notification_id', 'fan_user_id', 'install_hash', 'token_hash',
                'binding_generation',
                'dedupe_key', 'status', 'attempts', 'next_attempt_at',
                'lease_token', 'lease_until', 'last_error_code', 'created_at', 'updated_at',
            ),
        );
        foreach ($expected_columns as $name => $expected) {
            $columns = $wpdb->get_col("SHOW COLUMNS FROM {$tables[$name]}");
            if (!is_array($columns) || !empty($wpdb->last_error)
                || array_values(array_intersect($expected, $columns)) !== $expected) {
                return false;
            }
        }
        $expected_unique = array(
            'devices' => array(
                'token_hash' => array('token_hash'),
                'install_hash' => array('install_hash'),
            ),
            'install_states' => array(
                'PRIMARY' => array('install_hash'),
            ),
            'notifications' => array(
                'public_id' => array('public_id'),
                'actor_idempotency' => array('created_by', 'idempotency_key'),
            ),
            'recipients' => array(
                'notification_user' => array('notification_id', 'fan_user_id'),
            ),
            'outbox' => array('dedupe_key' => array('dedupe_key')),
        );
        foreach ($expected_unique as $name => $required_indexes) {
            $indexes = $wpdb->get_results("SHOW INDEX FROM {$tables[$name]}", ARRAY_A);
            $unique = array();
            foreach ((array) $indexes as $index) {
                if ((int) ($index['Non_unique'] ?? 1) === 0) {
                    $unique[(string) ($index['Key_name'] ?? '')][(int) ($index['Seq_in_index'] ?? 1)]
                        = (string) ($index['Column_name'] ?? '');
                }
            }
            foreach ($required_indexes as $index_name => $columns) {
                $actual = $unique[$index_name] ?? array();
                ksort($actual, SORT_NUMERIC);
                if (array_values($actual) !== $columns) { return false; }
            }
        }
        self::$push_schema_verified = true;
        return true;
    }

    private static function push_storage_ready() {
        return self::account_authority_enabled()
            && (int) get_option(self::PUSH_SCHEMA_OPTION, 0) === self::PUSH_SCHEMA_VERSION
            && self::push_tables_exist();
    }

    private static function push_storage_error() {
        return new WP_Error(
            'push_storage_unavailable',
            '推送服务暂时不可用，请稍后重试。',
            array('status' => 503)
        );
    }

    private static function push_device_crypto_error() {
        return new WP_Error(
            'push_device_crypto_unavailable',
            '推送安全存储暂时不可用。',
            array('status' => 503)
        );
    }

    private static function push_service_ready() {
        if (!self::push_storage_ready()
            || is_wp_error(self::apns_provider_configuration())) {
            return false;
        }
        $keys = self::push_device_keys();
        if (is_wp_error($keys)) { return false; }
        sodium_memzero($keys['encryption']);
        sodium_memzero($keys['index']);
        return true;
    }

    /** Read a private regular file only when its path is outside ABSPATH. */
    private static function push_read_secure_file($environment_name, $maximum_bytes) {
        $configured = getenv((string) $environment_name);
        $configured = is_string($configured) ? trim($configured) : '';
        $path = $configured !== '' ? realpath($configured) : false;
        $root = realpath(ABSPATH);
        if ($configured === '' || $configured[0] !== '/' || !$path || !$root
            || is_link($configured) || !is_file($path) || !is_readable($path)
            || $path === $root || strpos($path, $root . DIRECTORY_SEPARATOR) === 0) {
            return new WP_Error(
                'push_configuration_unavailable',
                '推送密钥配置不可用。',
                array('status' => 503)
            );
        }
        $before = @lstat($configured);
        $handle = @fopen($configured, 'rb');
        if (!is_array($before) || !is_resource($handle)) {
            return new WP_Error(
                'push_configuration_unavailable',
                '推送密钥文件配置不安全。',
                array('status' => 503)
            );
        }
        $opened = fstat($handle);
        $payload = stream_get_contents($handle, (int) $maximum_bytes + 1);
        $extra = fread($handle, 1);
        fclose($handle);
        if (!is_array($opened)
            || ($opened['mode'] & 0170000) !== 0100000
            || (int) ($opened['nlink'] ?? 0) !== 1
            || ($opened['mode'] & 077) !== 0
            || (int) ($opened['dev'] ?? -1) !== (int) ($before['dev'] ?? -2)
            || (int) ($opened['ino'] ?? -1) !== (int) ($before['ino'] ?? -2)
            || !is_string($payload) || $payload === ''
            || strlen($payload) > (int) $maximum_bytes || $extra !== '') {
            return new WP_Error(
                'push_configuration_unavailable',
                '推送密钥文件配置不安全。',
                array('status' => 503)
            );
        }
        return $payload;
    }

    private static function push_data_master_key() {
        if (self::apple_test_mode_enabled()) {
            $test_key = apply_filters('yishu_push_data_key', null);
            if (is_string($test_key) && strlen($test_key) === 32) { return $test_key; }
        }
        $encoded = self::push_read_secure_file('YISHU_APNS_DATA_KEY_PATH', 256);
        if (is_wp_error($encoded)) { return $encoded; }
        $encoded = trim((string) $encoded);
        if (preg_match('/^[A-Za-z0-9_-]{43}$/D', $encoded) !== 1) {
            return new WP_Error(
                'push_configuration_unavailable',
                '推送数据密钥格式无效。',
                array('status' => 503)
            );
        }
        $decoded = base64_decode(strtr($encoded . '=', '-_', '+/'), true);
        return is_string($decoded) && strlen($decoded) === 32
            ? $decoded
            : new WP_Error(
                'push_configuration_unavailable',
                '推送数据密钥格式无效。',
                array('status' => 503)
            );
    }

    private static function push_device_keys() {
        if (!function_exists('sodium_crypto_secretbox')
            || !function_exists('sodium_crypto_secretbox_open')
            || !function_exists('sodium_memzero') || !function_exists('hash_hkdf')) {
            return self::push_device_crypto_error();
        }
        $master = null;
        try {
            $master = self::push_data_master_key();
            if (is_wp_error($master)) { return $master; }
            $salt = hash('sha256', self::PUSH_TOPIC, true);
            $keys = array(
                'encryption' => hash_hkdf(
                    'sha256',
                    $master,
                    SODIUM_CRYPTO_SECRETBOX_KEYBYTES,
                    'yishu/apns-device-encryption/v1',
                    $salt
                ),
                'index' => hash_hkdf(
                    'sha256',
                    $master,
                    32,
                    'yishu/apns-device-index/v1',
                    $salt
                ),
            );
        } catch (Throwable $error) {
            return self::push_device_crypto_error();
        } finally {
            if (is_string($master)) { sodium_memzero($master); }
        }
        if (!is_string($keys['encryption'])
            || strlen($keys['encryption']) !== SODIUM_CRYPTO_SECRETBOX_KEYBYTES
            || !is_string($keys['index']) || strlen($keys['index']) !== 32) {
            if (is_string($keys['encryption'])) { sodium_memzero($keys['encryption']); }
            if (is_string($keys['index'])) { sodium_memzero($keys['index']); }
            return self::push_device_crypto_error();
        }
        return $keys;
    }

    /**
     * Return a non-secret identifier for the active device-data key.
     *
     * The fingerprint lets a worker distinguish a valid record encrypted by a
     * different deployment key from a damaged record. It is not key material
     * and must never replace the encrypted token's authentication checks.
     */
    private static function push_device_key_fingerprint($keys) {
        if (!is_array($keys) || !isset($keys['index'])
            || !is_string($keys['index']) || strlen($keys['index']) !== 32) {
            return '';
        }
        try {
            return hash_hmac(
                'sha256',
                'yishu/apns-device-key-fingerprint/v1',
                $keys['index']
            );
        } catch (Throwable $error) {
            return '';
        }
    }

    private static function encrypt_push_device_token($device_token) {
        $device_token = strtolower((string) $device_token);
        if (!self::valid_push_device_token($device_token)) {
            return new WP_Error(
                'push_device_token_invalid',
                '推送设备标识无效。',
                array('status' => 400)
            );
        }
        $keys = self::push_device_keys();
        if (is_wp_error($keys)) { return $keys; }
        try {
            $key_fingerprint = self::push_device_key_fingerprint($keys);
            if (preg_match('/^[a-f0-9]{64}$/D', $key_fingerprint) !== 1) {
                throw new RuntimeException('push device key fingerprint unavailable');
            }
            $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            $ciphertext = sodium_crypto_secretbox(
                $device_token,
                $nonce,
                $keys['encryption']
            );
            $result = array(
                'tokenHash' => hash_hmac('sha256', $device_token, $keys['index']),
                'ciphertext' => wp_json_encode(array(
                    'version' => 1,
                    'keyFingerprint' => $key_fingerprint,
                    'nonce' => rtrim(strtr(base64_encode($nonce), '+/', '-_'), '='),
                    'ciphertext' => rtrim(strtr(base64_encode($ciphertext), '+/', '-_'), '='),
                ), JSON_UNESCAPED_SLASHES),
            );
        } catch (Throwable $error) {
            $result = new WP_Error(
                'push_encryption_unavailable',
                '推送安全存储暂时不可用。',
                array('status' => 503)
            );
        }
        sodium_memzero($keys['encryption']);
        sodium_memzero($keys['index']);
        if (!is_wp_error($result)
            && (!is_string($result['ciphertext'])
                || strlen($result['ciphertext']) > 1024)) {
            return new WP_Error(
                'push_encryption_unavailable',
                '推送安全存储暂时不可用。',
                array('status' => 503)
            );
        }
        return $result;
    }

    /** @return string|WP_Error Decrypted token, invalid-row sentinel, or retryable outage. */
    private static function decrypt_push_device_token($encoded, $expected_hash) {
        $keys = self::push_device_keys();
        if (is_wp_error($keys)) { return self::push_device_crypto_error(); }
        $token = false;
        try {
            // Only classify a stored row as invalid after the active key is
            // known to be available. Otherwise a temporary configuration or
            // filesystem failure could permanently delete a valid binding.
            if (!is_string($encoded) || strlen($encoded) > 1024) { return ''; }
            $expected_hash = strtolower((string) $expected_hash);
            if (preg_match('/^[a-f0-9]{64}$/D', $expected_hash) !== 1) { return ''; }
            $record = json_decode($encoded, true);
            if (!is_array($record) || ($record['version'] ?? null) !== 1) { return ''; }
            $stored_fingerprint = $record['keyFingerprint'] ?? null;
            if (!is_string($stored_fingerprint)) { return ''; }
            $stored_fingerprint = strtolower($stored_fingerprint);
            if (preg_match('/^[a-f0-9]{64}$/D', $stored_fingerprint) !== 1) { return ''; }
            $active_fingerprint = self::push_device_key_fingerprint($keys);
            if (preg_match('/^[a-f0-9]{64}$/D', $active_fingerprint) !== 1) {
                return self::push_device_crypto_error();
            }
            if (!hash_equals($stored_fingerprint, $active_fingerprint)) {
                // A different but syntactically valid deployment key is an
                // operations outage, not proof that this device row is bad.
                return self::push_device_crypto_error();
            }
            $decode = static function ($value) {
                if (!is_string($value)
                    || preg_match('/^[A-Za-z0-9_-]+$/D', $value) !== 1) {
                    return false;
                }
                $padding = (4 - (strlen($value) % 4)) % 4;
                return base64_decode(
                    strtr($value . str_repeat('=', $padding), '-_', '+/'),
                    true
                );
            };
            $nonce = $decode($record['nonce'] ?? '');
            $ciphertext = $decode($record['ciphertext'] ?? '');
            if (!is_string($nonce)
                || strlen($nonce) !== SODIUM_CRYPTO_SECRETBOX_NONCEBYTES
                || !is_string($ciphertext)
                || strlen($ciphertext) < 2 + SODIUM_CRYPTO_SECRETBOX_MACBYTES
                || strlen($ciphertext) > 512 + SODIUM_CRYPTO_SECRETBOX_MACBYTES) {
                return '';
            }
            $token = sodium_crypto_secretbox_open(
                $ciphertext,
                $nonce,
                $keys['encryption']
            );
            if (!is_string($token) || !self::valid_push_device_token($token)) {
                if (is_string($token)) { sodium_memzero($token); }
                return '';
            }
            $actual_hash = hash_hmac('sha256', $token, $keys['index']);
            if (!hash_equals($expected_hash, $actual_hash)) {
                sodium_memzero($token);
                return '';
            }
            return $token;
        } catch (Throwable $error) {
            if (is_string($token)) { sodium_memzero($token); }
            return self::push_device_crypto_error();
        } finally {
            sodium_memzero($keys['encryption']);
            sodium_memzero($keys['index']);
        }
    }

    private static function valid_push_device_token($device_token) {
        return is_string($device_token)
            && strlen($device_token) >= 2
            && strlen($device_token) <= 512
            && strlen($device_token) % 2 === 0
            && preg_match('/^[a-f0-9]+$/D', $device_token) === 1;
    }

    public static function register_fan_push_device(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || (int) ($context['userID'] ?? 0) <= 0
            || (string) ($context['scope'] ?? '') !== 'normal') {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $device_token = strtolower(trim((string) $request->get_param('deviceToken')));
        $generation = self::normalize_push_binding_generation(
            $request->get_param('bindingGeneration')
        );
        if (!self::valid_push_device_token($device_token)) {
            return new WP_Error(
                'push_device_token_invalid',
                '推送设备标识无效。',
                array('status' => 400)
            );
        }
        if ($generation <= 0) {
            return new WP_Error(
                'push_binding_generation_invalid',
                '推送绑定顺序无效。',
                array('status' => 400)
            );
        }
        if (!self::push_storage_ready()) { return self::push_storage_error(); }
        $encrypted = self::encrypt_push_device_token($device_token);
        if (function_exists('sodium_memzero')) { sodium_memzero($device_token); }
        if (is_wp_error($encrypted)) { return $encrypted; }
        $user_id = (int) $context['userID'];
        $install_hash = hash('sha256', $install_id);
        // Account A and account B have different user locks. Take the shared
        // installation lock first so their delayed register/unregister calls
        // cannot mutate the globally unique installation row concurrently.
        $install_lock = self::acquire_named_fan_lock_with_timeout(
            'push_install',
            $install_hash,
            5
        );
        if (is_wp_error($install_lock)) { return $install_lock; }
        $lock = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock)) {
            self::release_named_fan_lock($install_lock);
            return $lock;
        }
        global $wpdb;
        $tables = self::push_table_names();
        $transaction = false;
        $committed = false;
        try {
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'insert')
                || $wpdb->query('START TRANSACTION') === false) {
                return self::push_storage_error();
            }
            $transaction = true;
            if (!self::fan_session_context_is_current_from_database($context, 'normal', true)) {
                return new WP_Error(
                    'fan_session_invalid',
                    '登录已失效，请重新登录。',
                    array('status' => 401)
                );
            }
            $option_id = self::push_session_option_id($context);
            $state = $option_id > 0 ? $wpdb->get_row($wpdb->prepare(
                "SELECT fan_user_id, session_option_id, binding_generation, desired_state,
                        session_expires_at
                 FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE",
                $install_hash
            ), ARRAY_A) : null;
            if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
            if (!is_array($state)) {
                $initialized = self::initialize_legacy_push_install_state(
                    $context,
                    $option_id,
                    $install_hash
                );
                if (is_wp_error($initialized)) { return $initialized; }
                $state = $wpdb->get_row($wpdb->prepare(
                    "SELECT fan_user_id, session_option_id, binding_generation, desired_state,
                            session_expires_at
                     FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE",
                    $install_hash
                ), ARRAY_A);
                if (!is_array($state) || !empty($wpdb->last_error)) {
                    return self::push_storage_error();
                }
            }
            if ((int) ($state['fan_user_id'] ?? 0) !== $user_id
                || (int) ($state['session_option_id'] ?? 0) !== $option_id
                || strtotime((string) ($state['session_expires_at'] ?? '') . ' UTC') <= time()) {
                return new WP_Error(
                    'push_install_session_superseded',
                    '设备的登录状态已更新。',
                    array('status' => 409)
                );
            }
            $transition = self::push_binding_transition(
                (int) $state['binding_generation'],
                (string) $state['desired_state'],
                $generation,
                'bound'
            );
            if ($transition === 'stale') {
                return new WP_Error(
                    'push_binding_superseded',
                    '设备的推送设置已更新。',
                    array('status' => 409)
                );
            }
            if ($transition === 'conflict' || $transition === 'invalid') {
                return new WP_Error(
                    'push_binding_conflict',
                    '推送绑定顺序冲突，请重试。',
                    array('status' => 409)
                );
            }
            if ($transition === 'idempotent') {
                $same = $wpdb->get_var($wpdb->prepare(
                    "SELECT COUNT(*) FROM {$tables['devices']}
                     WHERE fan_user_id = %d AND install_hash = %s
                       AND session_option_id = %d AND binding_generation = %d
                       AND token_hash = %s",
                    $user_id,
                    $install_hash,
                    $option_id,
                    $generation,
                    (string) $encrypted['tokenHash']
                ));
                if ((int) $same !== 1 || !empty($wpdb->last_error)) {
                    return new WP_Error(
                        'push_binding_conflict',
                        '推送绑定顺序冲突，请重试。',
                        array('status' => 409)
                    );
                }
                if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
                $committed = true;
                $response = rest_ensure_response(array('ok' => true));
                $response->header('Cache-Control', 'private, no-store, max-age=0');
                return $response;
            }
            $cancelled = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['outbox']}
                 SET status = 'dead', last_error_code = 'binding_replaced',
                     lease_token = NULL, lease_until = NULL, updated_at = %s
                 WHERE install_hash = %s AND status IN ('pending', 'processing')",
                gmdate('Y-m-d H:i:s'),
                $install_hash
            ));
            $deleted = $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['devices']}
                 WHERE token_hash = %s OR install_hash = %s",
                (string) $encrypted['tokenHash'],
                $install_hash
            ));
            $now = gmdate('Y-m-d H:i:s');
            $inserted = $deleted !== false && $wpdb->insert($tables['devices'], array(
                'fan_user_id' => $user_id,
                'install_hash' => $install_hash,
                'session_option_id' => $option_id,
                'binding_generation' => $generation,
                'token_hash' => (string) $encrypted['tokenHash'],
                'token_ciphertext' => (string) $encrypted['ciphertext'],
                'created_at' => $now,
                'updated_at' => $now,
                'expires_at' => gmdate('Y-m-d H:i:s', time() + self::PUSH_DEVICE_TTL),
            ), array('%d', '%s', '%d', '%d', '%s', '%s', '%s', '%s', '%s')) === 1;
            $state_updated = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['install_states']}
                 SET binding_generation = %d, desired_state = 'bound', updated_at = %s
                 WHERE install_hash = %s AND fan_user_id = %d AND session_option_id = %d",
                $generation,
                $now,
                $install_hash,
                $user_id,
                $option_id
            ));
            if ($cancelled === false || !$inserted || $state_updated !== 1) {
                return self::push_storage_error();
            }
            $stale_devices = method_exists($wpdb, 'get_results') ? $wpdb->get_results($wpdb->prepare(
                "SELECT id, install_hash, binding_generation FROM {$tables['devices']}
                 WHERE fan_user_id = %d ORDER BY updated_at DESC, id DESC
                 LIMIT 100 OFFSET %d",
                $user_id,
                self::PUSH_MAX_DEVICES_PER_USER
            ), ARRAY_A) : false;
            if (!is_array($stale_devices) || !empty($wpdb->last_error)) {
                return self::push_storage_error();
            }
            foreach ($stale_devices as $stale_device) {
                $stale_install_hash = strtolower((string) ($stale_device['install_hash'] ?? ''));
                $stale_generation = (int) ($stale_device['binding_generation'] ?? 0);
                if (preg_match('/^[a-f0-9]{64}$/D', $stale_install_hash) !== 1
                    || $stale_generation <= 0
                    || $wpdb->query($wpdb->prepare(
                        "UPDATE {$tables['outbox']} SET status = 'dead',
                            last_error_code = 'device_limit', lease_token = NULL,
                            lease_until = NULL, updated_at = %s
                         WHERE install_hash = %s AND binding_generation = %d
                           AND status IN ('pending', 'processing')",
                        $now,
                        $stale_install_hash,
                        $stale_generation
                    )) === false
                    || $wpdb->query($wpdb->prepare(
                        "UPDATE {$tables['install_states']} SET desired_state = 'unbound', updated_at = %s
                         WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d",
                        $now,
                        $stale_install_hash,
                        $user_id,
                        $stale_generation
                    )) === false
                    || $wpdb->query($wpdb->prepare(
                    "DELETE FROM {$tables['devices']} WHERE id = %d AND fan_user_id = %d",
                    (int) ($stale_device['id'] ?? 0),
                    $user_id
                )) === false) {
                    return self::push_storage_error();
                }
            }
            if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
            $committed = true;
            $response = rest_ensure_response(array('ok' => true));
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            return $response;
        } finally {
            if ($transaction && !$committed) { $wpdb->query('ROLLBACK'); }
            self::release_fan_lock($user_id, $lock);
            self::release_named_fan_lock($install_lock);
        }
    }

    public static function unregister_fan_push_device(WP_REST_Request $request) {
        $context = self::$fan_session_context;
        if (!is_array($context) || (int) ($context['userID'] ?? 0) <= 0) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        if ((string) ($context['scope'] ?? '') !== 'normal') {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $install_id = self::matching_request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        $generation = self::normalize_push_binding_generation(
            $request->get_param('bindingGeneration')
        );
        if ($generation <= 0) {
            return new WP_Error(
                'push_binding_generation_invalid',
                '推送绑定顺序无效。',
                array('status' => 400)
            );
        }
        if (!self::push_storage_ready()) { return self::push_storage_error(); }
        $user_id = (int) $context['userID'];
        $install_hash = hash('sha256', $install_id);
        $install_lock = self::acquire_named_fan_lock_with_timeout(
            'push_install',
            $install_hash,
            5
        );
        if (is_wp_error($install_lock)) { return $install_lock; }
        $lock = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock)) {
            self::release_named_fan_lock($install_lock);
            return $lock;
        }
        global $wpdb;
        $tables = self::push_table_names();
        $transaction = false;
        $committed = false;
        try {
            // Revalidate after the permission callback so a concurrently revoked
            // session cannot erase another installation's binding. Once the
            // current normal session and its installation match, clear that
            // globally unique installation row regardless of its former owner.
            // This removes an A-account residue when the same App installation
            // later signs in as B while notifications remain disabled.
            if (!isset($wpdb) || !method_exists($wpdb, 'query')
                || !method_exists($wpdb, 'prepare')
                || $wpdb->query('START TRANSACTION') === false) {
                return self::push_storage_error();
            }
            $transaction = true;
            if (!self::fan_session_context_is_current_from_database($context, 'normal', true)) {
                return new WP_Error(
                    'fan_session_invalid',
                    '登录已失效，请重新登录。',
                    array('status' => 401)
                );
            }
            $option_id = self::push_session_option_id($context);
            $state = $option_id > 0 ? $wpdb->get_row($wpdb->prepare(
                "SELECT fan_user_id, session_option_id, binding_generation, desired_state
                 FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE",
                $install_hash
            ), ARRAY_A) : null;
            if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
            if (!is_array($state)) {
                $initialized = self::initialize_legacy_push_install_state(
                    $context,
                    $option_id,
                    $install_hash
                );
                if (is_wp_error($initialized)) {
                    if ($initialized->get_error_code() !== 'push_install_session_superseded') {
                        return $initialized;
                    }
                    if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
                    $committed = true;
                    $response = rest_ensure_response(array('ok' => true));
                    $response->header('Cache-Control', 'private, no-store, max-age=0');
                    return $response;
                }
                $state = $wpdb->get_row($wpdb->prepare(
                    "SELECT fan_user_id, session_option_id, binding_generation, desired_state
                     FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE",
                    $install_hash
                ), ARRAY_A);
                if (!is_array($state) || !empty($wpdb->last_error)) {
                    return self::push_storage_error();
                }
            }
            if ((int) ($state['fan_user_id'] ?? 0) !== $user_id
                || (int) ($state['session_option_id'] ?? 0) !== $option_id) {
                if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
                $committed = true;
                $response = rest_ensure_response(array('ok' => true));
                $response->header('Cache-Control', 'private, no-store, max-age=0');
                return $response;
            }
            $transition = self::push_binding_transition(
                (int) $state['binding_generation'],
                (string) $state['desired_state'],
                $generation,
                'unbound'
            );
            if ($transition === 'conflict' || $transition === 'invalid') {
                return new WP_Error(
                    'push_binding_conflict',
                    '推送绑定顺序冲突，请重试。',
                    array('status' => 409)
                );
            }
            if ($transition === 'apply') {
                $now = gmdate('Y-m-d H:i:s');
                $cancelled = $wpdb->query($wpdb->prepare(
                    "UPDATE {$tables['outbox']}
                     SET status = 'dead', last_error_code = 'binding_revoked',
                         lease_token = NULL, lease_until = NULL, updated_at = %s
                     WHERE install_hash = %s AND status IN ('pending', 'processing')",
                    $now,
                    $install_hash
                ));
                $removed = $wpdb->query($wpdb->prepare(
                    "DELETE FROM {$tables['devices']}
                     WHERE install_hash = %s AND session_option_id = %d",
                    $install_hash,
                    $option_id
                ));
                $updated = $wpdb->query($wpdb->prepare(
                    "UPDATE {$tables['install_states']}
                     SET binding_generation = %d, desired_state = 'unbound', updated_at = %s
                     WHERE install_hash = %s AND fan_user_id = %d AND session_option_id = %d",
                    $generation,
                    $now,
                    $install_hash,
                    $user_id,
                    $option_id
                ));
                if ($cancelled === false || $removed === false || $updated !== 1) {
                    return self::push_storage_error();
                }
            }
            // A lower generation or the same already-unbound generation is an
            // idempotent no-op. It can never overwrite the latest choice.
            if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
            $committed = true;
            // Deliberately return no deletion count or prior owner. Repeating the
            // request is safe and cannot be used to enumerate device bindings.
            $response = rest_ensure_response(array('ok' => true));
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            return $response;
        } finally {
            if ($transaction && !$committed) { $wpdb->query('ROLLBACK'); }
            self::release_fan_lock($user_id, $lock);
            self::release_named_fan_lock($install_lock);
        }
    }

    private static function remove_push_device_for_install_hash($install_hash) {
        $install_hash = strtolower((string) $install_hash);
        if (preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1) { return false; }
        if (!self::push_tables_exist()) { return true; }
        global $wpdb;
        $tables = self::push_table_names();
        if (!isset($wpdb) || !method_exists($wpdb, 'query') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        return $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE install_hash = %s",
            $install_hash
        )) !== false;
    }

    private static function remove_fan_push_device_for_install_hash($user_id, $install_hash) {
        $user_id = (int) $user_id;
        $install_hash = strtolower((string) $install_hash);
        if ($user_id <= 0 || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1) {
            return false;
        }
        if (!self::push_tables_exist()) { return true; }
        global $wpdb;
        $tables = self::push_table_names();
        if (!isset($wpdb) || !method_exists($wpdb, 'query') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        return $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE fan_user_id = %d AND install_hash = %s",
            $user_id,
            $install_hash
        )) !== false;
    }

    /** Resolve the immutable wp_options row ID for a validated session. */
    private static function push_session_option_id($context) {
        $token_hash = is_array($context)
            ? strtolower((string) ($context['tokenHash'] ?? ''))
            : '';
        if (preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1) { return 0; }
        global $wpdb;
        if (!isset($wpdb->options) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare')) {
            return 0;
        }
        $raw = $wpdb->get_var($wpdb->prepare(
            "SELECT option_id FROM {$wpdb->options} WHERE option_name = %s LIMIT 1",
            self::FAN_SESSION_OPTION_PREFIX . $token_hash
        ));
        $raw = is_scalar($raw) ? (string) $raw : '';
        if (preg_match('/^[1-9][0-9]{0,17}$/D', $raw) !== 1
            || !empty($wpdb->last_error)) {
            return 0;
        }
        return (int) $raw;
    }

    /** A decimal counter accepted by both PHP/MySQL and Swift JSON clients. */
    private static function normalize_push_binding_generation($value) {
        if (!is_scalar($value)) { return 0; }
        $value = (string) $value;
        if (preg_match('/^[1-9][0-9]{0,18}$/D', $value) !== 1) { return 0; }
        $maximum = (string) PHP_INT_MAX;
        if (strlen($value) > strlen($maximum)
            || (strlen($value) === strlen($maximum) && strcmp($value, $maximum) > 0)) {
            return 0;
        }
        return (int) $value;
    }

    /** Pure fail-closed ordering rule used by register/unregister. */
    private static function push_binding_transition($current_generation, $current_state, $generation, $action) {
        $current_generation = (int) $current_generation;
        $generation = (int) $generation;
        if ($current_generation < 0 || $generation <= 0
            || !in_array($current_state, array('bound', 'unbound'), true)
            || !in_array($action, array('bound', 'unbound'), true)) {
            return 'invalid';
        }
        if ($generation < $current_generation) { return 'stale'; }
        if ($generation === $current_generation) {
            return hash_equals($current_state, $action) ? 'idempotent' : 'conflict';
        }
        return 'apply';
    }

    /** Parse a canonical non-negative integer without float/string coercion. */
    private static function legacy_push_session_integer($value, $allow_zero = false) {
        if (!is_int($value) && !is_string($value)) { return -1; }
        $value = (string) $value;
        $pattern = $allow_zero ? '/^(?:0|[1-9][0-9]{0,18})$/D' : '/^[1-9][0-9]{0,18}$/D';
        if (preg_match($pattern, $value) !== 1) { return -1; }
        $maximum = (string) PHP_INT_MAX;
        if (strlen($value) > strlen($maximum)
            || (strlen($value) === strlen($maximum) && strcmp($value, $maximum) > 0)) {
            return -1;
        }
        return (int) $value;
    }

    /**
     * Strictly decode one legacy session row. WordPress's permissive option
     * decoder is intentionally not used on this migration path:
     * an object, nested value or oversized record can never become authority.
     */
    private static function legacy_push_session_option_context($row, $install_hash, $now) {
        $install_hash = strtolower((string) $install_hash);
        $now = self::legacy_push_session_integer($now);
        if (!is_array($row)
            || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1
            || $now <= 0) {
            return null;
        }
        $option_id = self::legacy_push_session_integer($row['option_id'] ?? null);
        $option_name = is_string($row['option_name'] ?? null)
            ? (string) $row['option_name']
            : '';
        $serialized = is_string($row['option_value'] ?? null)
            ? (string) $row['option_value']
            : '';
        $prefix = self::FAN_SESSION_OPTION_PREFIX;
        if ($option_id <= 0 || strlen($option_name) !== strlen($prefix) + 64
            || strpos($option_name, $prefix) !== 0 || $serialized === ''
            || strlen($serialized) > 8192) {
            return null;
        }
        $token_hash = substr($option_name, strlen($prefix));
        if (preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1) { return null; }
        $candidate = @unserialize($serialized, array('allowed_classes' => false));
        if (!is_array($candidate) || count($candidate) === 0 || count($candidate) > 16) {
            return null;
        }
        foreach ($candidate as $key => $value) {
            if (!is_string($key) || (!is_scalar($value) && $value !== null)) {
                return null;
            }
        }
        $user_id = self::legacy_push_session_integer($candidate['userID'] ?? null);
        $created_at = self::legacy_push_session_integer($candidate['createdAt'] ?? null);
        $expires = self::legacy_push_session_integer($candidate['expires'] ?? null);
        $credential_epoch = self::legacy_push_session_integer(
            $candidate['credentialEpoch'] ?? 1
        );
        $recent_auth_until = self::legacy_push_session_integer(
            $candidate['recentAuthUntil'] ?? 0,
            true
        );
        $candidate_install_hash = (string) ($candidate['installHash'] ?? '');
        $auth_method = (string) ($candidate['authMethod'] ?? 'password');
        if ($user_id <= 0 || $created_at <= 0 || $created_at > $now + 60
            || $expires <= $now || $expires < $created_at
            || $expires - $created_at > self::FAN_SESSION_TTL + 60
            || $credential_epoch <= 0 || $recent_auth_until < 0
            || (string) ($candidate['scope'] ?? '') !== 'normal'
            || !in_array($auth_method, array('password', 'apple'), true)
            || preg_match('/^[a-f0-9]{64}$/D', $candidate_install_hash) !== 1
            || !hash_equals($install_hash, $candidate_install_hash)
            || preg_match('/^[a-f0-9]{32}$/D', (string) ($candidate['sessionID'] ?? '')) !== 1
            || preg_match(
                '/^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$/D',
                (string) ($candidate['installCode'] ?? '')
            ) !== 1) {
            return null;
        }
        $candidate['optionID'] = $option_id;
        $candidate['tokenHash'] = $token_hash;
        $candidate['userID'] = $user_id;
        $candidate['createdAt'] = $created_at;
        $candidate['expires'] = $expires;
        $candidate['credentialEpoch'] = $credential_epoch;
        $candidate['authMethod'] = $auth_method;
        $candidate['recentAuthUntil'] = $recent_auth_until;
        $candidate['installHash'] = $candidate_install_hash;
        return $candidate;
    }

    /** Parse one strictly later legacy session without serialized SQL matching. */
    private static function legacy_push_session_candidate_context(
        $row,
        $current_option_id,
        $install_hash,
        $now
    ) {
        $current_option_id = self::legacy_push_session_integer($current_option_id);
        if ($current_option_id <= 0) { return null; }
        $candidate = self::legacy_push_session_option_context($row, $install_hash, $now);
        return is_array($candidate)
            && (int) $candidate['optionID'] > $current_option_id
            ? $candidate
            : null;
    }

    /**
     * Lazily create schema-v2 ownership for a normal session issued before the
     * push tables existed. The caller holds the installation and fan locks and
     * an active transaction. Only the newest still-current normal session for
     * this installation may initialize or advance the persistent owner.
     */
    private static function initialize_legacy_push_install_state(
        $context,
        $option_id,
        $install_hash
    ) {
        $option_id = self::legacy_push_session_integer($option_id);
        $install_hash = strtolower((string) $install_hash);
        $user_id = is_array($context) ? (int) ($context['userID'] ?? 0) : 0;
        if (!is_array($context) || (string) ($context['scope'] ?? '') !== 'normal'
            || $user_id <= 0 || $option_id <= 0
            || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1
            || !hash_equals($install_hash, (string) ($context['installHash'] ?? ''))) {
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }
        global $wpdb;
        $tables = self::push_table_names();
        if (!isset($wpdb->options) || !isset($wpdb->users)
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')
            || !method_exists($wpdb, 'query') || !empty($wpdb->last_error)) {
            return self::push_storage_error();
        }

        // Re-read the exact option row under lock and treat its serialized DB
        // value, not an object-cache snapshot from the permission callback, as
        // the only migration input.
        $token_hash = strtolower((string) ($context['tokenHash'] ?? ''));
        if (preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1) {
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }
        $current_row = $wpdb->get_row($wpdb->prepare(
            "SELECT option_id, option_name, option_value FROM {$wpdb->options}
             WHERE option_id = %d AND option_name = %s LIMIT 1 FOR UPDATE",
            $option_id,
            self::FAN_SESSION_OPTION_PREFIX . $token_hash
        ), ARRAY_A);
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $now_timestamp = time();
        $fresh_context = self::legacy_push_session_option_context(
            $current_row,
            $install_hash,
            $now_timestamp
        );
        if (!is_array($fresh_context)
            || (int) $fresh_context['optionID'] !== $option_id
            || (int) $fresh_context['userID'] !== $user_id
            || !hash_equals($token_hash, (string) $fresh_context['tokenHash'])
            || !hash_equals(
                (string) ($context['sessionID'] ?? ''),
                (string) $fresh_context['sessionID']
            )
            || (int) ($context['credentialEpoch'] ?? 1)
                !== (int) $fresh_context['credentialEpoch']
            || !hash_equals(
                (string) ($context['authMethod'] ?? 'password'),
                (string) $fresh_context['authMethod']
            )
            || (int) ($context['recentAuthUntil'] ?? 0)
                !== (int) $fresh_context['recentAuthUntil']) {
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }
        $current_is_valid = self::fan_session_context_is_current_from_database(
            $fresh_context,
            'normal',
            true
        );
        if (!$current_is_valid) {
            if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }
        $current_user = $wpdb->get_var($wpdb->prepare(
            "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE",
            $user_id
        ));
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $current_uuid = self::fan_meta_from_database(
            $user_id,
            self::FAN_META_UUID,
            '',
            true
        );
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        if ((int) $current_user !== $user_id || !self::is_uuid_v4((string) $current_uuid)) {
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }

        // option_id is the authority-wide monotonic session order. Use locking
        // keyset reads so a concurrent newer login is either observed here or
        // advances the install-state row after this transaction. Never search
        // serialized option_value text, which is not a canonical identifier.
        $cursor = $option_id;
        $scanned = 0;
        while (true) {
            $query_limit = $scanned >= self::PUSH_LEGACY_SESSION_SCAN_LIMIT
                ? 1
                : min(
                    self::PUSH_LEGACY_SESSION_PAGE_SIZE,
                    self::PUSH_LEGACY_SESSION_SCAN_LIMIT - $scanned
                );
            $rows = $wpdb->get_results($wpdb->prepare(
                "SELECT option_id, option_name, option_value FROM {$wpdb->options}
                 WHERE option_id > %d AND option_name LIKE %s
                 ORDER BY option_id ASC LIMIT %d FOR UPDATE",
                $cursor,
                $wpdb->esc_like(self::FAN_SESSION_OPTION_PREFIX) . '%',
                $query_limit
            ), ARRAY_A);
            if (!is_array($rows) || !empty($wpdb->last_error)) {
                return self::push_storage_error();
            }
            if (empty($rows)) { break; }
            if ($scanned >= self::PUSH_LEGACY_SESSION_SCAN_LIMIT) {
                return self::push_storage_error();
            }
            foreach ($rows as $row) {
                $row_option_id = self::legacy_push_session_integer($row['option_id'] ?? null);
                if ($row_option_id <= $cursor) { return self::push_storage_error(); }
                $cursor = $row_option_id;
                $scanned++;
                if ($scanned > self::PUSH_LEGACY_SESSION_SCAN_LIMIT) {
                    return self::push_storage_error();
                }
                $candidate = self::legacy_push_session_candidate_context(
                    $row,
                    $option_id,
                    $install_hash,
                    $now_timestamp
                );
                if (!is_array($candidate)) { continue; }
                $candidate_user_id = (int) $candidate['userID'];
                $candidate_user = $wpdb->get_var($wpdb->prepare(
                    "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE",
                    $candidate_user_id
                ));
                if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
                $candidate_uuid = self::fan_meta_from_database(
                    $candidate_user_id,
                    self::FAN_META_UUID,
                    '',
                    true
                );
                if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
                $candidate_credential_epoch = (int) self::fan_meta_from_database(
                    $candidate_user_id,
                    self::FAN_META_CREDENTIAL_EPOCH,
                    0,
                    true
                );
                if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
                $candidate_credential_epoch = $candidate_credential_epoch > 0
                    ? $candidate_credential_epoch
                    : 1;
                if ((int) $candidate_user === $candidate_user_id
                    && self::is_uuid_v4((string) $candidate_uuid)
                    && (int) $candidate['credentialEpoch'] === $candidate_credential_epoch) {
                    return new WP_Error(
                        'push_install_session_superseded',
                        '设备的登录状态已更新。',
                        array('status' => 409)
                    );
                }
            }
            if (count($rows) < $query_limit) { break; }
        }

        if (!empty($wpdb->last_error)) {
            return self::push_storage_error();
        }

        $now = gmdate('Y-m-d H:i:s');
        $created = $wpdb->query($wpdb->prepare(
            "INSERT IGNORE INTO {$tables['install_states']}
             (install_hash, fan_user_id, session_option_id, binding_generation,
              desired_state, session_expires_at, created_at, updated_at)
             VALUES (%s, %d, %d, 0, 'unbound', %s, %s, %s)",
            $install_hash,
            $user_id,
            $option_id,
            gmdate('Y-m-d H:i:s', (int) $fresh_context['expires']),
            $now,
            $now
        ));
        if ($created === false) { return self::push_storage_error(); }
        $state = $wpdb->get_row($wpdb->prepare(
            "SELECT fan_user_id, session_option_id FROM {$tables['install_states']}
             WHERE install_hash = %s FOR UPDATE",
            $install_hash
        ), ARRAY_A);
        if (!is_array($state) || !empty($wpdb->last_error)) {
            return self::push_storage_error();
        }
        $owner_option_id = (int) ($state['session_option_id'] ?? 0);
        $owner_user_id = (int) ($state['fan_user_id'] ?? 0);
        if ($owner_option_id > $option_id) {
            return new WP_Error(
                'push_install_session_superseded',
                '设备的登录状态已更新。',
                array('status' => 409)
            );
        }
        if ($owner_option_id === $option_id && $owner_user_id !== $user_id) {
            // An immutable option row cannot legitimately belong to two users.
            // Treat this as authority corruption, never as a normal conflict.
            return self::push_storage_error();
        }
        if ($owner_option_id < $option_id || $created === 1) {
            $cancelled = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['outbox']}
                 SET status = 'dead', last_error_code = 'binding_superseded',
                     lease_token = NULL, lease_until = NULL, updated_at = %s
                 WHERE install_hash = %s AND status IN ('pending', 'processing')",
                $now,
                $install_hash
            ));
            $deleted = $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['devices']} WHERE install_hash = %s",
                $install_hash
            ));
            $updated = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['install_states']}
                 SET fan_user_id = %d, session_option_id = %d,
                     desired_state = 'unbound', session_expires_at = %s, updated_at = %s
                 WHERE install_hash = %s",
                $user_id,
                $option_id,
                gmdate('Y-m-d H:i:s', (int) $fresh_context['expires']),
                $now,
                $install_hash
            ));
            if ($cancelled === false || $deleted === false || $updated !== 1) {
                return self::push_storage_error();
            }
        }
        return true;
    }

    /**
     * Persistently make a newly issued normal session the installation owner.
     * The row lock is the cross-node authority fence; it survives cache loss and
     * serializes against a worker that is about to contact APNs.
     */
    private static function advance_push_install_ownership_for_session($context) {
        if (!is_array($context) || (string) ($context['scope'] ?? '') !== 'normal'
            || (int) ($context['userID'] ?? 0) <= 0
            || preg_match('/^[a-f0-9]{64}$/D', (string) ($context['installHash'] ?? '')) !== 1
            || (int) ($context['expires'] ?? 0) <= time()
            || !self::ensure_push_storage()) {
            return false;
        }
        $option_id = self::push_session_option_id($context);
        if ($option_id <= 0) { return false; }
        global $wpdb;
        $tables = self::push_table_names();
        $install_hash = (string) $context['installHash'];
        $user_id = (int) $context['userID'];
        $now = gmdate('Y-m-d H:i:s');
        if ($wpdb->query('START TRANSACTION') === false) { return false; }
        $committed = false;
        try {
            $created = $wpdb->query($wpdb->prepare(
                "INSERT IGNORE INTO {$tables['install_states']}
                 (install_hash, fan_user_id, session_option_id, binding_generation,
                  desired_state, session_expires_at, created_at, updated_at)
                 VALUES (%s, %d, %d, 0, 'unbound', %s, %s, %s)",
                $install_hash,
                $user_id,
                $option_id,
                gmdate('Y-m-d H:i:s', (int) $context['expires']),
                $now,
                $now
            ));
            if ($created === false) { return false; }
            $state = $wpdb->get_row($wpdb->prepare(
                "SELECT fan_user_id, session_option_id, binding_generation, desired_state
                 FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE",
                $install_hash
            ), ARRAY_A);
            if (!is_array($state) || !empty($wpdb->last_error)) { return false; }
            $current_option_id = (int) ($state['session_option_id'] ?? 0);
            if ($current_option_id > $option_id) { return false; }
            if ($current_option_id < $option_id || $created === 1) {
                $cancelled = $wpdb->query($wpdb->prepare(
                    "UPDATE {$tables['outbox']}
                     SET status = 'dead', last_error_code = 'binding_superseded',
                         lease_token = NULL, lease_until = NULL, updated_at = %s
                     WHERE install_hash = %s AND status IN ('pending', 'processing')",
                    $now,
                    $install_hash
                ));
                $deleted = $wpdb->query($wpdb->prepare(
                    "DELETE FROM {$tables['devices']} WHERE install_hash = %s",
                    $install_hash
                ));
                $updated = $wpdb->query($wpdb->prepare(
                    "UPDATE {$tables['install_states']}
                     SET fan_user_id = %d, session_option_id = %d,
                         desired_state = 'unbound', session_expires_at = %s, updated_at = %s
                     WHERE install_hash = %s",
                    $user_id,
                    $option_id,
                    gmdate('Y-m-d H:i:s', (int) $context['expires']),
                    $now,
                    $install_hash
                ));
                if ($cancelled === false || $deleted === false || $updated !== 1) { return false; }
            } elseif ((int) ($state['fan_user_id'] ?? 0) !== $user_id) {
                return false;
            }
            if ($wpdb->query('COMMIT') === false) { return false; }
            $committed = true;
            return true;
        } finally {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
        }
    }

    /** Preserve an unbound tombstone until the owning session expires. */
    private static function tombstone_push_install_session($context) {
        if (!is_array($context) || (string) ($context['scope'] ?? '') !== 'normal'
            || preg_match('/^[a-f0-9]{64}$/D', (string) ($context['installHash'] ?? '')) !== 1
            || !self::push_storage_ready()) {
            return true;
        }
        $option_id = self::push_session_option_id($context);
        if ($option_id <= 0) { return false; }
        global $wpdb;
        $tables = self::push_table_names();
        $install_hash = (string) $context['installHash'];
        $now = gmdate('Y-m-d H:i:s');
        if ($wpdb->query('START TRANSACTION') === false) { return false; }
        $committed = false;
        try {
            $state = $wpdb->get_row($wpdb->prepare(
                "SELECT session_option_id, binding_generation FROM {$tables['install_states']}
                 WHERE install_hash = %s FOR UPDATE",
                $install_hash
            ), ARRAY_A);
            if (!is_array($state) || (int) ($state['session_option_id'] ?? 0) !== $option_id) {
                if (!empty($wpdb->last_error) || $wpdb->query('COMMIT') === false) { return false; }
                $committed = true;
                return true;
            }
            $generation = (int) ($state['binding_generation'] ?? 0);
            $cancelled = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['outbox']} SET status = 'dead',
                    last_error_code = 'binding_revoked', lease_token = NULL,
                    lease_until = NULL, updated_at = %s
                 WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d
                   AND status IN ('pending', 'processing')",
                $now,
                $install_hash,
                (int) ($context['userID'] ?? 0),
                $generation
            ));
            $deleted = $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['devices']}
                 WHERE install_hash = %s AND session_option_id = %d
                   AND binding_generation = %d",
                $install_hash,
                $option_id,
                $generation
            ));
            $updated = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['install_states']} SET desired_state = 'unbound', updated_at = %s
                 WHERE install_hash = %s AND session_option_id = %d",
                $now,
                $install_hash,
                $option_id
            ));
            if ($cancelled === false || $deleted === false || $updated === false
                || $wpdb->query('COMMIT') === false) {
                return false;
            }
            $committed = true;
            return true;
        } finally {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
        }
    }

    private static function remove_all_fan_push_devices($user_id) {
        $user_id = (int) $user_id;
        if ($user_id <= 0) { return false; }
        if (!self::push_tables_exist()) { return true; }
        global $wpdb;
        $tables = self::push_table_names();
        if (!isset($wpdb) || !method_exists($wpdb, 'query') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        return $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE fan_user_id = %d",
            $user_id
        )) !== false;
    }

    private static function sanitize_targeted_push_request(WP_REST_Request $request) {
        $recipients = $request->get_param('recipients');
        if (!is_array($recipients) || count($recipients) < 1
            || count($recipients) > self::PUSH_MAX_RECIPIENTS) {
            return new WP_Error(
                'push_recipients_invalid',
                '请选择 1–100 个明确用户。',
                array('status' => 400)
            );
        }
        $resolved = array();
        $selectors = array();
        foreach ($recipients as $recipient) {
            if (!is_array($recipient)) {
                return new WP_Error('push_recipient_invalid', '推送目标无效。', array('status' => 400));
            }
            $uuid = isset($recipient['userID']) && is_scalar($recipient['userID'])
                ? strtolower(trim((string) $recipient['userID']))
                : '';
            $identity = isset($recipient['identityCode']) && is_scalar($recipient['identityCode'])
                ? self::normalize_identity_code($recipient['identityCode'])
                : '';
            if (($uuid === '') === ($identity === '')) {
                return new WP_Error(
                    'push_recipient_invalid',
                    '每个推送目标必须且只能提供用户 ID 或身份码。',
                    array('status' => 400)
                );
            }
            if ($uuid !== '') {
                $user = self::find_fan_user_by_uuid($uuid);
            } else {
                $users = get_users(array(
                    'number' => 2,
                    'fields' => 'all',
                    'meta_key' => self::FAN_META_CODE,
                    'meta_value' => $identity,
                ));
                $user = count($users) === 1 && $users[0] instanceof WP_User
                    ? $users[0]
                    : new WP_Error('fan_not_found', '用户不存在。', array('status' => 404));
            }
            if (is_wp_error($user)) { return $user; }
            $status = (string) get_user_meta((int) $user->ID, self::FAN_META_STATUS, true);
            if (!in_array($status, array('pending', 'active'), true)) {
                return new WP_Error(
                    'push_recipient_unavailable',
                    '推送目标当前不可用。',
                    array('status' => 409)
                );
            }
            $resolved[(int) $user->ID] = (int) $user->ID;
            $selectors[(int) $user->ID] = $uuid !== ''
                ? array('type' => 'uuid', 'value' => $uuid)
                : array('type' => 'identity', 'value' => $identity);
        }
        $title = self::normalize_push_text($request->get_param('title'), 60);
        if (is_wp_error($title)) { return $title; }
        $body = self::normalize_push_text($request->get_param('body'), 240);
        if (is_wp_error($body)) { return $body; }
        $raw_sensitive = $request->get_param('sensitive');
        if ($raw_sensitive !== null && !is_scalar($raw_sensitive)) {
            return new WP_Error('push_sensitive_invalid', '推送隐私标记无效。', array('status' => 400));
        }
        $sensitive = $raw_sensitive === null ? true : rest_sanitize_boolean($raw_sensitive);
        if ($sensitive) {
            $title = 'Hi，梳子';
            $body = '有新消息，请登录查看';
        }
        $idempotency_key = strtolower(trim((string) $request->get_param('idempotencyKey')));
        if (!self::is_uuid_v4($idempotency_key)) {
            return new WP_Error(
                'push_idempotency_key_invalid',
                '推送请求标识无效。',
                array('status' => 400)
            );
        }
        $user_ids = array_values($resolved);
        sort($user_ids, SORT_NUMERIC);
        $canonical = wp_json_encode(array(
            'userIDs' => $user_ids,
            'selectors' => $selectors,
            'title' => $title,
            'body' => $body,
            'sensitive' => $sensitive,
        ), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if (!is_string($canonical)) {
            return new WP_Error('push_payload_invalid', '推送内容无效。', array('status' => 400));
        }
        return array(
            'userIDs' => $user_ids,
            'selectors' => $selectors,
            'title' => $title,
            'body' => $body,
            'sensitive' => $sensitive,
            'idempotencyKey' => $idempotency_key,
            'payloadHash' => hash('sha256', $canonical),
        );
    }

    private static function normalize_push_text($value, $maximum) {
        if (!is_string($value) || strlen($value) > (int) $maximum * 4 + 16
            || preg_match('//u', $value) !== 1
            || preg_match('/[\x00-\x1F\x7F]/', $value)) {
            return new WP_Error('push_text_invalid', '推送文字无效。', array('status' => 400));
        }
        $normalized = sanitize_text_field(trim($value));
        $length = self::text_length($normalized);
        if ($length < 1 || $length > (int) $maximum) {
            return new WP_Error('push_text_invalid', '推送文字长度无效。', array('status' => 400));
        }
        return $normalized;
    }

    public static function create_targeted_push_notification(WP_REST_Request $request) {
        $input = self::sanitize_targeted_push_request($request);
        if (is_wp_error($input)) { return $input; }
        if (!self::push_storage_ready()) { return self::push_storage_error(); }
        $provider = self::apns_provider_configuration();
        if (is_wp_error($provider)) { return $provider; }
        $actor_id = get_current_user_id();
        if ($actor_id <= 0) {
            return new WP_Error('push_admin_required', '需要管理员权限。', array('status' => 403));
        }
        // Lock every target in deterministic order before opening the
        // transaction. Account deletion/suspension uses the same locks, so it
        // cannot race target validation and leave a new recipient/outbox row.
        $fan_locks = array();
        foreach ($input['userIDs'] as $target_user_id) {
            $target_user_id = (int) $target_user_id;
            $target_lock = self::acquire_fan_lock($target_user_id);
            if (is_wp_error($target_lock)) {
                foreach (array_reverse($fan_locks, true) as $locked_user_id => $owner) {
                    self::release_fan_lock((int) $locked_user_id, $owner);
                }
                return $target_lock;
            }
            $fan_locks[$target_user_id] = $target_lock;
        }
        global $wpdb;
        $tables = self::push_table_names();
        if (!isset($wpdb) || !method_exists($wpdb, 'query')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'get_results') || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'insert')
            || $wpdb->query('START TRANSACTION') === false) {
            foreach (array_reverse($fan_locks, true) as $locked_user_id => $owner) {
                self::release_fan_lock((int) $locked_user_id, $owner);
            }
            return self::push_storage_error();
        }
        $committed = false;
        try {
            // Lock installation ownership before any device/outbox rows. Session
            // issuance and delivery use the same database order, preventing an
            // account transition from deadlocking this recipient snapshot.
            foreach ($input['userIDs'] as $target_user_id) {
                $locked_installs = $wpdb->get_col($wpdb->prepare(
                    "SELECT install_hash FROM {$tables['install_states']}
                     WHERE fan_user_id = %d ORDER BY install_hash ASC FOR UPDATE",
                    (int) $target_user_id
                ));
                if (!is_array($locked_installs) || !empty($wpdb->last_error)) {
                    return self::push_storage_error();
                }
            }
            foreach ($input['userIDs'] as $target_user_id) {
                $exists = $wpdb->get_var($wpdb->prepare(
                    "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE",
                    (int) $target_user_id
                ));
                $uuid = (string) self::fan_meta_from_database(
                    (int) $target_user_id,
                    self::FAN_META_UUID,
                    '',
                    true
                );
                $status = (string) self::fan_meta_from_database(
                    (int) $target_user_id,
                    self::FAN_META_STATUS,
                    '',
                    true
                );
                $selector = $input['selectors'][(int) $target_user_id] ?? null;
                $selector_matches = is_array($selector)
                    && ((($selector['type'] ?? '') === 'uuid'
                            && hash_equals((string) ($selector['value'] ?? ''), $uuid))
                        || (($selector['type'] ?? '') === 'identity'
                            && hash_equals(
                                (string) ($selector['value'] ?? ''),
                                (string) self::fan_meta_from_database(
                                    (int) $target_user_id,
                                    self::FAN_META_CODE,
                                    '',
                                    true
                                )
                            )));
                if ((int) $exists !== (int) $target_user_id
                    || !self::is_uuid_v4($uuid)
                    || !$selector_matches
                    || !in_array($status, array('pending', 'active'), true)
                    || !empty($wpdb->last_error)) {
                    return new WP_Error(
                        'push_recipient_unavailable',
                        '推送目标当前不可用。',
                        array('status' => 409)
                    );
                }
            }
            $existing = $wpdb->get_row($wpdb->prepare(
                "SELECT id, public_id, payload_hash, recipient_count, device_count
                 FROM {$tables['notifications']}
                 WHERE created_by = %d AND idempotency_key = %s LIMIT 1 FOR UPDATE",
                $actor_id,
                (string) $input['idempotencyKey']
            ), ARRAY_A);
            if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
            if (is_array($existing)) {
                if (!hash_equals((string) $existing['payload_hash'], (string) $input['payloadHash'])) {
                    return new WP_Error(
                        'push_idempotency_conflict',
                        '该推送请求标识已用于其他内容。',
                        array('status' => 409)
                    );
                }
                if ($wpdb->query('COMMIT') === false) { return self::push_storage_error(); }
                $committed = true;
                return self::targeted_push_response($existing, false);
            }
            $public_id = strtolower((string) wp_generate_uuid4());
            if (!self::is_uuid_v4($public_id)) { return self::push_storage_error(); }
            $created_at = time();
            $deliver_before = $created_at + self::PUSH_APNS_EXPIRATION_SECONDS;
            $now = gmdate('Y-m-d H:i:s', $created_at);
            $inserted = $wpdb->insert($tables['notifications'], array(
                'public_id' => $public_id,
                'idempotency_key' => (string) $input['idempotencyKey'],
                'payload_hash' => (string) $input['payloadHash'],
                'title' => (string) $input['title'],
                'body' => (string) $input['body'],
                'sensitive' => $input['sensitive'] ? 1 : 0,
                'created_by' => $actor_id,
                'recipient_count' => count($input['userIDs']),
                'device_count' => 0,
                'deliver_before' => $deliver_before,
                'created_at' => $now,
                'expires_at' => gmdate('Y-m-d H:i:s', $created_at + self::PUSH_RETENTION_SECONDS),
            ), array('%s', '%s', '%s', '%s', '%s', '%d', '%d', '%d', '%d', '%d', '%s', '%s'));
            if ($inserted !== 1) { return self::push_storage_error(); }
            $notification_id = (int) $wpdb->insert_id;
            $device_count = 0;
            foreach ($input['userIDs'] as $user_id) {
                $recipient_inserted = $wpdb->insert($tables['recipients'], array(
                    'notification_id' => $notification_id,
                    'fan_user_id' => (int) $user_id,
                    'created_at' => $now,
                ), array('%d', '%d', '%s'));
                if ($recipient_inserted !== 1) { return self::push_storage_error(); }
                $devices = $wpdb->get_results($wpdb->prepare(
                    "SELECT d.install_hash, d.token_hash, d.binding_generation
                     FROM {$tables['devices']} d
                     INNER JOIN {$tables['install_states']} s
                       ON s.install_hash = d.install_hash
                      AND s.fan_user_id = d.fan_user_id
                      AND s.session_option_id = d.session_option_id
                      AND s.binding_generation = d.binding_generation
                      AND s.desired_state = 'bound'
                     WHERE d.fan_user_id = %d AND d.expires_at > %s
                       AND s.session_expires_at > %s
                     ORDER BY d.updated_at DESC, d.id DESC LIMIT %d FOR UPDATE",
                    (int) $user_id,
                    $now,
                    $now,
                    self::PUSH_MAX_DEVICES_PER_USER
                ), ARRAY_A);
                if (!is_array($devices) || !empty($wpdb->last_error)) {
                    return self::push_storage_error();
                }
                foreach ($devices as $device) {
                    $token_hash = strtolower((string) ($device['token_hash'] ?? ''));
                    $device_install_hash = strtolower((string) ($device['install_hash'] ?? ''));
                    $binding_generation = (int) ($device['binding_generation'] ?? 0);
                    if (preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1
                        || preg_match('/^[a-f0-9]{64}$/D', $device_install_hash) !== 1
                        || $binding_generation <= 0) {
                        continue;
                    }
                    $dedupe = hash(
                        'sha256',
                        $public_id . '|' . $token_hash . '|' . (string) $binding_generation
                    );
                    $job = $wpdb->insert($tables['outbox'], array(
                        'notification_id' => $notification_id,
                        'fan_user_id' => (int) $user_id,
                        'install_hash' => $device_install_hash,
                        'token_hash' => $token_hash,
                        'binding_generation' => $binding_generation,
                        'dedupe_key' => $dedupe,
                        'status' => 'pending',
                        'attempts' => 0,
                        'next_attempt_at' => $now,
                        'lease_token' => null,
                        'lease_until' => null,
                        'last_error_code' => '',
                        'created_at' => $now,
                        'updated_at' => $now,
                    ), array('%d', '%d', '%s', '%s', '%d', '%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s'));
                    if ($job !== 1) { return self::push_storage_error(); }
                    $device_count++;
                }
            }
            $updated = $wpdb->update(
                $tables['notifications'],
                array('device_count' => $device_count),
                array('id' => $notification_id),
                array('%d'),
                array('%d')
            );
            if ($updated === false || $wpdb->query('COMMIT') === false) {
                return self::push_storage_error();
            }
            $committed = true;
            self::schedule_push_sweep(time() + 5);
            return self::targeted_push_response(array(
                'public_id' => $public_id,
                'recipient_count' => count($input['userIDs']),
                'device_count' => $device_count,
            ), true);
        } finally {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
            foreach (array_reverse($fan_locks, true) as $locked_user_id => $owner) {
                self::release_fan_lock((int) $locked_user_id, $owner);
            }
        }
    }

    private static function targeted_push_response($row, $created) {
        $response = new WP_REST_Response(array(
            'notificationID' => (string) ($row['public_id'] ?? ''),
            'status' => 'queued',
            'recipientCount' => max(0, (int) ($row['recipient_count'] ?? 0)),
            'deviceCount' => max(0, (int) ($row['device_count'] ?? 0)),
        ), $created ? 201 : 200);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        return $response;
    }

    public static function ensure_push_outbox_schedule() {
        if (!self::account_authority_enabled() || !self::push_storage_ready()) {
            return false;
        }
        if (wp_next_scheduled(self::PUSH_SWEEP_HOOK) !== false) { return true; }
        return self::schedule_push_sweep(time() + 60);
    }

    private static function schedule_push_sweep($timestamp) {
        if (wp_next_scheduled(self::PUSH_SWEEP_HOOK) !== false) { return true; }
        $scheduled = wp_schedule_single_event(
            max(time() + 1, (int) $timestamp),
            self::PUSH_SWEEP_HOOK,
            array(),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            do_action('yishu_push_security_audit', 'outbox_schedule_failed');
            return false;
        }
        return true;
    }

    public static function sweep_push_outbox() {
        if (!self::account_authority_enabled() || !self::push_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::push_table_names();
        $now = gmdate('Y-m-d H:i:s');
        $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE expires_at <= %s",
            $now
        ));
        $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['install_states']} WHERE session_expires_at <= %s",
            $now
        ));
        $wpdb->query(
            "DELETE d FROM {$tables['devices']} d
             LEFT JOIN {$tables['install_states']} s ON s.install_hash = d.install_hash
             WHERE s.install_hash IS NULL"
        );
        // Notification content and terminal delivery metadata have a bounded
        // retention period. The delivery deadline is intentionally earlier:
        // terminal rows remain for the 30-day audit window after delivery stops.
        $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']} o
             INNER JOIN {$tables['notifications']} n ON n.id = o.notification_id
             SET o.status = 'dead', o.last_error_code = 'expired',
                 o.lease_token = NULL, o.lease_until = NULL, o.updated_at = %s
             WHERE n.deliver_before <= %d AND o.status IN ('pending', 'processing')",
            $now,
            time()
        ));
        // Recover crashed claims independently of the normal due-job selector.
        // A final-attempt crash becomes terminal instead of remaining in the
        // processing state forever; earlier attempts return to pending.
        $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'dead', last_error_code = 'attempts_exhausted',
                 lease_token = NULL, lease_until = NULL, updated_at = %s
             WHERE status = 'processing' AND lease_until <= %s AND attempts >= %d",
            $now,
            $now,
            self::PUSH_OUTBOX_MAX_ATTEMPTS
        ));
        $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'pending', lease_token = NULL, lease_until = NULL,
                 next_attempt_at = %s, last_error_code = 'lease_recovered', updated_at = %s
             WHERE status = 'processing' AND lease_until <= %s AND attempts < %d",
            $now,
            $now,
            $now,
            self::PUSH_OUTBOX_MAX_ATTEMPTS
        ));
        $wpdb->query($wpdb->prepare(
            "DELETE o FROM {$tables['outbox']} o
             INNER JOIN {$tables['notifications']} n ON n.id = o.notification_id
             WHERE n.expires_at <= %s",
            $now
        ));
        $wpdb->query($wpdb->prepare(
            "DELETE r FROM {$tables['recipients']} r
             INNER JOIN {$tables['notifications']} n ON n.id = r.notification_id
             WHERE n.expires_at <= %s",
            $now
        ));
        $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['notifications']} WHERE expires_at <= %s",
            $now
        ));
        if (!empty($wpdb->last_error)) { return false; }
        // Retention cleanup must continue even if APNs credentials are absent
        // or temporarily invalid. In that state leave live jobs untouched and
        // retry readiness on the next sweep without consuming delivery attempts.
        if (is_wp_error(self::apns_provider_configuration())) {
            self::schedule_push_sweep(time() + 60);
            return true;
        }
        // Do not claim jobs while the device data key or crypto runtime is
        // unavailable. Readiness failures are operational and must not consume
        // an APNs delivery attempt or cause a valid device binding to be purged.
        $device_keys = self::push_device_keys();
        if (is_wp_error($device_keys)) {
            self::schedule_push_sweep(time() + 60);
            return true;
        }
        sodium_memzero($device_keys['encryption']);
        sodium_memzero($device_keys['index']);
        $ids = $wpdb->get_col($wpdb->prepare(
            "SELECT id FROM {$tables['outbox']}
             WHERE attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))
             ORDER BY next_attempt_at ASC, id ASC LIMIT 20",
            self::PUSH_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if (!is_array($ids) || !empty($wpdb->last_error)) { return false; }
        foreach ($ids as $id) {
            if ((int) $id > 0) { self::process_push_outbox((int) $id); }
        }
        self::schedule_push_sweep(time() + 60);
        return true;
    }

    public static function process_push_outbox($job_id) {
        $job_id = (int) $job_id;
        if ($job_id <= 0 || !self::account_authority_enabled()
            || !self::push_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::push_table_names();
        try {
            $lease = bin2hex(random_bytes(16));
        } catch (Throwable $error) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        $lease_until = gmdate('Y-m-d H:i:s', time() + self::PUSH_OUTBOX_LEASE_SECONDS);
        $claimed = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'processing', attempts = attempts + 1,
                 lease_token = %s, lease_until = %s, updated_at = %s
             WHERE id = %d AND attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))",
            $lease,
            $lease_until,
            $now,
            $job_id,
            self::PUSH_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if ($claimed !== 1) { return false; }
        $routing = $wpdb->get_row($wpdb->prepare(
            "SELECT o.fan_user_id, o.install_hash
             FROM {$tables['outbox']} o
             WHERE o.id = %d AND o.lease_token = %s LIMIT 1",
            $job_id,
            $lease
        ), ARRAY_A);
        if (!empty($wpdb->last_error)) {
            return self::defer_push_outbox_without_attempt(
                $job_id,
                $lease,
                'storage_unavailable'
            );
        }
        $user_id = is_array($routing) ? (int) ($routing['fan_user_id'] ?? 0) : 0;
        $install_hash = is_array($routing)
            ? strtolower((string) ($routing['install_hash'] ?? ''))
            : '';
        if ($user_id <= 0 || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1) {
            self::complete_push_outbox_job($job_id, $lease, 'dead', 'device_missing');
            return false;
        }
        // Global lock order is always installation then fan. These locks, plus
        // the install-state row lock below, remain held through curl_exec so a
        // logout, account switch, suspension or delete has a single linearized
        // position relative to the APNs request.
        $install_lock = self::acquire_named_fan_lock_with_timeout(
            'push_install',
            $install_hash,
            5
        );
        if (is_wp_error($install_lock)) {
            return self::defer_push_outbox_without_attempt(
                $job_id,
                $lease,
                'delivery_lock_unavailable'
            );
        }
        $fan_lock = self::acquire_fan_lock($user_id);
        if (is_wp_error($fan_lock)) {
            self::release_named_fan_lock($install_lock);
            return self::defer_push_outbox_without_attempt(
                $job_id,
                $lease,
                'delivery_lock_unavailable'
            );
        }
        $transaction = false;
        $committed = false;
        $device_token = '';
        // Temporary delivery failures must release the database transaction
        // before defer_push_outbox_without_attempt() updates the same lease.
        // Centralizing this makes every return/finally path issue at most one
        // rollback while still preserving the defer update after it.
        $rollback_transaction = static function () use ($wpdb, &$transaction, &$committed) {
            if (!$transaction || $committed) {
                $transaction = false;
                return;
            }
            $wpdb->query('ROLLBACK');
            $transaction = false;
        };
        try {
            if ($wpdb->query('START TRANSACTION') === false) {
                return self::defer_push_outbox_without_attempt(
                    $job_id,
                    $lease,
                    'storage_unavailable'
                );
            }
            $transaction = true;
            // The cross-node lock order is installation state, then device and
            // outbox. Acquire the authority row explicitly before the joined job
            // snapshot; relying on the optimizer's JOIN order can invert that
            // order against login/logout and cause a deadlock.
            $owner_state = $wpdb->get_row($wpdb->prepare(
                "SELECT install_hash FROM {$tables['install_states']}
                 WHERE install_hash = %s LIMIT 1 FOR UPDATE",
                $install_hash
            ), ARRAY_A);
            if (!empty($wpdb->last_error)) {
                $rollback_transaction();
                return self::defer_push_outbox_without_attempt(
                    $job_id,
                    $lease,
                    'storage_unavailable'
                );
            }
            $job = $wpdb->get_row($wpdb->prepare(
                "SELECT o.id, o.fan_user_id, o.install_hash AS outbox_install_hash,
                        o.token_hash, o.binding_generation, o.attempts,
                        n.public_id, n.title, n.body, n.deliver_before,
                        d.install_hash, d.session_option_id, d.binding_generation AS device_generation,
                        d.token_ciphertext,
                        s.fan_user_id AS owner_user_id,
                        s.session_option_id AS owner_session_option_id,
                        s.binding_generation AS owner_generation,
                        s.desired_state, s.session_expires_at
                 FROM {$tables['outbox']} o
                 INNER JOIN {$tables['notifications']} n ON n.id = o.notification_id
                 LEFT JOIN {$tables['devices']} d
                   ON d.fan_user_id = o.fan_user_id
                  AND d.token_hash = o.token_hash
                  AND d.binding_generation = o.binding_generation
                 LEFT JOIN {$tables['install_states']} s ON s.install_hash = d.install_hash
                 WHERE o.id = %d AND o.lease_token = %s LIMIT 1 FOR UPDATE",
                $job_id,
                $lease
            ), ARRAY_A);
            if (!empty($wpdb->last_error)) {
                // Deadlock victims and transient database failures are not proof
                // that a recipient became inactive. Release the claim without
                // consuming an attempt instead of incorrectly killing the job.
                $rollback_transaction();
                return self::defer_push_outbox_without_attempt(
                    $job_id,
                    $lease,
                    'storage_unavailable'
                );
            }
            $session_state = is_array($job)
                ? self::push_delivery_session_is_current($job)
                : false;
            if (is_wp_error($session_state)) {
                $rollback_transaction();
                return self::defer_push_outbox_without_attempt(
                    $job_id,
                    $lease,
                    'storage_unavailable'
                );
            }
            $session_current = $session_state === true;
            if (!is_array($job) || empty($job['token_ciphertext'])
                || !hash_equals($install_hash, (string) ($job['install_hash'] ?? ''))
                || !hash_equals($install_hash, (string) ($job['outbox_install_hash'] ?? ''))
                || (int) ($job['fan_user_id'] ?? 0) !== $user_id
                || (int) ($job['binding_generation'] ?? 0) <= 0
                || (int) ($job['binding_generation'] ?? 0)
                    !== (int) ($job['device_generation'] ?? 0)
                || (int) ($job['device_generation'] ?? 0)
                    !== (int) ($job['owner_generation'] ?? 0)
                || (int) ($job['session_option_id'] ?? 0)
                    !== (int) ($job['owner_session_option_id'] ?? 0)
                || (int) ($job['owner_user_id'] ?? 0) !== $user_id
                || !hash_equals('bound', (string) ($job['desired_state'] ?? ''))
                || strtotime((string) ($job['session_expires_at'] ?? '') . ' UTC') <= time()
                || !$session_current) {
                self::complete_push_outbox_job($job_id, $lease, 'dead', 'recipient_inactive');
                if ($wpdb->query('COMMIT') === false) { return false; }
                $committed = true;
                return false;
            }
            if ((int) ($job['deliver_before'] ?? 0) <= time()) {
                self::complete_push_outbox_job($job_id, $lease, 'dead', 'expired');
                if ($wpdb->query('COMMIT') === false) { return false; }
                $committed = true;
                return false;
            }
            $device_token = self::decrypt_push_device_token(
                (string) $job['token_ciphertext'],
                (string) $job['token_hash']
            );
            if (is_wp_error($device_token)) {
                $rollback_transaction();
                return self::defer_push_outbox_without_attempt(
                    $job_id,
                    $lease,
                    'device_crypto_unavailable'
                );
            }
            if ($device_token === '') {
                self::invalidate_push_binding_for_job($job, 'device_ciphertext_invalid');
                self::complete_push_outbox_job(
                    $job_id,
                    $lease,
                    'dead',
                    'device_ciphertext_invalid'
                );
                if ($wpdb->query('COMMIT') === false) { return false; }
                $committed = true;
                return false;
            }
            $result = self::send_push_to_apns($device_token, $job);
            if (function_exists('sodium_memzero')) { sodium_memzero($device_token); }
            $device_token = '';
            $outcome = (string) ($result['outcome'] ?? 'retry');
            $code = sanitize_key((string) ($result['code'] ?? 'apns_error'));
            if ($outcome === 'sent') {
                $updated = self::complete_push_outbox_job($job_id, $lease, 'sent', '');
            } elseif ($outcome === 'invalid') {
                self::invalidate_push_binding_for_job($job, $code ?: 'device_invalid');
                $updated = self::complete_push_outbox_job(
                    $job_id,
                    $lease,
                    'dead',
                    $code ?: 'device_invalid'
                );
            } else {
                $attempts = (int) ($job['attempts'] ?? 1);
                if ($outcome === 'dead' || $attempts >= self::PUSH_OUTBOX_MAX_ATTEMPTS) {
                    $updated = self::complete_push_outbox_job(
                        $job_id,
                        $lease,
                        'dead',
                        $code ?: 'delivery_rejected'
                    );
                } else {
                    $delay = min(3600, 30 * (2 ** min($attempts, 7)));
                    $updated = $wpdb->update($tables['outbox'], array(
                        'status' => 'pending',
                        'next_attempt_at' => gmdate('Y-m-d H:i:s', time() + $delay),
                        'lease_token' => null,
                        'lease_until' => null,
                        'last_error_code' => $code ?: 'delivery_retry',
                        'updated_at' => gmdate('Y-m-d H:i:s'),
                    ), array('id' => $job_id, 'lease_token' => $lease),
                        array('%s', '%s', '%s', '%s', '%s', '%s'), array('%d', '%s')) === 1;
                    self::schedule_push_sweep(time() + $delay);
                }
            }
            if (!$updated || $wpdb->query('COMMIT') === false) { return false; }
            $committed = true;
            return $outcome === 'sent';
        } finally {
            if (is_string($device_token) && $device_token !== '') {
                if (function_exists('sodium_memzero')) { sodium_memzero($device_token); }
            }
            $rollback_transaction();
            self::release_fan_lock($user_id, $fan_lock);
            self::release_named_fan_lock($install_lock);
        }
    }

    /**
     * Release a claimed job after a temporary device-key outage.
     *
     * The claim increments attempts atomically. This fenced update rolls back
     * exactly that increment only while the same lease still owns the job.
     */
    private static function defer_push_outbox_without_attempt($job_id, $lease, $reason) {
        $job_id = (int) $job_id;
        $lease = (string) $lease;
        $reason = sanitize_key((string) $reason);
        if ($job_id <= 0 || preg_match('/^[a-f0-9]{32}$/D', $lease) !== 1
            || preg_match('/^[a-z0-9_-]{1,64}$/D', $reason) !== 1) {
            return false;
        }
        global $wpdb;
        $tables = self::push_table_names();
        $now = gmdate('Y-m-d H:i:s');
        $next_attempt = gmdate('Y-m-d H:i:s', time() + 60);
        $updated = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'pending',
                 attempts = CASE WHEN attempts > 0 THEN attempts - 1 ELSE 0 END,
                 next_attempt_at = %s, lease_token = NULL, lease_until = NULL,
                 last_error_code = %s, updated_at = %s
             WHERE id = %d AND lease_token = %s AND status = 'processing'",
            $next_attempt,
            $reason,
            $now,
            $job_id,
            $lease
        ));
        self::schedule_push_sweep(time() + 60);
        return $updated === 1;
    }

    private static function push_delivery_session_is_current($job) {
        if (!is_array($job)) {
            return false;
        }
        $user_id = (int) ($job['fan_user_id'] ?? 0);
        $install_hash = strtolower((string) ($job['install_hash'] ?? ''));
        $option_id = (int) ($job['session_option_id'] ?? 0);
        if ($user_id <= 0 || $option_id <= 0
            || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1) {
            return false;
        }
        global $wpdb;
        $option = $wpdb->get_row($wpdb->prepare(
            "SELECT option_name, option_value FROM {$wpdb->options}
             WHERE option_id = %d LIMIT 1 FOR UPDATE",
            $option_id
        ), ARRAY_A);
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $prefix = self::FAN_SESSION_OPTION_PREFIX;
        if (!is_array($option)
            || strpos((string) ($option['option_name'] ?? ''), $prefix) !== 0
            || !is_string($option['option_value'] ?? null)) {
            return false;
        }
        $token_hash = substr((string) $option['option_name'], strlen($prefix));
        $context = maybe_unserialize((string) $option['option_value']);
        if (!is_array($context)
            || preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1
            || (int) ($context['userID'] ?? 0) !== $user_id
            || !hash_equals($install_hash, (string) ($context['installHash'] ?? ''))
            || (string) ($context['scope'] ?? '') !== 'normal') {
            return false;
        }
        $context['tokenHash'] = $token_hash;
        $exists = $wpdb->get_var($wpdb->prepare(
            "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE",
            $user_id
        ));
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $status = (string) self::fan_meta_from_database(
            $user_id,
            self::FAN_META_STATUS,
            '',
            true
        );
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $uuid = (string) self::fan_meta_from_database(
            $user_id,
            self::FAN_META_UUID,
            '',
            true
        );
        if (!empty($wpdb->last_error)) { return self::push_storage_error(); }
        $session_current = self::fan_session_context_is_current_from_database(
            $context,
            'normal',
            true
        );
        if (!$session_current && !empty($wpdb->last_error)) {
            return self::push_storage_error();
        }
        return (int) $exists === $user_id
            && self::is_uuid_v4($uuid)
            && in_array($status, array('pending', 'active'), true)
            && $session_current;
    }

    /** Invalidate only the exact binding generation held by the current job. */
    private static function invalidate_push_binding_for_job($job, $reason) {
        if (!is_array($job)) { return false; }
        global $wpdb;
        $tables = self::push_table_names();
        $user_id = (int) ($job['fan_user_id'] ?? 0);
        $generation = (int) ($job['binding_generation'] ?? 0);
        $session_option_id = (int) ($job['session_option_id'] ?? 0);
        $install_hash = strtolower((string) ($job['install_hash'] ?? ''));
        if ($user_id <= 0 || $generation <= 0 || $session_option_id <= 0
            || preg_match('/^[a-f0-9]{64}$/D', $install_hash) !== 1) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        $jobs = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']} SET status = 'dead', last_error_code = %s,
                lease_token = NULL, lease_until = NULL, updated_at = %s
             WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d
               AND status IN ('pending', 'processing')",
            sanitize_key((string) $reason),
            $now,
            $install_hash,
            $user_id,
            $generation
        ));
        $device = $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE install_hash = %s
             AND fan_user_id = %d AND session_option_id = %d AND binding_generation = %d",
            $install_hash,
            $user_id,
            $session_option_id,
            $generation
        ));
        $state = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['install_states']} SET desired_state = 'unbound', updated_at = %s
             WHERE install_hash = %s AND fan_user_id = %d
               AND session_option_id = %d AND binding_generation = %d",
            $now,
            $install_hash,
            $user_id,
            $session_option_id,
            $generation
        ));
        return $jobs !== false && $device !== false && $state !== false;
    }

    private static function complete_push_outbox_job($job_id, $lease, $status, $code) {
        if (!in_array($status, array('sent', 'dead'), true)) { return false; }
        global $wpdb;
        $tables = self::push_table_names();
        $updated = $wpdb->update($tables['outbox'], array(
            'status' => $status,
            'lease_token' => null,
            'lease_until' => null,
            'last_error_code' => sanitize_key((string) $code),
            'updated_at' => gmdate('Y-m-d H:i:s'),
        ), array('id' => (int) $job_id, 'lease_token' => (string) $lease),
            array('%s', '%s', '%s', '%s', '%s'), array('%d', '%s'));
        return $updated === 1;
    }

    private static function remove_invalid_push_device($user_id, $token_hash) {
        $token_hash = strtolower((string) $token_hash);
        if ((int) $user_id <= 0 || preg_match('/^[a-f0-9]{64}$/D', $token_hash) !== 1) {
            return false;
        }
        global $wpdb;
        $tables = self::push_table_names();
        return $wpdb->query($wpdb->prepare(
            "DELETE FROM {$tables['devices']} WHERE fan_user_id = %d AND token_hash = %s",
            (int) $user_id,
            $token_hash
        )) !== false;
    }

    public static function purge_push_data_for_fan_user($fan_user_id) {
        $fan_user_id = (int) $fan_user_id;
        if ($fan_user_id <= 0) { return false; }
        global $wpdb;
        $tables = self::push_table_names();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')
            || !method_exists($wpdb, 'query')) {
            return false;
        }
        $present = 0;
        foreach ($tables as $table) {
            $found = $wpdb->get_var($wpdb->prepare(
                'SHOW TABLES LIKE %s',
                $wpdb->esc_like($table)
            ));
            if (!empty($wpdb->last_error)) { return false; }
            if (is_string($found) && hash_equals($table, $found)) { $present++; }
        }
        if ($present === 0) { return true; }
        if ($present !== count($tables) || $wpdb->query('START TRANSACTION') === false) {
            return false;
        }
        $committed = false;
        try {
            // Keep only the minimum anti-replay tombstone until the session's
            // existing expiry. Lock ownership before outbox/device rows, matching
            // bind, unbind, session transition and worker order.
            $states = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['install_states']}
                 SET fan_user_id = 0, desired_state = 'unbound', updated_at = %s
                 WHERE fan_user_id = %d",
                gmdate('Y-m-d H:i:s'),
                $fan_user_id
            ));
            $jobs = $states !== false ? $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['outbox']} WHERE fan_user_id = %d",
                $fan_user_id
            )) : false;
            $devices = $jobs !== false ? $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['devices']} WHERE fan_user_id = %d",
                $fan_user_id
            )) : false;
            $recipients = $wpdb->query($wpdb->prepare(
                "DELETE FROM {$tables['recipients']} WHERE fan_user_id = %d",
                $fan_user_id
            ));
            $orphans = $wpdb->query(
                "DELETE n FROM {$tables['notifications']} n
                 LEFT JOIN {$tables['recipients']} r ON r.notification_id = n.id
                 WHERE r.id IS NULL"
            );
            if ($jobs === false || $devices === false || $states === false || $recipients === false
                || $orphans === false
                || $wpdb->query('COMMIT') === false) {
                return false;
            }
            $committed = true;
            return true;
        } finally {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
        }
    }
}
