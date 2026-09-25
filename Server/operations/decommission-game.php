<?php
declare(strict_types=1);

/**
 * WP-CLI command, registered before WordPress loads. No plugin/cron/HTTP/mail
 * bootstrap runs. Default is read-only. Config is tokenized, never evaluated.
 * wp --allow-root --skip-packages --path=/var/www/html/shuzijun.com.cn --require=/PRIVATE/decommission-game.php \
 *   shuzijun retire-game --profile=production
 * Apply additionally requires --apply=PLAN_SHA256 and all five --confirm-* values
 * printed in the plan: database, home, environment, prefix, role.
 * Deploy the pinned no-game plugin first. Keep the private rollback.sql and
 * snapshot.json files: DROP TABLE cannot be rolled back by a SQL transaction.
 * A failed/uncertain apply is inspected with a new read-only invocation; it is
 * never retried automatically. This tool never restores data or deletes users.
 */
final class GameRetirementFailure extends RuntimeException {}
final class GameRetirementPolicy {
    public const RELEASE_SHA256 = '69e10dcf6f07a68b93590851bfed12c89a832f4c69cbb2ff8953c2601a5896e4';
    public const SCHEMA_OPTION = 'yishu_game_leaderboard_schema_version';
    public const COLUMNS = array('fan_user_id', 'rules_version', 'score', 'ending_id', 'origin', 'answered', 'achieved_at');
    public const LOCK = '/var/lib/shuzijun-sync/site-operation.lock';
    public const BACKUPS = '/var/backups/shuzijun-game-retirement';
    public const CACHE_SHA256 = 'b3e91c4365480363c5042a11e53e5c6748c789345fd3f6ee0cac18ab582a0f3b';
    public static ?string $backupID = null;
}
function retire_require(bool $condition, string $code): void {
    if (!$condition) { throw new GameRetirementFailure($code); }
}
function retire_json(array $value): string {
    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}
