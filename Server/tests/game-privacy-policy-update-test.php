<?php
declare(strict_types=1);

// Synthetic, offline transaction tests. No WordPress, network or real DB loads.
define('YISHU_GAME_PRIVACY_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/operations/update-game-privacy-policy.php';
$checks = 0;
function privacy_check(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function privacy_reject(callable $callback, string $code): GamePrivacyFailure {
    try { $callback(); }
    catch (GamePrivacyFailure $failure) {
        privacy_check($failure->getMessage() === $code, 'exact failure category: ' . $code);
        return $failure;
    }
    throw new RuntimeException('missing rejection: ' . $code);
}

final class PrivacyFakeDB {
    public string $posts = 'wp_posts';
    public string $last_error = '';
    public array $rows;
    public array $commands = array();
    public ?array $snapshot = null;
    public string $target = '';
    public string $fault = '';
    public bool $rollbackFails = false;
    public bool $commitRaises = false;
    public int $reads = 0;
    public function __construct(array $row) { $this->rows = array($row); }
    public function get_results(string $sql, string $type): array {
        privacy_check($type === 'ARRAY_A' && str_contains($sql, "post_name='app-privacy'"), 'fixed page query');
        ++$this->reads;
        if ($this->reads === 2 && $this->fault === 'body') { $this->rows[0]['post_content'] .= 'corrupt'; }
        if ($this->reads === 2 && $this->fault === 'other') { $this->rows[0]['post_title'] = 'foreign change'; }
        if ($this->reads === 3 && $this->fault === 'postcommit') { $this->rows[0]['post_content'] .= 'new editor'; }
        return $this->rows;
    }
    public function prepare(string $sql, string $target, int $id): string {
        privacy_check($id === 115 && str_starts_with($sql, 'UPDATE `wp_posts` SET post_content=%s WHERE ID=%d')
            && str_contains($sql, "post_status='publish'"), 'only exact body update');
        $this->target = $target;
        return 'UPDATE prepared-fixed-page';
    }
    public function query(string $sql): int|false {
        $this->commands[] = $sql;
        if ($sql === 'START TRANSACTION') { $this->snapshot = $this->rows; return 1; }
        if ($sql === 'ROLLBACK') {
            if ($this->rollbackFails) { throw new RuntimeException('synthetic lost connection'); }
            if ($this->snapshot !== null) { $this->rows = $this->snapshot; }
            $this->snapshot = null;
            return 1;
        }
        if ($sql === 'COMMIT') {
            $this->snapshot = null;
            if ($this->commitRaises) { throw new RuntimeException('synthetic lost commit reply'); }
            return $this->fault === 'commit' ? false : 1;
        }
        if ($sql === 'UPDATE prepared-fixed-page') {
            if ($this->fault === 'update') { return false; }
            if ($this->fault === 'exception') { throw new RuntimeException('private body and database secret'); }
            $this->rows[0]['post_content'] = $this->target;
            return 1;
        }
        throw new RuntimeException('unexpected SQL');
    }
}

$original = array('ID' => '115', 'post_name' => 'app-privacy', 'post_type' => 'page', 'post_status' => 'publish',
    'post_content' => '<p>Synthetic prior policy.</p>', 'post_title' => 'Synthetic Privacy',
    'post_author' => '1', 'post_modified' => '2026-01-01 00:00:00', 'post_modified_gmt' => '2026-01-01 00:00:00');
$body = file_get_contents(dirname(__DIR__) . '/app-privacy-policy.html');
privacy_check(is_string($body), 'reviewed candidate available');
game_privacy_validate_payload($body); privacy_check(true, 'pinned candidate hash');
$oldHash = hash('sha256', $original['post_content']);
$id = str_repeat('a', 32);
privacy_check(game_privacy_arguments(array()) === array('dry-run', null), 'default read only');
privacy_check(game_privacy_arguments(array('dry-run')) === array('dry-run', null), 'explicit dry run');
privacy_check(game_privacy_arguments(array('apply=' . $oldHash)) === array('apply', $oldHash), 'exact apply hash');
privacy_check(game_privacy_arguments(array('restore=' . $id)) === array('restore', $id), 'exact restore id');
foreach (array(array('apply'), array('--apply'), array('apply=' . strtoupper($oldHash)),
    array('apply=' . $id), array('apply=' . $oldHash, 'dry-run'), array('restore=../other'),
    array('restore=' . $id . '0'), array('restore=' . $oldHash), array(null)) as $arguments) {
    privacy_reject(static fn() => game_privacy_arguments($arguments), 'arguments');
}
privacy_check(game_privacy_cron_definition('<?php /* DISABLE_WP_CRON */ define("OTHER", true);'), 'absent cron gets process-local guard');
foreach (array('<?php define("DISABLE_WP_CRON", true);', "<?php define ( 'DISABLE_WP_CRON' , true );") as $config) {
    privacy_check(!game_privacy_cron_definition($config), 'literal true is not redefined');
}
foreach (array('<?php define("DISABLE_WP_CRON", false);', '<?php define("DISABLE_WP_CRON", getenv("X"));',
    '<?php const DISABLE_WP_CRON=true;', '<?php define("DISABLE_WP_CRON",true); echo DISABLE_WP_CRON;') as $config) {
    privacy_reject(static fn() => game_privacy_cron_definition($config), 'cron_config_unknown');
}
privacy_reject(static fn() => game_privacy_validate_payload($body . "\n"), 'payload_hash');
privacy_reject(static fn() => game_privacy_validate_payload('foreign html'), 'payload_hash');
privacy_check(game_privacy_row(array($original)) === $original, 'fixed published page');
foreach (array(array(), array($original, $original)) as $rows) {
    privacy_reject(static fn() => game_privacy_row($rows), 'page_not_unique');
}
foreach (array('ID' => '116', 'post_name' => 'other', 'post_type' => 'post', 'post_status' => 'draft',
    'post_content' => str_repeat('x', 131073)) as $key => $value) {
    privacy_reject(static fn() => game_privacy_row(array(array_replace($original, array($key => $value)))), 'page_identity');
}
$receipt = game_privacy_receipt($original);
privacy_check(game_privacy_validate_receipt($receipt) === $original, 'receipt preserves full original row');
$stream = tmpfile();
privacy_check(is_resource($stream), 'local test receipt stream');
try {
    game_privacy_write_receipt($stream, $original);
    rewind($stream);
    $diskReceipt = json_decode(stream_get_contents($stream), true);
    privacy_check(is_array($diskReceipt) && game_privacy_validate_receipt($diskReceipt) === $original,
        'actual PHP receipt stream fsync/readback');
    privacy_reject(static fn() => game_privacy_write_receipt($stream, $original), 'backup_mode');
} finally { fclose($stream); }
foreach (array('schema' => 2, 'site' => '/other', 'postID' => 116, 'payloadSha256' => $oldHash) as $key => $value) {
    privacy_reject(static fn() => game_privacy_validate_receipt(array_replace($receipt, array($key => $value))), 'receipt_identity');
}
foreach (array('originalContentSha256', 'originalRowSha256') as $key) {
    privacy_reject(static fn() => game_privacy_validate_receipt(array_replace($receipt, array($key => str_repeat('0', 64)))), 'receipt_hash');
}
$foreignReceipt = $receipt; $foreignReceipt['originalRow']['post_title'] = 'edited';
privacy_reject(static fn() => game_privacy_validate_receipt($foreignReceipt), 'receipt_hash');

$backups = array(); $caches = array(); $authorityCount = 0;
$backup = static function (array $row) use (&$backups, $id): string { $backups[] = game_privacy_receipt($row); return $id; };
$authority = static function () use (&$authorityCount): void { ++$authorityCount; };
$invalidate = static function (int $post) use (&$caches): void { $caches[] = $post; };
$db = new PrivacyFakeDB($original);
$result = game_privacy_change($db, $oldHash, $body, null, $backup, $authority, $invalidate);
privacy_check($result['status'] === 'applied' && $result['backupID'] === $id, 'applied only after commit/readback');
privacy_check(count($backups) === 1 && $backups[0] === $receipt && $caches === array(115)
    && $authorityCount === 2, 'exact backup, two role checks, one targeted cache invalidation');
privacy_check(game_privacy_same_other_fields($db->rows[0], $original)
    && $db->rows[0]['post_content'] === $body, 'all non-body columns including timestamps preserved');
privacy_check($db->commands === array('START TRANSACTION', 'UPDATE prepared-fixed-page', 'COMMIT'), 'single-column transaction');
$result = game_privacy_change($db, GamePrivacyPolicy::PAYLOAD_SHA256, $body, null, $backup, $authority, $invalidate);
privacy_check($result['status'] === 'unchanged' && count($backups) === 1 && count($caches) === 1, 'same candidate no write');
$result = game_privacy_change($db, GamePrivacyPolicy::PAYLOAD_SHA256, $original['post_content'], $original,
    $backup, $authority, $invalidate);
privacy_check($result['status'] === 'restored' && $db->rows === array($original)
    && count($backups) === 1 && $caches === array(115, 115), 'exact restore no unrelated backup');

foreach (array('update' => 'page_update', 'body' => 'transaction_readback', 'other' => 'transaction_readback',
    'exception' => 'unexpected_keep_backup') as $fault => $code) {
    $db = new PrivacyFakeDB($original); $db->fault = $fault;
    $failure = privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null,
        $backup, $authority, $invalidate), $code);
    privacy_check($db->rows === array($original) && end($db->commands) === 'ROLLBACK'
        && $failure->backupID === $id, 'precommit failure restores transaction, retains recovery id');
}
foreach (array('commit' => 'commit_uncertain_keep_backup', 'postcommit' => 'committed_readback_keep_backup') as $fault => $code) {
    $db = new PrivacyFakeDB($original); $db->fault = $fault;
    $failure = privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null,
        $backup, $authority, $invalidate), $code);
    privacy_check($failure->backupID === $id && $db->rows !== array($original), 'uncertain/changed commit not overwritten automatically');
    privacy_check(end($db->commands) === 'COMMIT', 'never send rollback after attempted commit');
}
$db = new PrivacyFakeDB($original); $db->commitRaises = true;
$invalidateCalls = 0;
$countInvalidate = static function (int $post) use (&$invalidateCalls): void {
    privacy_check($post === 115, 'uncertain commit exact cache scope'); ++$invalidateCalls;
};
$failure = privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null,
    $backup, $authority, $countInvalidate), 'commit_uncertain_keep_backup');
