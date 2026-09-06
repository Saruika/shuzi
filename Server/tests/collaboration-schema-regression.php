<?php
declare(strict_types=1);

// Runs the actual dormant trait, NOT the API entry point. The isolated fixture
// cannot register routes, send mail, load wp-config or activate the release fuse.
// Default: metadata/DDL fault harness, no database/network. --mysql additionally
// creates one random, empty test database through a local Unix socket and drops
// only that database in finally. No production WordPress runtime is loaded.
define('ABSPATH', __DIR__ . '/no-wordpress-runtime/');
define('ARRAY_A', 'ARRAY_A');
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php';

final class WP_Error {}
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function get_option($name, $default = false) { return $GLOBALS['schema_options'][$name] ?? $default; }
function update_option($name, $value, $autoload): bool {
    ++$GLOBALS['schema_option_writes'];
    $GLOBALS['schema_options'][$name] = $value;
    return true;
}
function do_action($name, ...$values): void {
    if ($name !== 'yishu_collaboration_security_audit'
        || count($values) !== 1
        || !in_array($values[0], array('schema_creation_failed', 'schema_lock_unavailable'), true)) {
        throw new RuntimeException('Unexpected or non-redacted audit event');
    }
    $GLOBALS['schema_events'][] = $values[0];
}
function dbDelta($sql) {
    global $wpdb;
    ++$GLOBALS['schema_delta_calls'];
    $GLOBALS['schema_ddl'][] = $sql;
    $wpdb->last_error = '';
    switch ($GLOBALS['schema_delta_failure']) {
        case 'false': return false;
        case 'nested': return array(array('invalid-result'));
        case 'error': $wpdb->last_error = 'synthetic_schema_error'; return array('attempted');
        case 'throw': throw new RuntimeException('synthetic_schema_exception');
    }
    $wpdb->install($sql);
    return array('Attempted schema update');
}

final class CollaborationSchemaHarness {
    use Shuzijun_App_Collaboration;
    public const COLLABORATION_SCHEMA_OPTION = 'fixture_schema_version';
    public const COLLABORATION_SCHEMA_VERSION = 1;
    public static bool $enabled = true;
    public static bool $authority = true;
    public static bool $lock_available = true;
    public static int $releases = 0;
    public static function collaboration_phase1_enabled(): bool { return self::$enabled; }
    public static function account_authority_enabled(): bool { return self::$authority; }
    private static function acquire_named_fan_lock($kind, $name) {
        return self::$lock_available ? 'fixture-lock' : new WP_Error();
    }
    private static function release_named_fan_lock($lock): void { ++self::$releases; }
    public static function probe(): bool { return self::collaboration_tables_exist(); }
    public static function ready(): bool { return self::collaboration_storage_ready(); }
}

