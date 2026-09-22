<?php
declare(strict_types=1);

// Entirely synthetic: no WordPress bootstrap, credentials, SSH, files or DB.
define('YISHU_PUBLIC_SELECTION_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/operations/apply-public-experience-selection.php';

$assertions = 0;
function selection_test(bool $condition, string $label): void {
    global $assertions;
    ++$assertions;
    if (!$condition) { throw new RuntimeException('Failed: ' . $label); }
}
function selection_fails(callable $operation, string $expected): void {
    try { $operation(); selection_test(false, 'expected ' . $expected); }
    catch (GamePrivacyFailure $error) { selection_test($error->getMessage() === $expected, $expected . ': ' . $error->getMessage()); }
}

final class SelectionFakeDB {
    public string $posts = 'wp_posts';
    public string $postmeta = 'wp_postmeta';
    public string $options = 'wp_options';
    public string $last_error = '';
    public string $engine = 'InnoDB';
    public string $triggers = '0';
    public string $autocommit = '1';
    public array $state;
    public ?array $transaction = null;
    public int $writes = 0;
    public int $transactions = 0;
    public int $failWrite = 0;
    public bool $failCommit = false;
    public bool $commitButReturnFailure = false;
    public bool $failRollback = false;
    public int $nextID = 200;
    public array $prepared = array();

    public function __construct(array $state) { $this->state = $state; }
    public function prepare(string $sql, mixed ...$params): string {
        $key = '@prepared-' . count($this->prepared);
        $this->prepared[$key] = array($sql, $params);
        return $key;
    }
    private function unpack(string $sql): array { return $this->prepared[$sql] ?? array($sql, array()); }
    public function get_var(string $query): mixed {
        [$sql] = $this->unpack($query);
        $this->last_error = '';
        if (str_contains($sql, 'SELECT ENGINE')) { return $this->engine; }
        if (str_contains($sql, 'information_schema.TRIGGERS')) { return $this->triggers; }
        if ($sql === 'SELECT @@SESSION.autocommit') { return $this->autocommit; }
        throw new RuntimeException('Unexpected fake scalar query');
    }
    public function get_results(string $query, string $mode): array {
        [$sql] = $this->unpack($query);
        $this->last_error = '';
        if (str_starts_with($sql, 'SELECT ID FROM')) { return $this->state['firstAlbums']; }
        if (str_contains($sql, 'post_id NOT IN')) { return $this->state['foreignSelections']; }
        if (str_contains($sql, '`wp_posts`')) { return $this->state['posts']; }
        if (str_contains($sql, '`wp_options`')) { return $this->state['option']; }
        if (str_contains($sql, '`wp_postmeta`')) {
            $rows = $this->state['meta'];
            usort($rows, static fn(array $a, array $b): int => (int) $a['meta_id'] <=> (int) $b['meta_id']);
            return $rows;
        }
        throw new RuntimeException('Unexpected fake select');
    }
    public function query(string $query): int|false {
        [$sql, $params] = $this->unpack($query);
        $this->last_error = '';
        if ($sql === 'START TRANSACTION') { $this->transaction = $this->state; ++$this->transactions; return 0; }
        if ($sql === 'ROLLBACK') {
            if ($this->failRollback) { return false; }
            if ($this->transaction !== null) { $this->state = $this->transaction; $this->transaction = null; }
            return 0;
        }
        if ($sql === 'COMMIT') {
            if ($this->commitButReturnFailure) { $this->transaction = null; return false; }
            if ($this->failCommit) { return false; }
            $this->transaction = null; return 0;
        }
        ++$this->writes;
        if ($this->writes === $this->failWrite) { return false; }
        $kind = str_contains($sql, '`wp_options`') ? 'option' : 'meta';
        $idKey = $kind === 'option' ? 'option_id' : 'meta_id';
        $valueKey = $kind === 'option' ? 'option_value' : 'meta_value';
        if (str_starts_with($sql, 'INSERT INTO')) {
            $row = $kind === 'option'
                ? array('option_id' => (string) $this->nextID++, 'option_name' => $params[0], 'option_value' => $params[1], 'autoload' => $params[2])
                : array('meta_id' => (string) $this->nextID++, 'post_id' => (string) $params[0], 'meta_key' => $params[1], 'meta_value' => $params[2]);
            $this->state[$kind][] = $row;
            return 1;
        }
        if (str_starts_with($sql, 'DELETE FROM')) {
            foreach ($this->state[$kind] as $index => $row) {
                if ($row[$idKey] === (string) $params[0]) { array_splice($this->state[$kind], $index, 1); return 1; }
            }
            return 0;
        }
        if (str_starts_with($sql, 'UPDATE')) {
            foreach ($this->state[$kind] as &$row) {
                if ($row[$idKey] === (string) $params[1]) {
                    $row[$valueKey] = (string) $params[0];
                    unset($row);
                    return 1;
                }
            }
            unset($row);
            return 0;
        }
        throw new RuntimeException('Unexpected fake mutation');
    }
}

function selection_fixture(bool $duplicate = false, bool $hasOption = true): SelectionFakeDB {
    $state = array('posts' => array(), 'meta' => array(), 'option' => array(),
        'firstAlbums' => array(array('ID' => '6'), array('ID' => '7'), array('ID' => '39')), 'foreignSelections' => array());
    $seq = 1;
    $add = static function (int $id, string $key, string $value) use (&$state, &$seq): void {
        $state['meta'][] = array('meta_id' => (string) $seq++, 'post_id' => (string) $id, 'meta_key' => $key, 'meta_value' => $value);
    };
    foreach (PublicSelectionPolicy::IDS as $id) {
        $album = isset(PublicSelectionPolicy::SELECTION[$id]);
        $state['posts'][] = array('ID' => (string) $id, 'post_type' => $album ? 'portfolio' : 'attachment',
            'post_status' => $album ? 'publish' : 'inherit', 'post_title' => 'Synthetic ' . $id, 'post_content' => 'Must remain unchanged');
        $add($id, '_unrelated_synthetic', 'untouched');
        if ($album) {
            $add($id, '_portfolio_gallery', json_encode(array_merge(PublicSelectionPolicy::SELECTION[$id], array(999))));
            if ($id === 6) {
                $add($id, PublicSelectionPolicy::KEY, serialize(array()));
                if ($duplicate) { $add($id, PublicSelectionPolicy::KEY, ''); }
            }
        } else {
            $meta = array('width' => $id === 18 ? 1400 : 1024, 'height' => $id === 18 ? 2093 : 1536,
                'file' => $id === 18 ? PublicSelectionPolicy::OLD_FILE : '2026/08/synthetic-' . $id . '.jpg',
                'sizes' => array('1536x1536' => array('file' => 'synthetic-preview-' . $id . '.jpg', 'width' => 1024, 'height' => 1536)),
                'image_meta' => array('arbitrary' => 'preserve exactly'));
            $add($id, '_wp_attachment_metadata', serialize($meta));
            $add($id, '_wp_attached_file', $id === 18 ? PublicSelectionPolicy::ATTACHED : $meta['file']);
        }
    }
    if ($hasOption) { $state['option'][] = array('option_id' => '77', 'option_name' => PublicSelectionPolicy::OPTION, 'option_value' => '1500000000', 'autoload' => 'yes'); }
    return new SelectionFakeDB($state);
}

function selection_effects(SelectionFakeDB $db, array &$trace): array {
    $originalRaw = public_selection_value(public_selection_snapshot($db, false), 18, '_wp_attachment_metadata');
    $trace = array('backup' => array(), 'after' => array(), 'invalidate' => 0, 'sharedInvalidate' => 0, 'policy' => array(), 'authority' => 0);
    $facts = array();
    foreach (PublicSelectionPolicy::SELECTION as $ids) {
        foreach ($ids as $id) {
            $facts[$id] = array('attached' => $id === 18 ? PublicSelectionPolicy::ATTACHED : '2026/08/synthetic-' . $id . '.jpg',
                'full' => array('width' => $id === 18 ? 1712 : 1024, 'height' => $id === 18 ? 2560 : 1536,
                    'filesize' => 100000 + $id, 'sha256' => hash('sha256', 'synthetic-' . $id)),
                'preview' => array('width' => 1024, 'height' => 1536, 'filesize' => 50000 + $id),
                'previewFile' => 'synthetic-preview-' . $id . '.jpg');
        }
    }
    return array(
        'files' => static fn(array $snapshot): array => $facts,
        // Only the matching fixture raw value stands in for the pinned production digest.
        'metadataHash' => static fn(string $raw): string => $raw === $originalRaw ? PublicSelectionPolicy::OLD_META : hash('sha256', $raw),
        'authority' => static function () use (&$trace): void { ++$trace['authority']; },
        'backup' => static function (array $snapshot, int $timestamp) use (&$trace): string {
            $trace['backup'][] = array('snapshot' => $snapshot, 'timestamp' => $timestamp);
            return str_repeat('a', 32);
        },
        'finishBackup' => static function (string $id, array $snapshot, int $timestamp) use (&$trace): void {
            $trace['after'][] = array('snapshot' => $snapshot, 'timestamp' => $timestamp);
        },
        'invalidate' => static function () use (&$trace): void { ++$trace['invalidate']; },
        'sharedInvalidate' => static function () use (&$trace): void { ++$trace['sharedInvalidate']; },
        'policy' => static function (array $facts, bool $old) use (&$trace, $db): void {
            $trace['policy'][] = $old;
            $meta = public_selection_decode(public_selection_value(public_selection_snapshot($db, false), 18, '_wp_attachment_metadata'));
            public_selection_require($old ? $meta['file'] === PublicSelectionPolicy::OLD_FILE : $meta['file'] === PublicSelectionPolicy::ATTACHED,
                'synthetic_policy_state');
        });
}

selection_test(public_selection_arguments(array()) === array('dry-run', null), 'default read-only');
selection_test(public_selection_arguments(array('--dry-run')) === array('dry-run', null), 'explicit read-only');
selection_fails(static fn() => public_selection_arguments(array('apply=yes')), 'arguments');
selection_fails(static fn() => public_selection_arguments(array('rollback=../../private')), 'arguments');
selection_fails(static fn() => public_selection_decode(serialize((object) array('a' => 1))), 'metadata_serialization');
selection_fails(static fn() => public_selection_decode(serialize(array('a' => (object) array()))), 'metadata_object');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace);
$before = public_selection_snapshot($db, false);
$dry = public_selection_execute($db, 'dry-run', null, null, $fx);
selection_test($dry['changeNeeded'] === true && $dry['validatedImageCount'] === 6, 'dry repair report');
selection_test($db->writes === 0 && $db->transactions === 0 && !$trace['backup'] && !$trace['invalidate'] && !$trace['sharedInvalidate'], 'dry run no writes or cache mutation');
selection_test(public_selection_snapshot($db, false) === $before, 'dry unchanged');
selection_test($trace['policy'] === array(true), 'dry checks existing policy');

