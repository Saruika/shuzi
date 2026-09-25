<?php
declare(strict_types=1);

/**
 * One reviewed publication, root PHP 8.3 CLI only. No image bytes are written.
 * Keep update-app-privacy-policy.php beside this root-owned helper; its library
 * supplies the existing site/authority/cron/network/path guards, not page writes.
 *   php8.3 apply-public-experience-selection.php                 # read-only
 *   php8.3 apply-public-experience-selection.php apply=2504f01680af781b15097409ba49ce58e85c0163804e4b3055719ca42dfa6b13
 *   php8.3 apply-public-experience-selection.php rollback=RETURNED_32_HEX_ID
 * Receipts are fsync'd before writes and again before COMMIT. An uncertain commit
 * is never retried or "fixed" automatically. Preserve both receipt files.
 */
if (!defined('YISHU_APP_PRIVACY_LIBRARY_ONLY')) { define('YISHU_APP_PRIVACY_LIBRARY_ONLY', true); }
require_once __DIR__ . '/update-app-privacy-policy.php';

final class PublicSelectionPolicy {
    public const SELECTION = array(6 => array(18, 19), 7 => array(33, 34), 39 => array(76, 77));
    public const IDS = array(6, 7, 18, 19, 33, 34, 39, 76, 77);
    public const KEY = '_yishu_public_preview_media';
    public const OPTION = 'shuzijun_app_content_updated_at';
    public const OLD_META = '2504f01680af781b15097409ba49ce58e85c0163804e4b3055719ca42dfa6b13';
    public const OLD_FILE = '2026/03/2023-12-19-024812.jpg';
    public const ATTACHED = '2026/03/2023-12-19-024812-scaled.jpg';
    public const FILE_HASHES = array(
        '2026/03/2023-12-19-024812.jpg' => 'c6eb75a5271a3a9ef5a30de8411b40b1bced6deca9b55c115e771abcdbd4c61c',
        '2026/03/2023-12-19-024812-scaled.jpg' => 'b5f0296fc1fcf487bc6fac74722bf32edeb7b7e80fef36ce2cdd4c0cfc31070d',
        '2026/03/2023-12-19-024812-1027x1536.jpg' => '7961c1432b2f02ffc33007aafd9c426911e2fc51927529a785dccd6a911d0013');
}

function public_selection_require(bool $ok, string $code): void { app_privacy_require($ok, $code); }

function public_selection_arguments(array $args): array {
    if ($args === array() || $args === array('dry-run') || $args === array('--dry-run')) { return array('dry-run', null); }
    public_selection_require(count($args) === 1 && is_string($args[0]), 'arguments');
    if (preg_match('/^apply=([a-f0-9]{64})$/D', $args[0], $m) === 1) { return array('apply', $m[1]); }
    public_selection_require(preg_match('/^rollback=([a-f0-9]{32})$/D', $args[0], $m) === 1, 'arguments');
    return array('rollback', $m[1]);
}

function public_selection_method(string $name, mixed ...$args): mixed {
    public_selection_require(in_array($name, array('acquire_editorial_publication_lock',
        'release_named_fan_lock', 'public_preview_image'), true), 'method_scope');
    $method = new ReflectionMethod('Shuzijun_App_Content_API', $name);
    public_selection_require($method->isStatic(), 'method_shape');
    return $method->invoke(null, ...$args);
}

function public_selection_tables(object $db): array {
    $tables = array();
    foreach (array('posts', 'postmeta', 'options') as $kind) {
        $name = $db->$kind ?? null;
        public_selection_require(is_string($name) && preg_match('/^[A-Za-z0-9_]+$/D', $name) === 1, 'table_identifier');
        $tables[$kind] = '`' . $name . '`';
    }
    return $tables;
}

function public_selection_database_guard(object $db): void {
    foreach (public_selection_tables($db) as $table) {
        $engine = $db->get_var($db->prepare('SELECT ENGINE FROM information_schema.TABLES'
            . ' WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s', trim($table, '`')));
        public_selection_require($db->last_error === '' && $engine === 'InnoDB', 'transactional_tables_required');
        $triggers = $db->get_var($db->prepare('SELECT COUNT(*) FROM information_schema.TRIGGERS'
            . ' WHERE TRIGGER_SCHEMA=DATABASE() AND EVENT_OBJECT_TABLE=%s', trim($table, '`')));
        public_selection_require($db->last_error === '' && (string) $triggers === '0', 'table_triggers');
    }
    public_selection_require((string) $db->get_var('SELECT @@SESSION.autocommit') === '1'
        && $db->last_error === '', 'fresh_transaction_required');
}

