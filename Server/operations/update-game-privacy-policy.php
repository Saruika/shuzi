<?php
declare(strict_types=1);

/**
 * Root CLI only. No WP-CLI, HTTP route, arbitrary site, post or HTML is accepted.
 * Default dry-run reads the page and prints hashes, never its body.
 * Stage the reviewed HTML at PAYLOAD (root-owned, not writable by others).
 *   /usr/bin/php8.3 THIS_FILE
 *   /usr/bin/php8.3 THIS_FILE apply=THE_DRY_RUN_CURRENT_SHA256
 *   /usr/bin/php8.3 THIS_FILE restore=THE_RETURNED_32_HEX_BACKUP_ID
 *
 * A receipt is durable before the single-column SQL update. Only post_content
 * changes: timestamps, title, author, status, slug, metadata and revisions are
 * untouched. WordPress post-update hooks intentionally do not run. Only the
 * exact post's cache is invalidated. This does not claim CDN/page-cache refresh.
 * In this CLI process only, the reviewed App API init maintenance callbacks are
 * removed before init. DISABLE_WP_CRON by itself does not prevent init writes.
 * Keep receipts after success/failure; never blindly retry an uncertain commit.
 */
final class GamePrivacyFailure extends RuntimeException {
    public ?string $backupID = null;
    public ?array $diagnostic = null;
}

final class GamePrivacyDiagnostics {
    public static string $stage = 'startup';
}

final class GamePrivacyPolicy {
    public const SITE = '/var/www/html/shuzijun.com.cn';
    public const HOME = 'https://www.shuzijun.com.cn';
    public const POST_ID = 115;
    public const PAYLOAD = '/var/lib/shuzijun-app-content/privacy/app-privacy-policy.html';
    public const PAYLOAD_SHA256 = '6ee96c3d7a35d2d19bd1a402900044c24be1208b56e0341cd62054d830ca4e29';
    public const BACKUPS = '/var/backups/shuzijun-app-content';
    public const ROLE = '/etc/shuzijun/account-authority-role';
    public const LOCK = '/var/lib/shuzijun-sync/site-operation.lock';
}

function game_privacy_stage(string $stage): void {
    game_privacy_require(in_array($stage, array('startup', 'runtime_guard', 'helper_permissions',
        'operation_lock', 'authority_verify', 'config_verify', 'bootstrap', 'runtime_verify', 'table_verify',
        'arguments', 'receipt_verify', 'payload_verify', 'snapshot_before', 'transaction_start',
        'transaction_snapshot', 'backup_write', 'authority_recheck', 'page_update', 'transaction_readback',
        'commit', 'cache_invalidate', 'committed_readback', 'report'), true), 'diagnostic_stage');
    GamePrivacyDiagnostics::$stage = $stage;
}

/** Only fixed stage/basename and bounded numbers; never warning text or paths. */
function game_privacy_diagnostic(int $level, string $file, int $line): array {
    $name = basename($file);
    $allowed = array('update-game-privacy-policy.php', 'wp-load.php', 'wp-config.php', 'wp-settings.php',
        'load.php', 'functions.php', 'class-wpdb.php', 'class-wp-hook.php', 'plugin.php', 'default-constants.php',
        'option.php', 'formatting.php', 'post.php', 'cache.php', 'class-wp-object-cache.php',
        'shuzijun-app-content.php', 'class-shuzijun-app-content-api.php');
    if (!in_array($name, $allowed, true)) { $name = 'other'; }
    if (!in_array($level, array(0, E_ERROR, E_WARNING, E_PARSE, E_NOTICE, E_CORE_ERROR, E_CORE_WARNING,
        E_COMPILE_ERROR, E_COMPILE_WARNING, E_USER_ERROR, E_USER_WARNING, E_USER_NOTICE, E_STRICT,
        E_RECOVERABLE_ERROR, E_DEPRECATED, E_USER_DEPRECATED), true)) { $level = 0; }
    return array('stage' => GamePrivacyDiagnostics::$stage, 'file' => $name,
        'line' => max(0, min($line, 1000000)), 'level' => $level);
}