class CollaborationSchemaFixtureDB {
    public string $prefix = 'fixture_';
    public string $last_error = '';
    public array $metadata = array();
    public array $queries = array();
    public string $fail_query = '';
    public bool $throw_query = false;
    public function get_charset_collate(): string { return 'DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'; }
    public function prepare($query, ...$values): array { return array($query, $values); }
    public function esc_like($value): string { return addcslashes($value, '_%\\'); }
    protected function start(string $query): void {
        $this->queries[] = $query;
        $this->last_error = $query === $this->fail_query ? 'synthetic_metadata_error' : '';
        if ($this->throw_query) { throw new RuntimeException('synthetic_metadata_exception'); }
    }
    public function get_row($prepared, $output) {
        $this->start('status');
        if ($prepared[0] !== 'SHOW TABLE STATUS LIKE %s') { throw new RuntimeException('Unexpected scalar SQL'); }
        $table = stripslashes($prepared[1][0]);
        return $this->metadata[$table]['status'] ?? null;
    }
    public function get_results($query, $output) {
        if (!preg_match('/^SHOW (FULL COLUMNS|INDEX) FROM `([a-zA-Z0-9_]+)`$/D', $query, $matches)) {
            throw new RuntimeException('Unexpected metadata SQL');
        }
        $kind = $matches[1] === 'INDEX' ? 'indexes' : 'columns';
        $this->start($kind);
        return $this->metadata[$matches[2]][$kind] ?? null;
    }
    public function install(string $sql): void {
        if (!preg_match('/^CREATE TABLE ([a-zA-Z0-9_]+) \((.*)\) ENGINE=InnoDB /s', $sql, $matches)) {
            throw new RuntimeException('Unexpected fixture DDL');
        }
        $table = $matches[1];
        $columns = array();
        $indexes = array();
        // Parse the actual CREATE statements, independently of the production
        // expected-schema map; divergent field/index definitions fail the test.
        foreach (explode("\n", $matches[2]) as $line) {
            $line = rtrim(trim($line), ',');
            if ($line === '') { continue; }
            if (preg_match('/^(PRIMARY KEY|UNIQUE KEY|KEY)\s+(?:([a-z_]+)\s+)?\(([^)]+)\)$/D', $line, $index)) {
                foreach (explode(',', $index[3]) as $position => $column) {
                    $indexes[] = array(
                        'Key_name' => $index[1] === 'PRIMARY KEY' ? 'PRIMARY' : $index[2],
                        'Non_unique' => $index[1] === 'KEY' ? '1' : '0',
                        'Seq_in_index' => (string) ($position + 1),
                        'Column_name' => trim($column), 'Sub_part' => null,
                        'Index_type' => 'BTREE', 'Collation' => 'A', 'Visible' => 'YES',
                    );
                }
                continue;
            }
            if (!preg_match('/^([a-z_]+) ([a-z]+(?:\([0-9]+\))?(?: unsigned)?) (NOT NULL|NULL)(.*)$/D', $line, $column)) {
                throw new RuntimeException('Unrecognized fixture column definition');
            }
            $default = null;
            if (preg_match("/ DEFAULT (?:'([^']*)'|([0-9]+))/", $column[4], $match)) {
                $default = isset($match[2]) ? $match[2] : $match[1];
            }
            $columns[] = array(
                'Field' => $column[1], 'Type' => $column[2],
                'Null' => $column[3] === 'NULL' ? 'YES' : 'NO', 'Default' => $default,
                'Extra' => str_contains($column[4], 'AUTO_INCREMENT') ? 'auto_increment' : '',
            );
        }
        $this->metadata[$table] = array(
            'status' => array('Name' => $table, 'Engine' => 'InnoDB'),
            'columns' => $columns, 'indexes' => $indexes,
        );
    }
}

$checks = 0;
function check_schema(bool $condition, string $label): void {
    global $checks;
    if (!$condition) { throw new RuntimeException('FAILED: ' . $label); }
    ++$checks;
}
function reset_schema_fixture(): void {
    $GLOBALS['schema_options'] = array();
    $GLOBALS['schema_option_writes'] = 0;
    $GLOBALS['schema_events'] = array();
    $GLOBALS['schema_delta_calls'] = 0;
    $GLOBALS['schema_delta_failure'] = '';
    $GLOBALS['schema_ddl'] = array();
    $GLOBALS['wpdb'] = new CollaborationSchemaFixtureDB();
    CollaborationSchemaHarness::$enabled = true;
    CollaborationSchemaHarness::$authority = true;
    CollaborationSchemaHarness::$lock_available = true;
    CollaborationSchemaHarness::$releases = 0;
}

reset_schema_fixture();
check_schema(CollaborationSchemaHarness::ensure_collaboration_storage(), 'actual DDL matches full metadata contract');
check_schema($GLOBALS['schema_delta_calls'] === 3 && $GLOBALS['schema_option_writes'] === 1, 'stamp only after all three verified tables');
check_schema(CollaborationSchemaHarness::$releases === 1, 'release migration lock');
$fixture_metadata = $GLOBALS['wpdb']->metadata;
$actual_ddl = $GLOBALS['schema_ddl'];
check_schema(CollaborationSchemaHarness::ensure_collaboration_storage(), 'already verified schema is idempotent');
check_schema($GLOBALS['schema_delta_calls'] === 3, 'do not repeat DDL when ready');