/** No wpdb reconnect/replay is permitted after a transaction/advisory lock. */
function public_selection_pin_database(): void {
    global $wpdb;
    public_selection_require(class_exists('wpdb') && $wpdb instanceof wpdb
        && !is_multisite() && in_array(ini_get('mysqli.reconnect'), array(false, '', '0'), true), 'database_runtime');
    if (!class_exists('PublicSelectionPinnedDB', false)) {
        class PublicSelectionPinnedDB extends wpdb {
            private bool $initialConnectionAttempted = false;
            private ?int $connectionIdentity = null;
            public function __construct($user, $password, $database, $host) {
                parent::__construct($user, $password, $database, $host);
                if ($this->dbh instanceof mysqli) { $this->connectionIdentity = mysqli_thread_id($this->dbh); }
            }
            public function db_connect($allow_bail = true) {
                if ($this->initialConnectionAttempted) { return false; }
                $this->initialConnectionAttempted = true;
                return parent::db_connect($allow_bail);
            }
            public function check_connection($allow_bail = true) { return false; }
            public function query($query) {
                if ($this->connectionIdentity !== null) {
                    try {
                        if (!$this->dbh instanceof mysqli || mysqli_thread_id($this->dbh) !== $this->connectionIdentity) {
                            $this->last_error = 'pinned_connection_changed'; return false;
                        }
                    } catch (Throwable $error) { $this->last_error = 'pinned_connection_lost'; return false; }
                }
                $result = parent::query($query);
                if ($this->connectionIdentity !== null) {
                    try {
                        if (!$this->dbh instanceof mysqli || mysqli_thread_id($this->dbh) !== $this->connectionIdentity) {
                            $this->last_error = 'pinned_connection_changed'; return false;
                        }
                    } catch (Throwable $error) { $this->last_error = 'pinned_connection_lost'; return false; }
                }
                return $result;
            }
        }
    }
    $original = $wpdb;
    $pinned = new PublicSelectionPinnedDB(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST);
    $pinned->hide_errors();
    public_selection_require($pinned->set_prefix($original->prefix) !== false, 'database_prefix');
    $pinned->set_blog_id((int) $original->blogid);
    public_selection_require(public_selection_tables($pinned) === public_selection_tables($original)
        && $pinned->get_charset_collate() === $original->get_charset_collate()
        && $pinned->get_var('SELECT DATABASE()') === 'wordpress' && $pinned->last_error === '', 'pinned_database_identity');
    $wpdb = $pinned;
    // No stale connection may be used by a later accidental reference.
    public_selection_require($original->close() !== false, 'old_database_close');
}

/** Per-process cache only. Unknown drop-in methods fail closed, never delegate. */
final class PublicSelectionMemoryCache {
    private array $values = array();
    public int $cache_hits = 0;
    public int $cache_misses = 0;
    public array $global_groups = array();
    public array $non_persistent_groups = array();
    private int $blog = 1;
    public function __construct(int $blog = 1) { $this->blog = $blog; }
    private function key(mixed $key, string $group): string {
        public_selection_require(is_int($key) || is_string($key), 'cache_key_shape');
        $group = $group === '' ? 'default' : $group;
        return (isset($this->global_groups[$group]) ? 'global' : (string) $this->blog) . ':' . $group . ':' . (string) $key;
    }
    private function copy(mixed $value): mixed { return is_object($value) ? clone $value : $value; }
    public function get($key, $group = 'default', $force = false, &$found = null): mixed {
        $index = $this->key($key, (string) $group);
        $found = array_key_exists($index, $this->values);
        if ($found) { ++$this->cache_hits; return $this->copy($this->values[$index]); }
        ++$this->cache_misses; return false;
    }
    public function set($key, $value, $group = 'default', $expire = 0): bool {
        $this->values[$this->key($key, (string) $group)] = $this->copy($value); return true;
    }
    public function add($key, $value, $group = 'default', $expire = 0): bool {
        $index = $this->key($key, (string) $group);
        if (array_key_exists($index, $this->values)) { return false; }
        return $this->set($key, $value, $group, $expire);
    }
    public function replace($key, $value, $group = 'default', $expire = 0): bool {
        $index = $this->key($key, (string) $group);
        if (!array_key_exists($index, $this->values)) { return false; }
        return $this->set($key, $value, $group, $expire);
    }
    public function delete($key, $group = 'default', $deprecated = false): bool {
        $index = $this->key($key, (string) $group);
        $found = array_key_exists($index, $this->values); unset($this->values[$index]); return $found;
    }
    public function get_multiple($keys, $group = 'default', $force = false): array {
        $result = array(); foreach ($keys as $key) { $result[$key] = $this->get($key, $group, $force); } return $result;
    }
    public function set_multiple($values, $group = 'default', $expire = 0): array {
        $result = array(); foreach ($values as $key => $value) { $result[$key] = $this->set($key, $value, $group, $expire); } return $result;
    }
    public function add_multiple($values, $group = 'default', $expire = 0): array {
        $result = array(); foreach ($values as $key => $value) { $result[$key] = $this->add($key, $value, $group, $expire); } return $result;
    }
    public function delete_multiple($keys, $group = 'default'): array {
        $result = array(); foreach ($keys as $key) { $result[$key] = $this->delete($key, $group); } return $result;
    }
    public function incr($key, $offset = 1, $group = 'default'): int|false {
        $value = $this->get($key, $group, false, $found); if (!$found) { return false; }
        $value = max(0, (int) $value + (int) $offset); $this->set($key, $value, $group); return $value;
    }
    public function decr($key, $offset = 1, $group = 'default'): int|false { return $this->incr($key, -(int) $offset, $group); }
    public function increment($key, $offset = 1, $group = 'default'): int|false { return $this->incr($key, $offset, $group); }
    public function decrement($key, $offset = 1, $group = 'default'): int|false { return $this->decr($key, $offset, $group); }
    public function add_global_groups($groups): void { foreach ((array) $groups as $group) { $this->global_groups[$group] = true; } }
    public function add_non_persistent_groups($groups): void { foreach ((array) $groups as $group) { $this->non_persistent_groups[$group] = true; } }
    public function switch_to_blog($blog): void { $this->blog = (int) $blog; }
    public function flush(): bool { $this->values = array(); return true; }
    public function flush_runtime(): bool { return $this->flush(); }
    public function flush_group($group): bool {
        $prefix = $this->key('', (string) $group);
        foreach (array_keys($this->values) as $key) { if (str_starts_with($key, $prefix)) { unset($this->values[$key]); } }
        return true;
    }
    public function reset(): bool { return $this->flush(); }
    public function close(): bool { return true; }
    public function supports($feature): bool { return in_array($feature, array('get_multiple', 'set_multiple', 'add_multiple', 'delete_multiple', 'flush_runtime', 'flush_group'), true); }
    public function __call(string $method, array $arguments): never { throw new AppPrivacyFailure('unsupported_isolated_cache_method'); }
}