function game_privacy_warning(int $level, string $unusedMessage, string $file, int $line): bool {
    // PHP invokes custom handlers even for @lstat/@fopen. Their explicit false
    // checks below remain fail-closed; suppression must not become an exception.
    if ((error_reporting() & $level) === 0) { return false; }
    $failure = new GamePrivacyFailure('runtime_warning');
    $failure->diagnostic = game_privacy_diagnostic($level, $file, $line);
    throw $failure;
}

function game_privacy_server(): array {
    return array('REQUEST_METHOD' => 'GET', 'HTTP_HOST' => 'www.shuzijun.com.cn',
        'SERVER_NAME' => 'www.shuzijun.com.cn', 'SERVER_PORT' => '443', 'HTTPS' => 'on',
        'REQUEST_URI' => '/app-privacy/', 'REMOTE_ADDR' => '127.0.0.1', 'SERVER_PROTOCOL' => 'HTTP/1.1',
        'PHP_SELF' => '/index.php', 'SCRIPT_NAME' => '/index.php',
        'SCRIPT_FILENAME' => GamePrivacyPolicy::SITE . '/index.php');
}

function game_privacy_maintenance_callbacks(): array {
    return array('ensure_roles' => 20, 'ensure_collaboration_storage' => 21,
        'ensure_push_storage' => 22, 'ensure_fan_apple_revocation_schedule' => 40,
        'ensure_fan_apple_event_schedule' => 41, 'ensure_fan_apple_tombstone_schedule' => 42,
        'ensure_collaboration_outbox_schedule' => 43, 'ensure_push_outbox_schedule' => 44);
}

/** Remove only reviewed App callbacks, never all init callbacks or WP hooks. */
function game_privacy_block_maintenance(): void {
    game_privacy_require(class_exists('Shuzijun_App_Content_API') && class_exists('WP_Hook')
        && function_exists('has_action') && function_exists('remove_action'), 'maintenance_hook_runtime');
    foreach (game_privacy_maintenance_callbacks() as $method => $priority) {
        $callback = array('Shuzijun_App_Content_API', $method);
        $registered = has_action('init', $callback);
        if ($registered === false) { continue; } // Conditional/previously removed.
        game_privacy_require($registered === $priority, 'maintenance_hook_priority');
        game_privacy_require(remove_action('init', $callback, $priority), 'maintenance_hook_remove');
        game_privacy_require(has_action('init', $callback) === false, 'maintenance_hook_remaining');
    }
    $hook = $GLOBALS['wp_filter']['init'] ?? null;
    game_privacy_require($hook instanceof WP_Hook && is_array($hook->callbacks), 'maintenance_hook_shape');
    foreach ($hook->callbacks as $callbacks) {
        game_privacy_require(is_array($callbacks), 'maintenance_hook_shape');
        foreach ($callbacks as $entry) {
            $callback = $entry['function'] ?? null;
            // Refuse unreviewed/re-prioritized/case-variant App callbacks rather
            // than silently removing more hooks or letting a missed one run.
            $owner = is_array($callback) ? ($callback[0] ?? null) : null;
            $appCallback = (is_string($owner) && strcasecmp(ltrim($owner, '\\'), 'Shuzijun_App_Content_API') === 0)
                || (is_object($owner) && $owner instanceof Shuzijun_App_Content_API)
                || (is_string($callback) && str_starts_with(strtolower(ltrim($callback, '\\')), 'shuzijun_app_content_api::'));
            game_privacy_require(!$appCallback, 'maintenance_hook_remaining');
        }
    }
}

/** WordPress converts these process-local arrays to WP_Hook while booting. */
function game_privacy_preinitialize_maintenance_guards(): void {
    $guard = array('function' => 'game_privacy_block_maintenance', 'accepted_args' => 0);
    $GLOBALS['wp_filter']['muplugins_loaded'][PHP_INT_MAX][] = $guard;
    $GLOBALS['wp_filter']['init'][PHP_INT_MIN][] = $guard;
}

function game_privacy_require(bool $condition, string $code): void {
    if (!$condition) { throw new GamePrivacyFailure($code); }
}