foreach ($fixture_metadata as $table => $metadata) {
    foreach (array('MyISAM', 'MEMORY', null) as $engine) {
        $GLOBALS['wpdb']->metadata = $fixture_metadata;
        $GLOBALS['wpdb']->metadata[$table]['status']['Engine'] = $engine;
        check_schema(!CollaborationSchemaHarness::ready(), 'reject nontransactional engine, including after earlier success');
    }
    $GLOBALS['wpdb']->metadata = $fixture_metadata;
    $GLOBALS['wpdb']->metadata[$table]['status']['Name'] .= '_other';
    check_schema(!CollaborationSchemaHarness::probe(), 'reject LIKE mismatch');
    foreach ($metadata['columns'] as $position => $column) {
        foreach (array('Field' => 'unknown', 'Type' => 'tinyint', 'Null' => 'UNKNOWN', 'Default' => 'wrong', 'Extra' => 'VIRTUAL GENERATED') as $key => $value) {
            $GLOBALS['wpdb']->metadata = $fixture_metadata;
            $GLOBALS['wpdb']->metadata[$table]['columns'][$position][$key] = $value;
            check_schema(!CollaborationSchemaHarness::probe(), 'reject each altered column property');
        }
        $GLOBALS['wpdb']->metadata = $fixture_metadata;
        unset($GLOBALS['wpdb']->metadata[$table]['columns'][$position]['Default']);
        check_schema(!CollaborationSchemaHarness::probe(), 'missing default metadata is not SQL NULL');
    }
    $GLOBALS['wpdb']->metadata = $fixture_metadata;
    array_pop($GLOBALS['wpdb']->metadata[$table]['columns']);
    check_schema(!CollaborationSchemaHarness::probe(), 'reject missing column');
    $GLOBALS['wpdb']->metadata = $fixture_metadata;
    $GLOBALS['wpdb']->metadata[$table]['columns'][] = $metadata['columns'][0];
    check_schema(!CollaborationSchemaHarness::probe(), 'reject duplicated/extra column');
    foreach ($metadata['indexes'] as $position => $index) {
        foreach (array('Key_name' => 'unknown', 'Non_unique' => '2', 'Seq_in_index' => '0', 'Column_name' => 'other', 'Sub_part' => '10', 'Index_type' => 'HASH', 'Visible' => 'NO', 'Ignored' => 'YES', 'Collation' => 'D') as $key => $value) {
            $GLOBALS['wpdb']->metadata = $fixture_metadata;
            $GLOBALS['wpdb']->metadata[$table]['indexes'][$position][$key] = $value;
            check_schema(!CollaborationSchemaHarness::probe(), 'reject altered index semantics');
        }
        $GLOBALS['wpdb']->metadata = $fixture_metadata;
        unset($GLOBALS['wpdb']->metadata[$table]['indexes'][$position]);
        check_schema(!CollaborationSchemaHarness::probe(), 'reject missing index column');
    }
    $GLOBALS['wpdb']->metadata = $fixture_metadata;
    $GLOBALS['wpdb']->metadata[$table]['indexes'][] = $metadata['indexes'][0];
    check_schema(!CollaborationSchemaHarness::probe(), 'reject duplicate index sequence');
}
$GLOBALS['wpdb']->metadata = $fixture_metadata;
foreach ($GLOBALS['wpdb']->metadata as &$metadata) {
    foreach ($metadata['columns'] as &$column) {
        $column['Type'] = preg_replace('/^(bigint|smallint)\([0-9]+\)/', '$1', $column['Type']);
    }
    unset($column);
    $metadata['columns'] = array_reverse($metadata['columns']);
    $metadata['indexes'] = array_reverse($metadata['indexes']);
}
unset($metadata);
check_schema(CollaborationSchemaHarness::probe(), 'MySQL display-width differences and metadata ordering are harmless');
foreach (array('status', 'columns', 'indexes') as $failure) {
    $GLOBALS['wpdb']->fail_query = $failure;
    check_schema(!CollaborationSchemaHarness::probe(), 'valid-looking rows plus query error fail closed');
}
$GLOBALS['wpdb']->fail_query = '';
$GLOBALS['wpdb']->throw_query = true;
check_schema(!CollaborationSchemaHarness::probe(), 'metadata exception fails closed');
foreach (array('fixture_bad`;', str_repeat('x', 65), "fixture_\n") as $prefix) {
    reset_schema_fixture();
    $GLOBALS['wpdb']->prefix = $prefix;
    check_schema(!CollaborationSchemaHarness::probe() && !$GLOBALS['wpdb']->queries, 'unsafe table prefix never queried');
}
foreach (array('false', 'nested', 'error', 'throw') as $failure) {
    reset_schema_fixture();
    $GLOBALS['schema_delta_failure'] = $failure;
    check_schema(!CollaborationSchemaHarness::ensure_collaboration_storage(), 'dbDelta failure is rejected');
    check_schema($GLOBALS['schema_delta_calls'] === 1 && $GLOBALS['schema_option_writes'] === 0, 'no later query erases migration failure');
    check_schema(CollaborationSchemaHarness::$releases === 1, 'failed migration releases lock');
    check_schema($GLOBALS['schema_events'] === array('schema_creation_failed'), 'failure emits only stable audit code');
}
foreach (array('enabled', 'authority', 'lock_available') as $gate) {
    reset_schema_fixture();
    CollaborationSchemaHarness::$$gate = false;
    check_schema(!CollaborationSchemaHarness::ensure_collaboration_storage(), 'disabled/standby/locked schema does not run');
    check_schema(!$GLOBALS['wpdb']->queries && !$GLOBALS['schema_delta_calls'] && !$GLOBALS['schema_option_writes'], 'closed gate has no database effects');
}