$db = selection_fixture(true); $trace = array(); $fx = selection_effects($db, $trace);
$before = public_selection_snapshot($db, false);
$result = public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx);
$after = public_selection_snapshot($db, false);
selection_test($result['status'] === 'applied' && strlen($result['backupID']) === 32, 'apply result receipt');
selection_test(count($trace['backup']) === 1 && count($trace['after']) === 1, 'before and after receipt');
selection_test($trace['backup'][0]['snapshot'] === $before && $trace['after'][0]['snapshot'] === $after, 'exact receipt snapshots');
selection_test($trace['backup'][0]['timestamp'] === $trace['after'][0]['timestamp'], 'receipt timestamp paired');
selection_test($trace['sharedInvalidate'] === 1, 'shared invalidation only after commit');
selection_test(public_selection_unowned($before) === public_selection_unowned($after), 'all non-target rows unchanged');
$oldMeta = public_selection_decode(public_selection_value($before, 18, '_wp_attachment_metadata'));
$newMeta = public_selection_decode(public_selection_value($after, 18, '_wp_attachment_metadata'));
selection_test($newMeta['file'] === PublicSelectionPolicy::ATTACHED && $newMeta['width'] === 1712 && $newMeta['height'] === 2560,
    'correct only actual attachment geometry');
selection_test($newMeta['sizes'] === $oldMeta['sizes'] && $newMeta['image_meta'] === $oldMeta['image_meta'], 'sizes and image metadata preserved');
unset($newMeta['file'], $newMeta['width'], $newMeta['height'], $newMeta['filesize']);
unset($oldMeta['file'], $oldMeta['width'], $oldMeta['height'], $oldMeta['filesize']);
selection_test($newMeta === $oldMeta, 'only four permitted metadata fields');
selection_test($after['option'][0]['autoload'] === 'yes', 'existing option autoload preserved');
selection_test(count(public_selection_meta($after, 6, PublicSelectionPolicy::KEY)) === 2, 'multiple existing rows retained');
foreach (PublicSelectionPolicy::SELECTION as $album => $ids) {
    foreach (public_selection_meta($after, $album, PublicSelectionPolicy::KEY) as $row) {
        selection_test(public_selection_decode($row['meta_value']) === $ids, 'exact fixed selection ' . $album);
    }
}
$writes = $db->writes;
$repeat = public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx);
selection_test($repeat['status'] === 'unchanged' && $db->writes === $writes && count($trace['backup']) === 1, 'idempotent apply');
$dry = public_selection_execute($db, 'dry-run', null, null, $fx);
selection_test($dry['changeNeeded'] === false && $db->writes === $writes, 'idempotent dry run');
$restore = array('before' => $before, 'after' => $after);
$rollback = public_selection_execute($db, 'rollback', null, $restore, $fx);
selection_test($rollback['status'] === 'restored' && public_selection_snapshot($db, false) === $before, 'exact rollback including multi-row presence and values');
$writes = $db->writes;
$repeat = public_selection_execute($db, 'rollback', null, $restore, $fx);
selection_test($repeat['status'] === 'already-restored' && $writes === $db->writes, 'idempotent rollback');