function game_privacy_arguments(array $arguments): array {
    if ($arguments === array() || $arguments === array('dry-run')) { return array('dry-run', null); }
    game_privacy_require(count($arguments) === 1 && is_string($arguments[0]), 'arguments');
    if (preg_match('/^apply=([a-f0-9]{64})$/D', $arguments[0], $match) === 1) {
        return array('apply', $match[1]);
    }
    game_privacy_require(preg_match('/^restore=([a-f0-9]{32})$/D', $arguments[0], $match) === 1, 'arguments');
    return array('restore', $match[1]);
}

/** Check every path component, not just the final file; never follow links. */
function game_privacy_safe_path(string $path, bool $directory, ?int $exactMode = null): array {
    game_privacy_require(str_starts_with($path, '/') && realpath($path) === $path, 'path_canonical');
    $cursor = '';
    $parts = explode('/', substr($path, 1));
    $stat = false;
    foreach ($parts as $index => $part) {
        $cursor .= '/' . $part;
        clearstatcache(true, $cursor);
        $stat = @lstat($cursor);
        $isDirectory = $index < count($parts) - 1 || $directory;
        game_privacy_require(is_array($stat) && !is_link($cursor)
            && ($stat['mode'] & 0170000) === ($isDirectory ? 0040000 : 0100000)
            && (int) $stat['uid'] === 0 && ($stat['mode'] & 0022) === 0, 'path_ownership');
        if (!$isDirectory) { game_privacy_require((int) $stat['nlink'] === 1, 'path_links'); }
    }
    game_privacy_require(is_array($stat) && ($exactMode === null || ($stat['mode'] & 0777) === $exactMode), 'path_mode');
    return $stat;
}

function game_privacy_read(string $path, int $limit, ?int $mode = null): string {
    $before = game_privacy_safe_path($path, false, $mode);
    game_privacy_require((int) $before['size'] <= $limit, 'file_size');
    $handle = @fopen($path, 'rb');
    game_privacy_require(is_resource($handle), 'file_open');
    try {
        $opened = fstat($handle);
        game_privacy_require(is_array($opened) && $opened['dev'] === $before['dev']
            && $opened['ino'] === $before['ino'] && $opened['nlink'] === 1
            && $opened['uid'] === 0 && ($opened['mode'] & 0022) === 0, 'file_changed');
        $body = stream_get_contents($handle, $limit + 1);
        game_privacy_require(is_string($body) && strlen($body) <= $limit, 'file_read');
        $after = fstat($handle);
        game_privacy_require(is_array($after) && $after['size'] === $opened['size']
            && strlen($body) === $opened['size'] && $after['mtime'] === $opened['mtime']
            && $after['ctime'] === $opened['ctime'], 'file_changed');
        return $body;
    } finally { fclose($handle); }
}

function game_privacy_authority(): void {
    game_privacy_safe_path('/etc/shuzijun', true, 0755);
    game_privacy_require(game_privacy_read(GamePrivacyPolicy::ROLE, 16, 0644) === "authority\n", 'not_authority');
}

function game_privacy_validate_payload(string $body): void {
    game_privacy_require(hash_equals(GamePrivacyPolicy::PAYLOAD_SHA256, hash('sha256', $body)), 'payload_hash');
}

/** Return true only when this CLI needs to add a process-local cron guard. */
function game_privacy_cron_definition(string $config): bool {
    $code = '';
    foreach (token_get_all($config) as $token) {
        if (is_array($token) && in_array($token[0], array(T_COMMENT, T_DOC_COMMENT, T_WHITESPACE), true)) { continue; }
        $code .= is_array($token) ? $token[1] : $token;
    }
    if (!str_contains($code, 'DISABLE_WP_CRON')) { return true; }
    game_privacy_require(substr_count($code, 'DISABLE_WP_CRON') === 1
        && preg_match('/define\([\x27\x22]DISABLE_WP_CRON[\x27\x22],true\)/i', $code) === 1,
        'cron_config_unknown');
    return false;
}

function game_privacy_row(array $rows): array {
    game_privacy_require(count($rows) === 1 && is_array($rows[0]), 'page_not_unique');
    $row = $rows[0];
    game_privacy_require((string) ($row['ID'] ?? '') === (string) GamePrivacyPolicy::POST_ID
        && ($row['post_name'] ?? null) === 'app-privacy' && ($row['post_type'] ?? null) === 'page'
        && ($row['post_status'] ?? null) === 'publish' && is_string($row['post_content'] ?? null)
        && strlen($row['post_content']) <= 131072, 'page_identity');
    foreach ($row as $key => $value) {
        game_privacy_require(is_string($key) && (is_string($value) || is_int($value)), 'page_fields');
    }
    return $row;
}