function public_selection_shared_ready(object $shared, bool $persistent): void {
    public_selection_require(method_exists($shared, 'delete'), 'shared_cache_shape');
    if ($persistent) {
        public_selection_require(method_exists($shared, 'redis_status') && $shared->redis_status() === true
            && method_exists($shared, 'flush_runtime'), 'shared_cache_unavailable');
    }
}

function public_selection_invalidate_shared(object $shared, PublicSelectionMemoryCache $local, bool $persistent = false): void {
    public_selection_shared_ready($shared, $persistent);
    if ($persistent) { public_selection_require($shared->flush_runtime() === true, 'shared_runtime_cache_clear'); }
    // Direct method deletion avoids clean_post_cache hooks or reads repopulating
    // shared storage with this transaction's data. Only known owned keys.
    foreach (PublicSelectionPolicy::IDS as $id) {
        $shared->delete($id, 'posts'); $shared->delete($id, 'post_meta');
    }
    $shared->delete(PublicSelectionPolicy::OPTION, 'options');
    $shared->delete('alloptions', 'options'); $shared->delete('notoptions', 'options');
    $shared->delete('last_changed', 'posts');
    public_selection_shared_ready($shared, $persistent);
    if ($persistent) { public_selection_require($shared->flush_runtime() === true, 'shared_runtime_cache_clear'); }
    $local->flush();
}

function public_selection_rows(object $db, string $sql): array {
    $rows = $db->get_results($sql, 'ARRAY_A');
    public_selection_require($db->last_error === '' && is_array($rows) && count($rows) <= 2000, 'snapshot_read');
    foreach ($rows as &$row) {
        public_selection_require(is_array($row), 'snapshot_row');
        foreach ($row as $key => &$value) {
            public_selection_require(is_string($key) && (is_string($value) || is_int($value)), 'snapshot_field');
            $value = (string) $value;
        }
        unset($value);
        ksort($row);
    }
    unset($row);
    return $rows;
}

function public_selection_snapshot(object $db, bool $locked): array {
    $t = public_selection_tables($db);
    $suffix = $locked ? ' FOR UPDATE' : '';
    $ids = implode(',', PublicSelectionPolicy::IDS);
    return array(
        'posts' => public_selection_rows($db, "SELECT * FROM {$t['posts']} WHERE ID IN ($ids) ORDER BY ID$suffix"),
        'meta' => public_selection_rows($db, "SELECT * FROM {$t['postmeta']} WHERE post_id IN ($ids) ORDER BY meta_id$suffix"),
        'option' => public_selection_rows($db, $db->prepare("SELECT * FROM {$t['options']} WHERE option_name=%s ORDER BY option_id$suffix", PublicSelectionPolicy::OPTION)),
        'firstAlbums' => public_selection_rows($db, "SELECT ID FROM {$t['posts']} WHERE post_type='portfolio' AND post_status='publish' ORDER BY post_date ASC, ID ASC LIMIT 3$suffix"),
        'foreignSelections' => public_selection_rows($db, $db->prepare("SELECT * FROM {$t['postmeta']} WHERE meta_key=%s AND post_id NOT IN (6,7,39) ORDER BY meta_id$suffix", PublicSelectionPolicy::KEY)));
}

function public_selection_meta(array $snapshot, int $id, string $key): array {
    return array_values(array_filter($snapshot['meta'], static fn(array $row): bool =>
        $row['post_id'] === (string) $id && $row['meta_key'] === $key));
}

function public_selection_value(array $snapshot, int $id, string $key, bool $optional = false): string {
    $rows = public_selection_meta($snapshot, $id, $key);
    public_selection_require(count($rows) === 1 || ($optional && !$rows), 'metadata_cardinality');
    return $rows ? $rows[0]['meta_value'] : '';
}