foreach (array(1, 2, 3, 4, 5) as $failWrite) {
    $db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace);
    $before = public_selection_snapshot($db, false); $db->failWrite = $failWrite;
    try { public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx); selection_test(false, 'failure injected'); }
    catch (GamePrivacyFailure $error) {
        selection_test(in_array($error->getMessage(), array('metadata_update', 'metadata_insert', 'updated_option_write'), true), 'bounded partial failure code');
        selection_test($error->backupID === str_repeat('a', 32), 'partial failure keeps receipt ID');
    }
    selection_test(public_selection_snapshot($db, false) === $before, 'atomic rollback at write ' . $failWrite);
    selection_test($trace['sharedInvalidate'] === 0, 'no uncommitted shared cache writes');
}

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace);
$before = public_selection_snapshot($db, false);
selection_fails(static fn() => public_selection_execute($db, 'apply', str_repeat('0', 64), null, $fx), 'expected_hash');
selection_test(!$db->writes && !$trace['backup'] && public_selection_snapshot($db, false) === $before, 'wrong expected digest cannot mutate');
$fx['metadataHash'] = static fn(string $raw): string => hash('sha256', $raw);
selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), 'metadata_hash_changed');
selection_test(!$db->writes && !$trace['backup'], 'changed raw metadata cannot mutate');