function game_privacy_same_other_fields(array $left, array $right): bool {
    unset($left['post_content'], $right['post_content']);
    ksort($left); ksort($right);
    return $left === $right;
}

function game_privacy_json(array $value): string {
    $encoded = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    game_privacy_require(is_string($encoded), 'json_encoding');
    return $encoded;
}

function game_privacy_receipt(array $row): array {
    game_privacy_row(array($row));
    return array('schema' => 1, 'site' => GamePrivacyPolicy::SITE, 'postID' => GamePrivacyPolicy::POST_ID,
        'payloadSha256' => GamePrivacyPolicy::PAYLOAD_SHA256,
        'originalContentSha256' => hash('sha256', $row['post_content']),
        'originalRowSha256' => hash('sha256', game_privacy_json($row)), 'originalRow' => $row);
}

function game_privacy_validate_receipt(array $receipt): array {
    game_privacy_require(array_keys($receipt) === array('schema', 'site', 'postID', 'payloadSha256',
        'originalContentSha256', 'originalRowSha256', 'originalRow')
        && $receipt['schema'] === 1 && $receipt['site'] === GamePrivacyPolicy::SITE
        && $receipt['postID'] === GamePrivacyPolicy::POST_ID
        && $receipt['payloadSha256'] === GamePrivacyPolicy::PAYLOAD_SHA256
        && is_array($receipt['originalRow']), 'receipt_identity');
    $row = game_privacy_row(array($receipt['originalRow']));
    game_privacy_require($receipt['originalContentSha256'] === hash('sha256', $row['post_content'])
        && $receipt['originalRowSha256'] === hash('sha256', game_privacy_json($row))
        && $receipt['originalContentSha256'] !== GamePrivacyPolicy::PAYLOAD_SHA256, 'receipt_hash');
    return $row;
}

function game_privacy_sync_directory(string $path): void {
    $handle = @fopen($path, 'r');
    game_privacy_require(is_resource($handle), 'directory_open');
    try { game_privacy_require(fsync($handle), 'directory_sync'); }
    finally { fclose($handle); }
}

/** Write one already exclusively-created, mode-0600 regular receipt stream. */
function game_privacy_write_receipt(mixed $handle, array $row): void {
    game_privacy_require(is_resource($handle), 'backup_open');
    $stat = fstat($handle);
    game_privacy_require(is_array($stat) && ($stat['mode'] & 0170000) === 0100000
        && ($stat['mode'] & 0777) === 0600 && $stat['nlink'] === 1 && $stat['size'] === 0, 'backup_mode');
    $bytes = game_privacy_json(game_privacy_receipt($row)) . "\n";
    $written = 0;
    while ($written < strlen($bytes)) {
        $count = fwrite($handle, substr($bytes, $written));
        game_privacy_require(is_int($count) && $count > 0, 'backup_write');
        $written += $count;
    }
    game_privacy_require(fflush($handle) && fsync($handle), 'backup_sync');
}

function game_privacy_backup(array $row): string {
    game_privacy_safe_path(GamePrivacyPolicy::BACKUPS, true, 0700);
    $id = bin2hex(random_bytes(16));
    $path = GamePrivacyPolicy::BACKUPS . '/privacy-' . $id;
    game_privacy_require(@mkdir($path, 0700), 'backup_create');
    game_privacy_safe_path($path, true, 0700);
    game_privacy_sync_directory(GamePrivacyPolicy::BACKUPS);
    $handle = @fopen($path . '/receipt.json', 'xb');
    game_privacy_require(is_resource($handle), 'backup_open');
    try {
        game_privacy_require(fstat($handle)['uid'] === 0, 'backup_owner');
        game_privacy_write_receipt($handle, $row);
    } finally { fclose($handle); }
    game_privacy_sync_directory($path);
    $checked = json_decode(game_privacy_read($path . '/receipt.json', 524288, 0600), true);
    game_privacy_require(is_array($checked) && game_privacy_validate_receipt($checked) === $row, 'backup_readback');
    return $id;
}