function retire_profile(string $name): array {
    if ($name === 'production') {
        return array('profile' => $name, 'site' => '/var/www/html/shuzijun.com.cn',
            'database' => 'wordpress', 'home' => 'https://www.shuzijun.com.cn', 'environment' => 'production');
    }
    retire_require($name === 'review', 'profile');
    return array('profile' => $name, 'site' => '/srv/shuzijun-review/site',
        'database' => 'shuzijun_review', 'home' => 'https://review.shuzijun.com.cn', 'environment' => 'review');
}
function retire_arguments(array $args, array $flags): array {
    retire_require($args === array(), 'arguments');
    $allowed = array('profile', 'apply', 'confirm-database', 'confirm-home', 'confirm-environment', 'confirm-prefix', 'confirm-role');
    retire_require(array_diff(array_keys($flags), $allowed) === array(), 'arguments');
    $profile = retire_profile($flags['profile'] ?? 'production');
    if (!isset($flags['apply'])) {
        retire_require(count($flags) === (isset($flags['profile']) ? 1 : 0), 'preflight_arguments');
        return array($profile, null, array());
    }
    retire_require(is_string($flags['apply']) && preg_match('/^[a-f0-9]{64}$/D', $flags['apply']) === 1, 'apply_hash');
    $confirm = array();
    foreach (array('database', 'home', 'environment', 'prefix', 'role') as $key) {
        retire_require(isset($flags['confirm-' . $key]) && is_string($flags['confirm-' . $key]), 'explicit_confirmation');
        $confirm[$key] = $flags['confirm-' . $key];
    }
    return array($profile, $flags['apply'], $confirm);
}
/** Decode one PHP constant-string token without eval or interpolation. */
function retire_literal(mixed $token): string {
    retire_require(is_array($token) && $token[0] === T_CONSTANT_ENCAPSED_STRING, 'literal_config_required');
    $quoted = $token[1]; $quote = $quoted[0]; $body = substr($quoted, 1, -1);
    if ($quote === "'") { return preg_replace_callback('/\\\\([\\\\\x27])/', static fn(array $m): string => $m[1], $body); }
    retire_require($quote === '"', 'literal_config_required');
    return preg_replace_callback('/\\\\(?:[nrtvef\\\\$"]|[0-7]{1,3}|x[0-9a-fA-F]{1,2})/',
        static function (array $m): string {
            $escape = substr($m[0], 1);
            $map = array('n' => "\n", 'r' => "\r", 't' => "\t", 'v' => "\v", 'e' => "\e", 'f' => "\f", '\\' => '\\', '$' => '$', '"' => '"');
            if (isset($map[$escape])) { return $map[$escape]; }
            return chr($escape[0] === 'x' ? hexdec(substr($escape, 1)) : octdec($escape));
        }, $body);
}
/** Only fixed literal database/environment settings are read; nothing executes. */
function retire_config(string $source): array {
    $tokens = array_values(array_filter(token_get_all($source), static fn($t): bool =>
        !is_array($t) || !in_array($t[0], array(T_WHITESPACE, T_COMMENT, T_DOC_COMMENT), true)));
    $keys = array('DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST', 'WP_HOME', 'WP_SITEURL', 'YISHU_APP_SERVICE_ENVIRONMENT', 'WP_ENVIRONMENT_TYPE',
        'WP_REDIS_HOST', 'WP_REDIS_PORT', 'WP_REDIS_DATABASE');
    $result = array();
    foreach ($tokens as $i => $token) {
        if (is_array($token) && $token[0] === T_STRING && strtolower($token[1]) === 'define'
            && ($tokens[$i + 1] ?? null) === '(' && is_array($tokens[$i + 2] ?? null)
            && $tokens[$i + 2][0] === T_CONSTANT_ENCAPSED_STRING) {
            $key = retire_literal($tokens[$i + 2]);
            if ((str_starts_with($key, 'WP_REDIS_') || in_array($key, array('WP_CACHE_KEY_SALT', 'MULTISITE'), true))
                && !in_array($key, $keys, true)) {
                $result['unsupportedCacheConfig'][] = $key;
            }
            if (!in_array($key, $keys, true)) { continue; }
            retire_require(!isset($result[$key]) && ($tokens[$i + 3] ?? null) === ','
                && ($tokens[$i + 5] ?? null) === ')' && ($tokens[$i + 6] ?? null) === ';', 'literal_config_required');
            $value = $tokens[$i + 4] ?? null;
            $result[$key] = str_starts_with($key, 'WP_REDIS_') && is_array($value) && $value[0] === T_LNUMBER
                ? $value[1] : retire_literal($value);
        }
        if (is_array($token) && $token[0] === T_VARIABLE && $token[1] === '$table_prefix') {
            retire_require(!isset($result['prefix']) && ($tokens[$i + 1] ?? null) === '='
                && ($tokens[$i + 3] ?? null) === ';', 'literal_prefix_required');
            $result['prefix'] = retire_literal($tokens[$i + 2] ?? null);
        }
    }
    foreach (array('DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST', 'prefix') as $key) {
        retire_require(isset($result[$key]) && $result[$key] !== '', 'database_config_missing');
    }
    retire_identifier($result['prefix']);
    retire_require(in_array($result['DB_HOST'], array('localhost', '127.0.0.1', 'localhost:/var/run/mysqld/mysqld.sock'), true), 'local_database_required');
    return $result;
}
function retire_identifier(string $name): string {
    retire_require(preg_match('/^[A-Za-z0-9_]{1,64}$/D', $name) === 1, 'identifier');
    return '`' . $name . '`';
}
function retire_option_allowed(string $name): bool {
    return $name === GameRetirementPolicy::SCHEMA_OPTION
        || preg_match('/^_transient_(?:timeout_)?yishu_game_(?:read|submit|delete)_[a-f0-9]{64}$/D', $name) === 1;
}
function retire_hex(string $text): string { return $text === '' ? "''" : '0x' . bin2hex($text); }
/** Root-owned canonical paths only; private backups additionally need 0700/0600. */
function retire_safe_path(string $path, bool $directory, ?int $exact = null): array {
    retire_require(str_starts_with($path, '/') && realpath($path) === $path, 'canonical_path');
    $cursor = ''; $parts = explode('/', substr($path, 1)); $stat = array();
    foreach ($parts as $index => $part) {
        $cursor .= '/' . $part; clearstatcache(true, $cursor); $stat = @lstat($cursor);
        $isDirectory = $index < count($parts) - 1 || $directory;
        retire_require(is_array($stat) && !is_link($cursor) && $stat['uid'] === 0
            && ($stat['mode'] & 0022) === 0
            && ($stat['mode'] & 0170000) === ($isDirectory ? 0040000 : 0100000), 'path_permissions');
    }
    retire_require($directory || $stat['nlink'] === 1, 'hardlink');
    retire_require($exact === null || ($stat['mode'] & 07777) === $exact, 'private_permissions');
    return $stat;
}
function retire_read(string $path, int $maximum): string {
    $before = retire_safe_path($path, false);
    retire_require($before['size'] <= $maximum, 'read_bound');
    $bytes = file_get_contents($path); clearstatcache(true, $path); $after = lstat($path);
    retire_require(is_string($bytes) && strlen($bytes) === $before['size'] && $before === $after, 'read_changed');
    return $bytes;
}
function retire_release(array $profile): void {
    $base = $profile['site'] . '/wp-content/mu-plugins/';
    $manifest = retire_read($base . 'release.sha256', 65536);
    retire_require(hash_equals(GameRetirementPolicy::RELEASE_SHA256, hash('sha256', $manifest)), 'no_game_release_required');
    foreach (explode("\n", trim($manifest)) as $line) {
        retire_require(preg_match('~^([a-f0-9]{64})  ([A-Za-z0-9_./-]+)$~D', $line, $m) === 1
            && !str_starts_with($m[2], '/') && !str_contains($m[2], '..'), 'release_manifest');
        $bytes = retire_read($base . $m[2], 4194304);
        retire_require(hash_equals($m[1], hash('sha256', $bytes)), 'release_file_changed');
    }
    foreach (array('class-shuzijun-game-rules.php', 'trait-shuzijun-app-game-leaderboard.php', 'game-rules-v1.json') as $name) {
        retire_require(!file_exists($base . 'vendor/shuzijun/app-content/' . $name), 'retired_resource_remaining');
    }
}
/** Direct mysqli has no reconnect/replay, WordPress hooks, shared cache or logs. */
final class GameRetirementDB {
    private mysqli $link;
    private int $connection;
    public function __construct(array $config) {
        mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
        $socket = str_starts_with($config['DB_HOST'], 'localhost:') ? substr($config['DB_HOST'], 10) : null;
        $host = $socket === null ? $config['DB_HOST'] : 'localhost';
        $this->link = new mysqli($host, $config['DB_USER'], $config['DB_PASSWORD'], $config['DB_NAME'], 0, $socket);
        $this->connection = $this->link->thread_id;
        retire_require($this->link->set_charset('utf8mb4'), 'database_charset');
    }
    public function read(string $sql): array {
        retire_require(preg_match('/^(SELECT|SHOW) /D', $sql) === 1, 'read_query');
        $result = $this->run($sql); retire_require($result instanceof mysqli_result, 'read_result');
        return $result->fetch_all(MYSQLI_ASSOC);
    }
    public function write(string $sql): void { retire_require($this->run($sql) === true, 'write_result'); }
    private function run(string $sql): mysqli_result|bool {
        retire_require($this->link->thread_id === $this->connection, 'connection_changed');
        $result = $this->link->query($sql);
        retire_require($this->link->thread_id === $this->connection, 'connection_changed');
        return $result;
    }
}
/** Exact observed Redis Object Cache drop-in, never loaded or bootstrapped. */
function retire_cache_config(array $config): void {
    retire_require(($config['unsupportedCacheConfig'] ?? array()) === array()
        && ($config['WP_REDIS_HOST'] ?? '127.0.0.1') === '127.0.0.1'
        && ($config['WP_REDIS_PORT'] ?? '6379') === '6379'
        && ($config['WP_REDIS_DATABASE'] ?? '0') === '0'
        && $config['prefix'] === 'wp_', 'persistent_cache_configuration_requires_review');
    retire_require(!getenv('WP_REDIS_PREFIX') && !isset($_SERVER['cw_allowed_ip']), 'persistent_cache_environment_requires_review');
}
function retire_cache_key_allowed(string $key): bool {
    // Pinned fast_build_key: empty salt + trim('wp_', '_-:$') + group + key.
    return $key === 'wp:options:' . GameRetirementPolicy::SCHEMA_OPTION
        || preg_match('/^wp:transient:yishu_game_(?:read|submit|delete)_[a-f0-9]{64}$/D', $key) === 1;
}
final class GameRetirementCache {
    public function __construct(private object $redis) {}
    private function sharedOptionsClean(): void {
        foreach (array('alloptions', 'notoptions') as $key) {
            $raw = $this->redis->rawCommand('GET', 'wp:options:' . $key);
            if ($raw === false || $raw === null) { continue; }
            retire_require(is_string($raw) && strlen($raw) <= 4194304, 'shared_cache_shape_requires_review');
            $values = @unserialize($raw, array('allowed_classes' => false, 'max_depth' => 64));
            retire_require(is_array($values), 'shared_cache_shape_requires_review');
            foreach (array_keys($values) as $name) {
                retire_require(!preg_match('/^(?:_transient_(?:timeout_)?)?yishu_game_/', (string) $name), 'shared_game_cache_requires_review');
            }
        }
    }
    public function snapshot(): array {
        $this->sharedOptionsClean();
        $cursor = '0'; $keys = array(); $iterations = 0;
        do {
            $reply = $this->redis->rawCommand('SCAN', $cursor, 'MATCH', 'wp:*:*yishu_game_*', 'COUNT', '250');
            retire_require(is_array($reply) && count($reply) === 2 && is_array($reply[1])
                && is_string($reply[0]) && ctype_digit($reply[0]), 'cache_scan_shape');
            $cursor = $reply[0];
            foreach ($reply[1] as $key) {
                retire_require(is_string($key) && retire_cache_key_allowed($key), 'unrecognized_game_cache_requires_review');
                $keys[$key] = true;
            }
            retire_require(++$iterations <= 10000 && count($keys) <= 100000, 'cache_scan_bound');
        } while ($cursor !== '0');
        ksort($keys, SORT_STRING); $entries = array();
        foreach (array_keys($keys) as $key) {
            $raw = $this->redis->rawCommand('GET', $key);
            if ($raw === false || $raw === null) { continue; }
            retire_require(is_string($raw) && strlen($raw) <= 1048576, 'cache_value_bound');
            $ttl = $this->redis->rawCommand('PTTL', $key);
            retire_require(is_int($ttl) && $ttl >= -2, 'cache_ttl');
            if ($ttl === -2) { continue; }
            $entries[] = array('key' => $key, 'valueBase64' => base64_encode($raw), 'ttlMs' => $ttl);
        }
        return array('adapterSha256' => GameRetirementPolicy::CACHE_SHA256,
            'database' => 0, 'namespace' => 'wp:', 'entries' => $entries);
    }
    public function deleteSnapshot(array $snapshot): void {
        $this->sharedOptionsClean();
        // Atomic compare-and-delete of ONE allowed game key. No shared array,
        // prefix deletion, FLUSHDB or FLUSHALL, and no retry after uncertainty.
        $script = "local v=redis.call('GET',KEYS[1]); if not v then return 0 end; "
            . "if v~=ARGV[1] then return -1 end; return redis.call('DEL',KEYS[1])";
        foreach ($snapshot['entries'] as $entry) {
            retire_require(retire_cache_key_allowed($entry['key']), 'cache_delete_scope');
            $value = base64_decode($entry['valueBase64'], true);
            retire_require(is_string($value), 'cache_backup_encoding');
            $result = $this->redis->rawCommand('EVAL', $script, '1', $entry['key'], $value);
            retire_require($result === 0 || $result === 1, 'cache_changed_keep_backup');
        }
        retire_require($this->snapshot()['entries'] === array(), 'cache_cleanup_incomplete_keep_backup');
    }
}
function retire_cache(array $profile, array $config): ?GameRetirementCache {
    $path = $profile['site'] . '/wp-content/object-cache.php';
    if (!file_exists($path)) { return null; }
    retire_require($profile['profile'] === 'production'
        && hash_equals(GameRetirementPolicy::CACHE_SHA256, hash('sha256', retire_read($path, 262144))), 'persistent_cache_implementation_requires_review');
    retire_cache_config($config);
    retire_require(extension_loaded('redis') && defined('Redis::OPT_MAX_RETRIES'), 'native_redis_required');
    $redis = new Redis();
    retire_require($redis->connect('127.0.0.1', 6379, 1.0, null, 0, 1.0)
        && $redis->setOption(Redis::OPT_MAX_RETRIES, 0)
        && $redis->select(0), 'cache_connection');
    return new GameRetirementCache($redis);
}
function retire_scalar(object $db, string $query): string {
    $rows = $db->read($query);
    retire_require(count($rows) === 1 && count($rows[0]) === 1, 'scalar');
    return (string) array_values($rows[0])[0];
}
function retire_identity(object $db, array $profile, array $config, string $role): array {
    retire_require($config['DB_NAME'] === $profile['database']
        && retire_scalar($db, 'SELECT DATABASE()') === $profile['database'], 'database_identity');
    retire_require(retire_scalar($db, 'SELECT @@SESSION.autocommit') === '1', 'autocommit_required');
    $environment = $config['YISHU_APP_SERVICE_ENVIRONMENT'] ?? $config['WP_ENVIRONMENT_TYPE'] ?? 'production';
    retire_require($environment === $profile['environment'], 'environment_identity');
    if ($profile['profile'] === 'review') {
        retire_require($config['DB_USER'] === 'shuzijun_review' && $config['prefix'] === 'review_'
            && $config['DB_HOST'] === 'localhost:/var/run/mysqld/mysqld.sock' && $role === 'review-isolated', 'review_identity');
        $databases = array_map(static fn($row): string => (string) array_values($row)[0], $db->read('SHOW DATABASES'));
        retire_require(array_diff($databases, array('information_schema', 'performance_schema', 'shuzijun_review')) === array(), 'review_database_scope');
    } else { retire_require(in_array($role, array('authority', 'standby'), true), 'production_role'); }
    $options = retire_identifier($config['prefix'] . 'options');
    foreach (array('home', 'siteurl') as $key) {
        retire_require(retire_scalar($db, 'SELECT option_value FROM ' . $options . ' WHERE option_name=' . retire_hex($key)) === $profile['home'], 'home_identity');
    }
    foreach (array('WP_HOME', 'WP_SITEURL') as $key) {
        retire_require(!isset($config[$key]) || $config[$key] === $profile['home'], 'configured_home');
    }
    return array('database' => $profile['database'], 'home' => $profile['home'], 'environment' => $environment,
        'prefix' => $config['prefix'], 'role' => $role);
}
function retire_snapshot(object $db, array $identity, ?GameRetirementCache $cache = null): array {
    $table = $identity['prefix'] . 'yishu_game_leaderboard'; $options = $identity['prefix'] . 'options';
    $status = $db->read('SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=' . retire_hex($table));
    retire_require(count($status) <= 1, 'table_identity');
    $create = null; $rows = array();
    foreach (array_merge(array($options), $status ? array($table) : array()) as $name) {
        retire_require(retire_scalar($db, 'SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=DATABASE() AND EVENT_OBJECT_TABLE=' . retire_hex($name)) === '0', 'table_triggers');
        retire_require(retire_scalar($db, 'SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND (TABLE_NAME=' . retire_hex($name)
            . ' OR REFERENCED_TABLE_NAME=' . retire_hex($name) . ') AND REFERENCED_TABLE_NAME IS NOT NULL') === '0', 'foreign_keys');
    }
    if ($status) {
        retire_require($status[0]['TABLE_NAME'] === $table && strtoupper($status[0]['ENGINE']) === 'INNODB', 'table_shape');
        $columns = $db->read('SHOW COLUMNS FROM ' . retire_identifier($table));
        retire_require(array_column($columns, 'Field') === GameRetirementPolicy::COLUMNS, 'table_columns');
        $definition = $db->read('SHOW CREATE TABLE ' . retire_identifier($table));
        retire_require(count($definition) === 1 && isset($definition[0]['Create Table']), 'table_ddl');
        $create = $definition[0]['Create Table'];
        retire_require(str_starts_with($create, 'CREATE TABLE ' . retire_identifier($table) . ' (')
            && !str_contains($create, ';') && !str_contains(strtoupper($create), 'DATA DIRECTORY'), 'table_ddl');
        $count = (int) retire_scalar($db, 'SELECT COUNT(*) FROM ' . retire_identifier($table));
        retire_require($count <= 100000, 'table_backup_bound');
        $rows = $db->read('SELECT * FROM ' . retire_identifier($table) . ' ORDER BY fan_user_id');
        retire_require(count($rows) === $count, 'table_snapshot_changed');
        foreach ($rows as $row) { retire_require(array_keys($row) === GameRetirementPolicy::COLUMNS, 'row_columns'); }
    }
    $optionRows = $db->read('SELECT option_name, option_value, autoload FROM ' . retire_identifier($options)
        . " WHERE option_name='yishu_game_leaderboard_schema_version' OR option_name REGEXP '^_transient_(timeout_)?yishu_game_(read|submit|delete)_[a-f0-9]{64}$' ORDER BY option_name");
    retire_require(count($optionRows) <= 100000, 'option_backup_bound');
    foreach ($optionRows as $row) { retire_require(retire_option_allowed($row['option_name']), 'option_scope'); }
    $meta = retire_scalar($db, 'SELECT COUNT(*) FROM ' . retire_identifier($identity['prefix'] . 'usermeta')
        . " WHERE meta_key REGEXP '^_?yishu_game_'");
    retire_require($meta === '0', 'unrecognized_game_meta_requires_review');
    $snapshot = array('schema' => 1, 'identity' => $identity, 'table' => $table,
        'createTable' => $create, 'rows' => $rows, 'options' => $optionRows, 'userMetaRows' => 0);
    if ($cache !== null) { $snapshot['cache'] = $cache->snapshot(); }
    return $snapshot;
}
function retire_snapshot_comparable(array $snapshot): array {
    // Normal TTL countdown is not a changed plan. Raw values and exact key
    // membership ARE part of the plan; expired keys require a fresh preflight.
    if (isset($snapshot['cache'])) {
        foreach ($snapshot['cache']['entries'] as &$entry) { unset($entry['ttlMs']); }
        unset($entry);
    }
    return $snapshot;
}
function retire_plan(array $snapshot): array {
    return array('status' => 'preflight', 'identity' => $snapshot['identity'], 'table' => $snapshot['table'],
        'tableExists' => $snapshot['createTable'] !== null, 'leaderboardRows' => count($snapshot['rows']),
        'gameOptions' => count($snapshot['options']), 'gameUserMetaRows' => 0,
        'gameCacheKeys' => count($snapshot['cache']['entries'] ?? array()),
        'cacheAdapterSha256' => $snapshot['cache']['adapterSha256'] ?? null,
        'planSha256' => hash('sha256', retire_json(retire_snapshot_comparable($snapshot))));
}
function retire_rollback_sql(array $snapshot): string {
    $sql = "-- Private game-only rollback; review identity before manual restore.\nSET NAMES utf8mb4;\n";
    if ($snapshot['createTable'] !== null) {
        $sql .= $snapshot['createTable'] . ";\n";
        foreach ($snapshot['rows'] as $row) {
            $sql .= 'INSERT INTO ' . retire_identifier($snapshot['table']) . ' ('
                . implode(',', array_map('retire_identifier', GameRetirementPolicy::COLUMNS)) . ') VALUES ('
                . implode(',', array_map(static fn($v): string => $v === null ? 'NULL' : retire_hex((string) $v), array_values($row))) . ");\n";
        }
    }
    foreach ($snapshot['options'] as $row) {
        retire_require(retire_option_allowed($row['option_name']), 'backup_option_scope');
        $sql .= 'INSERT INTO ' . retire_identifier($snapshot['identity']['prefix'] . 'options')
            . ' (option_name,option_value,autoload) VALUES ('
            . implode(',', array_map('retire_hex', array($row['option_name'], $row['option_value'], $row['autoload']))) . ");\n";
    }
    return $sql;
}
function retire_write_private(string $path, string $bytes): void {
    $stream = fopen($path, 'xb'); retire_require(is_resource($stream), 'backup_create');
    try {
        retire_require(chmod($path, 0600), 'backup_mode'); $offset = 0;
        while ($offset < strlen($bytes)) {
            $written = fwrite($stream, substr($bytes, $offset));
            retire_require(is_int($written) && $written > 0, 'backup_write'); $offset += $written;
        }
        retire_require(fflush($stream) && fsync($stream), 'backup_durable');
    } finally { fclose($stream); }
    retire_safe_path($path, false, 0600);
    retire_require(hash_file('sha256', $path) === hash('sha256', $bytes), 'backup_readback');
}
function retire_backup(array $snapshot): string {
    retire_safe_path(GameRetirementPolicy::BACKUPS, true, 0700);
    $id = bin2hex(random_bytes(16)); $directory = GameRetirementPolicy::BACKUPS . '/' . $id;
    retire_require(mkdir($directory, 0700), 'backup_directory'); GameRetirementPolicy::$backupID = $id;
    retire_safe_path($directory, true, 0700);
    $json = retire_json($snapshot) . "\n"; $sql = retire_rollback_sql($snapshot);
    retire_write_private($directory . '/snapshot.json', $json);
    retire_write_private($directory . '/rollback.sql', $sql);
    retire_write_private($directory . '/sha256.json', retire_json(array('snapshot.json' => hash('sha256', $json), 'rollback.sql' => hash('sha256', $sql))) . "\n");
    foreach (array($directory, GameRetirementPolicy::BACKUPS) as $path) {
        $stream = fopen($path, 'r'); retire_require(is_resource($stream) && fsync($stream), 'backup_directory_durable'); fclose($stream);
    }
    return $id;
}
/** The only destructive SQL in this file, bounded by an exact backed-up plan. */
function retire_apply(object $db, array $snapshot, string $expected, array $confirm, callable $backup, callable $recheck, ?GameRetirementCache $cache = null): array {
    $plan = retire_plan($snapshot);
    retire_require(hash_equals($plan['planSha256'], $expected), 'plan_changed');
    retire_require($confirm === $snapshot['identity'], 'confirmation_mismatch');
    retire_require(isset($snapshot['cache']) === ($cache !== null), 'cache_adapter_required');
    if (!$plan['tableExists'] && !$plan['gameOptions'] && !$plan['gameCacheKeys']) { return array_merge($plan, array('status' => 'already-retired')); }
    $backupID = $backup($snapshot);
    retire_require(is_string($backupID) && preg_match('/^[a-f0-9]{32}$/D', $backupID) === 1, 'backup_receipt');
    $recheck();
    retire_require(retire_snapshot_comparable(retire_snapshot($db, $snapshot['identity'], $cache))
        === retire_snapshot_comparable($snapshot), 'snapshot_changed_keep_backup');
    // Exact value predicates preserve foreign changes even if an operator fails
    // to quiesce old workers. DROP is irreversible; a private rollback exists.
    if ($plan['tableExists']) { $db->write('DROP TABLE ' . retire_identifier($snapshot['table'])); }
    foreach ($snapshot['options'] as $row) {
        retire_require(retire_option_allowed($row['option_name']), 'delete_option_scope');
        $db->write('DELETE FROM ' . retire_identifier($snapshot['identity']['prefix'] . 'options')
            . ' WHERE BINARY option_name=' . retire_hex($row['option_name'])
            . ' AND BINARY option_value=' . retire_hex($row['option_value']) . ' AND BINARY autoload=' . retire_hex($row['autoload']));
    }
    if ($cache !== null) { $cache->deleteSnapshot($snapshot['cache']); }
    $after = retire_snapshot($db, $snapshot['identity'], $cache);
    retire_require($after['createTable'] === null && $after['rows'] === array() && $after['options'] === array(), 'cleanup_incomplete_keep_backup');
    return array_merge(retire_plan($after), array('status' => 'retired', 'backupID' => $backupID,
        'removedLeaderboardRows' => count($snapshot['rows']), 'removedGameOptions' => count($snapshot['options']),
        'removedGameCacheKeys' => $plan['gameCacheKeys']));
}
function retire_run(array $arguments, array $flags): array {
    [$profile, $expected, $confirm] = retire_arguments($arguments, $flags);
    retire_require(PHP_SAPI === 'cli' && defined('WP_CLI') && WP_CLI === true
        && defined('ABSPATH') && ABSPATH === $profile['site'] . '/'
        && !defined('DB_NAME') && !class_exists('wpdb', false) && !function_exists('add_action')
        && function_exists('posix_geteuid') && posix_geteuid() === 0 && function_exists('fsync'), 'fresh_root_wp_cli_required');
    retire_require(ini_get('auto_prepend_file') === '' && ini_get('auto_append_file') === '', 'isolated_cli');
    umask(0077); retire_safe_path(__FILE__, false);
    $lockStat = retire_safe_path(GameRetirementPolicy::LOCK, false, 0600);
    retire_require($lockStat['size'] === 0, 'lock_shape');
    $lock = fopen(GameRetirementPolicy::LOCK, 'rb'); retire_require(is_resource($lock), 'lock_open');
    $opened = fstat($lock);
    retire_require(is_array($opened) && $opened['ino'] === $lockStat['ino'] && $opened['dev'] === $lockStat['dev']
        && flock($lock, LOCK_EX | LOCK_NB), 'site_operation_busy');
    try {
        $configSource = retire_read($profile['site'] . '/wp-config.php', 262144);
        $configSha = hash('sha256', $configSource); $config = retire_config($configSource); unset($configSource);
        $role = $profile['profile'] === 'review' ? 'review-isolated' : trim(retire_read('/etc/shuzijun/account-authority-role', 32));
        retire_release($profile);
        $db = new GameRetirementDB($config); $identity = retire_identity($db, $profile, $config, $role);
        $cache = retire_cache($profile, $config); unset($config);
        $snapshot = retire_snapshot($db, $identity, $cache);
        if ($expected === null) {
            return array_merge(retire_plan($snapshot), array('persistentCacheDropInPresent' => $cache !== null));
        }
        // Serialize the short backup/drop window with any in-flight old score
        // writer. The release pin excludes new game requests before this lock.
        $tables = array(retire_identifier($identity['prefix'] . 'options') . ' WRITE',
            retire_identifier($identity['prefix'] . 'usermeta') . ' READ');
        if ($snapshot['createTable'] !== null) { $tables[] = retire_identifier($snapshot['table']) . ' WRITE'; }
        $db->write('SET SESSION lock_wait_timeout=10');
        $db->write('LOCK TABLES ' . implode(', ', $tables));
        try {
            return retire_apply($db, $snapshot, $expected, $confirm, 'retire_backup', static function () use ($profile, $role, $configSha, $cache): void {
                retire_release($profile);
                retire_require(hash_equals($configSha, hash('sha256', retire_read($profile['site'] . '/wp-config.php', 262144))), 'configuration_changed_keep_backup');
                $path = $profile['site'] . '/wp-content/object-cache.php';
                retire_require($cache === null ? !file_exists($path)
                    : hash_equals(GameRetirementPolicy::CACHE_SHA256, hash('sha256', retire_read($path, 262144))), 'cache_implementation_changed_keep_backup');
                if ($profile['profile'] === 'production') {
                    retire_require(trim(retire_read('/etc/shuzijun/account-authority-role', 32)) === $role, 'role_changed_keep_backup');
                }
            }, $cache);
        } finally { $db->write('UNLOCK TABLES'); }
    } finally { flock($lock, LOCK_UN); fclose($lock); }
}
if (!defined('YISHU_GAME_RETIREMENT_LIBRARY_ONLY')) {
    retire_require(defined('WP_CLI') && WP_CLI === true && class_exists('WP_CLI'), 'wp_cli_required');
    WP_CLI::add_command('shuzijun retire-game', static function (array $arguments, array $flags): void {
        ini_set('display_errors', '0'); ini_set('log_errors', '0');
        try { WP_CLI::line(retire_json(retire_run($arguments, $flags))); }
        catch (Throwable $error) {
            $code = $error instanceof GameRetirementFailure ? $error->getMessage() : 'unexpected_failure_inspect_state_keep_backup';
            WP_CLI::error(retire_json(array('status' => 'failed', 'code' => $code, 'backupID' => GameRetirementPolicy::$backupID)));
        }
    }, array('when' => 'before_wp_load', 'synopsis' => '[--profile=<profile>] [--apply=<sha256>]'
        . ' [--confirm-database=<database>] [--confirm-home=<home>] [--confirm-environment=<environment>]'
        . ' [--confirm-prefix=<prefix>] [--confirm-role=<role>]'));
}
