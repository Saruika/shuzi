<?php
declare(strict_types=1);

/**
 * Review-only, actual WordPress REST dispatch / MySQL integration acceptance.
 * Run with WP-CLI eval-file inside the review OS sandbox, never via HTTP:
 *   wp --path=/srv/shuzijun-review/site --skip-packages eval-file THIS_FILE --use-include
 *   ... eval-file THIS_FILE --use-include install-schema=32_LOWERCASE_HEX_RUN_ID
 *   ... eval-file THIS_FILE --use-include run=32_LOWERCASE_HEX_RUN_ID
 *   ... eval-file THIS_FILE --use-include cleanup=THE_SAME_RUN_ID
 * --use-include is required: WP-CLI's default eval prepends a closing PHP tag,
 * which makes the strict_types declaration fail before any guard can execute.
 *
 * Default: read-only preflight. Schema installation is a separate explicit mode.
 * run= creates at most 102 subscriber fixtures and cleans them on success.
 * Failure retains a private recovery receipt; never blindly repeat run=.
 * Credentials stay in memory. Receipts contain exact synthetic cleanup targets,
 * not passwords/tokens. No login, HTTP/TLS, APNs or SMTP success is claimed.
 *
 * Required outer sandbox: User=shuzijun-review, PrivateNetwork=yes,
 * RestrictAddressFamilies=AF_UNIX, NoNewPrivileges=yes, production paths hidden,
 * and only /srv/shuzijun-review/tmp writable. Root owns remote execution.
 * Root must also quiesce only review web/PHP services for the entire acceptance
 * and cleanup window, then restore their prior state. The existing account
 * deletion hook collects orphan push records; empty-table guards below are
 * defense in depth, not a substitute for exclusive review write access.
 */

final class ReviewGameFailure extends RuntimeException {}

function review_game_require(bool $condition, string $code): void {
    if (!$condition) { throw new ReviewGameFailure($code); }
}

function review_game_arguments(array $arguments): array {
    if ($arguments === array() || $arguments === array('preflight')) { return array('preflight', null); }
    review_game_require(count($arguments) === 1 && is_string($arguments[0]), 'arguments');
    review_game_require(preg_match('/^(install-schema|run|cleanup)=([a-f0-9]{32})$/D', $arguments[0], $match) === 1, 'arguments');
    return array($match[1], $match[2]);
}

/** Pure validation also exercised offline; actual facts are collected below. */
function review_game_validate_isolation(array $facts): void {
    foreach (array('sapi' => 'cli', 'abspath' => '/srv/shuzijun-review/site/',
        'realpath' => '/srv/shuzijun-review/site', 'database' => 'shuzijun_review',
        'selectedDatabase' => 'shuzijun_review', 'databaseUser' => 'shuzijun_review',
        'databaseHost' => 'localhost:/var/run/mysqld/mysqld.sock',
        'environment' => 'review', 'home' => 'https://review.shuzijun.com.cn',
        'site' => 'https://review.shuzijun.com.cn', 'osUser' => 'shuzijun-review',
        'tablePrefix' => 'review_') as $key => $value) {
        review_game_require(($facts[$key] ?? null) === $value, 'isolation_' . $key);
    }
    foreach (array('cronDisabled', 'httpBlocked', 'fileModsDisabled', 'authority',
        'mailDenied', 'httpDenied', 'noPushConfiguration', 'productionHidden',
        'noPersistentCache', 'debugDisabled', 'mysqlAvailable', 'noNewPrivileges') as $key) {
        review_game_require(($facts[$key] ?? null) === true, 'isolation_' . $key);
    }
    $databases = $facts['databases'] ?? array();
    review_game_require(is_array($databases) && in_array('shuzijun_review', $databases, true)
        && array_diff($databases, array('information_schema', 'performance_schema', 'shuzijun_review')) === array(),
        'isolation_databases');
    $grants = $facts['grants'] ?? array();
    review_game_require(is_array($grants) && count($grants) === 2, 'isolation_grants');
    $usage = 0; $schema = 0;
    foreach ($grants as $grant) {
        review_game_require(is_string($grant) && !str_contains($grant, 'WITH GRANT OPTION'), 'isolation_grants');
        $usage += preg_match('/^GRANT USAGE ON \*\.\* TO [`\x27]shuzijun_review[`\x27]@[`\x27]localhost[`\x27]$/D', $grant) === 1 ? 1 : 0;
        $schema += preg_match('/^GRANT ALL PRIVILEGES ON `shuzijun_review`\.\* TO [`\x27]shuzijun_review[`\x27]@[`\x27]localhost[`\x27]$/D', $grant) === 1 ? 1 : 0;
    }
    review_game_require($usage === 1 && $schema === 1, 'isolation_grants');
}