function game_privacy_table(object $db): string {
    game_privacy_require(is_string($db->posts ?? null) && preg_match('/^[A-Za-z0-9_]+$/D', $db->posts) === 1, 'posts_table');
    return '`' . $db->posts . '`';
}

function game_privacy_select(object $db, bool $locked): array {
    $table = game_privacy_table($db);
    $rows = $db->get_results("SELECT * FROM $table WHERE post_type='page' AND post_name='app-privacy'"
        . ($locked ? ' FOR UPDATE' : ''), 'ARRAY_A');
    game_privacy_require($db->last_error === '' && is_array($rows), 'page_read');
    // A draft/trash duplicate also fails closed; only one published page is valid.
    return game_privacy_row($rows);
}

/** Testable transaction core. Receipt/authority/cache callbacks have no bypass CLI. */
function game_privacy_change(object $db, string $expectedHash, string $target, ?array $original,
    callable $backup, callable $authority, callable $invalidate): array {
    $table = game_privacy_table($db);
    game_privacy_stage('transaction_start');
    game_privacy_require($db->query('START TRANSACTION') !== false, 'transaction_start');
    $committed = false;
    $backupID = null;
    try {
        game_privacy_stage('authority_verify');
        $authority();
        game_privacy_stage('transaction_snapshot');
        $before = game_privacy_select($db, true);
        game_privacy_require(hash_equals($expectedHash, hash('sha256', $before['post_content'])), 'current_hash');
        if ($original !== null) {
            game_privacy_require(game_privacy_same_other_fields($before, $original), 'restore_foreign_fields');
        } else { game_privacy_validate_payload($target); }
        if ($before['post_content'] === $target) {
            game_privacy_require($db->query('ROLLBACK') !== false, 'transaction_rollback');
            return array('status' => 'unchanged', 'postID' => GamePrivacyPolicy::POST_ID,
                'currentSha256' => $expectedHash);
        }
        game_privacy_stage('backup_write');
        $backupID = $original === null ? $backup($before) : null;
        game_privacy_stage('authority_recheck');
        $authority();
        game_privacy_stage('page_update');
        $sql = $db->prepare("UPDATE $table SET post_content=%s WHERE ID=%d AND post_type='page'"
            . " AND post_name='app-privacy' AND post_status='publish'", $target, GamePrivacyPolicy::POST_ID);
        game_privacy_require(is_string($sql) && $db->query($sql) === 1 && $db->last_error === '', 'page_update');
        game_privacy_stage('transaction_readback');
        $after = game_privacy_select($db, true);
        game_privacy_require($after['post_content'] === $target
            && game_privacy_same_other_fields($before, $after), 'transaction_readback');
        game_privacy_stage('commit');
        game_privacy_require($db->query('COMMIT') !== false, 'commit_uncertain_keep_backup');
        $committed = true;
        // Invalidate even if a later verification fails: no stale object cache.
        game_privacy_stage('cache_invalidate');
        $invalidate(GamePrivacyPolicy::POST_ID);
        game_privacy_stage('committed_readback');
        $final = game_privacy_select($db, false);
        game_privacy_require($final === $after, 'committed_readback_keep_backup');
        return array('status' => $original === null ? 'applied' : 'restored',
            'postID' => GamePrivacyPolicy::POST_ID, 'currentSha256' => hash('sha256', $target),
            'backupID' => $backupID);
    } catch (Throwable $error) {
        if (!$committed) { $db->query('ROLLBACK'); }
        // No raw database/body/URL exception is ever printed by the CLI.
        $failure = $error instanceof GamePrivacyFailure ? $error : new GamePrivacyFailure('unexpected_keep_backup');
        $failure->backupID = $backupID;
        if ($failure->diagnostic === null) {
            $failure->diagnostic = game_privacy_diagnostic(0, $error->getFile(), $error->getLine());
        }
        throw $failure;
    }
}

