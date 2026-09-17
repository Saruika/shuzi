<?php
declare(strict_types=1);

// Pure offline tests: no WordPress bootstrap, database, account or network.
// Some locally bundled PHP builds omit POSIX. Only this test process supplies
// its file-owning UID for receipt permission checks; server preflight still
// requires the real POSIX extension and the dedicated review process user.
$mocked_posix = !function_exists('posix_geteuid');
if ($mocked_posix) { function posix_geteuid(): int { return getmyuid(); } }
define('YISHU_REVIEW_GAME_HARNESS_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/operations/test-review-game-leaderboard.php';
$checks = 0;
function check_review_game(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function reject_review_game(callable $callback, string $label): void {
    try { $callback(); }
    catch (ReviewGameFailure $error) { check_review_game(true, $label); return; }
    throw new RuntimeException($label);
}
$run = str_repeat('a', 32);
check_review_game(review_game_arguments(array()) === array('preflight', null), 'default is read only');
check_review_game(review_game_arguments(array('preflight')) === array('preflight', null), 'explicit read-only mode');
foreach (array('run', 'cleanup', 'install-schema') as $mode) {
    check_review_game(review_game_arguments(array($mode . '=' . $run)) === array($mode, $run), 'one explicit positional mode');
}
foreach (array(array('--run=' . $run), array('run'), array('run='), array('run=../other'), array('run=' . strtoupper($run)),
    array('run=' . $run, 'cleanup=' . $run), array('install-schema=' . $run . '0'), array('clean=' . $run), array(null)) as $args) {
    reject_review_game(static fn() => review_game_arguments($args), 'invalid/multiple/ambiguous mode rejected');
}
reject_review_game(static fn() => review_game_main(array('run=' . $run)), 'local non-WP invocation fails before any write');
$facts = array('sapi' => 'cli', 'abspath' => '/srv/shuzijun-review/site/', 'realpath' => '/srv/shuzijun-review/site',
    'database' => 'shuzijun_review', 'selectedDatabase' => 'shuzijun_review', 'databaseUser' => 'shuzijun_review',
    'databaseHost' => 'localhost:/var/run/mysqld/mysqld.sock', 'environment' => 'review',
    'home' => 'https://review.shuzijun.com.cn', 'site' => 'https://review.shuzijun.com.cn',
    'osUser' => 'shuzijun-review', 'tablePrefix' => 'review_', 'cronDisabled' => true, 'httpBlocked' => true,
    'fileModsDisabled' => true, 'authority' => true, 'mailDenied' => true, 'httpDenied' => true,
    'noPushConfiguration' => true, 'productionHidden' => true, 'noPersistentCache' => true,
    'debugDisabled' => true, 'mysqlAvailable' => true, 'noNewPrivileges' => true,
    'databases' => array('information_schema', 'performance_schema', 'shuzijun_review'),
    'grants' => array('GRANT USAGE ON *.* TO `shuzijun_review`@`localhost`',
        'GRANT ALL PRIVILEGES ON `shuzijun_review`.* TO `shuzijun_review`@`localhost`'));
review_game_validate_isolation($facts); check_review_game(true, 'exact isolated facts accepted');
foreach ($facts as $key => $value) {
    $bad = $facts; unset($bad[$key]);
    reject_review_game(static fn() => review_game_validate_isolation($bad), 'every guard fact required');
    $bad[$key] = is_bool($value) ? false : 'production';
    reject_review_game(static fn() => review_game_validate_isolation($bad), 'every unsafe isolation fact rejected');
}
foreach (array(array_merge($facts['databases'], array('wordpress')), array(), array('information_schema')) as $databases) {
    $bad = array_replace($facts, array('databases' => $databases));
    reject_review_game(static fn() => review_game_validate_isolation($bad), 'cross-schema enumeration denied');
}
foreach (array(
    array('GRANT ALL PRIVILEGES ON *.* TO `shuzijun_review`@`localhost`', $facts['grants'][1]),
    array($facts['grants'][0], $facts['grants'][1] . ' WITH GRANT OPTION'),
    array($facts['grants'][0], str_replace('`localhost`', '`%`', $facts['grants'][1])),
    array($facts['grants'][0], str_replace('`shuzijun_review`.*', '`production`.*', $facts['grants'][1])),
    array_merge($facts['grants'], array('GRANT SELECT ON `wordpress`.* TO `shuzijun_review`@`localhost`')),
) as $grants) {
    reject_review_game(static fn() => review_game_validate_isolation(array_replace($facts, array('grants' => $grants))), 'elevated or ambiguous grants rejected');
}
$account = array('login' => review_game_planned_login($run, 0), 'id' => 17, 'sessionHashes' => array(str_repeat('b', 64)));
review_game_validate_account($account, $run, 0); check_review_game(true, 'exact run-owned cleanup account');
foreach (array(array_replace($account, array('login' => 'Test1')), array_replace($account, array('id' => '17')),
    array_replace($account, array('id' => -1)), array_replace($account, array('sessionHashes' => array('yishu_foreign'))),
    array_replace($account, array('sessionHashes' => array_fill(0, 4, str_repeat('b', 64))))) as $bad) {
    reject_review_game(static fn() => review_game_validate_account($bad, $run, 0), 'foreign cleanup target rejected');
}
reject_review_game(static fn() => review_game_validate_account($account, str_repeat('c', 32), 0), 'another run cannot select account');
reject_review_game(static fn() => review_game_validate_account($account, $run, 1), 'index substitution rejected');
reject_review_game(static fn() => review_game_planned_login($run, 102), 'bounded account plan');
check_review_game(filter_var(review_game_fixture_ip($run), FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false, 'run-local network bucket is valid synthetic IPv6');

$entry = array('rank' => 1, 'displayName' => '玩家', 'score' => -214, 'endingTitle' => '测试',
    'originName' => '测试', 'answered' => 62, 'achievedAt' => '2026-09-17T00:00:00Z', 'isMe' => true);
$page = array('rulesVersion' => 'life-v1', 'entries' => array($entry), 'myEntry' => $entry);
review_game_validate_page($page); check_review_game(true, 'valid negative-score own page');
review_game_validate_page(array('rulesVersion' => 'life-v1', 'entries' => array(), 'myEntry' => null));
check_review_game(true, 'empty page');
$top = array();
for ($index = 0; $index < 100; ++$index) { $top[] = array_replace($entry, array('rank' => $index + 1, 'score' => 12981, 'isMe' => false)); }
$outside = array_replace($entry, array('rank' => 101));
review_game_validate_page(array_replace($page, array('entries' => $top, 'myEntry' => $outside)));
check_review_game(true, 'top100 plus outside own entry');
$collision = array_replace($outside, array('rank' => 100));
reject_review_game(static fn() => review_game_validate_page(array_replace($page, array('entries' => $top, 'myEntry' => $collision))),
    'original mixed-snapshot rank100 collision rejected');
foreach (array(array_replace($entry, array('userID' => 17)), array_replace($entry, array('token' => 'synthetic')),
    array_replace($entry, array('score' => '12966')), array_replace($entry, array('score' => 16777216)),
    array_replace($entry, array('answered' => 109)), array_replace($entry, array('rank' => 0)),
    array_replace($entry, array('displayName' => '')), array_replace($entry, array('displayName' => str_repeat('a', 41)))) as $bad) {
    reject_review_game(static fn() => review_game_validate_entry($bad), 'privacy/type/range malformed entry rejected');
}
reject_review_game(static fn() => review_game_validate_page(array_replace($page, array('entries' => array_fill(0, 101, $entry)))), 'response cap enforced');
reject_review_game(static fn() => review_game_validate_page(array_replace($page, array('myEntry' => null))), 'visible own record must match myEntry');

final class ReviewEmptyPushFake {
    public string $prefix = 'review_';
    public string $users = 'review_users';
    public string $last_error = '';
    public bool $present = true;
    public bool $fail = false;
    public int $rows = 0;
    public int $orphans = 0;
    public int $collisions = 0;
    public array $installRows = array();
    public array $queries = array();
    public function esc_like(string $value): string { return $value; }
    public function prepare(string $sql, ...$args): array { return array($sql, $args); }
    public function get_var(array $query) {
        $this->queries[] = $query;
        $this->last_error = $this->fail ? 'synthetic' : '';
        if (str_starts_with($query[0], 'SHOW TABLES')) { return $this->present ? $query[1][0] : null; }
        if (str_contains($query[0], 'LEFT JOIN')) { return (string) $this->orphans; }
        if (str_contains($query[0], 'WHERE fan_user_id')) { return (string) $this->collisions; }
        if ($query[1][0] === 'review_yishu_push_install_states') { return (string) count($this->installRows); }
        return (string) $this->rows;
    }
    public function get_results(array $query, string $format): array {
        $this->queries[] = $query;
        check_review_game(str_contains($query[0], 'ORDER BY install_hash LIMIT 4097'), 'installation snapshot is bounded and deterministic');
        return $this->installRows;
    }
}
define('ARRAY_A', 'ARRAY_A');
$GLOBALS['wpdb'] = new ReviewEmptyPushFake();
review_game_require_empty_push_tables();
check_review_game(count($GLOBALS['wpdb']->queries) === 8, 'all four delivery tables checked without writes');
$GLOBALS['wpdb']->rows = 1;
reject_review_game(static fn() => review_game_require_empty_push_tables(), 'any pre-existing delivery record blocks deletion');
$GLOBALS['wpdb']->rows = 0; $GLOBALS['wpdb']->fail = true;
reject_review_game(static fn() => review_game_require_empty_push_tables(), 'failed table probe never means empty');
$GLOBALS['wpdb']->fail = false; $GLOBALS['wpdb']->present = false;
review_game_require_empty_push_tables(); check_review_game(true, 'absent delivery tables require no DDL');
$GLOBALS['wpdb']->present = true;
for ($index = 0; $index < 34; ++$index) {
    $GLOBALS['wpdb']->installRows[] = array('install_hash' => hash('sha256', 'synthetic-' . $index),
        'fan_user_id' => '0', 'session_option_id' => (string) ($index + 1), 'binding_generation' => '1',
        'desired_state' => 'unbound', 'session_expires_at' => '2026-10-01 00:00:00',
        'created_at' => '2026-09-01 00:00:00', 'updated_at' => '2026-09-02 00:00:00');
}
$baseline = review_game_install_states_snapshot();
check_review_game($baseline['count'] === 34 && array_keys($baseline) === array('present', 'count', 'sha256'),
    'existing installation rows retained only as private count and digest');
review_game_require_untouched_push($baseline); check_review_game(true, 'unchanged 34 installation records coexist with empty delivery tables');
$saved_rows = $GLOBALS['wpdb']->installRows;
$GLOBALS['wpdb']->installRows[0]['updated_at'] = '2026-09-03 00:00:00';
reject_review_game(static fn() => review_game_require_untouched_push($baseline), 'same count but modified installation record rejected');
$GLOBALS['wpdb']->installRows = $saved_rows; array_pop($GLOBALS['wpdb']->installRows);
reject_review_game(static fn() => review_game_require_untouched_push($baseline), 'missing existing installation record rejected');
$GLOBALS['wpdb']->installRows = array_fill(0, 4097, $saved_rows[0]);
reject_review_game(static fn() => review_game_install_states_snapshot(), 'oversized installation baseline fails closed');
$GLOBALS['wpdb']->installRows = $saved_rows;
review_game_require_no_orphan_install_states(); check_review_game(true, 'zero/unbound or existing-user ownership accepted');
$GLOBALS['wpdb']->orphans = 1;
reject_review_game(static fn() => review_game_require_no_orphan_install_states(), 'positive orphan installation owner blocks any creation');
$GLOBALS['wpdb']->orphans = 0;
review_game_require_new_install_identity(999, str_repeat('c', 64)); check_review_game(true, 'new UID and installation hash absent from existing state');
$GLOBALS['wpdb']->collisions = 1;
reject_review_game(static fn() => review_game_require_new_install_identity(999), 'fixture UID collision rejected');
reject_review_game(static fn() => review_game_require_new_install_identity(999, str_repeat('c', 64)), 'fixture installation collision rejected');
unset($GLOBALS['wpdb']);

$directory = realpath(sys_get_temp_dir()) . '/review-game-harness-test-' . bin2hex(random_bytes(12));
check_review_game(mkdir($directory, 0700), 'private temporary test directory');
$paths = array();
try {
    $receipt = new ReviewGameReceipt($directory, $run, 'run');
    $path = $directory . '/' . $run . '.run.json'; $paths[] = $path;
    check_review_game((fileperms($path) & 0777) === 0600 && $receipt->data['acceptancePassed'] === false, 'new private receipt cannot claim acceptance');
    $receipt->data['state'] = 'failed'; $receipt->data['failure'] = 'synthetic_failure';
    $receipt->data['accounts'] = array($account); $receipt->save();
    $read = new ReviewGameReceipt($directory, $run, 'run', true);
    check_review_game($read->data === $receipt->data, 'atomic private receipt roundtrip');
    reject_review_game(static fn() => new ReviewGameReceipt($directory, $run, 'run'), 'same run cannot silently retry');
    $read->data['state'] = 'cleaned'; $read->save();
    $cleaned = new ReviewGameReceipt($directory, $run, 'run', true);
    check_review_game($cleaned->data['failure'] === 'synthetic_failure' && $cleaned->data['acceptancePassed'] === false,
        'cleanup retains failure and never promotes acceptance');
    chmod($path, 0644); clearstatcache(true, $path);
    reject_review_game(static fn() => new ReviewGameReceipt($directory, $run, 'run', true), 'readable-by-others receipt refused');
    chmod($path, 0600); clearstatcache(true, $path);
    $linked = $directory . '/' . str_repeat('c', 32) . '.run.json'; $paths[] = $linked;
    symlink($path, $linked);
    reject_review_game(static fn() => new ReviewGameReceipt($directory, str_repeat('c', 32), 'run', true), 'receipt symlink refused');
    $hard = $directory . '/hard-link'; $paths[] = $hard;
    link($path, $hard); clearstatcache(true, $path);
    reject_review_game(static fn() => new ReviewGameReceipt($directory, $run, 'run', true), 'hard-linked receipt refused');
    unlink($hard); array_pop($paths); clearstatcache(true, $path);
    chmod($directory, 0755); clearstatcache(true, $directory);
    reject_review_game(static fn() => new ReviewGameReceipt($directory, $run, 'run', true), 'nonprivate directory refused');
    chmod($directory, 0700);
} finally {
    foreach (array_reverse($paths) as $path) { if (is_file($path) || is_link($path)) { unlink($path); } }
    rmdir($directory);
}
$source = file_get_contents(dirname(__DIR__) . '/operations/test-review-game-leaderboard.php');
check_review_game(str_contains($source, "'cleanup' => \"review-game: exact-run cleanup passed; acceptance remains recorded separately")
    && str_contains($source, "'httpTLSOrLoginTested' => false")
    && str_contains($source, "'commitDuringSingleStatementTested' => false"), 'evidence labels do not overclaim transport or cleanup');
check_review_game(str_contains($source, "return \$sql; // Observe the exact shipped SQL; never modify it.")
    && !str_contains($source, 'curl_exec') && !str_contains($source, 'wp_remote_get(')
    && !str_contains($source, 'shell_exec') && !str_contains($source, 'TRUNCATE ')
    && !str_contains($source, 'DROP TABLE '), 'no network transport, shell, broad deletion or production-query rewriting');
check_review_game(substr_count($source, '$this->syncDirectory();') === 2
    && str_contains($source, "'receipt_directory_sync'")
    && substr_count($source, 'review_game_require_untouched_push(') >= 7,
    'durable receipt directory publication and repeated pre-deletion delivery guards');
echo 'review-game-harness: ' . $checks . ' offline guard/receipt/page assertions passed; no WP/MySQL/network executed; POSIX facade '
    . ($mocked_posix ? 'test-only' : 'native') . "\n";
