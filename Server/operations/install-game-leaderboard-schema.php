<?php
declare(strict_types=1);

/**
 * Explicit, production-authority-only schema setup. No WP-CLI dependency.
 * /usr/bin/php8.3 THIS_FILE backup=/PRIVATE/ROOT/OWNED/DUMP sha256=64_LOWERCASE_HEX
 * The same command with one additional positional `apply` permits first creation.
 * Default is preflight. The operator creates/verifies the database dump separately.
 * Dump bytes are only streamed through SHA-256, never parsed, retained or printed.
 * A matching digest is not evidence that a dump can be restored.
 *
 * Run from a root-owned, non-writable-parent location, with outbound network denied.
 * The existing site-operation lock excludes deployment/signed sync. The operator
 * must exclude other manual DDL. No explicit REST dispatch, account, push or mail
 * operation is performed; this is not a whole-WordPress no-write assertion.
 * The fixed API's init maintenance is fenced in this process, not in the plugin.
 * A failure after apply begins is an unknown/partial outcome: inspect, never retry
 * automatically. No table drop, data deletion, schema repair or database rollback.
 */

final class GameSchemaFailure extends RuntimeException {
    public ?string $diagnostic = null;
}
final class GameSchemaDiagnostics {
    public static string $stage = 'startup';
}
const GAME_SCHEMA_SITE = '/var/www/html/shuzijun.com.cn';
const GAME_SCHEMA_MANIFEST = '3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576';
const GAME_SCHEMA_OPTION = 'yishu_game_leaderboard_schema_version';

function game_schema_stage(string $stage): void {
    game_schema_require(in_array($stage, array('startup', 'arguments', 'runtime_guard', 'helper_permissions',
        'operation_lock', 'backup_verify', 'authority_verify', 'candidate_verify', 'bootstrap',
        'runtime_verify', 'candidate_recheck', 'snapshot_before', 'snapshot_recheck', 'ensure',
        'snapshot_after', 'report', 'unlock'), true), 'diagnostic_stage');
    GameSchemaDiagnostics::$stage = $stage;
}

/** Fixed metadata only. Never include warning text, absolute paths or traces. */
function game_schema_diagnostic(int $level, string $file, int $line): string {
    $name = basename($file);
    $allowed = array('install-game-leaderboard-schema.php', 'wp-load.php', 'wp-config.php', 'wp-settings.php',
        'load.php', 'functions.php', 'class-wpdb.php', 'class-wp-hook.php', 'plugin.php', 'default-constants.php',
        'option.php', 'formatting.php', 'upgrade.php', 'shuzijun-app-content.php',
        'class-shuzijun-app-content-api.php', 'class-shuzijun-game-rules.php',
        'trait-shuzijun-app-game-leaderboard.php');
    if (!in_array($name, $allowed, true)) { $name = 'other'; }
    if (!in_array($level, array(0, E_ERROR, E_WARNING, E_PARSE, E_NOTICE, E_CORE_ERROR, E_CORE_WARNING,
        E_COMPILE_ERROR, E_COMPILE_WARNING, E_USER_ERROR, E_USER_WARNING, E_USER_NOTICE, E_STRICT,
        E_RECOVERABLE_ERROR, E_DEPRECATED, E_USER_DEPRECATED), true)) { $level = 0; }
    return 'stage=' . GameSchemaDiagnostics::$stage . '; file=' . $name
        . '; line=' . max(0, min($line, 1000000)) . '; level=' . $level;
}

function game_schema_warning(int $level, string $unusedMessage, string $file, int $line): bool {
    // PHP still invokes a custom handler for @lstat/@fopen. Respect suppression:
    // their false result is checked by the existing explicit fail-closed guard.
    if ((error_reporting() & $level) === 0) { return false; }
    $failure = new GameSchemaFailure('runtime_warning');
    $failure->diagnostic = game_schema_diagnostic($level, $file, $line);
    throw $failure;
}

function game_schema_require(bool $condition, string $stage): void {
    if (!$condition) { throw new GameSchemaFailure($stage); }
}