fwrite(STDOUT, "collaboration-schema-regression: {$checks} metadata/fault assertions passed\n");
if (($argv[1] ?? '') !== '--mysql') { exit(0); }

// PDO is used only in this opt-in integration fixture. The database name is
// generated here, CREATE must succeed without IF NOT EXISTS, and cleanup is
// limited to that exact name. Nothing accepts an existing database as input.
final class CollaborationSchemaMySQLDB extends CollaborationSchemaFixtureDB {
    public function __construct(public PDO $connection) {}
    public function install(string $sql): void { $this->connection->exec($sql); }
    public function get_row($prepared, $output) {
        $this->start('status');
        $statement = $this->connection->query('SHOW TABLE STATUS LIKE ' . $this->connection->quote($prepared[1][0]));
        return $statement->fetch(PDO::FETCH_ASSOC) ?: null;
    }
    public function get_results($query, $output) {
        $this->start('metadata');
        return $this->connection->query($query)->fetchAll(PDO::FETCH_ASSOC);
    }
}
$socket = getenv('YISHU_SCHEMA_TEST_SOCKET') ?: '/var/run/mysqld/mysqld.sock';
if (!preg_match('#^/[A-Za-z0-9_./-]+$#D', $socket) || !str_ends_with($socket, '.sock')) {
    throw new RuntimeException('An absolute local test socket is required');
}
$connection = new PDO('mysql:unix_socket=' . $socket, 'root', '', array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
$database = 'yishu_schema_test_' . bin2hex(random_bytes(10));
$created = false;
$integration_start = $checks;
try {
    $connection->exec('CREATE DATABASE `' . $database . '` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    $created = true;
    $connection->exec('USE `' . $database . '`');
    reset_schema_fixture();
    $GLOBALS['wpdb'] = new CollaborationSchemaMySQLDB($connection);
    check_schema(CollaborationSchemaHarness::ensure_collaboration_storage(), 'actual MySQL DDL/engine/columns/indexes');
    check_schema(CollaborationSchemaHarness::ready(), 'actual MySQL readiness');
    foreach ($actual_ddl as $ddl) {
        preg_match('/^CREATE TABLE ([a-zA-Z0-9_]+)/', $ddl, $match);
        $table = $match[1];
        $connection->exec("ALTER TABLE `{$table}` ENGINE=MyISAM");
        check_schema(!CollaborationSchemaHarness::ready(), 'real MyISAM table fails closed');
        $connection->exec("ALTER TABLE `{$table}` ENGINE=InnoDB");
        check_schema(CollaborationSchemaHarness::ready(), 'real InnoDB recovery');
        $connection->exec("DROP TABLE `{$table}`");
        check_schema(!CollaborationSchemaHarness::ready(), 'real missing table fails closed');
        $connection->exec($ddl);
        check_schema(CollaborationSchemaHarness::ready(), 'real table recreation');
    }
    foreach (array(
        array('ALTER TABLE fixture_yishu_collaboration_requests DROP INDEX fan_submission',
            'ALTER TABLE fixture_yishu_collaboration_requests ADD UNIQUE KEY fan_submission (fan_user_id, submission_id)'),
        array('ALTER TABLE fixture_yishu_collaboration_requests MODIFY contact_name varchar(119) NOT NULL',
            'ALTER TABLE fixture_yishu_collaboration_requests MODIFY contact_name varchar(120) NOT NULL'),
        array('ALTER TABLE fixture_yishu_collaboration_requests ALTER COLUMN status SET DEFAULT \'reviewing\'',
            'ALTER TABLE fixture_yishu_collaboration_requests ALTER COLUMN status SET DEFAULT \'received\''),
        array('ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX due_jobs',
            'ALTER TABLE fixture_yishu_collaboration_outbox ADD KEY due_jobs (status, next_attempt_at)'),
        array('ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX dedupe_key, ADD UNIQUE KEY dedupe_key (dedupe_key(16))',
            'ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX dedupe_key, ADD UNIQUE KEY dedupe_key (dedupe_key)'),
        array('ALTER TABLE fixture_yishu_collaboration_audit DROP INDEX request_created, ADD KEY request_created (created_at, request_id)',
            'ALTER TABLE fixture_yishu_collaboration_audit DROP INDEX request_created, ADD KEY request_created (request_id, created_at)'),
    ) as [$break_sql, $repair_sql]) {
        $connection->exec($break_sql);
        check_schema(!CollaborationSchemaHarness::ready(), 'actual incompatible column/index fails closed');
        $connection->exec($repair_sql);
        check_schema(CollaborationSchemaHarness::ready(), 'actual repaired metadata revalidated');
    }
    $insert = "INSERT INTO fixture_yishu_collaboration_outbox
        (request_id, channel, dedupe_key, next_attempt_at, created_at, updated_at)
        VALUES (1, 'fixture', 'fixture-only', UTC_TIMESTAMP(), UTC_TIMESTAMP(), UTC_TIMESTAMP())";
    $connection->beginTransaction();
    $connection->exec($insert);
    $duplicate_rejected = false;
    try { $connection->exec($insert); } catch (PDOException $error) {
        $duplicate_rejected = ($error->errorInfo[1] ?? null) === 1062;
    }
    check_schema($duplicate_rejected, 'actual unique index rejects repeated outbox row');
    $connection->rollBack();
    check_schema((int) $connection->query('SELECT COUNT(*) FROM fixture_yishu_collaboration_outbox')->fetchColumn() === 0, 'actual InnoDB rollback leaves no synthetic message');
    $version = $connection->query('SELECT VERSION()')->fetchColumn();
    fwrite(STDOUT, 'collaboration-schema-mysql: ' . ($checks - $integration_start) . ' integration assertions passed; MySQL ' . $version . "\n");
} finally {
    if ($connection->inTransaction()) { $connection->rollBack(); }
    if ($created) {
        $connection->exec('DROP DATABASE `' . $database . '`');
        fwrite(STDOUT, "collaboration-schema-mysql: exact temporary database removed; no production data used\n");
    }
}