privacy_check($failure->backupID === $id && $invalidateCalls === 1 && end($db->commands) === 'COMMIT'
    && $db->rows[0]['post_content'] === $body, 'lost commit exception retains receipt and invalidates without replay');
$db = new PrivacyFakeDB($original); $db->fault = 'update'; $db->rollbackFails = true;
$failure = privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null,
    $backup, $authority, $invalidate), 'transaction_outcome_uncertain_keep_backup');
privacy_check($failure->backupID === $id && end($db->commands) === 'ROLLBACK', 'rollback failure does not mask recovery id or retry');
privacy_check(GamePrivacyRuntime::$pageUpdateQuery === null, 'exact mutation allowance cleared even on error');
$db = new PrivacyFakeDB($original);
privacy_reject(static fn() => game_privacy_change($db, str_repeat('0', 64), $body, null,
    $backup, $authority, $invalidate), 'current_hash');
privacy_check($db->commands === array('START TRANSACTION', 'ROLLBACK'), 'stale SHA refuses before any write');
$db = new PrivacyFakeDB(array_replace($original, array('post_content' => $body, 'post_title' => 'Another editor')));
privacy_reject(static fn() => game_privacy_change($db, GamePrivacyPolicy::PAYLOAD_SHA256, $original['post_content'], $original,
    $backup, $authority, $invalidate), 'restore_foreign_fields');