function public_selection_decode(string $raw): array {
    $value = @unserialize($raw, array('allowed_classes' => false));
    public_selection_require(is_array($value) && strlen($raw) <= 524288, 'metadata_serialization');
    // Serialized objects (including nested ones) are never accepted.
    $walk = static function (mixed $item) use (&$walk): void {
        public_selection_require(is_array($item) || is_scalar($item) || $item === null, 'metadata_object');
        if (is_array($item)) { foreach ($item as $child) { $walk($child); } }
    };
    $walk($value);
    return $value;
}

function public_selection_owned(array $snapshot): array {
    return array('meta' => array_values(array_filter($snapshot['meta'], static fn(array $row): bool =>
        ($row['post_id'] === '18' && $row['meta_key'] === '_wp_attachment_metadata')
        || (isset(PublicSelectionPolicy::SELECTION[(int) $row['post_id']]) && $row['meta_key'] === PublicSelectionPolicy::KEY))),
        'option' => $snapshot['option']);
}

function public_selection_unowned(array $snapshot): array {
    $ownedIDs = array_column(public_selection_owned($snapshot)['meta'], 'meta_id');
    $snapshot['meta'] = array_values(array_filter($snapshot['meta'], static fn(array $row): bool => !in_array($row['meta_id'], $ownedIDs, true)));
    unset($snapshot['option']);
    return $snapshot;
}

/** Strict identities and original gallery order. Never silently publish five. */
function public_selection_validate(array $snapshot): array {
    public_selection_require(array_map('intval', array_column($snapshot['posts'], 'ID')) === PublicSelectionPolicy::IDS,
        'post_identity');
    public_selection_require(array_map('intval', array_column($snapshot['firstAlbums'], 'ID')) === array(6, 7, 39), 'album_order_changed');
    public_selection_require(count($snapshot['option']) <= 1, 'updated_option_cardinality');
    foreach ($snapshot['foreignSelections'] as $row) {
        public_selection_require($row['meta_value'] === '' || public_selection_decode($row['meta_value']) === array(), 'foreign_public_selection');
    }
    $posts = array_column($snapshot['posts'], null, 'ID');
    foreach (PublicSelectionPolicy::SELECTION as $album => $ids) {
        public_selection_require($posts[$album]['post_type'] === 'portfolio' && $posts[$album]['post_status'] === 'publish'
            && public_selection_value($snapshot, $album, '_app_is_hidden', true) !== '1', 'album_not_visible');
        $gallery = json_decode(public_selection_value($snapshot, $album, '_portfolio_gallery'), true);
        public_selection_require(is_array($gallery) && array_slice($gallery, 0, 2) === $ids, 'gallery_order_changed');
        foreach (public_selection_meta($snapshot, $album, PublicSelectionPolicy::KEY) as $row) {
            $value = $row['meta_value'] === '' ? array() : public_selection_decode($row['meta_value']);
            public_selection_require($value === array() || $value === $ids, 'existing_selection_changed');
        }
        foreach ($ids as $id) {
            public_selection_require($posts[$id]['post_type'] === 'attachment' && $posts[$id]['post_status'] !== 'trash', 'attachment_identity');
            public_selection_decode(public_selection_value($snapshot, $id, '_wp_attachment_metadata'));
            public_selection_value($snapshot, $id, '_wp_attached_file');
        }
    }
    return public_selection_decode(public_selection_value($snapshot, 18, '_wp_attachment_metadata'));
}

/** Read local files only. No URL access, image decoding output or file writes. */
function public_selection_files(array $snapshot): array {
    $root = AppPrivacyPolicy::SITE . '/wp-content/uploads';
    public_selection_require(realpath($root) === $root && !is_link($root), 'uploads_root');
    $read = static function (string $relative) use ($root): array {
        public_selection_require(preg_match('#^2026/(03|08)/[A-Za-z0-9_.-]+\.jpg$#D', $relative) === 1, 'image_path');
        $path = $root . '/' . $relative;
        public_selection_require(realpath($path) === $path && is_file($path) && !is_link($path), 'image_file');
        $before = stat($path);
        $dimensions = @getimagesize($path);
        $hash = hash_file('sha256', $path);
        clearstatcache(true, $path);
        $after = stat($path);
        public_selection_require(is_array($before) && $before === $after && is_array($dimensions)
            && ($dimensions['mime'] ?? null) === 'image/jpeg' && is_string($hash), 'image_file_changed');
        return array('width' => $dimensions[0], 'height' => $dimensions[1], 'filesize' => (int) $before['size'], 'sha256' => $hash);
    };
    foreach (PublicSelectionPolicy::FILE_HASHES as $path => $sha) {
        public_selection_require(hash_equals($sha, $read($path)['sha256']), 'image18_bytes_changed');
    }
    $facts = array();
    foreach (PublicSelectionPolicy::SELECTION as $ids) {
        foreach ($ids as $id) {
            $attached = public_selection_value($snapshot, $id, '_wp_attached_file');
            $meta = public_selection_decode(public_selection_value($snapshot, $id, '_wp_attachment_metadata'));
            $full = $read($attached);
            if ($id === 18) {
                public_selection_require($attached === PublicSelectionPolicy::ATTACHED && $full['width'] === 1712
                    && $full['height'] === 2560, 'image18_attached_changed');
            } else {
                public_selection_require(($meta['file'] ?? null) === $attached && ($meta['width'] ?? null) === $full['width']
                    && ($meta['height'] ?? null) === $full['height'], 'attachment_metadata_mismatch');
            }
            $size = $meta['sizes']['1536x1536'] ?? null;
            public_selection_require(is_array($size) && is_string($size['file'] ?? null)
                && preg_match('/^[A-Za-z0-9_.-]+\.jpg$/D', $size['file']) === 1, 'preview_metadata');
            $preview = $read(dirname($attached) . '/' . $size['file']);
            public_selection_require($preview['width'] === ($size['width'] ?? null) && $preview['height'] === ($size['height'] ?? null)
                && max($preview['width'], $preview['height']) === 1536
                && abs(($preview['width'] / $preview['height']) / ($full['width'] / $full['height']) - 1) <= 0.02,
                'preview_dimensions');
            $facts[$id] = array('attached' => $attached, 'full' => $full, 'preview' => $preview, 'previewFile' => $size['file']);
        }
    }
    public_selection_require(count($facts) === 6, 'six_images_required');
    return $facts;
}

