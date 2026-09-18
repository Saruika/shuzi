<?php
declare(strict_types=1);

// Synthetic only: no WordPress bootstrap, filesystem writes, database or network.
define('YISHU_GAME_SCHEMA_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/operations/install-game-leaderboard-schema.php';
$checks = 0;
function schema_check(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function schema_reject(callable $callback, string $label): void {
    try { $callback(); } catch (GameSchemaFailure $error) { schema_check(true, $label); return; }
    throw new RuntimeException($label);
}
$digest = str_repeat('a', 64);
$server = game_schema_server_environment();
schema_check($server === array('HTTP_HOST' => 'www.shuzijun.com.cn', 'SERVER_NAME' => 'www.shuzijun.com.cn',
    'HTTPS' => 'on', 'SERVER_PORT' => '443', 'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/',
    'REMOTE_ADDR' => '127.0.0.1', 'SERVER_PROTOCOL' => 'HTTP/1.1',
    'PHP_SELF' => '/index.php', 'SCRIPT_NAME' => '/index.php',
    'SCRIPT_FILENAME' => GAME_SCHEMA_SITE . '/index.php'), 'actual fixed WordPress server environment');
schema_check($server['PHP_SELF'] === '/index.php' && $server['SCRIPT_NAME'] === '/index.php',
    'load.php PHP_SELF and SCRIPT_NAME are present before WordPress bootstrap');
schema_check(!isset($server['HTTP_AUTHORIZATION'], $server['PHP_AUTH_USER'], $server['PHP_AUTH_PW']),
    'fixed mapping does not inherit caller credentials');
$arguments = array('backup=/var/backups/private/database.sql', 'sha256=' . $digest);
schema_check(game_schema_arguments($arguments) === array('apply' => false,
    'backup' => '/var/backups/private/database.sql', 'sha256' => $digest), 'default preflight');
schema_check(game_schema_arguments(array_merge($arguments, array('apply')))['apply'] === true, 'explicit apply');
foreach (array(array(), array('apply'), array_merge($arguments, array('apply', 'apply')),
    array_merge($arguments, array('--apply')), array_merge($arguments, array('other=value')),
    array_merge($arguments, array('backup=/etc/other')), array_merge($arguments, array('sha256=' . $digest)),
    array($arguments[0], 'sha256=' . strtoupper($digest)), array($arguments[0], 'sha256=short'),
    array($arguments[0], $arguments[1], null)) as $bad) {
    schema_reject(static fn() => game_schema_arguments($bad), 'ambiguous/invalid arguments rejected');
}
foreach (array('relative.sql', '/var/backups/../x.sql', '/var//backup/x.sql', '/var/./x.sql',
    '/var/private name.sql', "/var/private\nname.sql", GAME_SCHEMA_SITE . '/private.sql', GAME_SCHEMA_SITE) as $path) {
    schema_reject(static fn() => game_schema_arguments(array('backup=' . $path, $arguments[1])), 'unsafe dump path');
}
$stat = array('mode' => 0100600, 'uid' => 0, 'gid' => 0, 'nlink' => 1,
    'size' => 123, 'dev' => 2, 'ino' => 3, 'mtime' => 4, 'ctime' => 5);
game_schema_validate_stat($stat, 0600, true); schema_check(true, 'private root-only dump');
foreach (array('mode' => 0100640, 'uid' => 501, 'gid' => 33, 'nlink' => 2) as $key => $value) {
    schema_reject(static fn() => game_schema_validate_stat(array_replace($stat, array($key => $value)), 0600, true), 'unsafe dump stat');
}
foreach (array(0120600, 0040600, 0104600, 0106600) as $mode) {
    schema_reject(static fn() => game_schema_validate_stat(array_replace($stat, array('mode' => $mode)), 0600, true), 'link/directory/special mode rejected');
}
schema_check(game_schema_same_file($stat, $stat), 'stable descriptor');
foreach ($stat as $key => $value) {
    schema_check(!game_schema_same_file($stat, array_replace($stat, array($key => $value + 1))), 'every stat change detected');
}
$types = array('fan_user_id' => 'bigint unsigned', 'rules_version' => 'varchar(32)', 'score' => 'int',
    'ending_id' => 'varchar(64)', 'origin' => 'varchar(32)', 'answered' => 'smallint unsigned', 'achieved_at' => 'datetime');
$columns = array();
foreach ($types as $field => $type) {
    $columns[] = array('Field' => $field, 'Type' => $type, 'Null' => 'NO', 'Default' => null, 'Extra' => '');
}
$indexes = array();
foreach (array('PRIMARY' => array('fan_user_id'), 'score_time_user' => array('score', 'achieved_at', 'fan_user_id')) as $name => $fields) {
    foreach ($fields as $number => $field) {
        $indexes[] = array('Key_name' => $name, 'Seq_in_index' => (string) ($number + 1),
            'Column_name' => $field, 'Non_unique' => $name === 'PRIMARY' ? '0' : '1',
            'Sub_part' => null, 'Index_type' => 'BTREE', 'Collation' => 'A', 'Null' => '', 'Visible' => 'YES', 'Expression' => null);
    }
}
game_schema_validate_shape($columns, $indexes); schema_check(true, 'MySQL8 complete exact shape');
$legacy = $columns;
$legacy[0]['Type'] = 'bigint(20) unsigned'; $legacy[2]['Type'] = 'int(11)'; $legacy[5]['Type'] = 'smallint(5) unsigned';
game_schema_validate_shape($legacy, $indexes); schema_check(true, 'display-width variants');
foreach (array('Type' => 'varchar(99)', 'Field' => 'extra', 'Null' => 'YES', 'Default' => '0', 'Extra' => 'auto_increment') as $key => $value) {
    $bad = $columns; $bad[0][$key] = $value;
    schema_reject(static fn() => game_schema_validate_shape($bad, $indexes), 'unknown column definition');
}
$bad = $columns; unset($bad[0]['Default']);
schema_reject(static fn() => game_schema_validate_shape($bad, $indexes), 'missing column field');
schema_reject(static fn() => game_schema_validate_shape(array_slice($columns, 1), $indexes), 'missing column');
schema_reject(static fn() => game_schema_validate_shape(array_merge($columns, array($columns[0])), $indexes), 'extra column');
schema_reject(static fn() => game_schema_validate_shape(array_reverse($columns), $indexes), 'reordered columns');
foreach (array('Key_name' => 'foreign', 'Seq_in_index' => 9, 'Column_name' => 'origin', 'Non_unique' => '0',
    'Sub_part' => 2, 'Index_type' => 'HASH', 'Collation' => 'D', 'Null' => 'YES', 'Visible' => 'NO', 'Expression' => 'score+1') as $key => $value) {
    $bad = $indexes; $bad[1][$key] = $value;
    schema_reject(static fn() => game_schema_validate_shape($columns, $bad), 'unknown index definition');
}
$bad = $indexes; $bad[2] = $bad[1];
schema_reject(static fn() => game_schema_validate_shape($columns, $bad), 'duplicate index sequence');
schema_reject(static fn() => game_schema_validate_shape($columns, array_slice($indexes, 1)), 'missing index');
schema_reject(static fn() => game_schema_validate_shape($columns, array_merge($indexes, array($indexes[0]))), 'extra index');

$absent = array('state' => 'absent', 'rows' => 0);
$installed = array('state' => 'installed', 'rows' => 0);
$writes = 0;
$neverInstall = static function () use (&$writes) { ++$writes; throw new RuntimeException('unexpected mutation'); };
schema_check(game_schema_execute(false, static fn() => $absent, $neverInstall) === 'preflight_absent', 'absent preflight never creates');
schema_check(game_schema_execute(false, static fn() => $installed, $neverInstall) === 'preflight_installed', 'installed preflight read only');
schema_check(game_schema_execute(true, static fn() => array('state' => 'installed', 'rows' => 3), $neverInstall)
    === 'already_installed_no_change', 'known populated table not mutated or claimed empty');
schema_check($writes === 0, 'no ensure invoked for read-only states');
$snapshots = array($absent, $absent, $installed);
schema_check(game_schema_execute(true, static function () use (&$snapshots) { return array_shift($snapshots); },
    static function () use (&$writes) { ++$writes; return true; }) === 'installed_verified_zero_rows', 'first create verified');
schema_check($writes === 1 && $snapshots === array(), 'exactly one ensure and postcheck');
foreach (array(false, 1, null) as $badResult) {
    $calls = 0;
    schema_reject(static function () use (&$calls, $badResult, $absent) {
        game_schema_execute(true, static fn() => $absent,
            static function () use (&$calls, $badResult) { ++$calls; return $badResult; });
    }, 'strict ensure boolean');
    schema_check($calls === 1, 'failed ensure not retried');
}
$snapshots = array($absent, $installed);
schema_reject(static fn() => game_schema_execute(true, static function () use (&$snapshots) { return array_shift($snapshots); }, $neverInstall), 'race before create rejected');
foreach (array($absent, array('state' => 'installed', 'rows' => 1)) as $post) {
    $snapshots = array($absent, $absent, $post);
    schema_reject(static fn() => game_schema_execute(true, static function () use (&$snapshots) { return array_shift($snapshots); },
        static fn() => true), 'partial or nonzero initial result rejected');
}
schema_reject(static fn() => game_schema_execute(true, static fn() => array('state' => 'unknown'), $neverInstall), 'unknown state rejected');
schema_reject(static fn() => game_schema_execute(true, static function () { throw new GameSchemaFailure('unknown_existing_option'); }, $neverInstall), 'unknown table blocks ensure');
schema_check($writes === 1, 'failure paths did not add mutations');

// Warning diagnostics preserve @ semantics without emitting the sensitive
// warning message, path, caller source or SQL. Missing files still fail guards.
game_schema_stage('bootstrap');
schema_check(game_schema_diagnostic(E_WARNING, '/private/account/wp-load.php', 123)
    === 'stage=bootstrap; file=wp-load.php; line=123; level=2', 'controlled basename only');
schema_check(game_schema_diagnostic(E_WARNING, '/private/person-secret.php', 9)
    === 'stage=bootstrap; file=other; line=9; level=2', 'unlisted basename hidden');
schema_check(game_schema_diagnostic(999999, '/private/person-secret.php', -9)
    === 'stage=bootstrap; file=other; line=0; level=0', 'unknown level and invalid line bounded');
schema_reject(static fn() => game_schema_stage('secret stage'), 'stage enum cannot echo arbitrary data');
$previousReporting = error_reporting(E_ALL);
set_error_handler('game_schema_warning');
try {
    schema_check(@lstat('/__yishu_schema_synthetic_missing__/file') === false, 'suppressed lstat returns false');
    schema_check(@fopen('/__yishu_schema_synthetic_missing__/file', 'rb') === false, 'suppressed fopen returns false');
    try {
        game_schema_require(is_array(@lstat('/__yishu_schema_synthetic_missing__/file')), 'file_path');
        throw new RuntimeException('missing-file guard was bypassed');
    } catch (GameSchemaFailure $error) {
        schema_check($error->getMessage() === 'file_path' && $error->diagnostic === null, 'existing explicit missing-file guard retained');
    }
    try {
        game_schema_warning(E_WARNING, 'token-secret /private/account/private.sql SQL body', '/private/wp-config.php', 71);
        throw new RuntimeException('unmasked warning not rejected');
    } catch (GameSchemaFailure $error) {
        schema_check($error->getMessage() === 'runtime_warning', 'unmasked warning still aborts');
        schema_check($error->diagnostic === 'stage=bootstrap; file=wp-config.php; line=71; level=2', 'safe warning metadata');
        schema_check(!str_contains($error->getMessage() . $error->diagnostic, 'secret')
            && !str_contains($error->diagnostic, '/private/'), 'warning message and path omitted');
    }
    game_schema_stage('backup_verify');
    try {
        trigger_error('fixture-private-token', E_USER_WARNING);
        throw new RuntimeException('actual warning not rejected');
    } catch (GameSchemaFailure $error) {
        schema_check($error->getMessage() === 'runtime_warning'
            && preg_match('/^stage=backup_verify; file=other; line=[0-9]+; level=512$/D', $error->diagnostic) === 1,
            'actual PHP warning has safe level and stage');
    }
} finally { restore_error_handler(); error_reporting($previousReporting); }

// Execute actual snapshot queries against a synthetic adapter. This exercises
// rejection sequencing, not MySQL syntax, permissions or WP's actual readiness.
define('ARRAY_A', 'ARRAY_A');
final class Shuzijun_App_Content_API {
    private static function game_leaderboard_storage_ready(): bool { return $GLOBALS['fixture_ready']; }
    public static function __callStatic(string $name, array $arguments): void { ++$GLOBALS['maintenance_calls']; }
}

// WP_Hook-compatible callback storage/dispatch. Exercise the actual isolation
// functions, not a source-fragment-only assertion; no WordPress or real DB load.
final class SchemaMaintenanceHook {
    public array $callbacks = array();
    public bool $refuseRemoval = false;
    private function key($callback): string {
        if (is_string($callback)) { return $callback; }
        if (is_array($callback)) { return (is_object($callback[0]) ? spl_object_hash($callback[0]) : $callback[0]) . '::' . $callback[1]; }
        return spl_object_hash($callback);
    }
    public function add($callback, int $priority, int $accepted = 0): void {
        $this->callbacks[$priority][$this->key($callback)] = array('function' => $callback, 'accepted_args' => $accepted);
    }
    public function remove($callback, int $priority): bool {
        $key = $this->key($callback);
        if ($this->refuseRemoval || !isset($this->callbacks[$priority][$key])) { return false; }
        unset($this->callbacks[$priority][$key]);
        if ($this->callbacks[$priority] === array()) { unset($this->callbacks[$priority]); }
        return true;
    }
    public function dispatch(): void {
        ksort($this->callbacks, SORT_NUMERIC);
        foreach (array_keys($this->callbacks) as $priority) {
            foreach ($this->callbacks[$priority] ?? array() as $entry) { $entry['function'](); }
        }
    }
}
function remove_action(string $hook, $callback, int $priority = 10): bool {
    return $GLOBALS['wp_filter'][$hook]->remove($callback, $priority);
}
function schema_maintenance_fixture(bool $collaboration = true): void {
    $GLOBALS['wp_filter'] = array();
    $GLOBALS['maintenance_calls'] = $GLOBALS['other_hook_calls'] = 0;
    game_schema_register_init_isolation();
    foreach ($GLOBALS['wp_filter'] as $name => $priorities) {
        $hook = new SchemaMaintenanceHook();
        foreach ($priorities as $priority => $entries) {
            foreach ($entries as $entry) { $hook->add($entry['function'], $priority, $entry['accepted_args']); }
        }
        $GLOBALS['wp_filter'][$name] = $hook;
    }
    foreach (game_schema_init_maintenance() as $method => $priority) {
        if (!$collaboration && str_starts_with($method, 'ensure_collaboration_')) { continue; }
        $GLOBALS['wp_filter']['init']->add(array('Shuzijun_App_Content_API', $method), $priority);
    }
    $GLOBALS['wp_filter']['init']->add(static function (): void { ++$GLOBALS['other_hook_calls']; }, 25);
}
$apiSource = file_get_contents(dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php');
preg_match_all("/add_action\\('init', array\\(__CLASS__, '([^']+)'\\), ([0-9]+)\\);/", $apiSource, $registered, PREG_SET_ORDER);
$actualInit = array();
foreach ($registered as $entry) { $actualInit[$entry[1]] = (int) $entry[2]; }
$reviewedInit = game_schema_init_maintenance(); ksort($actualInit); ksort($reviewedInit);
schema_check(count($actualInit) === 8 && $actualInit === $reviewedInit, 'all actual API init maintenance covered; plugin drift rejected');
foreach (array(false, true) as $collaboration) {
    schema_maintenance_fixture($collaboration);
    schema_check(count(game_schema_api_init_callbacks()) === ($collaboration ? 8 : 6), 'six mandatory and optional collaboration pair registered');
    $GLOBALS['wp_filter']['muplugins_loaded']->dispatch();
    schema_check(game_schema_api_init_callbacks() === array(), 'actual remove_action removes only fixed API init hooks');
    $GLOBALS['wp_filter']['init']->dispatch();
    schema_check($maintenance_calls === 0 && $other_hook_calls === 1, 'no API maintenance; unrelated init preserved');
}
foreach (array_keys(game_schema_init_maintenance()) as $method) {
    schema_maintenance_fixture();
    remove_action('init', array('Shuzijun_App_Content_API', $method), game_schema_init_maintenance()[$method]);
    schema_reject(static fn() => $GLOBALS['wp_filter']['muplugins_loaded']->dispatch(), 'missing mandatory hook or incomplete conditional pair rejected');
    schema_check($maintenance_calls === 0, 'missing hook fails before maintenance execution');
}
foreach (array('ensure_roles', 'unexpected_new_init_mutation') as $method) {
    schema_maintenance_fixture();
    $GLOBALS['wp_filter']['init']->add(array('Shuzijun_App_Content_API', $method), 19);
    schema_reject(static fn() => $GLOBALS['wp_filter']['muplugins_loaded']->dispatch(), 'duplicate, changed priority or unknown API init rejected');
}
schema_maintenance_fixture();
$GLOBALS['wp_filter']['init']->refuseRemoval = true;
schema_reject(static fn() => $GLOBALS['wp_filter']['muplugins_loaded']->dispatch(), 'failed removal is blocking');
foreach (array(array('Shuzijun_App_Content_API', 'ensure_roles'), 'Shuzijun_App_Content_API::ensure_roles',
    array('\\SHUZIJUN_APP_CONTENT_API', 'ENSURE_ROLES')) as $late) {
    schema_maintenance_fixture();
    $GLOBALS['wp_filter']['muplugins_loaded']->dispatch();
    $GLOBALS['wp_filter']['init']->add($late, 20);
    schema_reject(static fn() => $GLOBALS['wp_filter']['init']->dispatch(), 'earliest init fence rejects equivalent late callback forms');
    schema_check($maintenance_calls === 0 && $other_hook_calls === 0, 'late re-registration aborts before any normal init');
}
schema_maintenance_fixture();
remove_action('init', array('Shuzijun_App_Content_API', 'ensure_roles'), 20);
$GLOBALS['wp_filter']['init']->add('Shuzijun_App_Content_API::ensure_roles', 20);
$GLOBALS['wp_filter']['muplugins_loaded']->dispatch();
$GLOBALS['wp_filter']['init']->dispatch();
schema_check($maintenance_calls === 0 && $other_hook_calls === 1, 'equivalent static string registration removed');
schema_maintenance_fixture();
$GLOBALS['wp_filter']['init'] = null;
schema_reject(static fn() => game_schema_remove_init_maintenance(), 'unknown hook storage shape rejected');
unset($GLOBALS['wp_filter']);

final class SchemaSnapshotFakeDB {
    public string $prefix = 'wp_';
    public string $options = 'wp_options';
    public string $last_error = '';
    public ?string $found = null;
    public array $optionRows = array();
    public array $columns;
    public array $indexes;
    public string $engine = 'InnoDB';
    public string $extras = '0';
    public string $rows = '0';
    public function prepare(string $query, ...$parameters): string { return $query; }
    public function esc_like(string $value): string { return $value; }
    public function get_var(string $query): ?string {
        if (str_starts_with($query, 'SHOW TABLES')) { return $this->found; }
        if (str_contains($query, 'information_schema.')) { return $this->extras; }
        if (str_starts_with($query, 'SELECT COUNT(*)')) { return $this->rows; }
        throw new RuntimeException('unexpected fake query');
    }
    public function get_results(string $query, $format): array {
        if (str_starts_with($query, 'SELECT option_value')) { return $this->optionRows; }
        if (str_starts_with($query, 'SHOW COLUMNS')) { return $this->columns; }
        if (str_starts_with($query, 'SHOW INDEX')) { return $this->indexes; }
        throw new RuntimeException('unexpected fake query');
    }
    public function get_row(string $query, $format): array {
        schema_check(str_starts_with($query, 'SHOW TABLE STATUS'), 'only bounded table metadata');
        return array('Name' => 'wp_yishu_game_leaderboard', 'Engine' => $this->engine);
    }
}
$wpdb = new SchemaSnapshotFakeDB(); $wpdb->columns = $columns; $wpdb->indexes = $indexes;
$fixture_ready = true;
schema_check(game_schema_snapshot() === $absent, 'no table and no option is first-create state');
$wpdb->optionRows = array(array('option_value' => '1', 'autoload' => 'off'));
schema_reject(static fn() => game_schema_snapshot(), 'orphan option rejected before creation');
$wpdb->found = 'wp_yishu_game_leaderboard';
schema_check(game_schema_snapshot() === $installed, 'exact installed snapshot');
$wpdb->rows = '9';
schema_check(game_schema_snapshot() === array('state' => 'installed', 'rows' => 9), 'existing populated state read only');
$wpdb->rows = '0';
foreach (array(array(), array(array('option_value' => '2', 'autoload' => 'off')),
    array(array('option_value' => '1', 'autoload' => 'on')),
    array(array('option_value' => '1', 'autoload' => 'off'), array('option_value' => '1', 'autoload' => 'off'))) as $optionRows) {
    $wpdb->optionRows = $optionRows;
    schema_reject(static fn() => game_schema_snapshot(), 'unknown or duplicate version option rejected');
}
$wpdb->optionRows = array(array('option_value' => '1', 'autoload' => 'off'));
$fixture_ready = false;
schema_reject(static fn() => game_schema_snapshot(), 'actual Reflection readiness false is blocking');
$fixture_ready = true;
foreach (array('engine' => 'MyISAM', 'extras' => '1', 'rows' => '-1', 'last_error' => 'synthetic', 'found' => 'foreign_table') as $property => $value) {
    $saved = $wpdb->$property; $wpdb->$property = $value;
    schema_reject(static fn() => game_schema_snapshot(), 'engine/side-effect/read-error mismatch rejected');
    $wpdb->$property = $saved;
}

$source = file_get_contents(dirname(__DIR__) . '/operations/install-game-leaderboard-schema.php');
foreach (array("const GAME_SCHEMA_SITE = '/var/www/html/shuzijun.com.cn'", "DB_NAME === 'wordpress'", "'SELECT DATABASE()'",
    "'game_leaderboard_storage_ready'", "'app_service_environment'", '::ensure_game_leaderboard_storage()',
    "'DISABLE_WP_CRON'", "'pre_wp_mail'", "'pre_http_request'", 'LOCK_EX | LOCK_NB',
    'information_schema.TRIGGERS', 'information_schema.REFERENTIAL_CONSTRAINTS', 'game_schema_verify_candidate();') as $fragment) {
    schema_check(str_contains($source, $fragment), 'fixed production guard retained');
}
foreach (array('wp_create_user(', 'wp_insert_user(', 'rest_do_request(', 'DROP TABLE', 'TRUNCATE TABLE',
    'DELETE FROM', 'INSERT INTO', 'curl_exec(', 'shell_exec(', 'exec(') as $forbidden) {
    schema_check(!str_contains($source, $forbidden), 'no out-of-scope mutation/network/shell');
}
schema_check(str_contains($source, 'no explicit account or REST operation performed')
    && !str_contains($source, 'no account or REST write performed'), 'report describes only explicit helper operations');
echo "game-schema-installer: {$checks} synthetic checks passed; not WordPress/MySQL or production acceptance\n";