function review_game_preflight(): array {
    global $wpdb;
    review_game_require(PHP_SAPI === 'cli' && defined('WP_CLI') && WP_CLI === true, 'wp_cli_required');
    review_game_require(defined('ABSPATH') && ABSPATH === '/srv/shuzijun-review/site/'
        && defined('DB_NAME') && DB_NAME === 'shuzijun_review'
        && defined('YISHU_APP_SERVICE_ENVIRONMENT') && YISHU_APP_SERVICE_ENVIRONMENT === 'review', 'review_required');
    review_game_require(class_exists('Shuzijun_App_Content_API') && class_exists('Shuzijun_Game_Rules')
        && isset($wpdb) && function_exists('posix_geteuid'), 'review_runtime');
    $wpdb->hide_errors();
    $owner = posix_getpwuid(posix_geteuid());
    $no_push = true;
    foreach (array('YISHU_APNS_DATA_KEY_PATH', 'YISHU_APNS_PRIVATE_KEY_PATH', 'YISHU_APNS_KEY_PATH',
        'YISHU_APNS_KEY_ID', 'YISHU_APNS_TEAM_ID') as $key) {
        if ((defined($key) && constant($key)) || getenv($key)) { $no_push = false; }
    }
    // Only exercise the preflight filters; do not attempt mail or an HTTP call.
    $http_denied = apply_filters('pre_http_request', false, array(), 'https://review.invalid/no-request');
    $status = (string) @file_get_contents('/proc/self/status');
    review_game_validate_isolation(array(
        'sapi' => PHP_SAPI, 'abspath' => ABSPATH, 'realpath' => realpath(ABSPATH),
        'database' => DB_NAME, 'selectedDatabase' => $wpdb->get_var('SELECT DATABASE()'),
        'databaseUser' => DB_USER, 'databaseHost' => DB_HOST,
        'environment' => YISHU_APP_SERVICE_ENVIRONMENT, 'home' => home_url(), 'site' => site_url(),
        'osUser' => $owner['name'] ?? null, 'tablePrefix' => $wpdb->prefix,
        'cronDisabled' => defined('DISABLE_WP_CRON') && DISABLE_WP_CRON === true,
        'httpBlocked' => defined('WP_HTTP_BLOCK_EXTERNAL') && WP_HTTP_BLOCK_EXTERNAL === true,
        'fileModsDisabled' => defined('DISALLOW_FILE_MODS') && DISALLOW_FILE_MODS === true,
        'authority' => Shuzijun_App_Content_API::account_authority_enabled(),
        'mailDenied' => apply_filters('pre_wp_mail', null, array()) === false,
        'httpDenied' => is_wp_error($http_denied), 'noPushConfiguration' => $no_push,
        'productionHidden' => !is_readable('/var/www/html/wp-config.php') && !is_readable('/etc/shuzijun/push'),
        'noPersistentCache' => !wp_using_ext_object_cache(),
        'debugDisabled' => (!defined('WP_DEBUG') || WP_DEBUG === false) && (!defined('SAVEQUERIES') || SAVEQUERIES === false),
        'mysqlAvailable' => extension_loaded('mysqli'),
        'noNewPrivileges' => preg_match('/^NoNewPrivs:\s+1$/m', $status) === 1,
        'databases' => $wpdb->get_col('SHOW DATABASES'), 'grants' => $wpdb->get_col('SHOW GRANTS'),
    ));
    review_game_require($wpdb->last_error === '', 'preflight_database');
    foreach (array($wpdb->users, $wpdb->usermeta, $wpdb->options) as $table) {
        $row = $wpdb->get_row($wpdb->prepare('SHOW TABLE STATUS LIKE %s', $wpdb->esc_like($table)), ARRAY_A);
        review_game_require(is_array($row) && ($row['Name'] ?? '') === $table
            && strtoupper((string) ($row['Engine'] ?? '')) === 'INNODB' && $wpdb->last_error === '', 'identity_tables_innodb');
    }
    review_game_require_empty_push_tables();
    $install_states = review_game_install_states_snapshot();
    review_game_require_no_orphan_install_states();
    $hashes = array();
    foreach (array('Shuzijun_App_Content_API', 'Shuzijun_Game_Rules', 'Shuzijun_App_Game_Leaderboard') as $class) {
        $path = (new ReflectionClass($class))->getFileName();
        review_game_require(is_string($path) && !is_link($path)
            && str_starts_with((string) realpath($path), ABSPATH . 'wp-content/mu-plugins/vendor/shuzijun/app-content/'), 'candidate_source_path');
        $hashes[$class] = hash_file('sha256', $path);
    }
    $rules = Shuzijun_Game_Rules::bundled();
    review_game_require($rules->hash() !== '', 'rules_hash');
    $routes = rest_get_server()->get_routes();
    foreach (array('/shuzijun/v1/fan/game/leaderboard', '/shuzijun/v1/fan/game/scores', '/shuzijun/v1/fan/delete') as $route) {
        review_game_require(isset($routes[$route]), 'registered_routes');
    }
    return array('moduleHashes' => $hashes, 'rulesHash' => $rules->hash(), 'installStatesBaseline' => $install_states);
}

function review_game_require_empty_push_tables(): void {
    global $wpdb;
    // The root-controlled exclusive review window prevents a write between
    // this check and deletion; fail closed if any delivery data is observed.
    foreach (array('devices', 'notifications', 'recipients', 'outbox') as $suffix) {
        $table = $wpdb->prefix . 'yishu_push_' . $suffix;
        $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
        review_game_require($wpdb->last_error === '', 'push_table_probe');
        if ($found !== null) {
            review_game_require($found === $table && (string) $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i', $table)) === '0'
                && $wpdb->last_error === '', 'existing_push_data');
        }
    }
}