privacy_check($db->rows[0]['post_title'] === 'Another editor', 'restore refuses foreign field change');
$db = new PrivacyFakeDB($original);
$calls = 0;
$switchRole = static function () use (&$calls): void { if (++$calls === 2) { throw new GamePrivacyFailure('not_authority'); } };
privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null, $backup, $switchRole, $invalidate), 'not_authority');
privacy_check($db->rows === array($original) && $db->commands === array('START TRANSACTION', 'ROLLBACK'), 'role flip between backup/write denied');
$db = new PrivacyFakeDB($original); $db->posts = 'wp_posts;DELETE';
privacy_reject(static fn() => game_privacy_select($db, false), 'posts_table');
privacy_reject(static fn() => game_privacy_safe_path('/tmp/../etc/passwd', false), 'path_canonical');

// WordPress bootstrap gets a coherent fixed script mapping, not untrusted CLI
// environment/request values. wp-includes/load.php reads PHP_SELF directly.
$server = game_privacy_server();
privacy_check($server === array('REQUEST_METHOD' => 'GET', 'HTTP_HOST' => 'www.shuzijun.com.cn',
    'SERVER_NAME' => 'www.shuzijun.com.cn', 'SERVER_PORT' => '443', 'HTTPS' => 'on',
    'REQUEST_URI' => '/app-privacy/', 'REMOTE_ADDR' => '127.0.0.1', 'SERVER_PROTOCOL' => 'HTTP/1.1',
    'PHP_SELF' => '/index.php', 'SCRIPT_NAME' => '/index.php',
    'SCRIPT_FILENAME' => '/var/www/html/shuzijun.com.cn/index.php'), 'complete fixed WP server mapping');
