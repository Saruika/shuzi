<?php
declare(strict_types=1);

// Explicit integration test only. Use a fresh, checksum-verified WordPress 7.1
// download in /tmp, never a live wp-config, plugins, users, or database. Run in a
// network-disabled sandbox. The dormant trait is tested without its API entry.
if (PHP_SAPI !== 'cli' || $argc !== 2 || !function_exists('posix_geteuid')
    || posix_geteuid() !== 0 || !extension_loaded('pdo_mysql')) {
    throw new RuntimeException('Requires isolated CLI, local socket authentication, and one fixture core path');
}
$network = @readlink('/proc/self/ns/net');
$host_network = @readlink('/proc/1/ns/net');
if (!is_string($network) || !is_string($host_network) || $network === $host_network) {
    throw new RuntimeException('Refusing to run in the host network namespace');
}
$core = realpath($argv[1]);
if (!is_string($core)
    || preg_match('#^/tmp/yishu-wordpress-schema\.[A-Za-z0-9]{6}/wordpress$#D', $core) !== 1
    || is_link($argv[1]) || fileowner(dirname($core)) !== 0
    || (fileperms(dirname($core)) & 0077) !== 0
    || file_exists($core . '/wp-config.php')
    || file_exists(dirname($core) . '/wp-config.php')) {
    throw new RuntimeException('Refusing a non-isolated or configured WordPress directory');
}
foreach (array('wp-settings.php', 'wp-includes/version.php', 'wp-admin/includes/upgrade.php') as $file) {
    $path = $core . '/' . $file;
    if (!is_file($path) || is_link($path) || fileowner($path) !== 0
        || (fileperms($path) & 0022) !== 0) {
        throw new RuntimeException('Untrusted fixture core metadata');
    }
}

$socket = '/var/run/mysqld/mysqld.sock';
$connection = new PDO('mysql:unix_socket=' . $socket, 'root', '', array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
$database = 'yishu_wp_schema_test_' . bin2hex(random_bytes(10));
$created = false;
$checks = 0;
function check_wordpress_schema(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException('WordPress schema assertion failed: ' . $label); }
    ++$GLOBALS['checks'];
}