function game_privacy_bootstrap(): mixed {
    game_privacy_stage('runtime_guard');
    game_privacy_require(PHP_SAPI === 'cli' && PHP_VERSION_ID >= 80300 && PHP_VERSION_ID < 80400 && function_exists('posix_geteuid')
        && posix_geteuid() === 0 && function_exists('fsync'), 'root_php83_cli_required');
    game_privacy_require(in_array(ini_get('opcache.enable_cli'), array(false, '', '0'), true)
        && ini_get('auto_prepend_file') === '' && ini_get('auto_append_file') === '', 'isolated_cli_configuration');
    ini_set('display_errors', '0'); ini_set('log_errors', '0');
    umask(0077);
    game_privacy_stage('helper_permissions');
    game_privacy_safe_path(__FILE__, false);
    game_privacy_stage('operation_lock');
    game_privacy_safe_path('/var/lib/shuzijun-sync', true, 0700);
    $before = game_privacy_safe_path(GamePrivacyPolicy::LOCK, false, 0600);
    game_privacy_require((int) $before['size'] === 0, 'lock_size');
    $lock = @fopen(GamePrivacyPolicy::LOCK, 'rb');
    game_privacy_require(is_resource($lock), 'lock_open');
    $opened = fstat($lock);
    game_privacy_require(is_array($opened) && $opened['ino'] === $before['ino'] && $opened['dev'] === $before['dev']
        && flock($lock, LOCK_EX | LOCK_NB), 'site_operation_busy');
    game_privacy_stage('authority_verify');
    game_privacy_authority();
    game_privacy_stage('config_verify');
    game_privacy_safe_path(GamePrivacyPolicy::SITE . '/wp-load.php', false);
    $config = game_privacy_read(GamePrivacyPolicy::SITE . '/wp-config.php', 262144);
    $addCronGuard = game_privacy_cron_definition($config);
    unset($config);
    game_privacy_require(!defined('ABSPATH') && !defined('REST_REQUEST') && !defined('DOING_CRON'), 'fresh_cli_required');
    if ($addCronGuard && !defined('DISABLE_WP_CRON')) { define('DISABLE_WP_CRON', true); }
    game_privacy_require(!defined('DISABLE_WP_CRON') || DISABLE_WP_CRON === true, 'cron_guard');
    define('REST_REQUEST', true);
    define('WP_USE_THEMES', false);
    $_SERVER = game_privacy_server();
    $_GET = $_POST = $_COOKIE = $_REQUEST = array();
    // WordPress converts preinitialized hooks before muplugins_loaded/init.
    // Network namespace isolation alone does not block a local sendmail binary.
    $GLOBALS['wp_filter']['pre_wp_mail'][PHP_INT_MAX][] = array('function' => static fn() => false, 'accepted_args' => 0);
    $GLOBALS['wp_filter']['pre_http_request'][PHP_INT_MAX][] = array(
        'function' => static fn() => new WP_Error('privacy_network_denied'), 'accepted_args' => 0);
    $GLOBALS['wp_filter']['muplugins_loaded'][PHP_INT_MIN][] = array('function' => static function (): void {
        game_privacy_require(defined('DISABLE_WP_CRON') && DISABLE_WP_CRON === true, 'cron_guard');
    }, 'accepted_args' => 0);
    game_privacy_preinitialize_maintenance_guards();
    game_privacy_stage('bootstrap');
    require GamePrivacyPolicy::SITE . '/wp-load.php';
    game_privacy_stage('runtime_verify');
    global $wpdb;
    game_privacy_require(defined('ABSPATH') && ABSPATH === GamePrivacyPolicy::SITE . '/'
        && defined('DB_NAME') && DB_NAME === 'wordpress'
        && defined('DISABLE_WP_CRON') && DISABLE_WP_CRON === true
        && class_exists('Shuzijun_App_Content_API') && Shuzijun_App_Content_API::account_authority_enabled()
        && home_url() === GamePrivacyPolicy::HOME && site_url() === GamePrivacyPolicy::HOME
        && isset($wpdb) && function_exists('clean_post_cache'), 'wordpress_identity');
    $wpdb->hide_errors();
    game_privacy_require($wpdb->get_var('SELECT DATABASE()') === 'wordpress' && $wpdb->last_error === '', 'database_identity');
    game_privacy_stage('table_verify');
    $table = game_privacy_table($wpdb);
    $engine = $wpdb->get_var($wpdb->prepare('SELECT ENGINE FROM information_schema.TABLES'
        . ' WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s', trim($table, '`')));
    game_privacy_require($wpdb->last_error === '' && $engine === 'InnoDB', 'transactional_posts_required');
    $triggers = $wpdb->get_var($wpdb->prepare('SELECT COUNT(*) FROM information_schema.TRIGGERS'
        . ' WHERE TRIGGER_SCHEMA=DATABASE() AND EVENT_OBJECT_TABLE=%s', trim($table, '`')));
    game_privacy_require($wpdb->last_error === '' && (string) $triggers === '0', 'posts_triggers');
    return $lock;
}