function public_selection_corrected(array $meta, array $facts): array {
    $meta['file'] = $facts[18]['attached'];
    foreach (array('width', 'height', 'filesize') as $key) { $meta[$key] = $facts[18]['full'][$key]; }
    return $meta;
}

function public_selection_is_applied(array $snapshot, array $facts): bool {
    $meta = public_selection_validate($snapshot);
    if ($meta !== public_selection_corrected($meta, $facts)) { return false; }
    foreach (PublicSelectionPolicy::SELECTION as $album => $ids) {
        $rows = public_selection_meta($snapshot, $album, PublicSelectionPolicy::KEY);
        if (!$rows) { return false; }
        foreach ($rows as $row) { if (public_selection_decode($row['meta_value']) !== $ids) { return false; } }
    }
    return true;
}

function public_selection_policy_images(array $facts, bool $allowKnownOld): void {
    foreach ($facts as $id => $fact) {
        $image = public_selection_method('public_preview_image', $id);
        if ($allowKnownOld && $id === 18) { public_selection_require($image === null, 'old_image18_policy_unexpected'); continue; }
        public_selection_require(is_array($image) && ($image['id'] ?? null) === $id
            && is_string($image['url'] ?? null) && basename((string) parse_url($image['url'], PHP_URL_PATH)) === $fact['previewFile'],
            'real_public_image_policy_failed');
    }
}

function public_selection_invalidate(): void {
    // No hooks or shared cache mutation may observe an uncommitted row.
    $cache = $GLOBALS['wp_object_cache'] ?? null;
    public_selection_require($cache instanceof PublicSelectionMemoryCache, 'isolated_cache_required');
    $cache->flush();
}

function public_selection_write_value(object $db, array $rows, int $postID, string $key, string $value): void {
    $table = public_selection_tables($db)['postmeta'];
    if (!$rows) {
        $sql = $db->prepare("INSERT INTO $table (post_id,meta_key,meta_value) VALUES (%d,%s,%s)", $postID, $key, $value);
        public_selection_require($db->query($sql) === 1 && $db->last_error === '', 'metadata_insert');
        return;
    }
    foreach ($rows as $row) {
        if ($row['meta_value'] === $value) { continue; }
        $sql = $db->prepare("UPDATE $table SET meta_value=%s WHERE meta_id=%d AND post_id=%d AND meta_key=%s", $value, (int) $row['meta_id'], $postID, $key);
        public_selection_require($db->query($sql) === 1 && $db->last_error === '', 'metadata_update');
    }
}

function public_selection_write_option(object $db, array $rows, string $value): void {
    $table = public_selection_tables($db)['options'];
    if (!$rows) {
        $sql = $db->prepare("INSERT INTO $table (option_name,option_value,autoload) VALUES (%s,%s,%s)", PublicSelectionPolicy::OPTION, $value, 'off');
    } else {
        if ($rows[0]['option_value'] === $value) { return; }
        $sql = $db->prepare("UPDATE $table SET option_value=%s WHERE option_id=%d AND option_name=%s", $value, (int) $rows[0]['option_id'], PublicSelectionPolicy::OPTION);
    }
    public_selection_require($db->query($sql) === 1 && $db->last_error === '', 'updated_option_write');
}

function public_selection_json(array $value): string { return app_privacy_json($value); }

function public_selection_write_receipt(string $path, array $value): void {
    $handle = @fopen($path, 'xb');
    public_selection_require(is_resource($handle), 'backup_open');
    try {
        $stat = fstat($handle);
        public_selection_require($stat['uid'] === 0 && ($stat['mode'] & 0777) === 0600 && $stat['nlink'] === 1, 'backup_permissions');
        $bytes = public_selection_json($value) . "\n";
        $written = 0;
        while ($written < strlen($bytes)) {
            $count = fwrite($handle, substr($bytes, $written));
            public_selection_require(is_int($count) && $count > 0, 'backup_write');
            $written += $count;
        }
        public_selection_require(fflush($handle) && fsync($handle), 'backup_sync');
    } finally { fclose($handle); }
    app_privacy_sync_directory(dirname($path));
    public_selection_require(app_privacy_read($path, 8388608, 0600) === $bytes, 'backup_readback');
}