foreach (array('gallery', 'hidden', 'firstAlbums', 'foreignSelection') as $issue) {
    $db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace);
    if ($issue === 'gallery') {
        foreach ($db->state['meta'] as &$row) { if ($row['post_id'] === '6' && $row['meta_key'] === '_portfolio_gallery') { $row['meta_value'] = '[19,18]'; } } unset($row);
        $code = 'gallery_order_changed';
    } elseif ($issue === 'hidden') {
        $db->state['meta'][] = array('meta_id' => '101', 'post_id' => '6', 'meta_key' => '_app_is_hidden', 'meta_value' => '1'); $code = 'album_not_visible';
    } elseif ($issue === 'firstAlbums') {
        $db->state['firstAlbums'][0]['ID'] = '999'; $code = 'album_order_changed';
    } else {
        $db->state['foreignSelections'][] = array('meta_id' => '102', 'post_id' => '999', 'meta_key' => PublicSelectionPolicy::KEY, 'meta_value' => serialize(array(888)));
        $code = 'foreign_public_selection';
    }
    selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), $code);
    selection_test(!$db->writes && !$trace['backup'], $issue . ' prevents every write');
}

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false);
$fx['policy'] = static function (array $facts, bool $old): void { if (!$old) { throw new GamePrivacyFailure('real_public_image_policy_failed'); } };
selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), 'real_public_image_policy_failed');
selection_test(public_selection_snapshot($db, false) === $before && !$trace['after'], 'policy after repair fails closed before publication');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false);
$fx['finishBackup'] = static function (): void { throw new GamePrivacyFailure('backup_sync'); };
selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), 'backup_sync');
selection_test(public_selection_snapshot($db, false) === $before, 'after receipt must be durable before commit');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false); $db->failCommit = true;
selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), 'commit_uncertain_keep_backup');
selection_test(public_selection_snapshot($db, false) === $before && count($trace['after']) === 1, 'failed commit preserves receipts and rollback');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $db->commitButReturnFailure = true;
selection_fails(static fn() => public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx), 'transaction_outcome_uncertain_keep_backup');
selection_test(count($trace['backup']) === 1 && count($trace['after']) === 1, 'uncertain commit retains recovery evidence');
selection_test($trace['sharedInvalidate'] === 1, 'uncertain commit invalidates old shared cache');