function game_privacy_main(array $arguments): array {
    // Runtime, authority and cron isolation precede all mutation-mode parsing.
    $lock = game_privacy_bootstrap();
    try {
        global $wpdb;
        game_privacy_stage('arguments');
        [$mode, $value] = game_privacy_arguments($arguments);
        if ($mode === 'restore') {
            game_privacy_stage('receipt_verify');
            $directory = GamePrivacyPolicy::BACKUPS . '/privacy-' . $value;
            game_privacy_safe_path(GamePrivacyPolicy::BACKUPS, true, 0700);
            game_privacy_safe_path($directory, true, 0700);
            $receipt = json_decode(game_privacy_read($directory . '/receipt.json', 524288, 0600), true);
            game_privacy_require(is_array($receipt), 'receipt_json');
            $original = game_privacy_validate_receipt($receipt);
            $result = game_privacy_change($wpdb, GamePrivacyPolicy::PAYLOAD_SHA256, $original['post_content'], $original,
                'game_privacy_backup', 'game_privacy_authority', 'clean_post_cache');
            $result['backupID'] = $value;
            return $result;
        }
        game_privacy_stage('payload_verify');
        $payload = game_privacy_read(GamePrivacyPolicy::PAYLOAD, 131072);
        game_privacy_validate_payload($payload);
        if ($mode === 'dry-run') {
            game_privacy_stage('snapshot_before');
            $row = game_privacy_select($wpdb, false);
            return array('status' => 'dry-run', 'postID' => GamePrivacyPolicy::POST_ID,
                'currentSha256' => hash('sha256', $row['post_content']), 'candidateSha256' => GamePrivacyPolicy::PAYLOAD_SHA256,
                'changeNeeded' => $row['post_content'] !== $payload);
        }
        return game_privacy_change($wpdb, $value, $payload, null,
            'game_privacy_backup', 'game_privacy_authority', 'clean_post_cache');
    } finally { flock($lock, LOCK_UN); fclose($lock); }
}

if (!defined('YISHU_GAME_PRIVACY_LIBRARY_ONLY')) {
    ini_set('display_errors', '0'); ini_set('log_errors', '0');
    set_error_handler('game_privacy_warning');
    // Also discard output when wp-load exits/dies without returning to us.
    ob_start(static fn(string $bytes): string => '');
    $finished = false;
    register_shutdown_function(static function () use (&$finished): void {
        if (!$finished) {
            $last = error_get_last();
            fwrite(STDERR, game_privacy_json(array('status' => 'failed', 'code' => 'bootstrap_or_fatal_exit_keep_backup',
                'diagnostic' => game_privacy_diagnostic((int) ($last['type'] ?? 0), (string) ($last['file'] ?? ''),
                    (int) ($last['line'] ?? 0)))) . "\n");
            exit(1);
        }
    });
    try {
        $result = game_privacy_main(array_slice($argv ?? array(), 1));
        game_privacy_stage('report');
        $unexpected = ob_get_clean();
        game_privacy_require($unexpected === '', 'unexpected_output_keep_backup');
        $finished = true;
        echo game_privacy_json($result) . "\n";
    }
    catch (Throwable $error) {
        if (ob_get_level() > 0) { ob_end_clean(); }
        $finished = true;
        $code = $error instanceof GamePrivacyFailure ? $error->getMessage() : 'unexpected_keep_backup';
        fwrite(STDERR, game_privacy_json(array('status' => 'failed', 'code' => $code,
            'backupID' => $error instanceof GamePrivacyFailure ? $error->backupID : null,
            'diagnostic' => $error instanceof GamePrivacyFailure && $error->diagnostic !== null ? $error->diagnostic
                : game_privacy_diagnostic(0, $error->getFile(), $error->getLine()))) . "\n");
        exit(1);
    }
}