function public_selection_receipt(array $snapshot, int $timestamp): array {
    return array('schema' => 1, 'site' => AppPrivacyPolicy::SITE, 'selection' => PublicSelectionPolicy::SELECTION,
        'oldMetadataSha256' => PublicSelectionPolicy::OLD_META, 'timestamp' => $timestamp,
        'snapshot' => $snapshot, 'snapshotSha256' => hash('sha256', public_selection_json($snapshot)));
}

function public_selection_validate_receipt(array $receipt): array {
    public_selection_require(array_keys($receipt) === array('schema', 'site', 'selection', 'oldMetadataSha256', 'timestamp', 'snapshot', 'snapshotSha256')
        && $receipt['schema'] === 1 && $receipt['site'] === AppPrivacyPolicy::SITE
        && $receipt['selection'] === PublicSelectionPolicy::SELECTION && $receipt['oldMetadataSha256'] === PublicSelectionPolicy::OLD_META
        && is_int($receipt['timestamp']) && $receipt['timestamp'] > 0 && is_array($receipt['snapshot'])
        && $receipt['snapshotSha256'] === hash('sha256', public_selection_json($receipt['snapshot'])), 'receipt_identity');
    public_selection_validate($receipt['snapshot']);
    return $receipt['snapshot'];
}

function public_selection_backup(array $snapshot, int $timestamp): string {
    app_privacy_safe_path(AppPrivacyPolicy::BACKUPS, true, 0700);
    $id = bin2hex(random_bytes(16));
    $directory = AppPrivacyPolicy::BACKUPS . '/public-selection-' . $id;
    public_selection_require(@mkdir($directory, 0700), 'backup_directory');
    app_privacy_safe_path($directory, true, 0700);
    app_privacy_sync_directory(AppPrivacyPolicy::BACKUPS);
    public_selection_write_receipt($directory . '/before.json', public_selection_receipt($snapshot, $timestamp));
    return $id;
}

function public_selection_finish_backup(string $id, array $snapshot, int $timestamp): void {
    public_selection_require(preg_match('/^[a-f0-9]{32}$/D', $id) === 1, 'backup_id');
    $directory = AppPrivacyPolicy::BACKUPS . '/public-selection-' . $id;
    app_privacy_safe_path($directory, true, 0700);
    public_selection_write_receipt($directory . '/after.json', public_selection_receipt($snapshot, $timestamp));
}

function public_selection_load_backup(string $id): array {
    public_selection_require(preg_match('/^[a-f0-9]{32}$/D', $id) === 1, 'backup_id');
    $directory = AppPrivacyPolicy::BACKUPS . '/public-selection-' . $id;
    app_privacy_safe_path($directory, true, 0700);
    $records = array();
    foreach (array('before', 'after') as $name) {
        $receipt = json_decode(app_privacy_read($directory . '/' . $name . '.json', 8388608, 0600), true);
        public_selection_require(is_array($receipt), 'receipt_json');
        $records[$name] = public_selection_validate_receipt($receipt);
        $records[$name . 'Timestamp'] = $receipt['timestamp'];
    }
    public_selection_require($records['beforeTimestamp'] === $records['afterTimestamp']
        && hash('sha256', public_selection_value($records['before'], 18, '_wp_attachment_metadata')) === PublicSelectionPolicy::OLD_META
        && public_selection_unowned($records['before']) === public_selection_unowned($records['after']), 'receipt_scope');
    return $records;
}

/** Restore exact rows, IDs, absence and raw serialized values; never overwrite a foreign edit. */
function public_selection_restore_rows(object $db, array $current, array $original): void {
    $tables = public_selection_tables($db);
    foreach (array('meta', 'option') as $kind) {
        $idKey = $kind === 'meta' ? 'meta_id' : 'option_id';
        $table = $tables[$kind === 'meta' ? 'postmeta' : 'options'];
        $valueKey = $kind === 'meta' ? 'meta_value' : 'option_value';
        $target = array_column($original[$kind], null, $idKey);
        foreach ($current[$kind] as $row) {
            $id = $row[$idKey];
            if (!isset($target[$id])) {
                public_selection_require($db->query($db->prepare("DELETE FROM $table WHERE $idKey=%d", (int) $id)) === 1
                    && $db->last_error === '', 'restore_inserted_row');
                continue;
            }
            $old = $target[$id];
            $left = $row; $right = $old; unset($left[$valueKey], $right[$valueKey]);
            public_selection_require($left === $right, 'restore_row_structure');
            if ($row[$valueKey] !== $old[$valueKey]) {
                public_selection_require($db->query($db->prepare("UPDATE $table SET $valueKey=%s WHERE $idKey=%d", $old[$valueKey], (int) $id)) === 1
                    && $db->last_error === '', 'restore_value');
            }
            unset($target[$id]);
        }
        public_selection_require(!$target, 'restore_missing_original_row');
    }
}