function game_schema_arguments(array $arguments): array {
    $result = array('apply' => false);
    foreach ($arguments as $argument) {
        game_schema_require(is_string($argument), 'arguments');
        if ($argument === 'apply') {
            game_schema_require($result['apply'] === false, 'arguments');
            $result['apply'] = true;
        } elseif (preg_match('/^(backup|sha256)=(.+)$/D', $argument, $match) === 1) {
            game_schema_require(!isset($result[$match[1]]), 'arguments');
            $result[$match[1]] = $match[2];
        } else { throw new GameSchemaFailure('arguments'); }
    }
    game_schema_require(isset($result['backup'], $result['sha256'])
        && preg_match('/^[a-f0-9]{64}$/D', $result['sha256']) === 1, 'arguments');
    game_schema_require(str_starts_with($result['backup'], '/') && strlen($result['backup']) <= 4096
        && preg_match('/[\x00-\x20\x7f]/', $result['backup']) === 0
        && !str_contains($result['backup'], '//')
        && !preg_match('~/(?:\.|\.\.)(?:/|$)~', $result['backup'])
        && !str_starts_with($result['backup'], GAME_SCHEMA_SITE . '/')
        && $result['backup'] !== GAME_SCHEMA_SITE, 'backup_path');
    return $result;
}

/** Pure stat policy; file contents and error paths are never put in output. */
function game_schema_validate_stat(array $stat, int $mode, bool $private): void {
    game_schema_require(($stat['mode'] & 0170000) === 0100000
        && ($stat['mode'] & 07777) === $mode && ($stat['uid'] ?? -1) === 0
        && (!$private || ($stat['gid'] ?? -1) === 0)
        && ($stat['nlink'] ?? 0) === 1, 'file_permissions');
}

function game_schema_safe_parents(string $path, bool $privateParent = false): void {
    $parent = dirname($path);
    if ($privateParent) {
        $stat = @lstat($parent);
        game_schema_require(is_array($stat) && ($stat['mode'] & 07777) === 0700
            && ($stat['gid'] ?? -1) === 0, 'private_parent');
    }
    while (true) {
        $stat = @lstat($parent);
        game_schema_require(is_array($stat) && ($stat['mode'] & 0170000) === 0040000
            && ($stat['uid'] ?? -1) === 0 && ($stat['mode'] & 0022) === 0
            && !is_link($parent) && realpath($parent) === $parent, 'parent_permissions');
        if ($parent === '/') { break; }
        $parent = dirname($parent);
    }
}

function game_schema_same_file(array $before, array $after): bool {
    foreach (array('dev', 'ino', 'size', 'mtime', 'ctime', 'mode', 'uid', 'gid', 'nlink') as $key) {
        if (!isset($before[$key], $after[$key]) || $before[$key] !== $after[$key]) { return false; }
    }
    return true;
}

function game_schema_verify_file(string $path, string $expected, bool $private = false): array {
    game_schema_safe_parents($path, $private);
    clearstatcache(true, $path);
    $before = @lstat($path);
    game_schema_require(is_array($before) && !is_link($path) && realpath($path) === $path, 'file_path');
    game_schema_validate_stat($before, $private ? 0600 : 0644, $private);
    game_schema_require($before['size'] > 0, 'empty_file');
    $stream = @fopen($path, 'rb');
    game_schema_require(is_resource($stream), 'file_open');
    try {
        game_schema_require(game_schema_same_file($before, fstat($stream)), 'file_changed');
        $context = hash_init('sha256');
        game_schema_require(hash_update_stream($context, $stream) === $before['size'], 'file_read');
        $digest = hash_final($context);
        clearstatcache(true, $path);
        $after = @lstat($path);
        game_schema_require(is_array($after) && game_schema_same_file($before, $after)
            && game_schema_same_file($before, fstat($stream)) && hash_equals($expected, $digest), 'file_digest');
        return array('sha256' => $digest, 'bytes' => $before['size']);
    } finally { fclose($stream); }
}

