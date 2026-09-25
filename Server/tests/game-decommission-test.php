<?php
declare(strict_types=1);
define('YISHU_GAME_RETIREMENT_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/operations/decommission-game.php';
$checks = 0;
function decommission_check(bool $ok, string $label): void {
    if (!$ok) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function decommission_reject(callable $action, string $code): void {
    try { $action(); }
    catch (GameRetirementFailure $error) {
        decommission_check($error->getMessage() === $code, 'expected ' . $code . ', got ' . $error->getMessage()); return;
    }
    throw new RuntimeException('missing rejection: ' . $code);
}
final class RetirementFakeDB {
    public array $writes = array();
    public bool $exists = true;
    public array $options;
    public array $rows;
    public string $meta = '0';
    public string $triggers = '0';
    public string $foreignKeys = '0';
    public bool $badColumns = false;
    public bool $dropFails = false;
    public function __construct() {
        $this->rows = array(array('fan_user_id' => '123', 'rules_version' => 'life-v1', 'score' => '15',
            'ending_id' => 'plain', 'origin' => 'teacher', 'answered' => '108', 'achieved_at' => '2026-09-01 00:00:00'));
        $this->options = array(
            array('option_name' => '_transient_timeout_yishu_game_read_' . str_repeat('a', 64), 'option_value' => '123456', 'autoload' => 'off'),
            array('option_name' => '_transient_yishu_game_read_' . str_repeat('a', 64), 'option_value' => '1', 'autoload' => 'off'),
            array('option_name' => GameRetirementPolicy::SCHEMA_OPTION, 'option_value' => '1', 'autoload' => 'off'));
    }
    public function read(string $sql): array {
        if (str_starts_with($sql, 'SELECT TABLE_NAME, ENGINE')) {
            return $this->exists ? array(array('TABLE_NAME' => 'wp_yishu_game_leaderboard', 'ENGINE' => 'InnoDB')) : array();
        }
        if (str_contains($sql, 'information_schema.TRIGGERS')) { return array(array('COUNT(*)' => $this->triggers)); }
        if (str_contains($sql, 'information_schema.KEY_COLUMN_USAGE')) { return array(array('COUNT(*)' => $this->foreignKeys)); }
        if ($sql === 'SHOW COLUMNS FROM `wp_yishu_game_leaderboard`') {
            return array_map(static fn($name): array => array('Field' => $name), $this->badColumns ? array('other') : GameRetirementPolicy::COLUMNS);
        }
        if ($sql === 'SHOW CREATE TABLE `wp_yishu_game_leaderboard`') {
            return array(array('Create Table' => 'CREATE TABLE `wp_yishu_game_leaderboard` (`fan_user_id` bigint unsigned NOT NULL) ENGINE=InnoDB'));
        }
        if ($sql === 'SELECT COUNT(*) FROM `wp_yishu_game_leaderboard`') { return array(array('COUNT(*)' => (string) count($this->rows))); }
        if ($sql === 'SELECT * FROM `wp_yishu_game_leaderboard` ORDER BY fan_user_id') { return $this->rows; }
        if (str_starts_with($sql, 'SELECT option_name, option_value, autoload FROM `wp_options`')) { return $this->options; }
        if (str_starts_with($sql, 'SELECT COUNT(*) FROM `wp_usermeta` WHERE meta_key REGEXP')) { return array(array('COUNT(*)' => $this->meta)); }
        throw new RuntimeException('unrecognized test query');
    }
    public function write(string $sql): void {
        $this->writes[] = $sql;
        if ($sql === 'DROP TABLE `wp_yishu_game_leaderboard`') {
            if ($this->dropFails) { throw new GameRetirementFailure('simulated_drop_failure'); }
            $this->exists = false; $this->rows = array(); return;
        }
        foreach ($this->options as $index => $row) {
            $expected = 'DELETE FROM `wp_options` WHERE BINARY option_name=' . retire_hex($row['option_name'])
                . ' AND BINARY option_value=' . retire_hex($row['option_value']) . ' AND BINARY autoload=' . retire_hex($row['autoload']);
            if ($sql === $expected && retire_option_allowed($row['option_name'])) { unset($this->options[$index]); $this->options = array_values($this->options); return; }
        }
        throw new RuntimeException('write outside explicit game scope');
    }
}
$identity = array('database' => 'wordpress', 'home' => 'https://www.shuzijun.com.cn', 'environment' => 'production', 'prefix' => 'wp_', 'role' => 'authority');
$profile = retire_profile('production');
decommission_check(retire_arguments(array(), array()) === array($profile, null, array()), 'default is read only');
decommission_check(retire_arguments(array(), array('profile' => 'review'))[0]['database'] === 'shuzijun_review', 'separate review database');
foreach (array(array('yes' => true), array('apply' => 'yes'), array('profile' => 'other'), array('confirm-role' => 'authority')) as $flags) {
    $code = isset($flags['yes']) ? 'arguments' : (isset($flags['apply']) ? 'apply_hash' : (isset($flags['profile']) ? 'profile' : 'preflight_arguments'));
    decommission_reject(static fn() => retire_arguments(array(), $flags), $code);
}
decommission_reject(static fn() => retire_arguments(array(), array('apply' => str_repeat('a', 64))), 'explicit_confirmation');
$configText = <<<'CONFIG'
<?php
define('DB_NAME', 'wordpress'); define('DB_USER', 'synthetic');
define('DB_PASSWORD', 'a\q\\b\'c'); define('DB_HOST', 'localhost');
$table_prefix = 'wp_';
// define('DB_NAME', 'comment ignored');
throw new Exception('Must never be executed');
CONFIG;
$parsed = retire_config($configText);
decommission_check($parsed['DB_NAME'] === 'wordpress' && $parsed['DB_PASSWORD'] === "a\\q\\b'c", 'literal parsing never executes arbitrary config');
final class RetirementIdentityDB {
    public string $database = 'wordpress';
    public string $home = 'https://www.shuzijun.com.cn';
    public string $autocommit = '1';
    public array $databases = array('information_schema', 'shuzijun_review');
    public function read(string $sql): array {
        if ($sql === 'SELECT DATABASE()') { return array(array('database' => $this->database)); }
        if ($sql === 'SELECT @@SESSION.autocommit') { return array(array('autocommit' => $this->autocommit)); }
        if ($sql === 'SHOW DATABASES') { return array_map(static fn($name): array => array('Database' => $name), $this->databases); }
        if (str_starts_with($sql, 'SELECT option_value FROM ')) { return array(array('option_value' => $this->home)); }
        throw new RuntimeException('unexpected identity query');
    }
}
$identityDB = new RetirementIdentityDB();
decommission_check(retire_identity($identityDB, $profile, $parsed, 'authority') === $identity, 'exact production identity');
$identityDB->database = 'foreign';
decommission_reject(static fn() => retire_identity($identityDB, $profile, $parsed, 'authority'), 'database_identity');
$identityDB->database = 'wordpress'; $identityDB->home = 'https://other.invalid';
decommission_reject(static fn() => retire_identity($identityDB, $profile, $parsed, 'authority'), 'home_identity');
$identityDB->home = $identity['home']; $identityDB->autocommit = '0';
decommission_reject(static fn() => retire_identity($identityDB, $profile, $parsed, 'authority'), 'autocommit_required');
$identityDB->autocommit = '1';
decommission_reject(static fn() => retire_identity($identityDB, $profile, array_replace($parsed, array('YISHU_APP_SERVICE_ENVIRONMENT' => 'review')), 'authority'), 'environment_identity');
decommission_reject(static fn() => retire_identity($identityDB, $profile, $parsed, 'review-isolated'), 'production_role');
$reviewConfig = array_replace($parsed, array('DB_NAME' => 'shuzijun_review', 'DB_USER' => 'shuzijun_review',
    'DB_HOST' => 'localhost:/var/run/mysqld/mysqld.sock', 'prefix' => 'review_', 'YISHU_APP_SERVICE_ENVIRONMENT' => 'review'));
$identityDB->database = 'shuzijun_review'; $identityDB->home = 'https://review.shuzijun.com.cn';
decommission_check(retire_identity($identityDB, retire_profile('review'), $reviewConfig, 'review-isolated')['prefix'] === 'review_', 'exact isolated review profile');
$identityDB->databases[] = 'wordpress';
decommission_reject(static fn() => retire_identity($identityDB, retire_profile('review'), $reviewConfig, 'review-isolated'), 'review_database_scope');
decommission_check(retire_literal(array(T_CONSTANT_ENCAPSED_STRING, '"a\\n\\$b\\\\c"')) === "a\n\$b\\c", 'double literal escapes');
decommission_reject(static fn() => retire_config(str_replace("'localhost'", "getenv('DATABASE_HOST')", $configText)), 'literal_config_required');
decommission_reject(static fn() => retire_config($configText . "\ndefine('DB_NAME', 'other');"), 'literal_config_required');
decommission_reject(static fn() => retire_config(str_replace("'wp_'", "'wp_; DROP TABLE users'", $configText)), 'identifier');
decommission_reject(static fn() => retire_config(str_replace("'localhost'", "'remote.example'", $configText)), 'local_database_required');
foreach (array(GameRetirementPolicy::SCHEMA_OPTION, '_transient_yishu_game_submit_' . str_repeat('b', 64),
    '_transient_timeout_yishu_game_delete_' . str_repeat('c', 64)) as $name) {
    decommission_check(retire_option_allowed($name), 'confirmed game key');
}
foreach (array('yishu_fan_sessions', '_yishu_fan_uuid', 'yishu_push_schema_version',
    '_transient_yishu_game_submit_' . str_repeat('b', 63), '_transient_yishu_game_unknown_' . str_repeat('b', 64),
    '_transient_yishu_game_submit_' . str_repeat('b', 64) . '_extra') as $name) {
    decommission_check(!retire_option_allowed($name), 'reject unrelated/similar keys');
}
$db = new RetirementFakeDB(); $snapshot = retire_snapshot($db, $identity); $plan = retire_plan($snapshot);
decommission_check($db->writes === array() && $plan['leaderboardRows'] === 1 && $plan['gameOptions'] === 3, 'preflight cannot mutate');
$backups = array(); $rechecks = 0;
$backup = static function ($data) use (&$backups, $db): string {
    decommission_check($db->writes === array(), 'backup before first mutation'); $backups[] = $data; return str_repeat('b', 32);
};
$recheck = static function () use (&$rechecks): void { ++$rechecks; };
decommission_reject(static fn() => retire_apply($db, $snapshot, str_repeat('0', 64), $identity, $backup, $recheck), 'plan_changed');
decommission_reject(static fn() => retire_apply($db, $snapshot, $plan['planSha256'], array_replace($identity, array('role' => 'standby')), $backup, $recheck), 'confirmation_mismatch');
decommission_check(!$backups && !$db->writes, 'wrong plan or role never backs up or mutates');
decommission_reject(static fn() => retire_apply($db, $snapshot, $plan['planSha256'], $identity,
    static function (): never { throw new GameRetirementFailure('backup_failed'); }, $recheck), 'backup_failed');
decommission_check(!$db->writes, 'backup failure blocks all deletion');
$result = retire_apply($db, $snapshot, $plan['planSha256'], $identity, $backup, $recheck);
decommission_check($result['status'] === 'retired' && count($db->writes) === 4 && count($backups) === 1 && $rechecks === 1, 'exact table and three keys retired after backup');
decommission_check($result['leaderboardRows'] === 0 && $result['gameOptions'] === 0 && !$result['tableExists'], 'verified empty readback');
$empty = retire_snapshot($db, $identity); $beforeWrites = $db->writes;
$result = retire_apply($db, $empty, retire_plan($empty)['planSha256'], $identity, $backup, $recheck);
decommission_check($result['status'] === 'already-retired' && $db->writes === $beforeWrites && count($backups) === 1, 'idempotent with no new backup or writes');
foreach (array('meta' => 'unrecognized_game_meta_requires_review', 'triggers' => 'table_triggers', 'foreignKeys' => 'foreign_keys', 'badColumns' => 'table_columns') as $field => $code) {
    $badDB = new RetirementFakeDB(); $badDB->$field = $field === 'badColumns' ? true : '1';
    decommission_reject(static fn() => retire_snapshot($badDB, $identity), $code);
    decommission_check(!$badDB->writes, 'unknown schema or meta cannot mutate');
}
$changedDB = new RetirementFakeDB(); $old = retire_snapshot($changedDB, $identity);
$changedDB->rows[0]['score'] = '99';
decommission_reject(static fn() => retire_apply($changedDB, $old, retire_plan($old)['planSha256'], $identity,
    static fn(): string => str_repeat('a', 32), static function (): void {}), 'snapshot_changed_keep_backup');
decommission_check(!$changedDB->writes, 'changed records preserve all data');
$failedDB = new RetirementFakeDB(); $failedSnapshot = retire_snapshot($failedDB, $identity); $failedDB->dropFails = true;
$savedBeforeFailure = array();
$failedBackup = static function ($data) use (&$savedBeforeFailure): string { $savedBeforeFailure[] = $data; return str_repeat('d', 32); };
decommission_reject(static fn() => retire_apply($failedDB, $failedSnapshot, retire_plan($failedSnapshot)['planSha256'], $identity,
    $failedBackup,
    static function (): void {}), 'simulated_drop_failure');
decommission_check(count($savedBeforeFailure) === 1 && $failedDB->exists && count($failedDB->writes) === 1,
    'uncertain DROP never triggers automatic retry or unrelated delete');
$unknownOptionDB = new RetirementFakeDB(); $unknownOptionDB->options[] = array('option_name' => 'unrelated', 'option_value' => '1', 'autoload' => 'off');
decommission_reject(static fn() => retire_snapshot($unknownOptionDB, $identity), 'option_scope');
$bad = $snapshot; $bad['options'][0]['option_name'] = 'siteurl';
decommission_reject(static fn() => retire_rollback_sql($bad), 'backup_option_scope');
$safe = $snapshot; $safe['rows'][0]['ending_id'] = "'; DROP TABLE wp_users; --";
$sql = retire_rollback_sql($safe);
decommission_check(!str_contains($sql, 'DROP TABLE wp_users') && str_contains($sql, bin2hex($safe['rows'][0]['ending_id'])), 'rollback values are injection-proof hex');
decommission_check(!str_contains(retire_json($plan), 'fan_user_id') && !str_contains(retire_json($plan), 'option_value'), 'reports expose counts and hashes, not private rows');
// Pinned Redis adapter is exercised without a Redis extension or connection.
final class RetirementFakeRedis {
    public array $values;
    public array $ttls = array();
    public array $deletes = array();
    public bool $changeOnDelete = false;
    public function __construct() {
        $this->values = array('wp:options:' . GameRetirementPolicy::SCHEMA_OPTION => '1',
            'wp:transient:yishu_game_read_' . str_repeat('a', 64) => '2',
            'wp:options:alloptions' => serialize(array('blogname' => 'non-game', 'active_plugins' => 'unrelated')),
            'wp:options:notoptions' => serialize(array('unrelated_missing_option' => true)),
            'wp:users:123' => 'private-unrelated-user',
            'review:options:' . GameRetirementPolicy::SCHEMA_OPTION => 'foreign-site');
    }
    public function rawCommand(string $command, mixed ...$args): mixed {
        if ($command === 'GET') { return $this->values[$args[0]] ?? false; }
        if ($command === 'PTTL') { return isset($this->values[$args[0]]) ? ($this->ttls[$args[0]] ?? -1) : -2; }
        if ($command === 'SCAN') {
            decommission_check($args === array('0', 'MATCH', 'wp:*:*yishu_game_*', 'COUNT', '250'), 'bounded cache namespace scan');
            return array('0', array_values(array_filter(array_keys($this->values), static fn($key): bool =>
                str_starts_with($key, 'wp:') && str_contains($key, 'yishu_game_'))));
        }
        if ($command === 'EVAL') {
            decommission_check($args[1] === '1' && retire_cache_key_allowed($args[2])
                && str_contains($args[0], "redis.call('DEL',KEYS[1])")
                && !str_contains($args[0], 'FLUSH'), 'only atomic single game key deletion');
            $this->deletes[] = $args[2];
            if ($this->changeOnDelete) { $this->values[$args[2]] = 'changed'; }
            if (!isset($this->values[$args[2]])) { return 0; }
            if ($this->values[$args[2]] !== $args[3]) { return -1; }
            unset($this->values[$args[2]]); return 1;
        }
        throw new RuntimeException('redis command outside bounded scope');
    }
}
retire_cache_config($parsed);
decommission_check(true, 'observed cache defaults supported');
$redisConfig = retire_config($configText . "\ndefine('WP_REDIS_HOST', '127.0.0.1'); define('WP_REDIS_PORT', 6379); define('WP_REDIS_DATABASE', 0);");
retire_cache_config($redisConfig);
decommission_check($redisConfig['WP_REDIS_PORT'] === '6379' && $redisConfig['WP_REDIS_DATABASE'] === '0', 'only literal Redis numeric configuration');
foreach (array('WP_REDIS_PASSWORD', 'WP_REDIS_PREFIX', 'WP_REDIS_IGBINARY', 'WP_REDIS_CLUSTER', 'WP_CACHE_KEY_SALT', 'MULTISITE') as $key) {
    $changed = retire_config($configText . "\ndefine('" . $key . "', 'unsupported');");
    decommission_reject(static fn() => retire_cache_config($changed), 'persistent_cache_configuration_requires_review');
}
foreach (array('WP_REDIS_HOST' => 'remote.invalid', 'WP_REDIS_PORT' => '6380', 'WP_REDIS_DATABASE' => '1', 'prefix' => 'review_') as $key => $value) {
    decommission_reject(static fn() => retire_cache_config(array_replace($parsed, array($key => $value))), 'persistent_cache_configuration_requires_review');
}
decommission_check(!retire_cache_key_allowed('wp:options:alloptions') && !retire_cache_key_allowed('review:options:' . GameRetirementPolicy::SCHEMA_OPTION)
    && !retire_cache_key_allowed('wp:transient:yishu_game_unknown_' . str_repeat('a', 64)), 'cache namespace exact allowlist');
$redis = new RetirementFakeRedis(); $cache = new GameRetirementCache($redis); $cacheDB = new RetirementFakeDB();
$cacheSnapshot = retire_snapshot($cacheDB, $identity, $cache);
$cachePlan = retire_plan($cacheSnapshot);
decommission_check($cachePlan['gameCacheKeys'] === 2 && count($redis->deletes) === 0, 'cache preflight read only');
decommission_check(!str_contains(retire_json($cacheSnapshot), 'private-unrelated-user')
    && !str_contains(retire_json($cacheSnapshot), 'active_plugins') && !str_contains(retire_json($cacheSnapshot), 'foreign-site'), 'backup contains no foreign or shared cache data');
decommission_check(!str_contains(retire_json($cachePlan), 'valueBase64') && !str_contains(retire_json($cachePlan), str_repeat('a', 64)), 'cache report omits raw keys and values');
$ttlChanged = $cacheSnapshot; $ttlChanged['cache']['entries'][0]['ttlMs'] = 500;
decommission_check(retire_plan($ttlChanged)['planSha256'] === $cachePlan['planSha256'], 'TTL countdown does not invalidate exact key and value plan');
$changedValue = $cacheSnapshot; $changedValue['cache']['entries'][0]['valueBase64'] = base64_encode('new');
decommission_check(retire_plan($changedValue)['planSha256'] !== $cachePlan['planSha256'], 'cache value change invalidates plan');
$unrelated = array_filter($redis->values, static fn($key): bool => !retire_cache_key_allowed($key), ARRAY_FILTER_USE_KEY);
$savedCacheSnapshot = null;
$result = retire_apply($cacheDB, $cacheSnapshot, $cachePlan['planSha256'], $identity,
    static function ($snapshot) use (&$savedCacheSnapshot): string { $savedCacheSnapshot = $snapshot; return str_repeat('d', 32); }, static function (): void {}, $cache);
decommission_check($result['status'] === 'retired' && $result['removedGameCacheKeys'] === 2 && $result['gameCacheKeys'] === 0, 'database and exact cache keys retired together');
decommission_check($redis->values === $unrelated, 'shared options user cache and foreign namespace byte-identical');
decommission_check($savedCacheSnapshot === $cacheSnapshot, 'private backup retains exact cache raw bytes and TTL');
$empty = retire_snapshot($cacheDB, $identity, $cache);
decommission_check(retire_apply($cacheDB, $empty, retire_plan($empty)['planSha256'], $identity,
    static function (): never { throw new RuntimeException('empty must not back up'); }, static function (): void {}, $cache)['status'] === 'already-retired', 'cache-aware retirement idempotent');
foreach (array('wp:transient:yishu_game_unknown_' . str_repeat('a', 64), 'wp:options:_transient_yishu_game_read_' . str_repeat('a', 64)) as $unknown) {
    $fake = new RetirementFakeRedis(); $fake->values[$unknown] = 'unknown';
    decommission_reject(static fn() => (new GameRetirementCache($fake))->snapshot(), 'unrecognized_game_cache_requires_review');
    decommission_check($fake->deletes === array(), 'unknown cache key never deleted');
}
foreach (array('alloptions', 'notoptions') as $sharedKey) {
    $fake = new RetirementFakeRedis(); $fake->values['wp:options:' . $sharedKey] = serialize(array(GameRetirementPolicy::SCHEMA_OPTION => '1'));
    decommission_reject(static fn() => (new GameRetirementCache($fake))->snapshot(), 'shared_game_cache_requires_review');
    decommission_check($fake->deletes === array(), 'shared game entry requires separate review, no shared write');
}
$fake = new RetirementFakeRedis(); $adapter = new GameRetirementCache($fake); $cacheDB = new RetirementFakeDB();
$before = retire_snapshot($cacheDB, $identity, $adapter);
decommission_reject(static fn() => retire_apply($cacheDB, $before, retire_plan($before)['planSha256'], $identity,
    static function () use ($fake): string { $fake->values['wp:options:' . GameRetirementPolicy::SCHEMA_OPTION] = 'changed'; return str_repeat('e', 32); },
    static function (): void {}, $adapter), 'snapshot_changed_keep_backup');
decommission_check($cacheDB->writes === array() && $fake->deletes === array(), 'cache drift after backup prevents all writes');
$fake = new RetirementFakeRedis(); $adapter = new GameRetirementCache($fake); $cacheDB = new RetirementFakeDB();
$before = retire_snapshot($cacheDB, $identity, $adapter); $fake->changeOnDelete = true;
decommission_reject(static fn() => retire_apply($cacheDB, $before, retire_plan($before)['planSha256'], $identity,
    static fn(): string => str_repeat('f', 32), static function (): void {}, $adapter), 'cache_changed_keep_backup');
decommission_check(count($fake->deletes) === 1 && $fake->values['wp:options:' . GameRetirementPolicy::SCHEMA_OPTION] === 'changed', 'uncertain cache mutation is not retried or overwritten');
$fake = new RetirementFakeRedis(); $adapter = new GameRetirementCache($fake); $cacheDB = new RetirementFakeDB();
$cacheDB->exists = false; $cacheDB->rows = array(); $cacheDB->options = array();
$before = retire_snapshot($cacheDB, $identity, $adapter);
decommission_check(retire_apply($cacheDB, $before, retire_plan($before)['planSha256'], $identity,
    static fn(): string => str_repeat('e', 32), static function (): void {}, $adapter)['status'] === 'retired'
    && $cacheDB->writes === array(), 'cache-only partial cleanup can safely resume from fresh plan');
echo 'game-decommission-test: ' . $checks . " checks passed (synthetic, no WordPress/database/network)\n";