$db = selection_fixture(false, false); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false);
public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx);
$after = public_selection_snapshot($db, false);
selection_test($after['option'][0]['autoload'] === 'off', 'new timestamp not autoloaded');
public_selection_execute($db, 'rollback', null, array('before' => $before, 'after' => $after), $fx);
selection_test(public_selection_snapshot($db, false) === $before, 'rollback restores absence of timestamp');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false);
public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx); $after = public_selection_snapshot($db, false);
$db->state['option'][0]['option_value'] = '1700000000'; $writes = $db->writes;
selection_fails(static fn() => public_selection_execute($db, 'rollback', null, array('before' => $before, 'after' => $after), $fx), 'restore_foreign_edit');
selection_test($db->writes === $writes && $db->state['option'][0]['option_value'] === '1700000000', 'foreign edit never overwritten');

$db = selection_fixture(); $trace = array(); $fx = selection_effects($db, $trace); $before = public_selection_snapshot($db, false);
public_selection_execute($db, 'apply', PublicSelectionPolicy::OLD_META, null, $fx); $after = public_selection_snapshot($db, false);
$db->state['posts'][0]['post_title'] = 'An unrelated editorial change';
public_selection_execute($db, 'rollback', null, array('before' => $before, 'after' => $after), $fx);
selection_test($db->state['posts'][0]['post_title'] === 'An unrelated editorial change', 'rollback preserves unowned external changes');
selection_test(public_selection_owned(public_selection_snapshot($db, false)) === public_selection_owned($before), 'rollback only owned values');

$db = selection_fixture(); public_selection_database_guard($db);
selection_test(true, 'InnoDB no-trigger database accepted');
$db->engine = 'MyISAM'; selection_fails(static fn() => public_selection_database_guard($db), 'transactional_tables_required');
$db->engine = 'InnoDB'; $db->triggers = '1'; selection_fails(static fn() => public_selection_database_guard($db), 'table_triggers');
$db->triggers = '0'; $db->autocommit = '0'; selection_fails(static fn() => public_selection_database_guard($db), 'fresh_transaction_required');
$receipt = public_selection_receipt($before, 1750000000);
selection_test(public_selection_validate_receipt($receipt) === $before, 'receipt hash validates');
$receipt['selection'][6] = array(18, 20);
selection_fails(static fn() => public_selection_validate_receipt($receipt), 'receipt_identity');

$cache = new PublicSelectionMemoryCache();
selection_test($cache->get(18, 'post_meta', false, $found) === false && !$found, 'isolated cache starts empty');
selection_test($cache->set(18, 'uncommitted', 'post_meta') && $cache->get(18, 'post_meta', false, $found) === 'uncommitted' && $found,
    'isolated cache stores only in memory');
$object = (object) array('value' => 1); $cache->set('object', $object); $object->value = 2;
selection_test($cache->get('object')->value === 1, 'object clone on set');
$copied = $cache->get('object'); $copied->value = 3;
selection_test($cache->get('object')->value === 1, 'object clone on get');
selection_test(!$cache->add(18, 'cannot replace', 'post_meta') && $cache->replace(18, 'new', 'post_meta'), 'memory add and replace contract');
$cache->set('counter', 2);
selection_test($cache->increment('counter', 3) === 5 && $cache->decrement('counter', 8) === 0, 'Redis increment aliases');
$cache->add_global_groups(array('users')); $cache->set('global', 'retained', 'users'); $cache->switch_to_blog(2);
selection_test($cache->get(18, 'post_meta') === false && $cache->get('global', 'users') === 'retained', 'blog and global group boundaries');
$cache->set_multiple(array('a' => 1, 'b' => 2), 'batch');
selection_test($cache->get_multiple(array('a', 'b'), 'batch') === array('a' => 1, 'b' => 2), 'multiple APIs');
$cache->flush_group('batch'); selection_test($cache->get('a', 'batch') === false && $cache->get('global', 'users') === 'retained', 'group flush isolated');
selection_fails(static fn() => $cache->unreviewed_remote_command(), 'unsupported_isolated_cache_method');