function game_schema_verify_candidate(): void {
    $root = GAME_SCHEMA_SITE . '/wp-content/mu-plugins/';
    $manifest = $root . 'release.sha256';
    $metadata = game_schema_verify_file($manifest, GAME_SCHEMA_MANIFEST);
    game_schema_require($metadata['bytes'] < 65536, 'manifest_size');
    $bytes = file_get_contents($manifest);
    game_schema_require(is_string($bytes) && hash_equals(GAME_SCHEMA_MANIFEST, hash('sha256', $bytes))
        && str_ends_with($bytes, "\n"), 'manifest_digest');
    $lines = explode("\n", substr($bytes, 0, -1));
    game_schema_require(count($lines) === 37, 'manifest_count');
    $seen = array();
    foreach ($lines as $line) {
        game_schema_require(preg_match('~^([a-f0-9]{64})  ([A-Za-z0-9_./-]+)$~D', $line, $match) === 1, 'manifest_format');
        $relative = $match[2];
        game_schema_require(!str_starts_with($relative, '/') && !str_contains($relative, '..')
            && !isset($seen[$relative]), 'manifest_path');
        $seen[$relative] = true;
        game_schema_verify_file($root . $relative, $match[1]);
    }
}

function game_schema_lock() {
    $path = '/var/lib/shuzijun-sync/site-operation.lock';
    game_schema_safe_parents($path, true);
    $before = @lstat($path);
    game_schema_require(is_array($before) && realpath($path) === $path && !is_link($path), 'lock_path');
    game_schema_validate_stat($before, 0600, true);
    game_schema_require($before['size'] === 0, 'lock_size');
    $stream = @fopen($path, 'rb'); // Existing lock only; never create or truncate.
    game_schema_require(is_resource($stream), 'lock_open');
    if (!game_schema_same_file($before, fstat($stream)) || !flock($stream, LOCK_EX | LOCK_NB)) {
        fclose($stream); throw new GameSchemaFailure('lock_busy_or_changed');
    }
    clearstatcache(true, $path);
    $after = @lstat($path);
    if (!is_array($after) || !game_schema_same_file($before, $after)) {
        flock($stream, LOCK_UN); fclose($stream); throw new GameSchemaFailure('lock_changed');
    }
    return $stream;
}

/** Minimal, fixed front-controller environment expected by WordPress load.php. */
function game_schema_server_environment(): array {
    return array('HTTP_HOST' => 'www.shuzijun.com.cn', 'SERVER_NAME' => 'www.shuzijun.com.cn',
        'HTTPS' => 'on', 'SERVER_PORT' => '443', 'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/',
        'REMOTE_ADDR' => '127.0.0.1', 'SERVER_PROTOCOL' => 'HTTP/1.1',
        'PHP_SELF' => '/index.php', 'SCRIPT_NAME' => '/index.php',
        'SCRIPT_FILENAME' => GAME_SCHEMA_SITE . '/index.php');
}

/** The reviewed API's complete init set; never disable another plugin's hooks. */
function game_schema_init_maintenance(): array {
    return array('ensure_roles' => 20, 'ensure_push_storage' => 22,
        'ensure_fan_apple_revocation_schedule' => 40, 'ensure_fan_apple_event_schedule' => 41,
        'ensure_fan_apple_tombstone_schedule' => 42, 'ensure_push_outbox_schedule' => 44,
        'ensure_collaboration_storage' => 21, 'ensure_collaboration_outbox_schedule' => 43);
}

/** Inspect real WP_Hook callbacks, including equivalent string/case forms. */
function game_schema_api_init_callbacks(): array {
    $hook = $GLOBALS['wp_filter']['init'] ?? null;
    game_schema_require(is_object($hook) && isset($hook->callbacks) && is_array($hook->callbacks), 'init_hook_shape');
    $result = array();
    foreach ($hook->callbacks as $priority => $callbacks) {
        game_schema_require(is_array($callbacks), 'init_hook_shape');
        foreach ($callbacks as $entry) {
            game_schema_require(is_array($entry) && isset($entry['function']), 'init_hook_shape');
            $callback = $entry['function'];
            $parts = is_string($callback) ? explode('::', $callback) : $callback;
            if (!is_array($parts) || count($parts) !== 2 || !isset($parts[0], $parts[1])
                || !is_string($parts[1])) { continue; }
            $class = is_object($parts[0]) ? get_class($parts[0]) : $parts[0];
            if (!is_string($class) || strtolower(ltrim($class, '\\')) !== 'shuzijun_app_content_api') { continue; }
            $result[] = array('method' => strtolower($parts[1]), 'priority' => $priority, 'callback' => $callback);
        }
    }
    return $result;
}