privacy_check(!isset($server['HTTP_AUTHORIZATION'], $server['HTTP_COOKIE']), 'no inherited credentials/cookies');

// Actual @/error_reporting semantics remain intact. Diagnostic output excludes
// warning message, arbitrary basename, absolute path, SQL and input content.
game_privacy_stage('bootstrap');
privacy_check(game_privacy_diagnostic(E_WARNING, '/private/account/wp-load.php', 123)
    === array('stage' => 'bootstrap', 'file' => 'wp-load.php', 'line' => 123, 'level' => E_WARNING), 'allowed diagnostic basename');
privacy_check(game_privacy_diagnostic(E_WARNING, '/private/person-secret.php', 9)
    === array('stage' => 'bootstrap', 'file' => 'other', 'line' => 9, 'level' => E_WARNING), 'unlisted diagnostic basename redacted');
privacy_check(game_privacy_diagnostic(999999, '/private/person-secret.php', -2)
    === array('stage' => 'bootstrap', 'file' => 'other', 'line' => 0, 'level' => 0), 'unknown severity and negative line bounded');
privacy_check(game_privacy_diagnostic(E_ERROR, '/private/wp-load.php', PHP_INT_MAX)['line'] === 1000000, 'oversized line bounded');
privacy_reject(static fn() => game_privacy_stage('untrusted input stage'), 'diagnostic_stage');
$previousReporting = error_reporting(E_ALL);
set_error_handler('game_privacy_warning');
try {
    privacy_check(@lstat('/__yishu_privacy_synthetic_missing__/file') === false, 'suppressed lstat returns false');
    privacy_check(@fopen('/__yishu_privacy_synthetic_missing__/file', 'rb') === false, 'suppressed fopen returns false');
    $failure = privacy_reject(static fn() => game_privacy_require(
        is_array(@lstat('/__yishu_privacy_synthetic_missing__/file')), 'path_ownership'), 'path_ownership');
    privacy_check($failure->diagnostic === null, 'explicit suppressed missing-file guard remains in charge');
    $failure = privacy_reject(static fn() => game_privacy_warning(E_WARNING,
        'fixture-token private SQL body', '/private/wp-config.php', 71), 'runtime_warning');
    privacy_check($failure->diagnostic === array('stage' => 'bootstrap', 'file' => 'wp-config.php', 'line' => 71,
        'level' => E_WARNING), 'unmasked warning gives controlled metadata');
    $serialized = game_privacy_json($failure->diagnostic);
    privacy_check(!str_contains($serialized, 'fixture-token') && !str_contains($serialized, 'SQL')
        && !str_contains($serialized, '/private/'), 'no warning text or path leaked');
    game_privacy_stage('backup_write');
    $failure = privacy_reject(static fn() => trigger_error('fixture-private-token', E_USER_WARNING), 'runtime_warning');
    privacy_check($failure->diagnostic['stage'] === 'backup_write' && $failure->diagnostic['file'] === 'other'
        && $failure->diagnostic['level'] === E_USER_WARNING && $failure->diagnostic['line'] > 0,
        'real PHP warning converted without private message');
    error_reporting(E_ERROR);
    privacy_check(game_privacy_warning(E_WARNING, 'fixture-private-token', '/private/other.php', 99) === false,
        'error_reporting mask honored without @');
    privacy_check(@trigger_error('fixture-private-token', E_USER_WARNING), 'suppressed user warning does not throw');
    error_reporting(E_ALL);
    $db = new PrivacyFakeDB($original);
    $failure = privacy_reject(static fn() => game_privacy_change($db, $oldHash, $body, null, $backup, $authority,
        static function (int $post): void { trigger_error('fixture-private-cache-value', E_USER_WARNING); }), 'runtime_warning');
    privacy_check($failure->backupID === $id && $failure->diagnostic['stage'] === 'cache_invalidate'
        && $db->rows[0]['post_content'] === $body, 'postcommit warning keeps recovery ID and original failure stage');
} finally { restore_error_handler(); error_reporting($previousReporting); }