$shared = new class {
    public array $deleted = array();
    public function delete($key, $group = ''): bool { $this->deleted[] = array($key, $group); return true; }
};
public_selection_invalidate_shared($shared, $cache);
selection_test(count($shared->deleted) === 22, 'only bounded shared invalidations');
selection_test($cache->get('global', 'users') === false, 'local cache cleared after shared invalidation');

$redis = new class {
    public bool $connected = true;
    public bool $disconnectOnDelete = false;
    public int $clears = 0;
    public function redis_status(): bool { return $this->connected; }
    public function flush_runtime(): bool { ++$this->clears; return true; }
    public function delete($key, $group = ''): bool { if ($this->disconnectOnDelete) { $this->connected = false; } return false; }
};
public_selection_invalidate_shared($redis, $cache, true);
selection_test($redis->clears === 2, 'Redis runtime cache cleared before and after without global flush');
$redis->disconnectOnDelete = true;
selection_fails(static fn() => public_selection_invalidate_shared($redis, $cache, true), 'shared_cache_unavailable');
selection_fails(static fn() => public_selection_shared_ready($shared, true), 'shared_cache_unavailable');

// Stub the original wpdb transport, not the subclass under test. No sockets.
if (class_exists('wpdb', false)) { throw new RuntimeException('Unexpected WordPress bootstrap in synthetic test'); }
if (!class_exists('wpdb', false)) {
class wpdb {
    public string $posts = 'wp_posts'; public string $postmeta = 'wp_postmeta'; public string $options = 'wp_options';
    public string $prefix = 'wp_'; public int $blogid = 1; public string $last_error = '';
    protected mixed $dbh = null;
    public int $connectCalls = 0; public int $queryCalls = 0; public int $replayCalls = 0; public bool $closed = false;
    public bool $serverGone = false;
    public function __construct($user, $password, $database, $host) { $this->db_connect(); }
    public function db_connect($allow_bail = true) { ++$this->connectCalls; return true; }
    public function check_connection($allow_bail = true) { return $this->db_connect(); }
    public function query($sql) {
        ++$this->queryCalls;
        if ($this->serverGone) {
            $this->last_error = 'synthetic_2006';
            if (!$this->check_connection()) { return false; }
            ++$this->replayCalls;
        }
        return 1;
    }
    public function get_var($sql) { return 'wordpress'; }
    public function hide_errors() { return false; }
    public function set_prefix($prefix) { $this->prefix = $prefix; return 'wp_'; }
    public function set_blog_id($id) { $this->blogid = $id; return 1; }
    public function get_charset_collate() { return 'DEFAULT CHARACTER SET utf8mb4'; }
    public function close() { $this->closed = true; return true; }
}
}
function is_multisite(): bool { return false; }
define('DB_USER', 'synthetic'); define('DB_PASSWORD', ''); define('DB_NAME', 'wordpress'); define('DB_HOST', 'unused.invalid');
$wpdb = new wpdb('', '', '', ''); $originalDB = $wpdb;
public_selection_pin_database();
selection_test($wpdb instanceof PublicSelectionPinnedDB && $GLOBALS['wpdb'] === $wpdb, 'global WP reads pinned to no-replay database');
selection_test($originalDB->closed, 'original reconnecting transport closed');
selection_test($wpdb->connectCalls === 1 && $wpdb->db_connect(false) === false && $wpdb->connectCalls === 1, 'second explicit connection prohibited');
selection_test($wpdb->check_connection() === false && $wpdb->connectCalls === 1, 'wpdb reconnect prohibited');
$wpdb->serverGone = true;
selection_test($wpdb->query('UPDATE synthetic') === false && $wpdb->connectCalls === 1 && $wpdb->replayCalls === 0,
    'lost connection never replays a mutation');
selection_test($wpdb->query('SELECT policy metadata') === false && $wpdb->replayCalls === 0,
    'WordPress policy reads cannot reconnect either');

echo 'Public selection operation: ' . $assertions . " synthetic assertions passed. No production access.\n";