/** Injectable effects for synthetic tests; CLI never accepts overrides. */
function public_selection_execute(object $db, string $mode, ?string $hash, ?array $restore, array $effects): array {
    public_selection_require(in_array($mode, array('dry-run', 'apply', 'rollback'), true), 'mode');
    if ($mode === 'dry-run') {
        $before = public_selection_snapshot($db, false);
        public_selection_validate($before);
        $facts = $effects['files']($before);
        $applied = public_selection_is_applied($before, $facts);
        $currentHash = $effects['metadataHash'](public_selection_value($before, 18, '_wp_attachment_metadata'));
        public_selection_require($applied || $currentHash === PublicSelectionPolicy::OLD_META, 'metadata_hash_changed');
        $effects['policy']($facts, !$applied);
        return array('status' => 'dry-run', 'selection' => PublicSelectionPolicy::SELECTION,
            'metadataSha256' => $currentHash, 'changeNeeded' => !$applied, 'validatedImageCount' => count($facts));
    }
    public_selection_require($db->query('START TRANSACTION') !== false && $db->last_error === '', 'transaction_start');
    $committed = false; $backupID = null; $before = null;
    try {
        $effects['authority']();
        $before = public_selection_snapshot($db, true);
        public_selection_validate($before);
        $facts = $effects['files']($before);
        if ($mode === 'apply') {
            public_selection_require($hash === PublicSelectionPolicy::OLD_META, 'expected_hash');
            if (public_selection_is_applied($before, $facts)) {
                $effects['policy']($facts, false);
                public_selection_require($db->query('ROLLBACK') !== false, 'transaction_rollback');
                return array('status' => 'unchanged', 'selection' => PublicSelectionPolicy::SELECTION, 'validatedImageCount' => 6);
            }
            $raw = public_selection_value($before, 18, '_wp_attachment_metadata');
            public_selection_require(hash_equals($hash, $effects['metadataHash']($raw)), 'metadata_hash_changed');
            $meta = public_selection_decode($raw);
            public_selection_require(($meta['file'] ?? null) === PublicSelectionPolicy::OLD_FILE
                && ($meta['width'] ?? null) === 1400 && ($meta['height'] ?? null) === 2093
                && !isset($meta['original_image']), 'legacy_metadata_shape');
            $effects['policy']($facts, true);
            $timestamp = max(time(), 1 + (int) ($before['option'][0]['option_value'] ?? 0));
            $backupID = $effects['backup']($before, $timestamp);
            $effects['authority']();
            public_selection_write_value($db, public_selection_meta($before, 18, '_wp_attachment_metadata'), 18,
                '_wp_attachment_metadata', serialize(public_selection_corrected($meta, $facts)));
            $effects['invalidate']();
            $effects['policy']($facts, false); // Real WordPress policy, after repair and before publication.
            foreach (PublicSelectionPolicy::SELECTION as $album => $ids) {
                public_selection_write_value($db, public_selection_meta($before, $album, PublicSelectionPolicy::KEY),
                    $album, PublicSelectionPolicy::KEY, serialize($ids));
            }
            public_selection_write_option($db, $before['option'], (string) $timestamp);
            $after = public_selection_snapshot($db, true);
            public_selection_require(public_selection_is_applied($after, $facts)
                && public_selection_value($after, 18, '_wp_attachment_metadata') === serialize(public_selection_corrected($meta, $facts))
                && public_selection_unowned($before) === public_selection_unowned($after), 'apply_readback');
            public_selection_require($effects['files']($after) === $facts, 'image_bytes_changed_during_operation');
            $effects['finishBackup']($backupID, $after, $timestamp);
        } else {
            public_selection_require(is_array($restore) && isset($restore['before'], $restore['after']), 'restore_receipt_required');
            $original = public_selection_owned($restore['before']);
            $expected = public_selection_owned($restore['after']);
            $current = public_selection_owned($before);
            if ($current === $original) {
                public_selection_require($db->query('ROLLBACK') !== false, 'transaction_rollback');
                return array('status' => 'already-restored');
            }
            public_selection_require($current === $expected, 'restore_foreign_edit');
            $effects['authority']();
            public_selection_restore_rows($db, $current, $original);
            $after = public_selection_snapshot($db, true);
            public_selection_require(public_selection_owned($after) === $original
                && public_selection_unowned($before) === public_selection_unowned($after), 'restore_readback');
            public_selection_require($effects['files']($after) === $facts, 'image_bytes_changed_during_operation');
        }
        $effects['authority']();
        public_selection_require($db->query('COMMIT') !== false && $db->last_error === '', 'commit_uncertain_keep_backup');
        $committed = true;
        $effects['invalidate']();
        $effects['sharedInvalidate']();
        $final = public_selection_snapshot($db, false);
        public_selection_require(public_selection_owned($final) === public_selection_owned($after), 'committed_readback_keep_backup');
        return array('status' => $mode === 'apply' ? 'applied' : 'restored', 'backupID' => $backupID,
            'selection' => PublicSelectionPolicy::SELECTION, 'originalImageBytesUnchanged' => true);
    } catch (Throwable $error) {
        $failure = $error instanceof AppPrivacyFailure ? $error : new AppPrivacyFailure('unexpected_keep_backup');
        $failure->backupID = $backupID;
        if (!$committed) {
            try {
                public_selection_require($db->query('ROLLBACK') !== false && $db->last_error === '', 'rollback_uncertain_keep_backup');
                if ($before !== null) {
                    public_selection_require(public_selection_owned(public_selection_snapshot($db, false)) === public_selection_owned($before),
                        'transaction_outcome_uncertain_keep_backup');
                }
            } catch (Throwable $rollbackError) {
                $failure = new AppPrivacyFailure('transaction_outcome_uncertain_keep_backup');
                $failure->backupID = $backupID;
                // May have committed despite a lost reply; do not leave old
                // shared data behind, and do not publish local cache entries.
                try { $effects['sharedInvalidate'](); }
                catch (Throwable $cacheError) { /* Preserve the uncertain outcome. */ }
            }
        }
        try { $effects['invalidate'](); }
        catch (Throwable $cacheError) {
            $failure = new AppPrivacyFailure('cache_invalidation_failed_keep_backup');
            $failure->backupID = $backupID;
        }
        throw $failure;
    }
}