// Executable WordPress-style hook stub: callbacks are dispatched in priority
// order and removals during dispatch take effect. No actual plugin/DB is loaded.
final class WP_Hook { public array $callbacks = array(); }
final class Shuzijun_App_Content_API {
    public static function __callStatic(string $name, array $arguments): void {
        $GLOBALS['privacy_maintenance_calls'][] = $name;
    }
}
function privacy_hook_key(mixed $callback): string {
    if (is_array($callback)) { return (string) $callback[0] . '::' . (string) $callback[1]; }
    return is_string($callback) ? $callback : 'closure-' . spl_object_id($callback);
}
function add_action(string $name, mixed $callback, int $priority = 10, int $accepted = 1): void {
    if (!isset($GLOBALS['wp_filter'][$name])) { $GLOBALS['wp_filter'][$name] = new WP_Hook(); }
    $GLOBALS['wp_filter'][$name]->callbacks[$priority][privacy_hook_key($callback)] = array(
        'function' => $callback, 'accepted_args' => $accepted);
}
function has_action(string $name, mixed $callback): int|false {
    $priorities = $GLOBALS['wp_filter'][$name]->callbacks ?? array();
    ksort($priorities);
    foreach ($priorities as $priority => $entries) {
        if (isset($entries[privacy_hook_key($callback)])) { return $priority; }
    }
    return false;
}
function remove_action(string $name, mixed $callback, int $priority = 10): bool {
    if (($GLOBALS['privacy_remove_fault'] ?? '') === 'failure') { return false; }
    if (($GLOBALS['privacy_remove_fault'] ?? '') === 'no-op') { return true; }
    $key = privacy_hook_key($callback);
    if (!isset($GLOBALS['wp_filter'][$name]->callbacks[$priority][$key])) { return false; }
    unset($GLOBALS['wp_filter'][$name]->callbacks[$priority][$key]);
    return true;
}
function do_action(string $name, mixed ...$arguments): void {
    $priorities = array_keys($GLOBALS['wp_filter'][$name]->callbacks ?? array()); sort($priorities);
    foreach ($priorities as $priority) {
        $keys = array_keys($GLOBALS['wp_filter'][$name]->callbacks[$priority] ?? array());
        foreach ($keys as $key) {
            $entry = $GLOBALS['wp_filter'][$name]->callbacks[$priority][$key] ?? null;
            if ($entry !== null) { ($entry['function'])(...array_slice($arguments, 0, $entry['accepted_args'])); }
        }
    }
}
function privacy_fixture_hooks(bool $collaboration): void {
    $GLOBALS['wp_filter'] = array(); $GLOBALS['privacy_remove_fault'] = '';
    $GLOBALS['privacy_maintenance_calls'] = array(); $GLOBALS['privacy_unrelated_calls'] = array();
    game_privacy_preinitialize_maintenance_guards();
    $preinitialized = $GLOBALS['wp_filter']; $GLOBALS['wp_filter'] = array();
    foreach ($preinitialized as $name => $priorities) {
        foreach ($priorities as $priority => $entries) {
            foreach ($entries as $entry) { add_action($name, $entry['function'], $priority, $entry['accepted_args']); }
        }
    }
    foreach (game_privacy_maintenance_callbacks() as $method => $priority) {
        if (!$collaboration && str_contains($method, 'collaboration')) { continue; }
        add_action('init', array('Shuzijun_App_Content_API', $method), $priority, 0);
    }
    add_action('init', static function (): void { $GLOBALS['privacy_unrelated_calls'][] = 'wp_core_init'; }, 10, 0);
    add_action('clean_post_cache', static function (int $id): void { $GLOBALS['privacy_unrelated_calls'][] = $id; }, 10, 1);
    add_action('rest_api_init', array('Shuzijun_App_Content_API', 'register_routes'), 10, 0);
}
$expectedMaintenance = array('register_public_preview_image_size' => 10,
    'ensure_roles' => 20, 'ensure_collaboration_storage' => 21,
    'ensure_push_storage' => 22, 'ensure_fan_apple_revocation_schedule' => 40,
    'ensure_fan_apple_event_schedule' => 41, 'ensure_fan_apple_tombstone_schedule' => 42,
    'ensure_collaboration_outbox_schedule' => 43, 'ensure_push_outbox_schedule' => 44);