function game_schema_remove_init_maintenance(): void {
    game_schema_require(class_exists('Shuzijun_App_Content_API', false) && function_exists('remove_action'), 'init_api_missing');
    $allowed = game_schema_init_maintenance();
    $found = game_schema_api_init_callbacks();
    $seen = array();
    foreach ($found as $entry) {
        $method = $entry['method'];
        game_schema_require(isset($allowed[$method]) && !isset($seen[$method])
            && $entry['priority'] === $allowed[$method], 'init_maintenance_changed');
        $seen[$method] = true;
    }
    foreach (array_slice(array_keys($allowed), 0, 6) as $method) {
        game_schema_require(isset($seen[$method]), 'init_maintenance_missing');
    }
    game_schema_require(isset($seen['ensure_collaboration_storage'])
        === isset($seen['ensure_collaboration_outbox_schedule']), 'init_collaboration_pair');
    foreach ($found as $entry) {
        game_schema_require(remove_action('init', $entry['callback'], $entry['priority']) === true, 'init_remove_failed');
    }
    game_schema_require_init_isolation();
}

function game_schema_require_init_isolation(): void {
    // Runs again at init's earliest priority: later plugin/theme registration is
    // an unknown bootstrap, so abort before any reviewed maintenance can run.
    game_schema_require(game_schema_api_init_callbacks() === array(), 'init_maintenance_reintroduced');
}

function game_schema_register_init_isolation(): void {
    $GLOBALS['wp_filter']['muplugins_loaded'][PHP_INT_MAX][] = array(
        'function' => 'game_schema_remove_init_maintenance', 'accepted_args' => 0);
    $GLOBALS['wp_filter']['init'][PHP_INT_MIN][] = array(
        'function' => 'game_schema_require_init_isolation', 'accepted_args' => 0);
}

function game_schema_bootstrap(): void {
    game_schema_require(!defined('ABSPATH') && !isset($GLOBALS['wpdb']), 'already_bootstrapped');
    foreach (array('DISABLE_WP_CRON', 'WP_HTTP_BLOCK_EXTERNAL', 'DISALLOW_FILE_MODS', 'REST_REQUEST') as $name) {
        game_schema_require(!defined($name) || constant($name) === true, 'bootstrap_constants');
        if (!defined($name)) { define($name, true); }
    }
    define('WP_USE_THEMES', false);
    $_SERVER = game_schema_server_environment();
    $_GET = $_POST = $_COOKIE = $_REQUEST = array();
    // WordPress converts these preinitialized filters to WP_Hook during bootstrap.
    $GLOBALS['wp_filter']['pre_wp_mail'][PHP_INT_MAX][] = array('function' => static fn() => false, 'accepted_args' => 0);
    $GLOBALS['wp_filter']['pre_http_request'][PHP_INT_MAX][] = array(
        'function' => static fn() => new WP_Error('schema_network_denied'), 'accepted_args' => 0);
    game_schema_register_init_isolation();
    require GAME_SCHEMA_SITE . '/wp-load.php';
    game_schema_require_init_isolation();
}