function review_game_install_states_snapshot(): array {
    global $wpdb;
    $table = $wpdb->prefix . 'yishu_push_install_states';
    $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
    review_game_require($wpdb->last_error === '', 'install_states_probe');
    if ($found === null) { return array('present' => false, 'count' => 0, 'sha256' => hash('sha256', 'absent')); }
    review_game_require($found === $table, 'install_states_table');
    $count = filter_var($wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i', $table)), FILTER_VALIDATE_INT);
    review_game_require($count !== false && $count >= 0 && $count <= 4096 && $wpdb->last_error === '', 'install_states_bound');
    $rows = $wpdb->get_results($wpdb->prepare('SELECT install_hash, fan_user_id, session_option_id, binding_generation,
        desired_state, session_expires_at, created_at, updated_at FROM %i ORDER BY install_hash LIMIT 4097', $table), ARRAY_A);
    review_game_require(is_array($rows) && count($rows) === $count && $wpdb->last_error === '', 'install_states_snapshot');
    // Existing installation identifiers never leave memory; only this digest
    // and count are retained privately, and no existing row is modified.
    return array('present' => true, 'count' => $count, 'sha256' => hash('sha256', serialize($rows)));
}

function review_game_require_no_orphan_install_states(): void {
    global $wpdb;
    $table = $wpdb->prefix . 'yishu_push_install_states';
    $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
    review_game_require($wpdb->last_error === '', 'install_states_owner_probe');
    if ($found === null) { return; }
    review_game_require($found === $table && (string) $wpdb->get_var($wpdb->prepare(
        'SELECT COUNT(*) FROM %i s LEFT JOIN %i u ON u.ID = s.fan_user_id WHERE s.fan_user_id <> 0 AND u.ID IS NULL',
        $table, $wpdb->users)) === '0' && $wpdb->last_error === '', 'orphan_install_state_owner');
}

function review_game_require_untouched_push(array $baseline): void {
    review_game_require_empty_push_tables();
    review_game_require(review_game_install_states_snapshot() === $baseline, 'existing_install_states_changed');
}

function review_game_require_new_install_identity(int $id, ?string $install_hash = null): void {
    global $wpdb;
    review_game_require($id > 0 && ($install_hash === null || preg_match('/^[a-f0-9]{64}$/D', $install_hash) === 1), 'fixture_install_identity');
    $table = $wpdb->prefix . 'yishu_push_install_states';
    $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
    review_game_require($wpdb->last_error === '', 'fixture_install_probe');
    if ($found === null) { return; }
    $query = $install_hash === null
        ? $wpdb->prepare('SELECT COUNT(*) FROM %i WHERE fan_user_id = %d', $table, $id)
        : $wpdb->prepare('SELECT COUNT(*) FROM %i WHERE fan_user_id = %d OR install_hash = %s', $table, $id, $install_hash);
    review_game_require($found === $table && (string) $wpdb->get_var($query) === '0'
        && $wpdb->last_error === '', 'fixture_install_collision');
}

final class ReviewGameReceipt {
    public array $data;
    private string $path;
    public function __construct(private string $directory, string $run, string $kind, bool $existing = false) {
        review_game_require(preg_match('/^[a-f0-9]{32}$/D', $run) === 1
            && in_array($kind, array('run', 'schema'), true), 'receipt_name');
        $this->path = $directory . '/' . $run . '.' . $kind . '.json';
        $this->checkDirectory();
        if ($existing) {
            $this->checkFile();
            $raw = file_get_contents($this->path);
            review_game_require(is_string($raw) && strlen($raw) <= 262144, 'receipt_size');
            $this->data = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
            review_game_require(($this->data['run'] ?? '') === $run && ($this->data['kind'] ?? '') === $kind
                && ($this->data['environment'] ?? '') === 'review' && ($this->data['version'] ?? 0) === 1, 'receipt_identity');
        } else {
            $this->data = array('version' => 1, 'environment' => 'review', 'run' => $run, 'kind' => $kind,
                'createdAt' => gmdate('c'), 'state' => 'prepared', 'acceptancePassed' => false, 'accounts' => array());
            $this->writeNew($this->path, $this->encode());
        }
    }
    private function checkDirectory(): void {
        clearstatcache(true, $this->directory);
        $stat = lstat($this->directory);
        review_game_require(is_array($stat) && ($stat['mode'] & 0170000) === 0040000
            && ($stat['mode'] & 0777) === 0700 && $stat['uid'] === posix_geteuid()
            && realpath($this->directory) === $this->directory, 'receipt_directory');
    }
    private function checkFile(): void {
        clearstatcache(true, $this->path);
        $stat = lstat($this->path);
        review_game_require(is_array($stat) && ($stat['mode'] & 0170000) === 0100000
            && ($stat['mode'] & 0777) === 0600 && $stat['uid'] === posix_geteuid()
            && $stat['nlink'] === 1, 'receipt_file');
    }
    private function encode(): string { return json_encode($this->data, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT) . "\n"; }
    private function syncDirectory(): void {
        $handle = fopen($this->directory, 'rb');
        review_game_require(is_resource($handle), 'receipt_directory_open');
        try { review_game_require(fsync($handle), 'receipt_directory_sync'); }
        finally { fclose($handle); }
    }
    private function writeNew(string $path, string $body): void {
        review_game_require(!file_exists($path) && !is_link($path), 'receipt_already_exists');
        $handle = fopen($path, 'xb');
        review_game_require(is_resource($handle), 'receipt_create');
        try {
            review_game_require(chmod($path, 0600) && fwrite($handle, $body) === strlen($body)
                && fflush($handle) && fsync($handle), 'receipt_write');
        } finally { fclose($handle); }
        $this->syncDirectory();
    }
    public function save(): void {
        $this->checkDirectory(); $this->checkFile();
        $temporary = $this->path . '.' . bin2hex(random_bytes(8)) . '.tmp';
        $this->writeNew($temporary, $this->encode());
        review_game_require(rename($temporary, $this->path), 'receipt_replace');
        $this->syncDirectory();
    }
}

function review_game_planned_login(string $run, int $index): string {
    review_game_require(preg_match('/^[a-f0-9]{32}$/D', $run) === 1 && $index >= 0 && $index < 102, 'fixture_index');
    return 'rgli_' . $run . '_' . sprintf('%03d', $index);
}

/** A cleanup receipt is not permission to select arbitrary IDs/options. */
function review_game_validate_account(array $account, string $run, int $index): void {
    review_game_require(($account['login'] ?? '') === review_game_planned_login($run, $index)
        && isset($account['id']) && is_int($account['id']) && $account['id'] >= 0
        && isset($account['sessionHashes']) && is_array($account['sessionHashes'])
        && count($account['sessionHashes']) <= 3, 'cleanup_account');
    foreach ($account['sessionHashes'] as $hash) {
        review_game_require(is_string($hash) && preg_match('/^[a-f0-9]{64}$/D', $hash) === 1, 'cleanup_session');
    }
}

function review_game_existing_users_fingerprint(): string {
    global $wpdb;
    $users = $wpdb->get_results("SELECT ID, user_login, display_name FROM {$wpdb->users} ORDER BY ID", ARRAY_A);
    review_game_require(is_array($users) && $wpdb->last_error === '', 'baseline_users');
    $meta = $wpdb->get_results($wpdb->prepare(
        'SELECT user_id, meta_key, meta_value FROM %i WHERE meta_key IN (%s,%s,%s,%s) ORDER BY user_id, meta_key, umeta_id',
        $wpdb->usermeta, $wpdb->prefix . 'capabilities', Shuzijun_App_Content_API::FAN_META_STATUS,
        Shuzijun_App_Content_API::FAN_META_UUID, Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH), ARRAY_A);
    review_game_require(is_array($meta) && $wpdb->last_error === '', 'baseline_meta');
    return hash('sha256', serialize(array($users, $meta)));
}

function review_game_request(string $method, string $path, ?array $actor = null, $body = null): WP_REST_Response {
    review_game_require(in_array($path, array('/fan/game/leaderboard', '/fan/game/scores', '/fan/delete'), true), 'request_path');
    wp_set_current_user(0);
    $request = new WP_REST_Request($method, '/shuzijun/v1' . $path);
    $request->set_header('Content-Type', 'application/json');
    if ($actor !== null) {
        $request->set_header('Authorization', 'Bearer ' . $actor['token']);
        $request->set_header('X-Yishu-Install-ID', $actor['install']);
    }
    if ($body !== null) { $request->set_body(is_string($body) ? $body : json_encode($body, JSON_THROW_ON_ERROR)); }
    $response = rest_do_request($request);
    review_game_require($response instanceof WP_REST_Response, 'rest_response');
    return $response;
}

function review_game_status(WP_REST_Response $response, int $status, string $code): array {
    review_game_require($response->get_status() === $status && is_array($response->get_data()), $code);
    return $response->get_data();
}

/** Same strict page relationship checked by the native client, including own rank. */
function review_game_validate_page(array $page): void {
    review_game_require(array_keys($page) === array('rulesVersion', 'entries', 'myEntry')
        && $page['rulesVersion'] === 'life-v1' && is_array($page['entries']) && count($page['entries']) <= 100, 'page_shape');
    $mine = null;
    foreach ($page['entries'] as $index => $entry) {
        review_game_validate_entry($entry);
        review_game_require($entry['rank'] === $index + 1, 'page_rank');
        if ($entry['isMe']) { review_game_require($mine === null, 'page_duplicate_own'); $mine = $entry; }
        if ($index > 0) {
            $prior = $page['entries'][$index - 1];
            review_game_require($prior['score'] >= $entry['score']
                && ($prior['score'] !== $entry['score'] || strcmp($prior['achievedAt'], $entry['achievedAt']) <= 0), 'page_order');
        }
    }
    if ($page['myEntry'] !== null) {
        review_game_validate_entry($page['myEntry']);
        review_game_require($page['myEntry']['isMe'], 'page_own_identity');
        if ($page['myEntry']['rank'] <= count($page['entries'])) {
            review_game_require($page['entries'][$page['myEntry']['rank'] - 1] === $page['myEntry'], 'page_own_consistency');
        } else { review_game_require($mine === null && $page['myEntry']['rank'] > 100, 'page_outside_own'); }
    } else { review_game_require($mine === null, 'page_missing_own'); }
}

function review_game_validate_entry(array $entry): void {
    review_game_require(array_keys($entry) === array('rank', 'displayName', 'score', 'endingTitle', 'originName', 'answered', 'achievedAt', 'isMe')
        && is_int($entry['rank']) && $entry['rank'] >= 1 && is_int($entry['score'])
        && $entry['score'] >= -16777216 && $entry['score'] <= 16777215
        && is_int($entry['answered']) && $entry['answered'] >= 1 && $entry['answered'] <= 108
        && is_bool($entry['isMe']) && is_string($entry['achievedAt'])
        && preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/D', $entry['achievedAt']) === 1, 'entry_shape');
    foreach (array('displayName' => 40, 'endingTitle' => 80, 'originName' => 40) as $key => $limit) {
        review_game_require(is_string($entry[$key]) && preg_match('/^.{1,' . $limit . '}$/usD', $entry[$key]) === 1, 'entry_text');
    }
}

function review_game_read(array $actor): array {
    $queries = array();
    $capture = static function (string $sql) use (&$queries): string {
        if (str_starts_with($sql, 'SELECT candidate.fan_user_id,')) { $queries[] = $sql; }
        return $sql; // Observe the exact shipped SQL; never modify it.
    };
    add_filter('query', $capture, PHP_INT_MAX);
    try { $response = review_game_request('GET', '/fan/game/leaderboard', $actor); }
    finally { remove_filter('query', $capture, PHP_INT_MAX); }
    $page = review_game_status($response, 200, 'leaderboard_read');
    review_game_require(count($queries) === 1 && str_contains($queries[0], ') UNION (')
        && str_contains($queries[0], 'LIMIT 100)') && str_ends_with($queries[0], 'LIMIT 101'), 'single_real_projection');
    review_game_require(str_contains((string) ($response->get_headers()['Cache-Control'] ?? ''), 'no-store'), 'private_response');
    review_game_validate_page($page);
    return $page;
}

function review_game_create_actor(ReviewGameReceipt $receipt, int $index): array {
    global $wpdb;
    $account = $receipt->data['accounts'][$index];
    review_game_validate_account($account, $receipt->data['run'], $index);
    review_game_require($account['id'] === 0 && get_user_by('login', $account['login']) === false, 'fixture_exists');
    $password = bin2hex(random_bytes(32)) . 'aA9!';
    $id = wp_insert_user(array('user_login' => $account['login'], 'user_email' => $account['login'] . '@example.invalid',
        'user_pass' => $password, 'display_name' => 'Review Game ' . sprintf('%03d', $index), 'role' => 'subscriber'));
    review_game_require(is_int($id) && $id > 0, 'fixture_create');
    // Record the ID immediately; pre-recorded login handles a crash before here.
    $receipt->data['accounts'][$index]['id'] = $id; $receipt->save();
    review_game_require_new_install_identity($id);
    foreach (array('_yishu_review_game_run' => $receipt->data['run'],
        Shuzijun_App_Content_API::FAN_META_UUID => wp_generate_uuid4(),
        Shuzijun_App_Content_API::FAN_META_STATUS => $index === 101 ? 'pending' : 'active',
        Shuzijun_App_Content_API::FAN_META_DOUYIN_ID => 'rg.' . $receipt->data['run'] . '.' . $index,
        Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH => 1,
        Shuzijun_App_Content_API::FAN_META_ACCOUNT_SOURCE => 'password') as $key => $value) {
        update_user_meta($id, $key, $value);
        review_game_require(get_user_meta($id, $key, true) == $value, 'fixture_metadata');
    }
    review_game_require(!user_can($id, 'manage_options') && !user_can($id, Shuzijun_App_Content_API::CAPABILITY)
        && !user_can($id, Shuzijun_App_Content_API::FAN_CAPABILITY)
        && !user_can($id, Shuzijun_App_Content_API::PUSH_CAPABILITY), 'fixture_no_admin');
    $token = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
    $hash = hash('sha256', $token); $install = wp_generate_uuid4();
    review_game_require_new_install_identity($id, hash('sha256', $install));
    $receipt->data['accounts'][$index]['sessionHashes'][] = $hash; $receipt->save();
    // Explicit fixture provisioning, not a claim of password-login/HTTP testing.
    // All subsequent requests execute the real registered permission callback,
    // token/installation/epoch verifier, fresh database recheck and real SQL.
    $context = array('userID' => $id, 'expires' => time() + 1800, 'createdAt' => time(),
        'installHash' => hash('sha256', $install), 'installCode' => 'IN-ABC-234',
        'sessionID' => bin2hex(random_bytes(16)), 'scope' => 'normal', 'credentialEpoch' => 1,
        'authMethod' => 'password', 'recentAuthUntil' => 0);
    review_game_require(add_option(Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $hash, $context, '', false), 'fixture_session');
    update_user_meta($id, Shuzijun_App_Content_API::FAN_META_SESSIONS, array(array(
        'hash' => $hash, 'expires' => $context['expires'], 'createdAt' => $context['createdAt'],
        'sessionID' => $context['sessionID'], 'installCode' => $context['installCode'])));
    return array('id' => $id, 'token' => $token, 'install' => $install, 'password' => $password);
}

function review_game_score_row(int $id): ?array {
    global $wpdb;
    $row = $wpdb->get_row($wpdb->prepare('SELECT * FROM %i WHERE fan_user_id = %d', $wpdb->prefix . 'yishu_game_leaderboard', $id), ARRAY_A);
    review_game_require($wpdb->last_error === '', 'score_row_read');
    return $row;
}

function review_game_mvcc(array $actor, array $peer, string $transition): void {
    global $wpdb;
    review_game_require(in_array($transition, array('withdrawal', 'suspension'), true), 'mvcc_mode');
    $before = review_game_read($actor);
    review_game_require($before['myEntry']['rank'] === 101, 'mvcc_baseline');
    $other = mysqli_init();
    review_game_require($other instanceof mysqli, 'mvcc_initialize');
    $transaction = false;
    try {
        $other->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
        review_game_require($other->real_connect('localhost', DB_USER, DB_PASSWORD, 'shuzijun_review', 0,
            '/var/run/mysqld/mysqld.sock'), 'mvcc_connect');
        review_game_require($other->query('SELECT DATABASE()')->fetch_row()[0] === 'shuzijun_review', 'mvcc_database');
        review_game_require($other->begin_transaction(), 'mvcc_begin'); $transaction = true;
        $sql = $transition === 'withdrawal'
            ? $wpdb->prepare('DELETE FROM %i WHERE fan_user_id = %d', $wpdb->prefix . 'yishu_game_leaderboard', $peer['id'])
            : $wpdb->prepare('UPDATE %i SET meta_value = %s WHERE user_id = %d AND meta_key = %s AND meta_value = %s',
                $wpdb->usermeta, 'suspended', $peer['id'], Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
        review_game_require($other->query($sql) === true && $other->affected_rows === 1, 'mvcc_peer_write');
        // The second connection holds an actual uncommitted row change while
        // the main connection executes the exact unmodified production SELECT.
        $during = review_game_read($actor);
        review_game_require($during === $before, 'mvcc_uncommitted_not_visible');
        review_game_require($other->commit(), 'mvcc_commit'); $transaction = false;
        $after = review_game_read($actor);
        review_game_require($after['myEntry']['rank'] === 100 && count($after['entries']) === 100
            && $after['entries'][99] === $after['myEntry'], 'mvcc_committed_new_snapshot');
    } finally {
        if ($transaction) { $other->rollback(); }
        $other->close();
    }
}

function review_game_cleanup(ReviewGameReceipt $receipt): void {
    global $wpdb;
    $accounts = $receipt->data['accounts'] ?? null;
    review_game_require(is_array($accounts) && count($accounts) === 102 && array_is_list($accounts), 'cleanup_plan');
    foreach ($accounts as $index => $account) { review_game_validate_account($account, $receipt->data['run'], $index); }
    review_game_require(isset($receipt->data['installStatesBaseline']) && is_array($receipt->data['installStatesBaseline']), 'cleanup_install_baseline');
    review_game_require_untouched_push($receipt->data['installStatesBaseline']);
    require_once ABSPATH . 'wp-admin/includes/user.php';
    $receipt->data['state'] = 'cleaning'; $receipt->save();
    foreach ($accounts as $index => $account) {
        $user = get_user_by('login', $account['login']);
        if ($user instanceof WP_User) {
            $marker = get_user_meta($user->ID, '_yishu_review_game_run', true);
            review_game_require(($account['id'] === 0 || $account['id'] === (int) $user->ID)
                && $user->user_email === $account['login'] . '@example.invalid'
                && array_values($user->roles) === array('subscriber')
                && ($marker === $receipt->data['run'] || $marker === ''), 'cleanup_user_identity');
            $id = (int) $user->ID;
            $receipt->data['accounts'][$index]['id'] = $id; $receipt->save();
            review_game_require((string) $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i WHERE post_author = %d', $wpdb->posts, $id)) === '0'
                && $wpdb->last_error === '', 'fixture_has_no_content');
            review_game_require_new_install_identity($id);
            review_game_require_untouched_push($receipt->data['installStatesBaseline']);
            review_game_require(wp_delete_user($id), 'cleanup_core_delete');
            review_game_require_untouched_push($receipt->data['installStatesBaseline']);
        } else { $id = $account['id']; }
        if ($id > 0) {
            review_game_require(get_userdata($id) === false && review_game_score_row($id) === null, 'cleanup_user_and_score');
            review_game_require((string) $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i WHERE user_id = %d', $wpdb->usermeta, $id)) === '0'
                && $wpdb->last_error === '', 'cleanup_usermeta');
            foreach (array('game_read', 'game_submit', 'game_delete', 'fan_delete_failure') as $bucket) {
                $key = 'yishu_' . $bucket . '_' . hash('sha256', (string) $id);
                delete_transient($key);
                review_game_require(get_transient($key) === false, 'cleanup_actor_budget');
            }
        }
        foreach ($account['sessionHashes'] as $hash) {
            $option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $hash;
            $context = get_option($option, null);
            review_game_require($context === null || (is_array($context) && (int) ($context['userID'] ?? 0) === $id), 'cleanup_session_owner');
            delete_option($option);
            review_game_require(get_option($option, null) === null, 'cleanup_session_removed');
        }
        $receipt->data['accounts'][$index]['cleaned'] = true; $receipt->save();
    }
    $fingerprint = hash('sha256', review_game_fixture_ip($receipt->data['run']) . '|' . home_url('/'));
    delete_transient('yishu_fan_delete_net_' . hash('sha256', $fingerprint));
    review_game_require_untouched_push($receipt->data['installStatesBaseline']);
    review_game_require(review_game_existing_users_fingerprint() === $receipt->data['baselineUsersHash'], 'existing_users_unchanged');
    review_game_require((string) $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i', $wpdb->prefix . 'yishu_game_leaderboard')) === '0'
        && $wpdb->last_error === '', 'cleanup_empty_game_table');
    $receipt->data['state'] = 'cleaned'; $receipt->data['cleanedAt'] = gmdate('c'); $receipt->save();
}

function review_game_fixture_ip(string $run): string { return 'fd00:' . implode(':', str_split(substr($run, 0, 28), 4)); }

function review_game_run(ReviewGameReceipt $receipt): void {
    global $wpdb;
    review_game_require((new ReflectionMethod(Shuzijun_App_Content_API::class, 'game_leaderboard_storage_ready'))->invoke(null) === true,
        'install_schema_separately');
    review_game_require((string) $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i', $wpdb->prefix . 'yishu_game_leaderboard')) === '0'
        && $wpdb->last_error === '', 'existing_game_data');
    review_game_require_no_orphan_install_states();
    $receipt->data['installStatesBaseline'] = review_game_install_states_snapshot();
    $receipt->data['baselineUsersHash'] = review_game_existing_users_fingerprint();
    for ($index = 0; $index < 102; ++$index) {
        $login = review_game_planned_login($receipt->data['run'], $index);
        review_game_require(get_user_by('login', $login) === false, 'planned_login_exists');
        $receipt->data['accounts'][] = array('login' => $login, 'id' => 0, 'sessionHashes' => array(), 'cleaned' => false);
    }
    $receipt->data['state'] = 'creating'; $receipt->save();
    $actors = array();
    for ($index = 0; $index < 102; ++$index) { $actors[] = review_game_create_actor($receipt, $index); }
    $receipt->data['state'] = 'testing'; $receipt->save();
    $_SERVER['REMOTE_ADDR'] = review_game_fixture_ip($receipt->data['run']);
    unset($_SERVER['HTTP_X_YISHU_CLIENT_IP'], $_SERVER['PHP_AUTH_USER'], $_SERVER['PHP_AUTH_PW']);
    $a = $actors[0]; $b = $actors[1]; $pending = $actors[101];
    $full = array_fill(0, 108, 0); $full[2] = 1;
    $early = array_merge(array_fill(0, 20, 3), array_fill(0, 42, 2));
    $payload = array('rulesVersion' => 'life-v1', 'origin' => 'business', 'choices' => $full, 'consent' => true);
    $teacher = array_replace($payload, array('origin' => 'teacher'));
    foreach (array('GET' => '/fan/game/leaderboard', 'POST' => '/fan/game/scores', 'DELETE' => '/fan/game/scores') as $method => $path) {
        review_game_status(review_game_request($method, $path, null, $method === 'POST' ? $payload : null), 401, 'anonymous_denied');
        review_game_status(review_game_request($method, $path, $pending, $method === 'POST' ? $payload : null), 403, 'pending_denied');
    }
    update_user_meta($pending['id'], Shuzijun_App_Content_API::FAN_META_STATUS, 'suspended');
    review_game_status(review_game_request('GET', '/fan/game/leaderboard', $pending), 403, 'suspended_denied');
    update_user_meta($pending['id'], Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
    delete_user_meta($pending['id'], Shuzijun_App_Content_API::FAN_META_DOUYIN_ID);
    review_game_status(review_game_request('GET', '/fan/game/leaderboard', $pending), 403, 'incomplete_account_denied');
    update_user_meta($pending['id'], Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, 'rg.' . $receipt->data['run'] . '.101');
    $pending_option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . hash('sha256', $pending['token']);
    $pending_context = get_option($pending_option);
    review_game_require(is_array($pending_context), 'fixture_context_exists');
    update_option($pending_option, array_replace($pending_context, array('scope' => 'onboarding')), false);
    review_game_status(review_game_request('GET', '/fan/game/leaderboard', $pending), 403, 'restricted_scope_denied');
    update_option($pending_option, $pending_context, false);
    update_user_meta($pending['id'], Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH, 2);
    review_game_status(review_game_request('GET', '/fan/game/leaderboard', $pending), 401, 'revoked_epoch_denied');
    $low = review_game_status(review_game_request('POST', '/fan/game/scores', $a,
        array_replace($payload, array('choices' => $early))), 200, 'negative_score_submit');
    review_game_require($low['myEntry']['score'] === -214 && $low['myEntry']['answered'] === 62, 'negative_score_replay');
    $high = review_game_status(review_game_request('POST', '/fan/game/scores', $a, $payload), 200, 'high_score_submit');
    review_game_require($high['myEntry']['score'] === 12966 && $high['myEntry']['answered'] === 108, 'full_score_replay');
    $saved = review_game_score_row($a['id']);
    review_game_status(review_game_request('POST', '/fan/game/scores', $a, $payload), 200, 'same_score_retry');
    review_game_status(review_game_request('POST', '/fan/game/scores', $a,
        array_replace($payload, array('choices' => $early))), 200, 'lower_score_retry');
    review_game_require(review_game_score_row($a['id']) === $saved, 'highest_one_tie_time_unchanged');
    foreach (array(array_replace($payload, array('score' => 16777215)), array_replace($payload, array('userID' => $b['id'])),
        array_replace($payload, array('choices' => (object) $full))) as $invalid) {
        review_game_status(review_game_request('POST', '/fan/game/scores', $a, $invalid), 400, 'client_forgery_denied');
    }
    review_game_status(review_game_request('POST', '/fan/game/scores', $b, $teacher), 200, 'peer_submit');
    $b_saved = review_game_score_row($b['id']);
    review_game_status(review_game_request('DELETE', '/fan/game/scores', $a, array('userID' => $b['id'])), 400, 'cross_user_withdraw_denied');
    review_game_require(review_game_score_row($a['id']) === $saved && review_game_score_row($b['id']) === $b_saved, 'forgery_writes_nothing');
    $withdrawn = review_game_status(review_game_request('DELETE', '/fan/game/scores', $b), 200, 'self_withdraw');
    review_game_require($withdrawn['myEntry'] === null && review_game_score_row($b['id']) === null
        && review_game_score_row($a['id']) === $saved, 'only_own_score_removed');
    review_game_status(review_game_request('DELETE', '/fan/game/scores', $b), 200, 'self_withdraw_idempotent');
    review_game_status(review_game_request('POST', '/fan/game/scores', $b, $teacher), 200, 'peer_resubmit');
    for ($index = 2; $index <= 100; ++$index) {
        review_game_status(review_game_request('POST', '/fan/game/scores', $actors[$index], $teacher), 200, 'top100_fixture_submit');
    }
    $page = review_game_read($a);
    review_game_require(count($page['entries']) === 100 && $page['myEntry']['rank'] === 101
        && count(array_filter($page['entries'], static fn($entry) => $entry['isMe'])) === 0, 'top100_plus_own');
    wp_update_user(array('ID' => $a['id'], 'display_name' => 'HS-ABCD-2345'));
    review_game_require(review_game_read($a)['myEntry']['displayName'] === '玩家', 'identity_name_redacted');
    wp_update_user(array('ID' => $a['id'], 'display_name' => 'Review Game 000'));
    review_game_mvcc($a, $actors[2], 'withdrawal');
    review_game_status(review_game_request('POST', '/fan/game/scores', $actors[2], $teacher), 200, 'mvcc_restore_withdrawn_peer');
    review_game_mvcc($a, $actors[3], 'suspension');
    wp_cache_delete($actors[3]['id'], 'user_meta');
    update_user_meta($actors[3]['id'], Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
    review_game_require(review_game_read($a)['myEntry']['rank'] === 101, 'mvcc_restore_suspended_peer');
    review_game_require_untouched_push($receipt->data['installStatesBaseline']);
    review_game_status(review_game_request('POST', '/fan/delete', $b, array('installID' => $b['install'],
        'currentPassword' => $b['password'], 'confirmation' => 'DELETE_ACCOUNT')), 200, 'real_account_delete_endpoint');
    review_game_require_untouched_push($receipt->data['installStatesBaseline']);
    review_game_require(get_userdata($b['id']) === false && review_game_score_row($b['id']) === null, 'account_delete_purges_score');
    review_game_status(review_game_request('GET', '/fan/game/leaderboard', $b), 401, 'deleted_session_denied');
    review_game_require(review_game_read($a)['myEntry']['rank'] === 100, 'account_delete_updates_rank');
    $receipt->data['evidence'] = array('registeredRestDispatch' => true, 'actualBearerVerifier' => true,
        'syntheticSessionProvisioning' => true, 'realMySQLProjection' => true, 'twoConnectionMVCC' => true,
        'uncommittedReadAndPostCommitRead' => true, 'httpTLSOrLoginTested' => false,
        'commitDuringSingleStatementTested' => false, 'fixtureCount' => 102);
    $receipt->data['acceptancePassed'] = true;
    $receipt->data['state'] = 'passed'; $receipt->save();
    unset($actors, $a, $b, $pending);
    review_game_cleanup($receipt);
}

function review_game_main(array $arguments): void {
    [$mode, $run] = review_game_arguments($arguments);
    $evidence = review_game_preflight();
    if ($mode === 'preflight') { echo "review-game: read-only preflight passed; no harness mutations\n"; return; }
    $parent = '/srv/shuzijun-review/tmp';
    $directory = $parent . '/game-leaderboard-integration';
    $stat = lstat($parent);
    review_game_require(is_array($stat) && realpath($parent) === $parent && ($stat['mode'] & 0777) === 0700
        && $stat['uid'] === posix_geteuid(), 'private_parent');
    $previous_umask = umask(0077);
    $receipt = null; $lock = null;
    try {
        if (!file_exists($directory) && !is_link($directory)) { review_game_require(mkdir($directory, 0700), 'private_directory_create'); }
        $directory_stat = lstat($directory);
        review_game_require(is_array($directory_stat) && ($directory_stat['mode'] & 0170000) === 0040000
            && ($directory_stat['mode'] & 0777) === 0700 && $directory_stat['uid'] === posix_geteuid()
            && realpath($directory) === $directory, 'private_directory');
        $lock_path = $directory . '/operation.lock';
        review_game_require(!is_link($lock_path), 'operation_lock_link');
        $lock = fopen($lock_path, 'c+b');
        review_game_require(is_resource($lock) && flock($lock, LOCK_EX | LOCK_NB), 'operation_lock_busy');
        $lock_stat = fstat($lock);
        review_game_require($lock_stat['uid'] === posix_geteuid() && ($lock_stat['mode'] & 0777) === 0600
            && $lock_stat['nlink'] === 1, 'operation_lock_permissions');
        $receipt = new ReviewGameReceipt($directory, $run, $mode === 'install-schema' ? 'schema' : 'run', $mode === 'cleanup');
        if ($mode === 'cleanup') {
            review_game_cleanup($receipt);
        } else {
            $receipt->data['candidate'] = $evidence; $receipt->save();
            if ($mode === 'install-schema') {
                review_game_require(Shuzijun_App_Content_API::ensure_game_leaderboard_storage(), 'schema_install');
                review_game_require_untouched_push($evidence['installStatesBaseline']);
                $receipt->data['state'] = 'installed'; $receipt->save();
            } else { review_game_run($receipt); }
        }
        echo match ($mode) {
            'install-schema' => "review-game: explicit review schema installation passed; no fixture accounts created\n",
            'cleanup' => "review-game: exact-run cleanup passed; acceptance remains recorded separately in the private receipt\n",
            default => "review-game: actual WP REST/MySQL acceptance and exact-run cleanup passed; private receipt retained; not HTTP/TLS or mid-statement commit proof\n",
        };
    } catch (Throwable $error) {
        if ($receipt !== null) {
            $receipt->data['state'] = 'failed';
            $receipt->data['failure'] = $error instanceof ReviewGameFailure ? $error->getMessage() : 'runtime_failure';
            $receipt->save();
        }
        throw $error;
    } finally {
        if (is_resource($lock)) { flock($lock, LOCK_UN); fclose($lock); }
        umask($previous_umask);
    }
}

// The library-only switch is for local pure tests, not an alternate execution
// mode: every mutating main path still performs the fixed review preflight.
if (!defined('YISHU_REVIEW_GAME_HARNESS_LIBRARY_ONLY')) {
    try { review_game_main(isset($args) && is_array($args) ? $args : array_slice($_SERVER['argv'] ?? array(), 1)); }
    catch (Throwable $error) {
        $code = $error instanceof ReviewGameFailure ? $error->getMessage() : 'runtime_failure';
        fwrite(STDERR, 'review-game: failed (' . $code . "); no credentials emitted; inspect private receipt if created\n");
        exit(1);
    }
}