privacy_check(game_privacy_maintenance_callbacks() === $expectedMaintenance, 'exact nine reviewed method/priority pairs');
$apiSource = file_get_contents(dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php');
preg_match_all("/add_action\\('init', array\\(__CLASS__, '([a-z_]+)'\\)(?:, ([0-9]+))?\\);/", $apiSource, $matches, PREG_SET_ORDER);
$actualMaintenance = array();
foreach ($matches as $match) { $actualMaintenance[$match[1]] = isset($match[2]) ? (int) $match[2] : 10; }
ksort($actualMaintenance); ksort($expectedMaintenance);
privacy_check($actualMaintenance === $expectedMaintenance && count($matches) === 9, 'no real API init hook omitted from reviewed list');
foreach (array(false, true) as $collaboration) {
    privacy_fixture_hooks($collaboration);
    privacy_check(has_action('muplugins_loaded', 'game_privacy_block_maintenance') === PHP_INT_MAX
        && has_action('init', 'game_privacy_block_maintenance') === PHP_INT_MIN, 'guards at mu tail and init head');
    do_action('muplugins_loaded');
    foreach ($expectedMaintenance as $method => $priority) {
        privacy_check(has_action('init', array('Shuzijun_App_Content_API', $method)) === false, 'each maintenance callback removed');
    }
    // Another plugin registration between muplugins_loaded and init is caught.
    add_action('init', array('Shuzijun_App_Content_API', 'ensure_push_storage'), 22, 0);
    do_action('init');
    do_action('clean_post_cache', 115);
    privacy_check($GLOBALS['privacy_maintenance_calls'] === array(), 'no reviewed maintenance callback executed');
    privacy_check($GLOBALS['privacy_unrelated_calls'] === array('wp_core_init', 115), 'unrelated init and targeted cache hook preserved');
    privacy_check(has_action('rest_api_init', array('Shuzijun_App_Content_API', 'register_routes')) === 10,
        'App non-init hooks not removed');
}
foreach (array('failure' => 'maintenance_hook_remove', 'no-op' => 'maintenance_hook_remaining') as $fault => $code) {
    privacy_fixture_hooks(true); $GLOBALS['privacy_remove_fault'] = $fault;
    privacy_reject(static fn() => do_action('muplugins_loaded'), $code);
    privacy_check($GLOBALS['privacy_maintenance_calls'] === array(), 'failed or skipped removal aborts before init');
}
privacy_fixture_hooks(true);
remove_action('init', array('Shuzijun_App_Content_API', 'ensure_roles'), 20);
add_action('init', array('Shuzijun_App_Content_API', 'ensure_roles'), 19, 0);
privacy_reject(static fn() => do_action('muplugins_loaded'), 'maintenance_hook_priority');
privacy_fixture_hooks(true);
add_action('init', array('Shuzijun_App_Content_API', 'ensure_push_storage'), 99, 0);
privacy_reject(static fn() => do_action('muplugins_loaded'), 'maintenance_hook_remaining');
foreach (array(array('Shuzijun_App_Content_API', 'future_unreviewed_maintenance'),
    array('SHUZIJUN_APP_CONTENT_API', 'ensure_roles'), 'Shuzijun_App_Content_API::ensure_roles') as $unknown) {
    privacy_fixture_hooks(true); add_action('init', $unknown, 30, 0);
    privacy_reject(static fn() => do_action('muplugins_loaded'), 'maintenance_hook_remaining');
    privacy_check($GLOBALS['privacy_maintenance_calls'] === array(), 'unreviewed or alternate callback refused');
}
privacy_fixture_hooks(true); do_action('muplugins_loaded');
add_action('init', array('Shuzijun_App_Content_API', 'future_unreviewed_maintenance'), 30, 0);
privacy_reject(static fn() => do_action('init'), 'maintenance_hook_remaining');
privacy_check($GLOBALS['privacy_maintenance_calls'] === array(), 'late unreviewed registration blocked before init dispatch');
$GLOBALS['wp_filter']['init'] = array();
privacy_reject(static fn() => game_privacy_block_maintenance(), 'maintenance_hook_shape');
unset($GLOBALS['wp_filter'], $GLOBALS['privacy_remove_fault']);

// Execute the shared, already-tested no-replay/cache library without either CLI.
define('YISHU_PUBLIC_SELECTION_LIBRARY_ONLY', true);
require_once dirname(__DIR__) . '/operations/apply-public-experience-selection.php';
foreach (array('SELECT 1', ' SELECT * FROM wp_posts', 'SHOW TABLES', 'DESCRIBE wp_posts', 'EXPLAIN SELECT 1') as $sql) {
    privacy_check(game_privacy_guard_query($sql) === $sql, 'bootstrap accepts only read statements');
}
foreach (array('UPDATE wp_options SET option_value=1', 'INSERT INTO wp_posts VALUES (1)',
    'DELETE FROM wp_posts', 'CREATE TABLE x(a INT)', 'COMMIT', 'START TRANSACTION',
    'SELECT 1 INTO OUTFILE \'/tmp/x\'', '/* ignored */ UPDATE wp_posts SET post_content=1') as $sql) {
    privacy_reject(static fn() => game_privacy_guard_query($sql), 'unreviewed_database_write');
}
GamePrivacyRuntime::$allowPageWrite = true;
foreach (array('START TRANSACTION', 'COMMIT', 'ROLLBACK') as $sql) {
    privacy_check(game_privacy_guard_query($sql) === $sql, 'explicit transaction mode permits control');
}
$exactSQL = "UPDATE `wp_posts` SET post_content='fixed' WHERE ID=115 AND post_type='page' AND post_name='app-privacy' AND post_status='publish'";
GamePrivacyRuntime::$pageUpdateQuery = $exactSQL;
privacy_check(game_privacy_guard_query($exactSQL) === $exactSQL, 'only one exact prepared page write allowed');
privacy_reject(static fn() => game_privacy_guard_query(str_replace('ID=115', 'ID=116', $exactSQL)), 'unreviewed_database_write');
privacy_reject(static fn() => game_privacy_guard_query('UPDATE `wp_options` SET option_value=1'), 'unreviewed_database_write');
GamePrivacyRuntime::$allowPageWrite = false; GamePrivacyRuntime::$pageUpdateQuery = null;
game_privacy_preinitialize_runtime_guards();
privacy_check($GLOBALS['wp_filter']['query'][PHP_INT_MAX][0]['function'] === 'game_privacy_guard_query'
    && $GLOBALS['wp_filter']['muplugins_loaded'][PHP_INT_MIN][0]['function'] === 'game_privacy_isolate_cache',
    'read-only SQL guard starts before bootstrap and cache isolation before plugin init');
unset($GLOBALS['wp_filter']);

final class PrivacySharedCacheFixture {
    public bool $ready = true;
    public array $deletions = array();
    public int $runtimeFlushes = 0;
    public function redis_status(): bool { return $this->ready; }
    public function flush_runtime(): bool { ++$this->runtimeFlushes; return true; }
    public function delete(mixed $key, string $group): bool { $this->deletions[] = array($key, $group); return false; }
}
function wp_using_ext_object_cache(): bool { return true; }
$wpdb = (object) array('blogid' => 1);
$shared = new PrivacySharedCacheFixture();
$GLOBALS['wp_object_cache'] = $shared;
game_privacy_isolate_cache();
$local = $GLOBALS['wp_object_cache'];
privacy_check($local instanceof PublicSelectionMemoryCache && GamePrivacyRuntime::$sharedCache === $shared,
    'isolated cache replaces shared object without writing it');
$local->set(115, 'uncommitted synthetic row', 'posts');
privacy_check($shared->deletions === array() && $shared->runtimeFlushes === 0, 'local reads/writes never touch shared');
game_privacy_invalidate_shared(115);
privacy_check($shared->deletions === array(array(115, 'posts'), array('last_changed', 'posts'))
    && $shared->runtimeFlushes === 2 && $local->get(115, 'posts') === false,
    'only exact page object and query generation invalidated, no hooks or global flush');
privacy_reject(static fn() => game_privacy_invalidate_shared(116), 'cache_post_scope');
privacy_reject(static fn() => game_privacy_isolate_cache(), 'fresh_cache_isolation');
$shared->ready = false;
privacy_reject(static fn() => game_privacy_invalidate_shared(115), 'shared_cache_unavailable');
privacy_check(count($shared->deletions) === 2, 'disconnected persistent cache refuses before invalidation');
GamePrivacyRuntime::$sharedCache = null; GamePrivacyRuntime::$persistentCache = false;
unset($GLOBALS['wp_object_cache'], $wpdb);

$source = file_get_contents(dirname(__DIR__) . '/operations/update-game-privacy-policy.php');
foreach (array("public const POST_ID = 115;", "public const SITE = '/var/www/html/shuzijun.com.cn';",
    "public const LOCK = '/var/lib/shuzijun-sync/site-operation.lock';", "'root_php83_cli_required'",
    "'transactional_posts_required'", "game_privacy_sync_directory(GamePrivacyPolicy::BACKUPS)",
    "game_privacy_sync_directory(\$path)", "fopen(\$path . '/receipt.json', 'xb')",
    "DB_NAME === 'wordpress'", "\$wpdb->get_var('SELECT DATABASE()') === 'wordpress'",
    "['pre_wp_mail'][PHP_INT_MAX]", "['pre_http_request'][PHP_INT_MAX]", "'posts_triggers'",
    "ob_start(static fn(string \$bytes): string => '')", "register_shutdown_function(",
    "\$_SERVER = game_privacy_server();", "set_error_handler('game_privacy_warning')",
    "game_privacy_preinitialize_maintenance_guards();", "'game_privacy_authority', 'game_privacy_invalidate_shared'",
    'public_selection_pin_database();', 'game_privacy_preinitialize_runtime_guards();',
    'ca1e99bc39a83837d3f71750e03163f0764f6f070c35346ec7d1684f6c07702b',
    'SELECT @@SESSION.autocommit', '$commitAttempted = true;', '$GLOBALS[\'wp_object_cache\'] instanceof PublicSelectionMemoryCache') as $contract) {
    privacy_check(str_contains($source, $contract), 'production boundary retained');
}
foreach (array('wp_update_post(', 'wp_cache_flush(', 'wp_remote_', 'wp_mail(', 'shell_exec(', 'exec(', 'system(',
    'remove_all_actions(', 'remove_all_filters(', 'clean_post_cache(') as $forbidden) {
    privacy_check(!str_contains($source, $forbidden), 'no unrelated side-effect API');
}
privacy_check(strpos($source, '$lock = game_privacy_bootstrap();') < strpos($source, '[$mode, $value] = game_privacy_arguments'),
    'authority/runtime before mutation mode');
echo 'PASS ' . $checks . " checks; synthetic DB only, no production execution.\n";