function game_schema_verify_runtime(): void {
    global $wpdb;
    game_schema_require(defined('ABSPATH') && ABSPATH === GAME_SCHEMA_SITE . '/'
        && realpath(ABSPATH) === GAME_SCHEMA_SITE && defined('DB_NAME') && DB_NAME === 'wordpress'
        && isset($wpdb) && class_exists('Shuzijun_App_Content_API') && class_exists('Shuzijun_Game_Rules'), 'runtime_site');
    $wpdb->hide_errors();
    game_schema_require($wpdb->get_var('SELECT DATABASE()') === 'wordpress' && $wpdb->last_error === '', 'runtime_database');
    game_schema_require(Shuzijun_App_Content_API::account_authority_enabled() === true
        && (new ReflectionMethod('Shuzijun_App_Content_API', 'app_service_environment'))->invoke(null) === 'production'
        && home_url() === 'https://www.shuzijun.com.cn' && site_url() === 'https://www.shuzijun.com.cn', 'runtime_authority');
    foreach (array(
        'Shuzijun_App_Content_API' => 'class-shuzijun-app-content-api.php',
        'Shuzijun_App_Game_Leaderboard' => 'trait-shuzijun-app-game-leaderboard.php',
        'Shuzijun_Game_Rules' => 'class-shuzijun-game-rules.php',
    ) as $class => $file) {
        game_schema_require((new ReflectionClass($class))->getFileName()
            === GAME_SCHEMA_SITE . '/wp-content/mu-plugins/vendor/shuzijun/app-content/' . $file, 'runtime_class_source');
    }
    game_schema_require(Shuzijun_App_Content_API::GAME_SCHEMA_OPTION === GAME_SCHEMA_OPTION
        && Shuzijun_App_Content_API::GAME_SCHEMA_VERSION === 1
        && Shuzijun_Game_Rules::bundled()->hash() === 'b15b84299a91a5658b71d51e35062c1835b7f57538e3bc120027dc44c424129f', 'runtime_rules');
    game_schema_require(preg_match('/^[A-Za-z0-9_]+$/D', (string) $wpdb->prefix) === 1
        && $wpdb->options === $wpdb->prefix . 'options', 'runtime_prefix');
}

/** Strict extra shape checks supplement, not replace, the actual readiness method. */
function game_schema_validate_shape(array $columns, array $indexes): void {
    game_schema_require(count($columns) === 7 && count($indexes) === 4, 'schema_shape');
    $expected = array('fan_user_id' => '/^bigint(?:\(20\))? unsigned$/D', 'rules_version' => '/^varchar\(32\)$/D',
        'score' => '/^int(?:\(11\))?$/D', 'ending_id' => '/^varchar\(64\)$/D', 'origin' => '/^varchar\(32\)$/D',
        'answered' => '/^smallint(?:\(5\))? unsigned$/D', 'achieved_at' => '/^datetime$/D');
    game_schema_require(array_column($columns, 'Field') === array_keys($expected), 'schema_columns');
    foreach ($columns as $column) {
        game_schema_require(preg_match($expected[$column['Field']], strtolower((string) ($column['Type'] ?? ''))) === 1
            && ($column['Null'] ?? '') === 'NO' && array_key_exists('Default', $column) && $column['Default'] === null
            && ($column['Extra'] ?? null) === '', 'schema_column_definition');
    }
    $actual = array();
    foreach ($indexes as $index) {
        $name = $index['Key_name'] ?? ''; $sequence = (int) ($index['Seq_in_index'] ?? 0);
        game_schema_require(in_array($name, array('PRIMARY', 'score_time_user'), true)
            && $sequence > 0 && !isset($actual[$name][$sequence])
            && (string) ($index['Non_unique'] ?? '') === ($name === 'PRIMARY' ? '0' : '1')
            && ($index['Sub_part'] ?? null) === null && ($index['Index_type'] ?? '') === 'BTREE'
            && ($index['Collation'] ?? '') === 'A' && ($index['Null'] ?? null) === ''
            && (!isset($index['Visible']) || $index['Visible'] === 'YES')
            && ($index['Expression'] ?? null) === null, 'schema_index_definition');
        $actual[$name][$sequence] = $index['Column_name'] ?? '';
    }
    foreach (array('PRIMARY' => array(1 => 'fan_user_id'),
        'score_time_user' => array(1 => 'score', 2 => 'achieved_at', 3 => 'fan_user_id')) as $name => $expectedIndex) {
        game_schema_require(isset($actual[$name]), 'schema_index_missing');
        ksort($actual[$name]); game_schema_require($actual[$name] === $expectedIndex, 'schema_index_columns');
    }
}