function public_selection_main(array $args): array {
    [$mode, $value] = public_selection_arguments($args);
    // Reuse the reviewed root/site/authority/cron/mail/network guards. The helper
    // library is never asked to read its privacy payload or update a page.
    $siteLock = app_privacy_bootstrap();
    $publicationLock = null;
    $sharedCache = null;
    try {
        app_privacy_safe_path(__FILE__, false);
        global $wpdb;
        public_selection_pin_database();
        $sharedCache = $GLOBALS['wp_object_cache'] ?? null;
        public_selection_require(is_object($sharedCache) && method_exists($sharedCache, 'delete'), 'shared_cache_shape');
        $persistentCache = wp_using_ext_object_cache();
        public_selection_shared_ready($sharedCache, $persistentCache);
        $localCache = new PublicSelectionMemoryCache((int) $wpdb->blogid);
        $GLOBALS['wp_object_cache'] = $localCache;
        public_selection_require(Shuzijun_App_Content_API::OPTION_UPDATED === PublicSelectionPolicy::OPTION
            && method_exists('Shuzijun_App_Content_API', 'get_public_experience'), 'public_release_required');
        public_selection_database_guard($wpdb);
        $publicationLock = public_selection_method('acquire_editorial_publication_lock');
        public_selection_require(is_string($publicationLock) && !is_wp_error($publicationLock), 'publication_lock_busy');
        $restore = $mode === 'rollback' ? public_selection_load_backup($value) : null;
        $effects = array('files' => 'public_selection_files', 'policy' => 'public_selection_policy_images',
            'authority' => 'app_privacy_authority', 'backup' => 'public_selection_backup',
            'finishBackup' => 'public_selection_finish_backup', 'invalidate' => 'public_selection_invalidate',
            'sharedInvalidate' => static fn() => public_selection_invalidate_shared($sharedCache, $localCache, $persistentCache),
            'metadataHash' => static fn(string $raw): string => hash('sha256', $raw));
        $result = public_selection_execute($wpdb, $mode, $value, $restore, $effects);
        if ($mode === 'rollback') { $result['backupID'] = $value; }
        return $result;
    } finally {
        if (is_string($publicationLock)) { public_selection_method('release_named_fan_lock', $publicationLock); }
        if (is_object($sharedCache)) { $GLOBALS['wp_object_cache'] = $sharedCache; }
        flock($siteLock, LOCK_UN); fclose($siteLock);
    }
}

if (!defined('YISHU_PUBLIC_SELECTION_LIBRARY_ONLY')) {
    ini_set('display_errors', '0'); ini_set('log_errors', '0');
    set_error_handler('app_privacy_warning');
    ob_start(static fn(string $unused): string => '');
    $finished = false;
    register_shutdown_function(static function () use (&$finished): void {
        if (!$finished) {
            fwrite(STDERR, "{\"status\":\"failed\",\"code\":\"fatal_or_bootstrap_exit_keep_receipts\"}\n");
            exit(1);
        }
    });
    try {
        $result = public_selection_main(array_slice($argv ?? array(), 1));
        $unexpected = ob_get_clean();
        public_selection_require($unexpected === '', 'unexpected_output_keep_receipts');
        $finished = true;
        echo public_selection_json($result) . "\n";
    } catch (Throwable $error) {
        if (ob_get_level()) { ob_end_clean(); }
        $finished = true;
        fwrite(STDERR, public_selection_json(array('status' => 'failed',
            'code' => $error instanceof AppPrivacyFailure ? $error->getMessage() : 'unexpected_keep_receipts',
            'backupID' => $error instanceof AppPrivacyFailure ? $error->backupID : null)) . "\n");
        exit(1);
    }
}