try {
    // No IF NOT EXISTS: an existing database can never become our test target.
    $connection->exec('CREATE DATABASE `' . $database . '` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    $created = true;
    define('ABSPATH', $core . '/');
    define('DB_NAME', $database);
    define('DB_USER', 'root');
    define('DB_PASSWORD', ''); // Local root Unix-socket authentication, not a secret.
    define('DB_HOST', 'localhost:' . $socket);
    define('DB_CHARSET', 'utf8mb4');
    define('DB_COLLATE', 'utf8mb4_unicode_ci');
    define('WP_HOME', 'https://example.invalid');
    define('WP_SITEURL', 'https://example.invalid');
    define('WP_INSTALLING', true);
    define('DISABLE_WP_CRON', true);
    define('AUTOMATIC_UPDATER_DISABLED', true);
    define('DISALLOW_FILE_MODS', true);
    define('WP_HTTP_BLOCK_EXTERNAL', true);
    define('WP_DEBUG', false);
    define('WP_DEBUG_LOG', false);
    define('WP_DISABLE_FATAL_ERROR_HANDLER', true);
    define('WP_CACHE', false);
    define('WP_CONTENT_DIR', dirname($core) . '/empty-content');
    define('WP_PLUGIN_DIR', WP_CONTENT_DIR . '/plugins');
    define('WPMU_PLUGIN_DIR', WP_CONTENT_DIR . '/mu-plugins');
    define('WP_CACHE_KEY_SALT', $database);
    foreach (array('AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
        'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT') as $salt) {
        define($salt, bin2hex(random_bytes(32)));
    }
    $table_prefix = 'fixture_';
    $_SERVER['HTTP_HOST'] = 'example.invalid';
    $_SERVER['SERVER_NAME'] = 'example.invalid';
    $_SERVER['REQUEST_METHOD'] = 'GET';
    $_SERVER['REQUEST_URI'] = '/';
    $_SERVER['SERVER_PROTOCOL'] = 'HTTP/1.1';
    $_SERVER['SERVER_PORT'] = '443';
    $_SERVER['HTTPS'] = 'on';
    require ABSPATH . 'wp-settings.php';
    require ABSPATH . 'wp-admin/includes/upgrade.php';
    check_wordpress_schema($wp_version === '7.1', 'same reviewed WordPress release');
    check_wordpress_schema($wpdb->get_var('SELECT DATABASE()') === $database, 'only the fresh test database');
    check_wordpress_schema($wpdb instanceof wpdb, 'real WordPress database implementation');
    $wpdb->suppress_errors(true);
    // Core installation notifications must not reach any transport. The outer
    // PrivateNetwork sandbox independently blocks outbound network connections.
    add_filter('pre_wp_mail', static function () { return false; });
    add_filter('pre_http_request', static function () { return new WP_Error('fixture_network_disabled'); });
    $installation = wp_install('Synthetic schema fixture', 'fixture_admin',
        'fixture@example.invalid', false, '', bin2hex(random_bytes(24)), 'en_US');
    check_wordpress_schema(is_array($installation) && !empty($installation['user_id']), 'fresh WordPress core tables');
    unset($installation);
    require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php';
    require dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-collaboration-private-payload.php';

    final class CollaborationWordPressSchemaHarness {
        use Shuzijun_App_Collaboration;
        public const COLLABORATION_SCHEMA_OPTION = 'fixture_collaboration_schema_version';
        public const COLLABORATION_SCHEMA_VERSION = 2;
        public static bool $fixture_enabled = true;
        public static function collaboration_phase1_enabled(): bool { return self::$fixture_enabled; }
        public static function account_authority_enabled(): bool { return true; }
        // Read-only inbox tests use the isolated class, never a production
        // feature constant or an actual mail transport.
        private static function collaboration_mail_transport_ready(): bool { return true; }
        private static function acquire_named_fan_lock($kind, $name) {
            global $wpdb;
            $lock = 'fixture-schema-' . substr(hash('sha256', DB_NAME), 0, 48);
            return (int) $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 2)', $lock)) === 1
                ? $lock : new WP_Error('fixture_lock_unavailable');
        }
        private static function release_named_fan_lock($lock): void {
            global $wpdb;
            $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock));
        }
        public static function ready(): bool { return self::collaboration_storage_ready(); }
    }

    $ddl = array();
    add_filter('query', static function ($query) use (&$ddl) {
        if (preg_match('/^(?:CREATE|ALTER) TABLE fixture_yishu_collaboration_/', $query)) { $ddl[] = $query; }
        return $query;
    });
    $run = static fn(): bool => CollaborationWordPressSchemaHarness::ensure_collaboration_storage();
    $ready = static fn(): bool => CollaborationWordPressSchemaHarness::ready();
    $reset_version = static function (): void {
        delete_option(CollaborationWordPressSchemaHarness::COLLABORATION_SCHEMA_OPTION);
    };
    check_wordpress_schema($run(), 'real dbDelta fresh install');
    check_wordpress_schema($ready(), 'full schema readiness after install');
    check_wordpress_schema(count($ddl) === 3, 'exactly three collaboration table creations');
    $ddl = array();
    $reset_version();
    check_wordpress_schema($run() && $ready(), 'real dbDelta on existing compatible tables');
    check_wordpress_schema(count($ddl) === 0, 'repeat upgrade performs no DDL');

    foreach (array(
        'ALTER TABLE fixture_yishu_collaboration_requests MODIFY private_payload tinytext NOT NULL',
        'ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX due_jobs',
        'ALTER TABLE fixture_yishu_collaboration_audit DROP COLUMN metadata_json',
    ) as $mutation) {
        check_wordpress_schema($wpdb->query($mutation) !== false, 'synthetic incomplete schema setup');
        check_wordpress_schema(!$ready(), 'incomplete schema cannot be ready');
        $reset_version();
        check_wordpress_schema($run() && $ready(), 'real dbDelta repairs compatible schema drift');
    }

    check_wordpress_schema($wpdb->query('ALTER TABLE fixture_yishu_collaboration_audit DROP COLUMN metadata_json') !== false,
        'set up a synthetic repair failure');
    $reset_version();
    $rejected_queries = 0;
    $reject_fixture_alter = static function ($query) use (&$rejected_queries) {
        if (str_starts_with($query, 'ALTER TABLE fixture_yishu_collaboration_audit')) {
            ++$rejected_queries;
            return 'SYNTHETIC_FIXTURE_INVALID_SQL';
        }
        return $query;
    };
    add_filter('query', $reject_fixture_alter, 99);
    try {
        check_wordpress_schema(!$run() && !$ready(), 'real SQL failure cannot be treated as successful dbDelta');
        check_wordpress_schema($rejected_queries > 0, 'the failure reached the actual database query');
        check_wordpress_schema(get_option(CollaborationWordPressSchemaHarness::COLLABORATION_SCHEMA_OPTION, null) === null,
            'failed DDL never stamps ready version');
    } finally {
        remove_filter('query', $reject_fixture_alter, 99);
    }
    check_wordpress_schema($run() && $ready(), 'recover after transient synthetic DDL failure');

    foreach (array(
        array('ALTER TABLE fixture_yishu_collaboration_requests ENGINE=MyISAM',
            'ALTER TABLE fixture_yishu_collaboration_requests ENGINE=InnoDB'),
        array('ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX dedupe_key, ADD UNIQUE KEY dedupe_key (dedupe_key(16))',
            'ALTER TABLE fixture_yishu_collaboration_outbox DROP INDEX dedupe_key, ADD UNIQUE KEY dedupe_key (dedupe_key)'),
    ) as [$mutation, $repair]) {
        check_wordpress_schema($wpdb->query($mutation) !== false, 'synthetic incompatible schema setup');
        $reset_version();
        check_wordpress_schema(!$run() && !$ready(), 'dbDelta cannot bless incompatible engine or prefix index');
        check_wordpress_schema(get_option(CollaborationWordPressSchemaHarness::COLLABORATION_SCHEMA_OPTION, null) === null,
            'incompatible migration does not stamp ready version');
        check_wordpress_schema($wpdb->query($repair) !== false, 'repair only the synthetic table');
        check_wordpress_schema($run() && $ready(), 'explicit test repair is revalidated');
    }

    foreach (array('', 'received') as $status) {
        $request = new WP_REST_Request('GET');
        $request->set_param('status', $status);
        $result = CollaborationWordPressSchemaHarness::list_collaboration_requests($request);
        check_wordpress_schema($result instanceof WP_REST_Response && $result->get_status() === 200,
            'a genuinely empty inbox remains a successful response');
        check_wordpress_schema($result->get_data()['requests'] === array() && $result->get_data()['total'] === 0,
            'genuine empty inbox has exactly zero items and count');
        foreach (array('rows', 'count', 'null_count') as $fault) {
            $count_queries = 0;
            $injected_queries = 0;
            $inject = static function ($query) use ($fault, &$count_queries, &$injected_queries) {
                $is_rows = str_starts_with($query, 'SELECT r.*, o.status AS mail_status');
                $is_count = str_starts_with($query, 'SELECT COUNT(*) FROM fixture_yishu_collaboration_requests');
                if ($is_count) { ++$count_queries; }
                if (($fault === 'rows' && $is_rows) || ($fault !== 'rows' && $is_count)) {
                    ++$injected_queries;
                    return $fault === 'null_count' ? 'SELECT NULL' : 'SYNTHETIC_FIXTURE_INVALID_SQL';
                }
                return $query;
            };
            add_filter('query', $inject, 99);
            try {
                $result = CollaborationWordPressSchemaHarness::list_collaboration_requests($request);
                check_wordpress_schema(is_wp_error($result) && $result->get_error_code() === 'collaboration_storage_unavailable',
                    'failed or invalid query must not become an empty successful inbox: ' . $fault);
                check_wordpress_schema($injected_queries === 1, 'exactly one real query received the synthetic fault');
                check_wordpress_schema($fault !== 'rows' || $count_queries === 0,
                    'do not issue another query that can erase the list error');
            } finally {
                remove_filter('query', $inject, 99);
            }
            $result = CollaborationWordPressSchemaHarness::list_collaboration_requests($request);
            check_wordpress_schema($result instanceof WP_REST_Response && $result->get_status() === 200,
                'inbox can retry normally after the synthetic failure');
        }
    }
    require __DIR__ . '/collaboration-wordpress-deletion-regression.php';
    require __DIR__ . '/collaboration-wordpress-payload-integration.php';
    check_wordpress_schema($wpdb->get_var('SELECT DATABASE()') === $database, 'test database remained isolated');
    check_wordpress_schema(!class_exists('Shuzijun_App_Content_API', false), 'production API entry never loaded');
    check_wordpress_schema(!wp_next_scheduled('yishu_sweep_collaboration_outbox')
        && !wp_next_scheduled('yishu_process_collaboration_outbox'), 'no collaboration worker scheduled');
    fwrite(STDOUT, 'collaboration-wordpress-schema: ' . $checks . ' assertions passed; WordPress 7.1; MySQL '
        . $connection->query('SELECT VERSION()')->fetchColumn() . "\n");
} finally {
    if (isset($wpdb) && $wpdb instanceof wpdb) { $wpdb->close(); }
    if ($created) {
        $connection->exec('DROP DATABASE `' . $database . '`');
        fwrite(STDOUT, "collaboration-wordpress-schema: exact temporary database removed; no production data used\n");
    }
}