function game_schema_snapshot(): array {
    global $wpdb;
    $table = $wpdb->prefix . 'yishu_game_leaderboard';
    $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
    game_schema_require($wpdb->last_error === '' && ($found === null || $found === $table), 'table_probe');
    $options = $wpdb->get_results($wpdb->prepare('SELECT option_value, autoload FROM %i WHERE option_name = %s',
        $wpdb->options, GAME_SCHEMA_OPTION), ARRAY_A);
    game_schema_require(is_array($options) && $wpdb->last_error === '', 'option_probe');
    if ($found === null) {
        game_schema_require($options === array(), 'orphan_schema_option');
        return array('state' => 'absent', 'rows' => 0);
    }
    game_schema_require(count($options) === 1 && ($options[0]['option_value'] ?? null) === '1'
        && in_array($options[0]['autoload'] ?? null, array('no', 'off', 'auto-off'), true), 'unknown_existing_option');
    game_schema_require((new ReflectionMethod('Shuzijun_App_Content_API', 'game_leaderboard_storage_ready'))->invoke(null) === true,
        'actual_readiness');
    $status = $wpdb->get_row($wpdb->prepare('SHOW TABLE STATUS LIKE %s', $wpdb->esc_like($table)), ARRAY_A);
    game_schema_require(is_array($status) && $wpdb->last_error === '' && ($status['Name'] ?? '') === $table
        && strtoupper((string) ($status['Engine'] ?? '')) === 'INNODB', 'schema_engine');
    $columns = $wpdb->get_results($wpdb->prepare('SHOW COLUMNS FROM %i', $table), ARRAY_A);
    game_schema_require(is_array($columns) && $wpdb->last_error === '', 'schema_columns_query');
    $indexes = $wpdb->get_results($wpdb->prepare('SHOW INDEX FROM %i', $table), ARRAY_A);
    game_schema_require(is_array($indexes) && $wpdb->last_error === '', 'schema_indexes_query');
    game_schema_validate_shape($columns, $indexes);
    // Reject hidden trigger/foreign-key side effects on a preexisting table.
    $extras = $wpdb->get_var($wpdb->prepare('SELECT
        (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = %s) +
        (SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = %s)', $table, $table));
    game_schema_require((string) $extras === '0' && $wpdb->last_error === '', 'schema_extras');
    $rows = $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM %i', $table));
    game_schema_require(is_string($rows) && preg_match('/^(0|[1-9][0-9]*)$/D', $rows) === 1
        && $wpdb->last_error === '', 'schema_rows');
    return array('state' => 'installed', 'rows' => (int) $rows);
}

/** Testable sequencing; production callbacks below always call the real API. */
function game_schema_execute(bool $apply, callable $snapshot, callable $install): string {
    game_schema_stage('snapshot_before');
    $before = $snapshot();
    game_schema_require(in_array($before['state'] ?? null, array('absent', 'installed'), true), 'schema_state');
    if (!$apply) { return $before['state'] === 'absent' ? 'preflight_absent' : 'preflight_installed'; }
    if ($before['state'] === 'installed') { return 'already_installed_no_change'; }
    game_schema_stage('snapshot_recheck');
    game_schema_require($snapshot() === $before, 'schema_changed_before_apply');
    game_schema_stage('ensure');
    game_schema_require($install() === true, 'ensure_failed_outcome_requires_inspection');
    game_schema_stage('snapshot_after');
    $after = $snapshot();
    game_schema_require(($after['state'] ?? null) === 'installed' && ($after['rows'] ?? null) === 0,
        'post_apply_requires_inspection');
    return 'installed_verified_zero_rows';
}

function game_schema_main(array $arguments): void {
    game_schema_stage('arguments');
    $options = game_schema_arguments($arguments);
    game_schema_stage('runtime_guard');
    game_schema_require(PHP_SAPI === 'cli' && PHP_VERSION_ID >= 80300 && PHP_VERSION_ID < 80400
        && function_exists('posix_geteuid') && posix_geteuid() === 0, 'root_php83_cli_required');
    game_schema_require(in_array(ini_get('opcache.enable_cli'), array(false, '', '0'), true)
        && ini_get('auto_prepend_file') === '' && ini_get('auto_append_file') === '', 'isolated_cli_configuration');
    game_schema_require(!defined('ABSPATH'), 'standalone_only');
    game_schema_stage('helper_permissions');
    game_schema_safe_parents(__FILE__);
    $self = @lstat(__FILE__);
    game_schema_require(is_array($self), 'helper_file');
    game_schema_validate_stat($self, ($self['mode'] & 07777) === 0755 ? 0755 : 0644, true);
    game_schema_stage('operation_lock');
    $lock = game_schema_lock();
    try {
        game_schema_stage('backup_verify');
        $backup = game_schema_verify_file($options['backup'], $options['sha256'], true);
        game_schema_stage('authority_verify');
        game_schema_verify_file('/etc/shuzijun/account-authority-role', hash('sha256', "authority\n"));
        game_schema_require(filegroup('/etc/shuzijun/account-authority-role') === 0, 'authority_marker_owner');
        game_schema_stage('candidate_verify');
        game_schema_verify_candidate();
        game_schema_stage('bootstrap');
        game_schema_bootstrap();
        game_schema_stage('runtime_verify');
        game_schema_verify_runtime();
        // Recheck candidate after bootstrap, before any permitted DDL.
        game_schema_stage('candidate_recheck');
        game_schema_verify_candidate();
        $stage = game_schema_execute($options['apply'], 'game_schema_snapshot',
            static fn() => Shuzijun_App_Content_API::ensure_game_leaderboard_storage());
        game_schema_stage('report');
        echo 'game-schema: ' . $stage . '; backup_sha256=' . $backup['sha256']
            . '; backup_bytes=' . $backup['bytes'] . "; no explicit account or REST operation performed\n";
    } finally { flock($lock, LOCK_UN); fclose($lock); }
}

if (!defined('YISHU_GAME_SCHEMA_LIBRARY_ONLY')) {
    // Silence library/bootstrap diagnostic output; emit only fixed stage codes.
    ini_set('display_errors', '0'); ini_set('log_errors', '0');
    set_error_handler('game_schema_warning');
    // The filter also discards buffered output if wp-load terminates early.
    ob_start(static fn(string $bytes): string => '');
    $finished = false;
    register_shutdown_function(static function () use (&$finished): void {
        if (!$finished) {
            $last = error_get_last();
            $diagnostic = game_schema_diagnostic((int) ($last['type'] ?? 0), (string) ($last['file'] ?? ''), (int) ($last['line'] ?? 0));
            fwrite(STDERR, 'game-schema: failed (bootstrap_or_fatal_exit); ' . $diagnostic
                . "; outcome requires inspection; do not automatically retry\n");
            exit(1);
        }
    });
    try {
        game_schema_main(array_slice($_SERVER['argv'] ?? array(), 1));
        $output = ob_get_clean();
        if (preg_match('/^game-schema: [a-z_]+; backup_sha256=[a-f0-9]{64}; backup_bytes=[0-9]+; no explicit account or REST operation performed\n$/D', $output) !== 1) {
            throw new GameSchemaFailure('unexpected_runtime_output');
        }
        $finished = true;
        echo $output;
    } catch (Throwable $error) {
        if (ob_get_level() > 0) { ob_end_clean(); }
        $stage = $error instanceof GameSchemaFailure ? $error->getMessage() : 'runtime_failure';
        $diagnostic = $error instanceof GameSchemaFailure && $error->diagnostic !== null
            ? $error->diagnostic : game_schema_diagnostic(0, $error->getFile(), $error->getLine());
        $finished = true;
        fwrite(STDERR, 'game-schema: failed (' . $stage . '); ' . $diagnostic
            . "; outcome requires inspection; do not automatically retry\n");
        exit(1);
    }
}
