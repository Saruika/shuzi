<?php
declare(strict_types=1);

// Minimal WordPress-compatible harness for the plugin's pure validation layer.
// It intentionally does not connect to a database, network service or live site.
define('ABSPATH', __DIR__ . '/');
define('WP_ENVIRONMENT_TYPE', 'local');
define('YISHU_APPLE_TEST_MODE', true);
// Simulate a mistakenly enabled external wp-config flag. Build 41's internal
// release fuse must keep every collaboration path dormant anyway.
define('YISHU_ENABLE_COLLABORATION_PHASE1', true);
$authority_test_path = tempnam(sys_get_temp_dir(), 'yishu-authority-role-');
if (!is_string($authority_test_path)) { throw new RuntimeException('无法创建角色标记测试文件'); }
file_put_contents($authority_test_path, "standby\n");
chmod($authority_test_path, 0644);
define('YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH', $authority_test_path);
define('HOUR_IN_SECONDS', 3600);
define('DAY_IN_SECONDS', 86400);
define('MINUTE_IN_SECONDS', 60);
define('ARRAY_A', 'ARRAY_A');

final class WP_Error {
    private string $code;
    private string $message;
    private array $data;

    public function __construct(string $code, string $message = '', array $data = array()) {
        $this->code = $code;
        $this->message = $message;
        $this->data = $data;
    }

    public function get_error_code(): string { return $this->code; }
    public function get_error_message(): string { return $this->message; }
    public function get_error_data(): array { return $this->data; }
}

class WP_User {}
class WP_Post {}
class WP_REST_Request {
    private array $parameters;
    private array $headers;
    private string $route;
    private string $method;

    public function __construct(
        array $parameters = array(),
        array $headers = array(),
        string $route = '',
        string $method = 'GET'
    ) {
        $this->parameters = $parameters;
        $this->headers = array_change_key_case($headers, CASE_LOWER);
        $this->route = $route;
        $this->method = strtoupper($method);
    }

    public function get_param(string $name) { return $this->parameters[$name] ?? null; }
    public function get_header(string $name): string {
        return (string) ($this->headers[strtolower($name)] ?? '');
    }
    public function get_route(): string { return $this->route; }
    public function get_method(): string { return $this->method; }
}
class WP_REST_Response {
    public $data;
    public int $status;
    public array $headers = array();

    public function __construct($data = null, int $status = 200) {
        $this->data = $data;
        $this->status = $status;
    }

    public function header(string $name, string $value): void { $this->headers[$name] = $value; }
}
final class WP_REST_Server {
    public const READABLE = 'GET';
    public const CREATABLE = 'POST';
    public const EDITABLE = 'POST,PUT,PATCH';
}

$GLOBALS['yishu_test_options'] = array();
$GLOBALS['yishu_test_filters'] = array();
$GLOBALS['yishu_test_scheduled'] = array();
$GLOBALS['yishu_test_registered_actions'] = array();
$GLOBALS['yishu_test_registered_filters'] = array();
$GLOBALS['yishu_test_registered_routes'] = array();
$GLOBALS['yishu_test_fired_actions'] = array();
$GLOBALS['yishu_test_lock_result'] = '1';
$GLOBALS['yishu_test_lock_results'] = array();

final class Yishu_Test_WPDB {
    public string $options = 'wp_options';
    public string $users = 'wp_users';
    public string $usermeta = 'wp_usermeta';
    public string $prefix = 'wp_';
    public string $last_error = '';
    public array $existing_tables = array();
    public array $table_probe_failures = array();
    public array $collaboration_request_ids = array();
    public array $executed_queries = array();
    public array $user_display_names = array();
    public array $user_meta_rows = array();

    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }

    public function get_var($prepared) {
        if (!is_array($prepared)) { return null; }
        $query = (string) ($prepared['query'] ?? '');
        $arguments = (array) ($prepared['arguments'] ?? array());
        $this->last_error = '';
        if (strpos($query, 'SELECT GET_LOCK') !== false) {
            $lock_name = (string) ($arguments[0] ?? '');
            foreach ($GLOBALS['yishu_test_lock_results'] as $prefix => $result) {
                if (strpos($lock_name, (string) $prefix) === 0) { return (string) $result; }
            }
            return (string) $GLOBALS['yishu_test_lock_result'];
        }
        if (strpos($query, 'SELECT RELEASE_LOCK') !== false) { return '1'; }
        if (strpos($query, 'SELECT option_value') !== false) {
            $name = (string) ($arguments[0] ?? '');
            return array_key_exists($name, $GLOBALS['yishu_test_options'])
                ? maybe_serialize($GLOBALS['yishu_test_options'][$name])
                : null;
        }
        if (strpos($query, 'SELECT display_name FROM wp_users') !== false) {
            $user_id = (int) ($arguments[0] ?? 0);
            return array_key_exists($user_id, $this->user_display_names)
                ? (string) $this->user_display_names[$user_id]
                : null;
        }
        if (strpos($query, 'SELECT meta_value FROM wp_usermeta') !== false) {
            $user_id = (int) ($arguments[0] ?? 0);
            $meta_key = (string) ($arguments[1] ?? '');
            return array_key_exists($meta_key, $this->user_meta_rows[$user_id] ?? array())
                ? maybe_serialize($this->user_meta_rows[$user_id][$meta_key])
                : null;
        }
        if (strpos($query, 'SHOW TABLES LIKE') !== false) {
            $table = (string) ($arguments[0] ?? '');
            if (in_array($table, $this->table_probe_failures, true)) {
                $this->last_error = 'simulated_table_probe_failure';
                return null;
            }
            return in_array($table, $this->existing_tables, true) ? $table : null;
        }
        return null;
    }

    public function get_col($prepared): array {
        $this->last_error = '';
        if (!is_array($prepared)) { return array(); }
        $query = (string) ($prepared['query'] ?? '');
        $arguments = (array) ($prepared['arguments'] ?? array());
        if (strpos($query, 'SELECT id FROM wp_yishu_collaboration_requests') !== false) {
            return array_values($this->collaboration_request_ids[(int) ($arguments[0] ?? 0)] ?? array());
        }
        return array();
    }

    public function query($prepared) {
        $query = is_array($prepared)
            ? (string) ($prepared['query'] ?? '')
            : (string) $prepared;
        $arguments = is_array($prepared)
            ? (array) ($prepared['arguments'] ?? array())
            : array();
        $this->last_error = '';
        $this->executed_queries[] = $query;
        if (strpos($query, 'DELETE FROM wp_yishu_collaboration_requests') !== false) {
            return count($this->collaboration_request_ids[(int) ($arguments[0] ?? 0)] ?? array());
        }
        return 1;
    }

    public function esc_like(string $value): string { return $value; }
}

$GLOBALS['wpdb'] = new Yishu_Test_WPDB();

function add_action(...$args): void {
    $GLOBALS['yishu_test_registered_actions'][] = $args;
}
function add_filter(...$args): void {
    $GLOBALS['yishu_test_registered_filters'][] = $args;
}
function do_action(string $name, ...$args): void {
    $GLOBALS['yishu_test_fired_actions'][] = array($name, $args);
}
function register_rest_route(string $namespace, string $route, array $arguments): bool {
    $GLOBALS['yishu_test_registered_routes'][] = array(
        'namespace' => $namespace,
        'route' => $route,
        'arguments' => $arguments,
    );
    return true;
}
function apply_filters(string $hook, $value, ...$args) {
    $callback = $GLOBALS['yishu_test_filters'][$hook] ?? null;
    return is_callable($callback) ? $callback($value, ...$args) : $value;
}
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function get_option(string $name, $default = false) {
    return array_key_exists($name, $GLOBALS['yishu_test_options'])
        ? $GLOBALS['yishu_test_options'][$name]
        : $default;
}
function add_option(string $name, $value, string $deprecated = '', bool $autoload = false): bool {
    if (array_key_exists($name, $GLOBALS['yishu_test_options'])) { return false; }
    $GLOBALS['yishu_test_options'][$name] = $value;
    return true;
}
function update_option(string $name, $value, bool $autoload = false): bool {
    $changed = !array_key_exists($name, $GLOBALS['yishu_test_options'])
        || $GLOBALS['yishu_test_options'][$name] !== $value;
    $GLOBALS['yishu_test_options'][$name] = $value;
    return $changed;
}
function delete_option(string $name): bool {
    if (!array_key_exists($name, $GLOBALS['yishu_test_options'])) { return false; }
    unset($GLOBALS['yishu_test_options'][$name]);
    return true;
}
function maybe_serialize($value): string { return serialize($value); }
function maybe_unserialize($value) {
    if (!is_string($value)) { return $value; }
    $decoded = @unserialize($value);
    return $decoded === false && $value !== serialize(false) ? $value : $decoded;
}
function wp_json_encode($value, int $flags = 0, int $depth = 512) {
    return json_encode($value, $flags, $depth);
}
function wp_cache_delete(...$args): bool { return true; }
function rest_ensure_response($value): WP_REST_Response {
    return $value instanceof WP_REST_Response ? $value : new WP_REST_Response($value);
}
function wp_schedule_single_event($timestamp, string $hook, array $args = array(), bool $wp_error = false) {
    if (!empty($GLOBALS['yishu_test_schedule_failure'])) { return false; }
    $GLOBALS['yishu_test_scheduled'][] = array(
        'timestamp' => (int) $timestamp,
        'hook' => $hook,
        'args' => $args,
    );
    return true;
}
function wp_next_scheduled(string $hook, array $args = array()) {
    foreach ($GLOBALS['yishu_test_scheduled'] as $event) {
        if (($event['hook'] ?? '') === $hook && ($event['args'] ?? null) === $args) {
            return (int) $event['timestamp'];
        }
    }
    return false;
}
function wp_salt(string $scheme = 'auth'): string {
    return hash('sha256', 'contract-test-only|' . $scheme);
}
function home_url(string $path = '/'): string {
    return 'https://www.shuzijun.com.cn/' . ltrim($path, '/');
}
function wp_parse_url(string $url, int $component = -1) {
    return $component === -1 ? parse_url($url) : parse_url($url, $component);
}
function esc_url_raw($value, array $protocols = array()): string {
    if (!is_scalar($value)) { return ''; }
    $url = filter_var(trim((string) $value), FILTER_SANITIZE_URL);
    if (!is_string($url) || filter_var($url, FILTER_VALIDATE_URL) === false) { return ''; }
    $scheme = strtolower((string) parse_url($url, PHP_URL_SCHEME));
    return $protocols && !in_array($scheme, $protocols, true) ? '' : $url;
}
function sanitize_text_field($value): string {
    if (!is_scalar($value)) { return ''; }
    $text = strip_tags((string) $value);
    $text = preg_replace('/[\x00-\x1F\x7F]/u', '', $text);
    return trim(is_string($text) ? $text : '');
}
function sanitize_key($value): string {
    $value = strtolower((string) $value);
    return (string) preg_replace('/[^a-z0-9_\-]/', '', $value);
}
function sanitize_email($value): string {
    if (!is_scalar($value)) { return ''; }
    $email = filter_var(trim((string) $value), FILTER_SANITIZE_EMAIL);
    return is_string($email) ? $email : '';
}
function is_email($value) {
    return is_string($value) && filter_var($value, FILTER_VALIDATE_EMAIL) !== false
        ? $value
        : false;
}
function rest_sanitize_boolean($value): bool {
    if (is_string($value)) {
        return !in_array(strtolower($value), array('false', '0', ''), true);
    }
    return (bool) $value;
}

require dirname(__DIR__) . '/shuzijun-app-content.php';

$plugin_entry_source = file_get_contents(dirname(__DIR__) . '/shuzijun-app-content.php');
$plugin_module_paths = array(
    '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php',
    '/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php',
    '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php',
    '/vendor/shuzijun/app-content/trait-shuzijun-app-push-notifications.php',
    '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-identity.php',
    '/vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php',
);
$plugin_module_sources = array_map(
    static fn (string $path) => file_get_contents(dirname(__DIR__) . $path),
    $plugin_module_paths
);
$plugin_implementation_source = $plugin_module_sources[0];
$plugin_source = (string) $plugin_entry_source . "\n" . implode(
    "\n",
    array_map('strval', $plugin_module_sources)
);
$fan_smoke_source = file_get_contents(__DIR__ . '/fan-api-smoke.sh');
$backup_proxy_source = file_get_contents(
    dirname(__DIR__) . '/nginx/shuzijun-account-api-backup-proxy.conf'
);
$composer_lock = json_decode(
    (string) file_get_contents(dirname(__DIR__) . '/composer.lock'),
    true
);
$privacy_policy_source = file_get_contents(dirname(__DIR__) . '/app-privacy-policy.html');

function invoke_plugin_method(string $name, array $arguments = array()) {
    $method = new ReflectionMethod(Shuzijun_App_Content_API::class, $name);
    $method->setAccessible(true);
    return $method->invokeArgs(null, $arguments);
}

function plugin_method_source(string $source, string $name): string {
    $public_start = strpos($source, 'public static function ' . $name);
    $private_start = strpos($source, 'private static function ' . $name);
    if ($public_start === false && $private_start === false) { return ''; }
    $start = $public_start === false
        ? $private_start
        : ($private_start === false ? $public_start : min($public_start, $private_start));
    $next_public = strpos($source, "\n    public static function ", $start + 1);
    $next_private = strpos($source, "\n    private static function ", $start + 1);
    $ends = array_values(array_filter(
        array($next_public, $next_private),
        static fn ($value): bool => $value !== false
    ));
    $end = $ends ? min($ends) : strlen($source);
    return substr($source, $start, $end - $start);
}

function expect_true(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "plugin-contract-test: {$message}\n");
        exit(1);
    }
}

expect_true(
    is_string($plugin_entry_source)
        && is_string($plugin_implementation_source)
        && count(array_filter($plugin_module_sources, 'is_string')) === 6
        && strpos(
            $plugin_entry_source,
            "require_once __DIR__ . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php';"
        ) !== false
        && substr_count($plugin_entry_source, 'Shuzijun_App_Content_API::init();') === 1
        && strpos($plugin_implementation_source, 'final class Shuzijun_App_Content_API') !== false
        && substr_count($plugin_implementation_source, 'require_once __DIR__ . \'/trait-') === 5
        && substr_count($plugin_implementation_source, '    use Shuzijun_App_') === 5
        && strpos($plugin_implementation_source, 'Shuzijun_App_Content_API::init();') === false,
    '插件入口必须只装配一次模块化 API 实现并只启动一次'
);

function expect_same($expected, $actual, string $message): void {
    expect_true($expected === $actual, $message);
}

function expect_error_code(string $code, $actual, string $message): void {
    expect_true($actual instanceof WP_Error, $message . '（未返回 WP_Error）');
    expect_same($code, $actual->get_error_code(), $message . '（错误代码不符）');
}

// Binding generations are decimal counters shared by Swift, PHP and MySQL.
// The pure transition rule makes delayed lower generations harmless and treats
// an equal generation with the opposite action as a protocol conflict.
expect_same(
    1,
    invoke_plugin_method('normalize_push_binding_generation', array('1')),
    '最小正绑定世代必须可被规范化'
);
expect_same(
    PHP_INT_MAX,
    invoke_plugin_method('normalize_push_binding_generation', array((string) PHP_INT_MAX)),
    '绑定世代上界必须精确等于 PHP 整数上界'
);
foreach (array(null, 0, '0', '01', '-1', '1.0', array(), (string) PHP_INT_MAX . '0') as $invalid_generation) {
    expect_same(
        0,
        invoke_plugin_method('normalize_push_binding_generation', array($invalid_generation)),
        '非规范或超界绑定世代必须失败关闭'
    );
}

foreach (array(
    array('stale', 7, 'bound', 6, 'bound'),
    array('stale', 7, 'bound', 6, 'unbound'),
    array('idempotent', 7, 'bound', 7, 'bound'),
    array('idempotent', 7, 'unbound', 7, 'unbound'),
    array('conflict', 7, 'bound', 7, 'unbound'),
    array('conflict', 7, 'unbound', 7, 'bound'),
    array('apply', 7, 'bound', 8, 'unbound'),
    array('apply', 7, 'unbound', 8, 'bound'),
    array('invalid', -1, 'bound', 8, 'bound'),
    array('invalid', 7, 'unknown', 8, 'bound'),
    array('invalid', 7, 'bound', 0, 'bound'),
    array('invalid', 7, 'bound', 8, 'unknown'),
) as $transition_case) {
    expect_same(
        $transition_case[0],
        invoke_plugin_method('push_binding_transition', array_slice($transition_case, 1)),
        '持久绑定世代转移必须严格单调且失败关闭'
    );
}

// Pre-Build-45 normal sessions can establish push ownership exactly once, but
// only after their raw wp_options row passes the strict scalar-only decoder.
$legacy_now = time();
$legacy_install_hash = str_repeat('a', 64);
$legacy_token_hash = str_repeat('b', 64);
$legacy_session = array(
    'userID' => 17,
    'installHash' => $legacy_install_hash,
    'installCode' => 'IN-ABC-234',
    'sessionID' => str_repeat('c', 32),
    'createdAt' => $legacy_now - 30,
    'expires' => $legacy_now + 600,
    'scope' => 'normal',
    'credentialEpoch' => 3,
    'authMethod' => 'apple',
    'recentAuthUntil' => $legacy_now + 300,
);
$legacy_row = array(
    'option_id' => '42',
    'option_name' => Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $legacy_token_hash,
    'option_value' => serialize($legacy_session),
);
$decoded_legacy = invoke_plugin_method(
    'legacy_push_session_option_context',
    array($legacy_row, $legacy_install_hash, $legacy_now)
);
expect_true(
    is_array($decoded_legacy)
        && ($decoded_legacy['optionID'] ?? null) === 42
        && ($decoded_legacy['userID'] ?? null) === 17
        && ($decoded_legacy['tokenHash'] ?? null) === $legacy_token_hash
        && ($decoded_legacy['credentialEpoch'] ?? null) === 3,
    '旧会话迁移只能从规范的原始 option 行恢复权威字段'
);
expect_true(
    is_array(invoke_plugin_method(
        'legacy_push_session_candidate_context',
        array($legacy_row, 41, $legacy_install_hash, $legacy_now)
    ))
        && invoke_plugin_method(
            'legacy_push_session_candidate_context',
            array($legacy_row, 42, $legacy_install_hash, $legacy_now)
        ) === null,
    '仅 option_id 严格更新的同安装会话才能阻断旧所有者'
);

$legacy_nested = $legacy_session;
$legacy_nested['unexpected'] = array('nested');
$legacy_object = $legacy_session;
$legacy_object['unexpected'] = new stdClass();
$legacy_uppercase_hash = $legacy_session;
$legacy_uppercase_hash['installHash'] = strtoupper($legacy_install_hash);
$legacy_expired = $legacy_session;
$legacy_expired['expires'] = $legacy_now - 1;
$legacy_wrong_scope = $legacy_session;
$legacy_wrong_scope['scope'] = 'onboarding';
foreach (array(
    serialize($legacy_nested),
    serialize($legacy_object),
    serialize($legacy_uppercase_hash),
    serialize($legacy_expired),
    serialize($legacy_wrong_scope),
    str_repeat('x', 8193),
) as $unsafe_serialized_session) {
    $unsafe_row = $legacy_row;
    $unsafe_row['option_value'] = $unsafe_serialized_session;
    expect_same(
        null,
        invoke_plugin_method(
            'legacy_push_session_option_context',
            array($unsafe_row, $legacy_install_hash, $legacy_now)
        ),
        '对象、嵌套值、非规范字段、过期或超大旧会话必须失败关闭'
    );
}
$legacy_password_session = $legacy_session;
unset(
    $legacy_password_session['credentialEpoch'],
    $legacy_password_session['authMethod'],
    $legacy_password_session['recentAuthUntil']
);
$legacy_password_row = $legacy_row;
$legacy_password_row['option_value'] = serialize($legacy_password_session);
$decoded_legacy_password = invoke_plugin_method(
    'legacy_push_session_option_context',
    array($legacy_password_row, $legacy_install_hash, $legacy_now)
);
expect_true(
    is_array($decoded_legacy_password)
        && ($decoded_legacy_password['credentialEpoch'] ?? null) === 1
        && ($decoded_legacy_password['authMethod'] ?? null) === 'password'
        && ($decoded_legacy_password['recentAuthUntil'] ?? null) === 0,
    '部署前密码会话只能按既有验证规则映射到 epoch 1'
);
$legacy_unscoped_session = $legacy_password_session;
unset($legacy_unscoped_session['scope']);
$legacy_unscoped_row = $legacy_row;
$legacy_unscoped_row['option_value'] = serialize($legacy_unscoped_session);
$decoded_unscoped_session = invoke_plugin_method(
    'legacy_push_session_option_context',
    array($legacy_unscoped_row, $legacy_install_hash, $legacy_now)
);
expect_true(
    is_array($decoded_unscoped_session)
        && ($decoded_unscoped_session['scope'] ?? null) === 'normal'
        && ($decoded_unscoped_session['credentialEpoch'] ?? null) === 1,
    '引入 scope 前的旧密码会话必须按 normal / epoch 1 初始化推送所有权'
);
foreach (array(null, '', false, 0, array(), 'unknown', 'onboarding', 'password_recovery', 'apple_onboarding') as $invalid_legacy_scope) {
    $invalid_scope_session = $legacy_unscoped_session;
    $invalid_scope_session['scope'] = $invalid_legacy_scope;
    $invalid_scope_row = $legacy_row;
    $invalid_scope_row['option_value'] = serialize($invalid_scope_session);
    expect_same(
        null,
        invoke_plugin_method(
            'legacy_push_session_option_context',
            array($invalid_scope_row, $legacy_install_hash, $legacy_now)
        ),
        '显式无效或非 normal scope 不得借旧会话兼容规则获得推送所有权'
    );
}

// A pre-directory session has no trustworthy creation time or session ID.
// Migration must ask for sign-in, while a database outage remains retriable.
$legacy_migration_original_db = $GLOBALS['wpdb'];
$legacy_migration_db = new class {
    public string $options = 'wp_options';
    public string $users = 'wp_users';
    public string $prefix = 'wp_';
    public string $last_error = '';
    public array $row = array();
    public bool $fail_read = false;
    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }
    public function get_row($prepared, $output) {
        $this->last_error = $this->fail_read ? 'simulated_read_failure' : '';
        return $this->fail_read ? null : $this->row;
    }
    public function get_var($prepared) { return null; }
    public function get_results($prepared, $output): array { return array(); }
    public function esc_like(string $value): string { return $value; }
    public function query($prepared) {
        throw new RuntimeException('缺少迁移依据的旧会话不得写入推送记录');
    }
};
$GLOBALS['wpdb'] = $legacy_migration_db;
foreach (array('createdAt', 'sessionID') as $missing_migration_field) {
    $unmigratable_session = $legacy_unscoped_session;
    unset($unmigratable_session[$missing_migration_field]);
    $legacy_migration_db->row = $legacy_row;
    $legacy_migration_db->row['option_value'] = serialize($unmigratable_session);
    $migration_request_context = $unmigratable_session;
    $migration_request_context['scope'] = 'normal';
    $migration_request_context['tokenHash'] = $legacy_token_hash;
    $migration_error = invoke_plugin_method(
        'initialize_legacy_push_install_state',
        array($migration_request_context, 42, $legacy_install_hash)
    );
    expect_error_code('fan_session_invalid', $migration_error, '缺少创建时间或会话标识必须明确要求重新登录');
    expect_same(401, $migration_error->get_error_data()['status'] ?? null, '旧会话无法迁移应返回可操作的登录错误');
}
$legacy_migration_db->fail_read = true;
$migration_storage_error = invoke_plugin_method(
    'initialize_legacy_push_install_state',
    array($migration_request_context, 42, $legacy_install_hash)
);
expect_error_code('push_storage_unavailable', $migration_storage_error, '真实数据库故障不得误报为需要重新登录');
expect_same(503, $migration_storage_error->get_error_data()['status'] ?? null, '数据库故障应保留可重试状态');
$GLOBALS['wpdb'] = $legacy_migration_original_db;

require __DIR__ . '/push-ownership-regression.php';
require __DIR__ . '/fan-inbox-regression.php';

// The worker must honor the absolute deadline stored with the notification.
// Test mode returns before network I/O but only after payload/deadline checks.
$GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static function (): array {
    return array('outcome' => 'sent', 'code' => '');
};
$push_notification = array(
    'public_id' => '123e4567-e89b-42d3-a456-426614174000',
    'title' => 'Contract',
    'body' => 'Deadline',
    'deliver_before' => time() + 60,
);
expect_same(
    array('outcome' => 'sent', 'code' => ''),
    invoke_plugin_method('send_push_to_apns', array(str_repeat('ab', 32), $push_notification)),
    '未过期的固定投递截止时间必须传递给 APNs 路径'
);
$push_notification['deliver_before'] = time() - 1;
expect_same(
    array('outcome' => 'dead', 'code' => 'expired'),
    invoke_plugin_method('send_push_to_apns', array(str_repeat('ab', 32), $push_notification)),
    '已过期通知不得因工作者延迟而获得新的投递窗口'
);
$push_notification['deliver_before'] = 'invalid';
expect_same(
    array('outcome' => 'dead', 'code' => 'payload_invalid'),
    invoke_plugin_method('send_push_to_apns', array(str_repeat('ab', 32), $push_notification)),
    '非规范投递截止时间必须失败关闭'
);
unset($GLOBALS['yishu_test_filters']['yishu_apns_delivery_result']);

// Device-token decryption has three outcomes: plaintext on success, an empty
// string for an authenticated-record failure under the expected key, and a
// fixed 503 error for temporary/mismatched deployment-key failures. A key
// outage must never be mistaken for proof that the device row is invalid.
if (function_exists('sodium_crypto_secretbox')
    && function_exists('sodium_crypto_secretbox_open')
    && function_exists('sodium_memzero') && function_exists('hash_hkdf')) {
    $push_data_key_a = str_repeat("\x31", 32);
    $push_data_key_b = str_repeat("\x32", 32);
    $GLOBALS['yishu_test_filters']['yishu_push_data_key'] = static function () use (
        $push_data_key_a
    ): string {
        return $push_data_key_a;
    };
    $opaque_device_token = str_repeat('ab', 256);
    $encrypted_device = invoke_plugin_method(
        'encrypt_push_device_token',
        array($opaque_device_token)
    );
    expect_true(
        is_array($encrypted_device)
            && preg_match('/^[a-f0-9]{64}$/D', (string) ($encrypted_device['tokenHash'] ?? '')) === 1
            && is_string($encrypted_device['ciphertext'] ?? null)
            && strlen((string) $encrypted_device['ciphertext']) <= 1024,
        '可变长设备令牌必须以有界密文和 HMAC 索引保存'
    );
    $encrypted_record = json_decode((string) $encrypted_device['ciphertext'], true);
    expect_true(
        is_array($encrypted_record)
            && (int) ($encrypted_record['version'] ?? 0) === 1
            && preg_match(
                '/^[a-f0-9]{64}$/D',
                (string) ($encrypted_record['keyFingerprint'] ?? '')
            ) === 1,
        '新密文必须携带非秘密数据密钥指纹'
    );
    expect_same(
        $opaque_device_token,
        invoke_plugin_method(
            'decrypt_push_device_token',
            array($encrypted_device['ciphertext'], $encrypted_device['tokenHash'])
        ),
        '当前数据密钥必须能解密已保存设备令牌'
    );

    $missing_fingerprint_record = $encrypted_record;
    unset($missing_fingerprint_record['keyFingerprint']);
    expect_same(
        '',
        invoke_plugin_method(
            'decrypt_push_device_token',
            array(
                wp_json_encode($missing_fingerprint_record, JSON_UNESCAPED_SLASHES),
                $encrypted_device['tokenHash'],
            )
        ),
        '未部署的 v1 密文格式必须严格要求密钥指纹'
    );

    $GLOBALS['yishu_test_filters']['yishu_push_data_key'] = static function () use (
        $push_data_key_b
    ): string {
        return $push_data_key_b;
    };
    $wrong_key_result = invoke_plugin_method(
        'decrypt_push_device_token',
        array($encrypted_device['ciphertext'], $encrypted_device['tokenHash'])
    );
    expect_error_code(
        'push_device_crypto_unavailable',
        $wrong_key_result,
        '语法有效但与指纹不符的数据密钥必须视为配置故障'
    );
    expect_same(
        503,
        (int) ($wrong_key_result->get_error_data()['status'] ?? 0),
        '设备数据密钥故障必须返回固定 503'
    );

    $GLOBALS['yishu_test_filters']['yishu_push_data_key'] = static function (): string {
        throw new RuntimeException('simulated key reader outage');
    };
    $reader_outage_result = invoke_plugin_method(
        'decrypt_push_device_token',
        array($encrypted_device['ciphertext'], $encrypted_device['tokenHash'])
    );
    expect_error_code(
        'push_device_crypto_unavailable',
        $reader_outage_result,
        '数据密钥读取异常不得被误判为损坏设备记录'
    );

    $GLOBALS['yishu_test_filters']['yishu_push_data_key'] = static function () use (
        $push_data_key_a
    ): string {
        return $push_data_key_a;
    };
    $damaged_record = $encrypted_record;
    $damaged_ciphertext = (string) $damaged_record['ciphertext'];
    $damaged_ciphertext[0] = $damaged_ciphertext[0] === 'A' ? 'B' : 'A';
    $damaged_record['ciphertext'] = $damaged_ciphertext;
    expect_same(
        '',
        invoke_plugin_method(
            'decrypt_push_device_token',
            array(
                wp_json_encode($damaged_record, JSON_UNESCAPED_SLASHES),
                $encrypted_device['tokenHash'],
            )
        ),
        '密钥可用时 Secretbox 认证失败必须标记设备记录无效'
    );
    unset($GLOBALS['yishu_test_filters']['yishu_push_data_key']);
    sodium_memzero($push_data_key_a);
    sodium_memzero($push_data_key_b);
    sodium_memzero($opaque_device_token);
}

$push_query_count = count($GLOBALS['wpdb']->executed_queries);
$push_schedule_count = count($GLOBALS['yishu_test_scheduled']);
expect_true(
    invoke_plugin_method(
        'defer_push_outbox_without_attempt',
        array(7, str_repeat('a', 32), 'device_crypto_unavailable')
    ) === true,
    '设备密钥故障必须能原子释放 Outbox 租约'
);
$push_defer_query = (string) ($GLOBALS['wpdb']->executed_queries[$push_query_count] ?? '');
expect_true(
    strpos(
        $push_defer_query,
        'attempts = CASE WHEN attempts > 0 THEN attempts - 1 ELSE 0 END'
    ) !== false
        && strpos($push_defer_query, 'last_error_code = %s') !== false
        && strpos($push_defer_query, "status = 'processing'") !== false
        && count($GLOBALS['yishu_test_scheduled']) === $push_schedule_count + 1,
    '暂时工作者故障退避必须不消耗尝试次数、保存错误码并计划下次 sweep'
);
expect_true(
    invoke_plugin_method(
        'defer_push_outbox_without_attempt',
        array(7, str_repeat('g', 32), 'device_crypto_unavailable')
    ) === false,
    '非法租约标识不得更新 Outbox'
);
expect_true(
    invoke_plugin_method(
        'defer_push_outbox_without_attempt',
        array(7, str_repeat('a', 32), '!!!')
    ) === false,
    '非规范退避原因不得更新 Outbox'
);

expect_true(
    defined('YISHU_ENABLE_COLLABORATION_PHASE1')
        && constant('YISHU_ENABLE_COLLABORATION_PHASE1') === true
        && Shuzijun_App_Content_API::COLLABORATION_PHASE1_RELEASE_FUSE === false
        && Shuzijun_App_Content_API::collaboration_phase1_enabled() === false,
    '即使外部显式定义 true，Build 41 内建发布熔断也必须保持 Phase 1 关闭'
);
Shuzijun_App_Content_API::register_routes();
$default_route_names = array_map(
    static fn (array $record): string => (string) ($record['route'] ?? ''),
    $GLOBALS['yishu_test_registered_routes']
);
expect_true(
    !in_array('/collaboration-requests', $default_route_names, true)
        && !in_array('/app-admin/collaboration-requests', $default_route_names, true)
        && !in_array(
            '/app-admin/collaboration-requests/(?P<request_id>[a-f0-9-]{36})',
            $default_route_names,
            true
        ),
    '默认关闭时不得注册粉丝或管理员合作邀约 REST 路由'
);
expect_true(
    in_array('/app-capabilities', $default_route_names, true)
        && strpos(
            $plugin_source,
            "'permission_callback' => array(__CLASS__, 'can_read_app_capabilities')"
        ) !== false,
    '应始终注册只读能力声明，供 App 在合作服务未开放时失败关闭'
);
$disabled_capabilities = Shuzijun_App_Content_API::app_capabilities();
expect_true(
    $disabled_capabilities instanceof WP_REST_Response
        && ($disabled_capabilities->data['collaborationSubmissionEnabled'] ?? null) === false
        && ($disabled_capabilities->data['collaborationInboxEnabled'] ?? null) === false
        && ($disabled_capabilities->headers['Cache-Control'] ?? '') === 'private, no-store, max-age=0',
    '内建熔断关闭时能力声明必须明确返回 false 且禁止缓存'
);
$disabled_collaboration_request = new WP_REST_Request();
expect_true(
    Shuzijun_App_Content_API::can_submit_collaboration($disabled_collaboration_request) === false
        && Shuzijun_App_Content_API::can_manage_collaboration($disabled_collaboration_request) === false,
    '默认关闭时合作邀约权限回调必须失败关闭'
);
foreach (array(
    Shuzijun_App_Content_API::create_collaboration_request($disabled_collaboration_request),
    Shuzijun_App_Content_API::list_collaboration_requests($disabled_collaboration_request),
    Shuzijun_App_Content_API::update_collaboration_request($disabled_collaboration_request),
) as $disabled_collaboration_response) {
    expect_error_code(
        'collaboration_feature_disabled',
        $disabled_collaboration_response,
        '即使直接调用回调，默认关闭也不得处理合作邀约数据'
    );
}

$registered_action_names = array_map(
    static fn (array $record): string => (string) ($record[0] ?? ''),
    $GLOBALS['yishu_test_registered_actions']
);
expect_true(
    !in_array('yishu_process_fan_apple_event', $registered_action_names, true)
        && !in_array('yishu_retry_fan_apple_revocation', $registered_action_names, true)
        && !in_array(Shuzijun_App_Content_API::COLLABORATION_OUTBOX_HOOK, $registered_action_names, true)
        && !in_array(Shuzijun_App_Content_API::COLLABORATION_SWEEP_HOOK, $registered_action_names, true)
        && !in_array('delete_user', $registered_action_names, true)
        && !in_array('save_post_portfolio', $registered_action_names, true)
        && !in_array('init', $registered_action_names, true),
    '未配置权威节点时不得注册异步账号写入回调'
);
expect_true(
    Shuzijun_App_Content_API::process_collaboration_outbox(1) === false
        && Shuzijun_App_Content_API::sweep_collaboration_outbox() === false
        && Shuzijun_App_Content_API::ensure_collaboration_outbox_schedule() === false,
    '备用节点即使直接调用也不得领取、发送或安排合作邀约 Outbox'
);
$authority_filters = array_values(array_filter(
    $GLOBALS['yishu_test_registered_filters'],
    static function (array $record): bool {
        return ($record[0] ?? '') === 'rest_pre_dispatch'
            && is_array($record[1] ?? null)
            && ($record[1][1] ?? '') === 'enforce_account_authority';
    }
));
expect_true(
    count($authority_filters) === 1 && ($authority_filters[0][2] ?? null) === 0,
    '权威节点门禁必须在其他 App REST pre-dispatch 过滤器之前执行'
);
expect_true(
    Shuzijun_App_Content_API::account_authority_enabled() === false,
    '固定角色标记为 standby 时必须默认非权威节点'
);

$_SERVER['HTTP_HOST'] = 'www.shuzijun.com.cn';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
$_SERVER['HTTP_X_FORWARDED_FOR'] = '101.43.79.80';
$spoofed_authority_request = new WP_REST_Request(
    array(),
    array(
        'Host' => 'www.shuzijun.com.cn',
        'X-Forwarded-For' => '101.43.79.80',
        'X-Account-Node' => 'primary',
    ),
    '/shuzijun/v1/fan/register',
    'POST'
);
$standby_denial = Shuzijun_App_Content_API::enforce_account_authority(
    new WP_REST_Response(array('unsafe' => true)),
    null,
    $spoofed_authority_request
);
expect_error_code(
    'yishu_account_authority_unavailable',
    $standby_denial,
    '伪造 Host、回环地址或转发头不得提升备用节点'
);
expect_same(
    array('status' => 503),
    $standby_denial->get_error_data(),
    '备用节点必须以明确的 503 失败关闭'
);
foreach (array(
    '/shuzijun/v1/app-content',
    '/shuzijun/v1/app-admin/fans',
    '/shuzijun/v1/collaboration-requests',
    '/shuzijun/v1/app-admin/collaboration-requests',
    '/shuzijun/v1/fan/apple-notifications',
) as $protected_route) {
    expect_error_code(
        'yishu_account_authority_unavailable',
        Shuzijun_App_Content_API::enforce_account_authority(
            null,
            null,
            new WP_REST_Request(array(), array(), $protected_route, 'GET')
        ),
        '备用节点必须拒绝 App 敏感读取与写入路由'
    );
}
$outside_result = new WP_REST_Response(array('ok' => true));
expect_same(
    $outside_result,
    Shuzijun_App_Content_API::enforce_account_authority(
        $outside_result,
        null,
        new WP_REST_Request(array(), array(), '/wp/v2/posts', 'GET')
    ),
    '权威节点门禁不得影响插件命名空间以外的 REST 路由'
);

chmod($authority_test_path, 0644);
file_put_contents($authority_test_path, "authority\n");
chmod($authority_test_path, 0644);
expect_true(
    Shuzijun_App_Content_API::account_authority_enabled() === true,
    '仅当固定角色标记精确为 authority 时允许权威账号路由'
);
$authority_passthrough = new WP_REST_Response(array('authority' => true));
expect_same(
    $authority_passthrough,
    Shuzijun_App_Content_API::enforce_account_authority(
        $authority_passthrough,
        null,
        new WP_REST_Request(array(), array(), '/shuzijun/v1/app-content', 'GET')
    ),
    '明确配置的权威节点必须保持 App REST 处理链'
);
Shuzijun_App_Content_API::init();
$authority_action_names = array_map(
    static fn (array $record): string => (string) ($record[0] ?? ''),
    $GLOBALS['yishu_test_registered_actions']
);
expect_true(
    in_array('yishu_process_fan_apple_event', $authority_action_names, true)
        && in_array('yishu_retry_fan_apple_revocation', $authority_action_names, true)
        && !in_array(Shuzijun_App_Content_API::COLLABORATION_OUTBOX_HOOK, $authority_action_names, true)
        && !in_array(Shuzijun_App_Content_API::COLLABORATION_SWEEP_HOOK, $authority_action_names, true)
        && in_array('delete_user', $authority_action_names, true)
        && in_array('save_post_portfolio', $authority_action_names, true)
        && in_array('init', $authority_action_names, true),
    '权威节点必须注册账号回调，但默认仍不得注册合作邀约 worker'
);
expect_true(
    Shuzijun_App_Content_API::ensure_collaboration_storage() === false
        && Shuzijun_App_Content_API::process_collaboration_outbox(1) === false
        && Shuzijun_App_Content_API::sweep_collaboration_outbox() === false
        && Shuzijun_App_Content_API::ensure_collaboration_outbox_schedule() === false,
    '即使是权威节点，默认关闭时也不得建表、领取、扫描或安排合作邀约任务'
);

$authority_method_start = strpos($plugin_source, 'public static function account_authority_enabled');
$authority_method_end = strpos($plugin_source, 'public static function block_fan_wordpress_login', $authority_method_start);
$authority_method_source = ($authority_method_start === false || $authority_method_end === false)
    ? ''
    : substr($plugin_source, $authority_method_start, $authority_method_end - $authority_method_start);
expect_true(
    $authority_method_source !== ''
        && strpos($plugin_source, "const ACCOUNT_AUTHORITY_ROLE_PATH = '/etc/shuzijun/account-authority-role';") !== false
        && strpos($authority_method_source, 'self::ACCOUNT_AUTHORITY_ROLE_PATH') !== false
        && strpos($authority_method_source, '$payload === "authority\\n"') !== false
        && strpos($authority_method_source, 'wp-config.php') === false
        && strpos($authority_method_source, '(int) ($opened[\'uid\'] ?? -1) !== 0') !== false
        && strpos($authority_method_source, '(int) ($opened[\'gid\'] ?? -1) !== 0') !== false
        && strpos($authority_method_source, '($opened[\'mode\'] & 0777) !== 0644') !== false
        && strpos($authority_method_source, '(int) ($opened[\'nlink\'] ?? 0) !== 1') !== false
        && strpos($authority_method_source, '$request->get_header') === false
        && strpos($authority_method_source, '$_SERVER[') === false,
    '权威判定只能依赖服务器所有的固定精确角色标记'
);

function valid_launch_poster(string $id): array {
    return array(
        'id' => $id,
        'isEnabled' => true,
        'imageURL' => 'https://img.shuzijun.com.cn/images/launch.webp',
        'eyebrow' => 'YI SHU',
        'title' => '易姝',
        'subtitle' => '镜头之内，自有叙事。',
        'startsAt' => '2026-01-01T00:00:00+00:00',
        'endsAt' => '2027-01-01T00:00:00+00:00',
        'displaySeconds' => 2.5,
    );
}

function valid_drama(string $id): array {
    return array(
        'id' => $id,
        'title' => '测试短剧',
        'imageURL' => 'https://img.shuzijun.com.cn/images/drama.webp',
        'destinationURL' => 'https://novelquickapp.com/s/example/',
    );
}

expect_same(
    'HS-ABCD-2345',
    invoke_plugin_method('normalize_identity_code', array(' hs-abcd-2345 ')),
    '粉丝身份码必须稳定归一化'
);
expect_same(
    '',
    invoke_plugin_method('normalize_identity_code', array('HS-ABCI-2345')),
    '粉丝身份码必须排除容易混淆的字符'
);
expect_same(
    'yishu_2026',
    invoke_plugin_method('normalize_douyin_id', array(' @YiShu_2026 ')),
    '抖音 ID 必须归一化并移除 @'
);
expect_same(
    '',
    invoke_plugin_method('normalize_douyin_id', array('https://v.douyin.com/test')),
    '抖音 ID 必须拒绝链接'
);
expect_error_code(
    'fan_douyin_id_invalid',
    invoke_plugin_method('normalize_required_douyin_id', array("  \n")),
    '必填抖音 ID 不得留空'
);
expect_error_code(
    'fan_douyin_id_invalid',
    invoke_plugin_method('normalize_required_douyin_id', array(null)),
    '必填抖音 ID 缺失时必须失败关闭'
);
expect_same(
    'yishu_2026',
    invoke_plugin_method('normalize_required_douyin_id', array(' @YiShu_2026 ')),
    '必填抖音 ID 必须保持归一化'
);
expect_error_code(
    'fan_douyin_id_invalid',
    invoke_plugin_method('normalize_required_douyin_id', array('https://v.douyin.com/test')),
    '必填抖音 ID 必须拒绝链接'
);
expect_error_code(
    'fan_douyin_id_invalid',
    invoke_plugin_method(
        'normalize_required_douyin_id',
        array('invite_' . str_repeat('a', 24))
    ),
    '邀请占位值不得伪装为用户填写的抖音 ID'
);

$fan_registration_source = plugin_method_source($plugin_source, 'register_fan');
$apple_registration_completion_source = plugin_method_source(
    $plugin_source,
    'complete_fan_apple_registration'
);
$invitation_completion_source = plugin_method_source(
    $plugin_source,
    'complete_fan_invitation'
);
expect_true(
    $fan_registration_source !== ''
        && $apple_registration_completion_source !== ''
        && $invitation_completion_source !== ''
        && strpos($fan_registration_source, 'normalize_required_douyin_id') !== false
        && strpos($apple_registration_completion_source, 'normalize_required_douyin_id') !== false
        && strpos($invitation_completion_source, 'normalize_required_douyin_id') !== false,
    '注册、Apple 申请和邀请完成必须在服务器端拒绝空或非法抖音 ID'
);

expect_same(
    '2026-09-04-approval-v4',
    Shuzijun_App_Content_API::FAN_CONSENT_VERSION,
    '当前隐私同意版本必须与 2026-09-04 政策一致'
);
expect_same(
    array(
        '2026-09-02-approval-v3',
        '2026-09-04-approval-v4',
    ),
    Shuzijun_App_Content_API::FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS,
    '1.5.13 新同意过渡只能精确接受 Build 42 v3 与 Build 45 v4'
);
expect_same(
    array(
        '2026-08-31-approval-v2',
        '2026-09-02-approval-v3',
    ),
    Shuzijun_App_Content_API::FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS,
    '存量同意兼容只能使用显式最小白名单'
);
expect_true(
    Shuzijun_App_Content_API::fan_consent_version_is_current(
        '2026-09-04-approval-v4'
    )
        && !Shuzijun_App_Content_API::fan_consent_version_is_current(
            '2026-09-02-approval-v3'
        )
        && !Shuzijun_App_Content_API::fan_consent_version_is_current(null),
    '当前版本匹配器只能精确识别 v4'
);
expect_true(
    Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(
        '2026-09-04-approval-v4'
    )
        && Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(
            '2026-09-02-approval-v3'
        )
        && !Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(
            '2026-08-31-approval-v2'
        )
        && !Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(
            '2026-08-30-approval-v1'
        )
        && !Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(null)
        && !Shuzijun_App_Content_API::fan_new_consent_version_is_accepted(array(
            '2026-08-31-approval-v2',
        )),
    '1.5.13 新同意只能精确接受 v3/v4，v2、未知、缺失或非字符串必须失败'
);
expect_true(
    Shuzijun_App_Content_API::fan_stored_consent_is_accepted(array(
        'version' => '2026-09-04-approval-v4',
        'acceptedAt' => '2026-09-04T00:00:00+00:00',
    ))
        && Shuzijun_App_Content_API::fan_stored_consent_is_accepted(array(
            'version' => '2026-09-02-approval-v3',
            'acceptedAt' => '2026-09-02T00:00:00+00:00',
        ))
        && Shuzijun_App_Content_API::fan_stored_consent_is_accepted(array(
            'version' => '2026-08-31-approval-v2',
            'acceptedAt' => '2026-08-31T00:00:00+00:00',
        ))
        && !Shuzijun_App_Content_API::fan_stored_consent_is_accepted(array(
            'version' => '2026-08-30-approval-v1',
        ))
        && !Shuzijun_App_Content_API::fan_stored_consent_is_accepted(null),
    '已存 v2、v3 和 v4 记录必须保持有效，未知或缺失记录必须失败关闭'
);
foreach (array(
    $fan_registration_source,
    $apple_registration_completion_source,
    $invitation_completion_source,
) as $new_consent_source) {
    expect_true(
        strpos(
            $new_consent_source,
            "\$consent_version = \$request->get_param('consentVersion');"
        ) !== false
            && strpos(
                $new_consent_source,
                'fan_new_consent_version_is_accepted($consent_version)'
            ) !== false
            && strpos($new_consent_source, "'version' => \$consent_version") !== false
            && strpos($new_consent_source, "'version' => self::FAN_CONSENT_VERSION") === false,
        '每个新同意入口都必须验证受审 v3/v4 过渡白名单，并保存客户端实际提交的原版本'
    );
}

$collaboration_submission_id = '123e4567-e89b-42d3-a456-426614174000';
$collaboration_date = gmdate('Y-m-d', time() + DAY_IN_SECONDS);
$valid_collaboration_request = new WP_REST_Request(array(
    'submissionID' => strtoupper($collaboration_submission_id),
    'contactName' => '合作方',
    'contactMethod' => 'contact@example.com',
    'organization' => '测试项目',
    'projectType' => 'commercial',
    'city' => '杭州',
    'preferredDate' => $collaboration_date,
    'budget' => '5000-10000',
    'details' => "第一行\r\n第二行",
));
$normalized_collaboration = invoke_plugin_method(
    'sanitize_collaboration_submission',
    array($valid_collaboration_request)
);
expect_true(
    is_array($normalized_collaboration)
        && ($normalized_collaboration['submissionID'] ?? '') === $collaboration_submission_id
        && ($normalized_collaboration['details'] ?? '') === "第一行\n第二行"
        && ($normalized_collaboration['preferredDate'] ?? '') === $collaboration_date
        && preg_match('/^[a-f0-9]{64}$/', (string) ($normalized_collaboration['payloadHash'] ?? '')) === 1,
    '合作邀约必须归一化 UUID、多行说明和幂等 payload hash'
);
$collaboration_crlf_request = new WP_REST_Request(array(
    'submissionID' => $collaboration_submission_id,
    'contactName' => "合作方\r\nBcc: attacker@example.com",
    'contactMethod' => 'contact@example.com',
    'organization' => '',
    'projectType' => 'drama',
    'city' => '',
    'preferredDate' => $collaboration_date,
    'budget' => '',
    'details' => '',
));
expect_error_code(
    'collaboration_field_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_crlf_request)),
    '单行合作字段必须拒绝 CRLF 邮件头注入'
);
$collaboration_invalid_date_request = new WP_REST_Request(array(
    'submissionID' => $collaboration_submission_id,
    'contactName' => '合作方',
    'contactMethod' => 'contact@example.com',
    'organization' => '',
    'projectType' => 'brand',
    'city' => '',
    'preferredDate' => '2027-02-30',
    'budget' => '',
    'details' => '',
));
expect_error_code(
    'collaboration_date_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_invalid_date_request)),
    '合作邀约日期必须是真实 YYYY-MM-DD 日期'
);
$collaboration_nested_request = new WP_REST_Request(array(
    'submissionID' => $collaboration_submission_id,
    'contactName' => array('注入'),
    'contactMethod' => 'contact@example.com',
    'organization' => '',
    'projectType' => 'other',
    'city' => '',
    'preferredDate' => $collaboration_date,
    'budget' => '',
    'details' => '',
));
expect_error_code(
    'collaboration_field_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_nested_request)),
    '合作邀约不得将嵌套 JSON 静默转为文本'
);
$collaboration_overlong_request = new WP_REST_Request(array(
    'submissionID' => $collaboration_submission_id,
    'contactName' => str_repeat('a', 81),
    'contactMethod' => 'contact@example.com',
    'organization' => '',
    'projectType' => 'event',
    'city' => '',
    'preferredDate' => $collaboration_date,
    'budget' => '',
    'details' => '',
));
expect_error_code(
    'collaboration_field_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_overlong_request)),
    '合作邀约单行字段必须严格限制长度'
);
$collaboration_unknown_type_request = new WP_REST_Request(array(
    'submissionID' => $collaboration_submission_id,
    'contactName' => '合作方',
    'contactMethod' => 'contact@example.com',
    'organization' => '',
    'projectType' => 'arbitrary-client-value',
    'city' => '',
    'preferredDate' => $collaboration_date,
    'budget' => '',
    'details' => '',
));
expect_error_code(
    'collaboration_project_type_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_unknown_type_request)),
    '合作类型必须使用服务端 allowlist'
);
expect_error_code(
    'collaboration_details_invalid',
    invoke_plugin_method('normalize_collaboration_details', array(str_repeat('a', 4001))),
    '合作邀约项目说明必须限制为 4000 字符'
);
$collaboration_bad_uuid_request = new WP_REST_Request(array(
    'submissionID' => '123e4567-e89b-12d3-a456-426614174000',
));
expect_error_code(
    'collaboration_submission_id_invalid',
    invoke_plugin_method('sanitize_collaboration_submission', array($collaboration_bad_uuid_request)),
    '合作邀约幂等标识必须是 UUIDv4'
);
$duplicate_collaboration_response = invoke_plugin_method(
    'collaboration_submission_response',
    array(array(
        'public_id' => '223e4567-e89b-42d3-a456-426614174000',
        'payload_hash' => $normalized_collaboration['payloadHash'],
        'status' => 'reviewing',
        'created_at' => '2026-09-02 10:00:00',
    ), $normalized_collaboration['payloadHash'], true)
);
expect_true(
    $duplicate_collaboration_response instanceof WP_REST_Response
        && $duplicate_collaboration_response->status === 200
        && ($duplicate_collaboration_response->data['duplicate'] ?? false) === true
        && ($duplicate_collaboration_response->data['status'] ?? '') === 'reviewing'
        && ($duplicate_collaboration_response->headers['Cache-Control'] ?? '')
            === 'private, no-store, max-age=0',
    '同一粉丝、同一 submission UUID 与同一 payload 在管理员推进状态后仍必须幂等返回原请求'
);
expect_error_code(
    'collaboration_storage_unavailable',
    invoke_plugin_method('collaboration_submission_response', array(array(
        'public_id' => '223e4567-e89b-42d3-a456-426614174000',
        'payload_hash' => str_repeat('a', 64),
        'status' => 'arbitrary-status',
        'created_at' => '2026-09-02 10:00:00',
    ), str_repeat('a', 64), true)),
    '重复回执只能返回服务端允许的合作状态'
);
expect_error_code(
    'collaboration_idempotency_conflict',
    invoke_plugin_method('collaboration_submission_response', array(array(
        'public_id' => '223e4567-e89b-42d3-a456-426614174000',
        'payload_hash' => str_repeat('a', 64),
        'status' => 'received',
        'created_at' => '2026-09-02 10:00:00',
    ), str_repeat('b', 64), true)),
    '同一 submission UUID 不得覆盖不同 payload'
);
expect_same(
    array('status' => 'pending', 'delay' => 60),
    invoke_plugin_method('collaboration_outbox_failure_state', array(1)),
    'Outbox 首次失败必须进入有界重试'
);
expect_same(
    array('status' => 'dead', 'delay' => 0),
    invoke_plugin_method(
        'collaboration_outbox_failure_state',
        array(Shuzijun_App_Content_API::COLLABORATION_OUTBOX_MAX_ATTEMPTS)
    ),
    'Outbox 达到最大尝试次数必须进入 dead 终态'
);
$sanitized_audit_metadata = invoke_plugin_method(
    'sanitize_collaboration_audit_metadata',
    array(array(
        'fromStatus' => 'received',
        'toStatus' => 'reviewing',
        'attempt' => 2,
        'errorCode' => 'mail_rejected',
        'contactName' => '不得进入审计',
        'contactMethod' => 'secret@example.com',
        'details' => '私密项目说明',
    ))
);
expect_same(
    array(
        'fromStatus' => 'received',
        'toStatus' => 'reviewing',
        'attempt' => 2,
        'errorCode' => 'mail_rejected',
    ),
    $sanitized_audit_metadata,
    '合作邀约审计只能保留状态、次数和错误码，不得包含 PII'
);
expect_same(
    Shuzijun_App_Content_API::COLLABORATION_EMAIL,
    invoke_plugin_method('collaboration_work_email'),
    '合作邀约 Outbox 必须使用服务端固定工作邮箱'
);
$GLOBALS['yishu_test_filters']['yishu_collaboration_work_email'] = static function (): string {
    return "recipient@example.com\r\nBcc: attacker@example.com";
};
expect_same(
    '',
    invoke_plugin_method('collaboration_work_email'),
    '工作收件人配置中的 CRLF 必须失败关闭'
);
unset($GLOBALS['yishu_test_filters']['yishu_collaboration_work_email']);

$collaboration_schema_start = strpos($plugin_source, 'public static function ensure_collaboration_storage');
$collaboration_schema_end = strpos($plugin_source, 'public static function create_collaboration_request', $collaboration_schema_start);
$collaboration_schema_source = ($collaboration_schema_start === false || $collaboration_schema_end === false)
    ? ''
    : substr($plugin_source, $collaboration_schema_start, $collaboration_schema_end - $collaboration_schema_start);
$collaboration_submit_start = strpos($plugin_source, 'public static function create_collaboration_request');
$collaboration_submit_end = strpos($plugin_source, 'public static function list_collaboration_requests', $collaboration_submit_start);
$collaboration_submit_source = ($collaboration_submit_start === false || $collaboration_submit_end === false)
    ? ''
    : substr($plugin_source, $collaboration_submit_start, $collaboration_submit_end - $collaboration_submit_start);
$collaboration_permission_start = strpos($plugin_source, 'public static function can_submit_collaboration');
$collaboration_permission_end = strpos($plugin_source, 'private static function can_manage_capability', $collaboration_permission_start);
$collaboration_permission_source = ($collaboration_permission_start === false || $collaboration_permission_end === false)
    ? ''
    : substr($plugin_source, $collaboration_permission_start, $collaboration_permission_end - $collaboration_permission_start);
$collaboration_worker_start = strpos($plugin_source, 'public static function process_collaboration_outbox');
$collaboration_worker_end = strpos($plugin_source, 'private static function collaboration_tables', $collaboration_worker_start);
$collaboration_worker_source = ($collaboration_worker_start === false || $collaboration_worker_end === false)
    ? ''
    : substr($plugin_source, $collaboration_worker_start, $collaboration_worker_end - $collaboration_worker_start);
$collaboration_update_start = strpos($plugin_source, 'public static function update_collaboration_request');
$collaboration_update_end = strpos($plugin_source, 'public static function ensure_collaboration_outbox_schedule', $collaboration_update_start);
$collaboration_update_source = ($collaboration_update_start === false || $collaboration_update_end === false)
    ? ''
    : substr($plugin_source, $collaboration_update_start, $collaboration_update_end - $collaboration_update_start);
$collaboration_audit_start = strpos($plugin_source, 'private static function sanitize_collaboration_audit_metadata');
$collaboration_audit_end = strpos($plugin_source, 'private static function schedule_collaboration_outbox_job', $collaboration_audit_start);
$collaboration_audit_source = ($collaboration_audit_start === false || $collaboration_audit_end === false)
    ? ''
    : substr($plugin_source, $collaboration_audit_start, $collaboration_audit_end - $collaboration_audit_start);
$collaboration_capabilities_source = plugin_method_source($plugin_source, 'app_capabilities');
$collaboration_capabilities_permission_source = plugin_method_source(
    $plugin_source,
    'can_read_app_capabilities'
);
$collaboration_mail_ready_source = plugin_method_source(
    $plugin_source,
    'collaboration_mail_transport_ready'
);
$collaboration_purge_source = plugin_method_source(
    $plugin_source,
    'purge_collaboration_data_for_fan_user'
);
$collaboration_fan_revalidation_source = plugin_method_source(
    $plugin_source,
    'collaboration_fan_context_is_current_from_database'
);
$fan_remove_source = plugin_method_source($plugin_source, 'remove_fan_user');
$fan_deletion_hook_source = plugin_method_source($plugin_source, 'prepare_fan_user_deletion');
$fan_deletion_finalize_source = plugin_method_source(
    $plugin_source,
    'finalize_fan_user_deletion'
);
$fan_deletion_release_registration_source = plugin_method_source(
    $plugin_source,
    'register_fan_user_deletion_release_hooks'
);
$fan_deletion_abort_source = plugin_method_source(
    $plugin_source,
    'abort_fan_user_deletion'
);
$collaboration_gate_source = plugin_method_source(
    $plugin_source,
    'collaboration_phase1_enabled'
);
expect_true(
    $collaboration_gate_source !== ''
        && strpos(
            $plugin_source,
            'const COLLABORATION_PHASE1_RELEASE_FUSE = false;'
        ) !== false
        && strpos(
            $collaboration_gate_source,
            'self::COLLABORATION_PHASE1_RELEASE_FUSE === true'
        ) !== false
        && strpos($collaboration_gate_source, "defined('YISHU_ENABLE_COLLABORATION_PHASE1')") !== false
        && strpos($collaboration_gate_source, "constant('YISHU_ENABLE_COLLABORATION_PHASE1') === true") !== false
        && strpos($collaboration_gate_source, 'apply_filters') === false
        && strpos($collaboration_gate_source, 'get_option') === false
        && strpos($collaboration_gate_source, 'getenv') === false,
    'Build 41 必须同时要求内建 release fuse 与外部 strict-true 常量，且内建 fuse 固定为 false'
);
foreach (array(
    'can_manage_collaboration',
    'can_submit_collaboration',
    'ensure_collaboration_storage',
    'create_collaboration_request',
    'list_collaboration_requests',
    'update_collaboration_request',
    'ensure_collaboration_outbox_schedule',
    'sweep_collaboration_outbox',
    'process_collaboration_outbox',
    'collaboration_storage_ready',
    'schedule_collaboration_outbox_job',
) as $gated_collaboration_method) {
    $gated_source = plugin_method_source($plugin_source, $gated_collaboration_method);
    expect_true(
        $gated_source !== ''
            && strpos($gated_source, 'self::collaboration_phase1_enabled()') !== false,
        $gated_collaboration_method . ' 必须自身执行 Phase 1 硬门禁'
    );
}
$collaboration_init_source = plugin_method_source($plugin_source, 'init');
$collaboration_routes_source = plugin_method_source($plugin_source, 'register_routes');
$collaboration_roles_source = plugin_method_source($plugin_source, 'ensure_roles');
$application_passwords_source = plugin_method_source(
    $plugin_source,
    'application_passwords_for_user'
);
expect_true(
    $collaboration_init_source !== ''
        && $collaboration_routes_source !== ''
        && $collaboration_roles_source !== ''
        && $application_passwords_source !== ''
        && strpos($collaboration_init_source, 'if (self::collaboration_phase1_enabled())') !== false
        && strpos($collaboration_routes_source, 'if (self::collaboration_phase1_enabled())') !== false
        && strpos($collaboration_roles_source, 'self::collaboration_phase1_enabled()') !== false
        && strpos($application_passwords_source, 'self::collaboration_phase1_enabled()') !== false
        && strpos($plugin_source, "define('YISHU_ENABLE_COLLABORATION_PHASE1'") === false
        && strpos($plugin_source, 'register_activation_hook') === false,
    '合作路由、权限、schema/Cron hook 注册与激活时动作必须全部受硬门禁保护'
);
expect_true(
    $collaboration_capabilities_source !== ''
        && $collaboration_capabilities_permission_source !== ''
        && $collaboration_mail_ready_source !== ''
        && strpos(
            $collaboration_capabilities_source,
            'self::collaboration_mail_transport_ready()'
        ) !== false
        && strpos(
            $collaboration_mail_ready_source,
            "defined('YISHU_COLLABORATION_MAIL_TRANSPORT_READY')"
        ) !== false
        && strpos(
            $collaboration_mail_ready_source,
            "constant('YISHU_COLLABORATION_MAIL_TRANSPORT_READY') === true"
        ) !== false
        && strpos(
            $collaboration_mail_ready_source,
            "defined('YISHU_COLLABORATION_EMAIL')"
        ) !== false
        && strpos($collaboration_mail_ready_source, "function_exists('wp_mail')") !== false
        && strpos($collaboration_mail_ready_source, 'self::collaboration_work_email()') !== false
        && strpos($collaboration_mail_ready_source, 'apply_filters') === false
        && substr_count($collaboration_capabilities_source, '$collaboration_enabled') >= 3,
    '提交与收件箱能力必须成对返回，且要求运维明确确认邮件传输和收件地址，不能仅依赖 wp_mail 存在'
);
expect_true(
    strpos($collaboration_capabilities_permission_source, "preg_match('/^Bearer") !== false
        && strpos($collaboration_capabilities_permission_source, 'self::$fan_session_context = null') !== false
        && strpos(
            $collaboration_capabilities_permission_source,
            'self::can_access_app_content($request)'
        ) !== false
        && strpos($collaboration_capabilities_permission_source, "preg_match('/^Basic") !== false
        && strpos(
            $collaboration_capabilities_permission_source,
            'self::authenticate_manager_for_capability('
        ) !== false
        && strpos(
            $collaboration_capabilities_permission_source,
            'self::COLLABORATION_CAPABILITY'
        ) !== false
        && strpos($collaboration_capabilities_permission_source, 'return true;') === false,
    '能力声明只允许已批准粉丝 Bearer 或具有合作专用权限的 Basic 管理员读取，不得匿名放行'
);
expect_true(
    strpos($plugin_source, "'/collaboration-requests'") !== false
        && strpos($plugin_source, "'/app-admin/collaboration-requests'") !== false
        && strpos($plugin_source, "'/app-admin/collaboration-requests/(?P<request_id>[a-f0-9-]{36})'") !== false
        && strpos($plugin_source, "'permission_callback' => array(__CLASS__, 'can_submit_collaboration')") !== false
        && substr_count($plugin_source, "'permission_callback' => array(__CLASS__, 'can_manage_collaboration')") === 2,
    '启用后的合作邀约提交、管理员收件箱与状态更新必须使用专用权限路由'
);
expect_true(
    $collaboration_permission_source !== ''
        && strpos($collaboration_permission_source, 'self::$fan_session_context = null') !== false
        && strpos($collaboration_permission_source, 'self::can_access_app_content($request)') !== false
        && strpos($collaboration_permission_source, "(\$context['scope'] ?? '') !== 'normal'") !== false,
    '提交合作邀约必须复用 App 内容门禁并且只接受已批准 normal 粉丝会话'
);
expect_true(
    $collaboration_schema_source !== ''
        && substr_count($collaboration_schema_source, 'CREATE TABLE') === 3
        && strpos($collaboration_schema_source, 'ENGINE=InnoDB') !== false
        && strpos($collaboration_schema_source, 'UNIQUE KEY fan_submission (fan_user_id, submission_id)') !== false
        && strpos($collaboration_schema_source, 'UNIQUE KEY dedupe_key (dedupe_key)') !== false
        && strpos($collaboration_schema_source, 'UNIQUE KEY request_channel (request_id, channel)') !== false
        && strpos($collaboration_schema_source, 'array($requests_sql, $outbox_sql, $audit_sql)') !== false
        && strpos($collaboration_schema_source, '$changes = dbDelta($schema_sql)') !== false
        && strpos($collaboration_schema_source, '!is_array($changes) || !empty($wpdb->last_error)') !== false
        && strpos($collaboration_schema_source, 'self::account_authority_enabled()') !== false,
    '合作邀约、Outbox 和审计必须使用权威节点创建的 InnoDB 专用表与唯一键'
);
expect_true(
    $collaboration_submit_source !== ''
        && $collaboration_fan_revalidation_source !== ''
        && strpos($collaboration_submit_source, "array('collaboration_user'") !== false
        && strpos($collaboration_submit_source, "array('collaboration_install'") !== false
        && strpos($collaboration_submit_source, "array('collaboration_net'") !== false
        && strpos($collaboration_submit_source, 'self::acquire_fan_lock($fan_user_id)') !== false
        && strpos(
            $collaboration_submit_source,
            'self::collaboration_fan_context_is_current_from_database($context)'
        ) !== false
        && strpos(
            $collaboration_submit_source,
            "collaboration_fan_context_is_current_from_database(\n                    \$context,\n                    true"
        ) !== false
        && strpos($collaboration_submit_source, "query('START TRANSACTION')")
            < strpos(
                $collaboration_submit_source,
                "collaboration_fan_context_is_current_from_database(\n                    \$context,\n                    true"
            )
        && strpos(
            $collaboration_submit_source,
            "collaboration_fan_context_is_current_from_database(\n                    \$context,\n                    true"
        ) < strpos($collaboration_submit_source, '$wpdb->insert($tables[\'requests\']')
        && strpos($collaboration_submit_source, 'self::release_fan_lock(') !== false
        && strpos($collaboration_submit_source, "query('START TRANSACTION')") !== false
        && strpos($collaboration_submit_source, "query('COMMIT')") !== false
        && strpos($collaboration_submit_source, "query('ROLLBACK')") !== false
        && strpos($collaboration_submit_source, "'request_received'") !== false,
    '新合作邀约必须与删号串行化，并在写事务内再次复核会话与账号状态'
);
expect_true(
    strpos($collaboration_fan_revalidation_source, 'self::fan_session_context_is_current_from_database(') !== false
        && strpos($collaboration_fan_revalidation_source, "'normal',") !== false
        && strpos($collaboration_fan_revalidation_source, '$wpdb->users') !== false
        && strpos($collaboration_fan_revalidation_source, "\$status !== 'active'") !== false
        && strpos($collaboration_fan_revalidation_source, 'self::FAN_META_INVITATION') !== false
        && strpos($collaboration_fan_revalidation_source, 'self::FAN_META_PASSWORD_RECOVERY') !== false
        && strpos($collaboration_fan_revalidation_source, 'self::FAN_META_APPLE_SETUP') !== false
        && strpos($collaboration_fan_revalidation_source, 'self::normalize_required_douyin_id') !== false
        && strpos($collaboration_fan_revalidation_source, 'self::fan_stored_consent_is_accepted') !== false
        && strpos($collaboration_fan_revalidation_source, 'self::FAN_META_PERMISSIONS') !== false
        && strpos($collaboration_fan_revalidation_source, 'sort($fresh_permissions, SORT_STRING)') !== false
        && strpos($collaboration_fan_revalidation_source, '$fresh_permissions === $callback_permissions') !== false
        && strpos($collaboration_fan_revalidation_source, "' FOR UPDATE'") !== false,
    '持有粉丝锁后必须从数据库复核用户存在、active、资料完整、同意、权限快照与当前会话'
);
$revalidation_user_id = 91;
$revalidation_token_hash = str_repeat('a', 64);
$revalidation_context = array(
    'userID' => $revalidation_user_id,
    'scope' => 'normal',
    'expires' => time() + HOUR_IN_SECONDS,
    'credentialEpoch' => 2,
    'authMethod' => 'password',
    'recentAuthUntil' => 0,
    'sessionID' => str_repeat('b', 32),
    'installHash' => str_repeat('c', 64),
    'tokenHash' => $revalidation_token_hash,
    'permissions' => array('gallery_full'),
);
$GLOBALS['yishu_test_options'][
    Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $revalidation_token_hash
] = $revalidation_context;
$GLOBALS['wpdb']->user_display_names[$revalidation_user_id] = '合作测试用户';
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id] = array(
    Shuzijun_App_Content_API::FAN_META_UUID => '123e4567-e89b-42d3-a456-426614174091',
    Shuzijun_App_Content_API::FAN_META_CODE => 'HS-ABCD-2345',
    Shuzijun_App_Content_API::FAN_META_STATUS => 'active',
    Shuzijun_App_Content_API::FAN_META_DOUYIN_ID => 'yishu_91',
    Shuzijun_App_Content_API::FAN_META_CONSENT => array(
        'version' => Shuzijun_App_Content_API::FAN_CONSENT_VERSION,
        'acceptedAt' => gmdate('c'),
    ),
    Shuzijun_App_Content_API::FAN_META_PERMISSIONS => array('gallery_full'),
    Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH => 2,
);
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($revalidation_context, true)
    ) === true,
    '写入事务内的数据库复核应接受会话、资料、active 状态和权限一致的账号'
);

// Deployed pre-scope sessions still authenticate as normal/password/epoch 1.
// Exercise the fresh database check used before binding, rather than just
// testing the normalization expression in isolation.
$unscoped_context = $revalidation_context;
$unscoped_context['credentialEpoch'] = 1;
$unscoped_stored_session = $unscoped_context;
unset(
    $unscoped_stored_session['scope'],
    $unscoped_stored_session['credentialEpoch'],
    $unscoped_stored_session['authMethod'],
    $unscoped_stored_session['recentAuthUntil']
);
$revalidation_option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $revalidation_token_hash;
$GLOBALS['yishu_test_options'][$revalidation_option] = $unscoped_stored_session;
unset($GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH]);
expect_true(
    invoke_plugin_method('fan_session_context_is_current_from_database', array($unscoped_context, 'normal', true)) === true,
    '缺失 scope 的未过期旧会话必须通过 normal 会话的事务内复核'
);
foreach (array('onboarding', 'password_recovery', 'apple_onboarding') as $non_normal_scope) {
    expect_true(
        invoke_plugin_method('fan_session_context_is_current_from_database', array($unscoped_context, $non_normal_scope, true)) === false,
        '缺失 scope 的旧会话只能获得 normal 范围，不能升级为安全设置会话'
    );
}
foreach (array(null, '', false, 0, array(), 'unknown', 'onboarding', 'password_recovery', 'apple_onboarding') as $invalid_stored_scope) {
    $GLOBALS['yishu_test_options'][$revalidation_option] = $unscoped_stored_session;
    $GLOBALS['yishu_test_options'][$revalidation_option]['scope'] = $invalid_stored_scope;
    expect_true(
        invoke_plugin_method('fan_session_context_is_current_from_database', array($unscoped_context, 'normal', true)) === false,
        '显式空值、无效值及非 normal scope 必须在数据库复核时失败关闭'
    );
}
foreach (array(
    'userID' => $revalidation_user_id + 1,
    'expires' => time() - 1,
    'installHash' => str_repeat('d', 64),
    'sessionID' => str_repeat('e', 32),
    'authMethod' => 'apple',
    'recentAuthUntil' => time() + 60,
) as $mismatched_field => $mismatched_value) {
    $GLOBALS['yishu_test_options'][$revalidation_option] = $unscoped_stored_session;
    $GLOBALS['yishu_test_options'][$revalidation_option][$mismatched_field] = $mismatched_value;
    expect_true(
        invoke_plugin_method('fan_session_context_is_current_from_database', array($unscoped_context, 'normal', true)) === false,
        '旧 scope 兼容不得放宽账号、到期、安装、会话或认证上下文一致性'
    );
}
$GLOBALS['yishu_test_options'][$revalidation_option] = $unscoped_stored_session;
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH] = 2;
expect_true(
    invoke_plugin_method('fan_session_context_is_current_from_database', array($unscoped_context, 'normal', true)) === false,
    '密码或安全状态已推进到 epoch 2 时，缺失 scope/epoch 的旧会话仍必须失效'
);
$GLOBALS['yishu_test_options'][$revalidation_option] = $revalidation_context;
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_STATUS
] = 'suspended';
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($revalidation_context, true)
    ) === false,
    '权限回调后被暂停的账号不得写入合作邀约'
);
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_STATUS
] = 'active';
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_CODE
] = '';
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($revalidation_context, true)
    ) === false,
    '权限回调后身份码缺失的账号不得写入合作邀约'
);
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_CODE
] = 'HS-ABCD-2345';
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_PERMISSIONS
] = array('video_view');
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($revalidation_context, true)
    ) === false,
    '权限回调后权限快照已改变时不得用旧快照写入合作邀约'
);
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_PERMISSIONS
] = array('gallery_full');
$empty_permission_context = $revalidation_context;
$empty_permission_context['permissions'] = array();
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_PERMISSIONS
] = array();
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($empty_permission_context, true)
    ) === true,
    '合法的空细分权限仍应与内容门禁一致，但不得接受过期权限快照'
);
$GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id][
    Shuzijun_App_Content_API::FAN_META_PERMISSIONS
] = array('gallery_full');
unset($GLOBALS['yishu_test_options'][
    Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $revalidation_token_hash
]);
expect_true(
    invoke_plugin_method(
        'collaboration_fan_context_is_current_from_database',
        array($revalidation_context, true)
    ) === false,
    '权限回调后已撤销的会话不得写入合作邀约'
);
unset(
    $GLOBALS['wpdb']->user_display_names[$revalidation_user_id],
    $GLOBALS['wpdb']->user_meta_rows[$revalidation_user_id]
);
expect_true(
    $collaboration_worker_source !== ''
        && strpos($collaboration_worker_source, 'self::account_authority_enabled()') !== false
        && strpos($collaboration_worker_source, "status = 'processing'") !== false
        && strpos($collaboration_worker_source, 'lease_token = %s') !== false
        && strpos($collaboration_worker_source, 'attempts = attempts + 1') !== false
        && strpos($collaboration_worker_source, 'wp_mail(') !== false
        && strpos($plugin_source, "array('status' => 'dead', 'delay' => 0)") !== false
        && strpos($plugin_source, 'mark_exhausted_collaboration_outbox_jobs') !== false
        && strpos($plugin_source, "'worker_interrupted'") !== false
        && strpos($plugin_source, 'COLLABORATION_OUTBOX_MAX_ATTEMPTS') !== false,
    'Outbox 必须仅在权威节点以 lease 领取，并有界重试至 dead 终态'
);
expect_true(
    $collaboration_update_source !== ''
        && strpos($collaboration_update_source, 'LIMIT 1 FOR UPDATE') !== false
        && strpos($collaboration_update_source, "get_param('version')") !== false
        && strpos($collaboration_update_source, "'collaboration_version_conflict'") !== false
        && strpos($collaboration_update_source, "'request_status_updated'") !== false
        && strpos($collaboration_update_source, "'fromStatus'") !== false
        && strpos($collaboration_update_source, "'toStatus'") !== false,
    '管理员更新邀约状态必须锁行、检查乐观并发版本并写入脱敏审计'
);
expect_true(
    $collaboration_audit_source !== ''
        && strpos($collaboration_audit_source, "'fromStatus', 'toStatus', 'channel', 'attempt', 'errorCode', 'version'") !== false
        && strpos($collaboration_audit_source, 'contact_name') === false
        && strpos($collaboration_audit_source, 'contact_method') === false
        && strpos($collaboration_audit_source, 'details') === false
        && strpos($collaboration_audit_source, 'metadata_json') !== false,
    '合作邀约审计表必须是严格 allowlist，不得写入联系资料或项目说明'
);
expect_true(
    $collaboration_purge_source !== ''
        && $fan_remove_source !== ''
        && $fan_deletion_hook_source !== ''
        && $fan_deletion_finalize_source !== ''
        && $fan_deletion_release_registration_source !== ''
        && $fan_deletion_abort_source !== ''
        && strpos($collaboration_purge_source, 'self::collaboration_phase1_enabled()') === false
        && strpos($collaboration_purge_source, 'self::collaboration_table_names()') !== false
        && strpos($collaboration_purge_source, 'self::COLLABORATION_SCHEMA_OPTION') === false
        && strpos($collaboration_purge_source, 'account_deletion_schema_probe_failed') !== false
        && strpos($collaboration_purge_source, "query('START TRANSACTION')") !== false
        && strpos($collaboration_purge_source, 'DELETE a FROM {$tables[\'audit\']} a') !== false
        && strpos($collaboration_purge_source, 'DELETE o FROM {$tables[\'outbox\']} o') !== false
        && strpos($collaboration_purge_source, 'DELETE FROM {$tables[\'requests\']}') !== false
        && strpos($collaboration_purge_source, "query('COMMIT')") !== false
        && strpos($collaboration_purge_source, "query('ROLLBACK')") !== false
        && strpos($fan_remove_source, 'self::purge_collaboration_data_for_fan_user') !== false
        && strpos($fan_remove_source, 'wp_delete_user') !== false
        && strpos($fan_remove_source, 'self::purge_collaboration_data_for_fan_user')
            < strpos($fan_remove_source, 'wp_delete_user')
        && strpos($fan_remove_source, 'self::$fan_user_deletion_prepared[$user_id] = true') !== false
        && strpos($fan_deletion_hook_source, 'self::acquire_fan_lock($user_id)') !== false
        && strpos($fan_deletion_hook_source, 'self::purge_collaboration_data_for_fan_user') !== false
        && strpos($fan_deletion_hook_source, 'self::abort_fan_user_deletion') !== false
        && strpos($fan_deletion_hook_source, 'self::release_fan_user_deletion_lock($user_id)') !== false
        && strpos($fan_deletion_release_registration_source, "add_action('deleted_user'") !== false
        && strpos($fan_deletion_release_registration_source, "add_action('shutdown'") !== false
        && strpos($fan_deletion_finalize_source, 'self::release_fan_user_deletion_lock') !== false
        && strpos($fan_deletion_abort_source, "function_exists('wp_die')") !== false
        && strpos($fan_deletion_abort_source, 'throw new RuntimeException') !== false,
    'App 与 WordPress 核心删号都必须在不可逆删除开始前清除合作 PII，失败时必须阻断删号'
);

// Physical-table discovery, rather than the advisory schema option, is the
// deletion authority. Exercise the missing/corrupt-marker cases dynamically so
// a future shortcut cannot silently strand collaboration PII.
$purge_db = $GLOBALS['wpdb'];
$collaboration_tables = array(
    'wp_yishu_collaboration_requests',
    'wp_yishu_collaboration_outbox',
    'wp_yishu_collaboration_audit',
);
$purge_db->existing_tables = $collaboration_tables;
$purge_db->collaboration_request_ids[77] = array(901, 902);
unset($GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::COLLABORATION_SCHEMA_OPTION]);
expect_true(
    Shuzijun_App_Content_API::purge_collaboration_data_for_fan_user(77) === true
        && substr_count(implode("\n", $purge_db->executed_queries), 'DELETE ') === 3,
    '即使 schema option 缺失，只要物理表存在就必须事务性清除合作数据'
);
$purge_db->executed_queries = array();
$GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::COLLABORATION_SCHEMA_OPTION] = 'corrupt';
$purge_db->collaboration_request_ids[78] = array(903);
expect_true(
    Shuzijun_App_Content_API::purge_collaboration_data_for_fan_user(78) === true
        && substr_count(implode("\n", $purge_db->executed_queries), 'DELETE ') === 3,
    '即使 schema option 损坏，物理表中的合作数据仍必须被清除'
);
$purge_db->executed_queries = array();
$purge_db->existing_tables = array($collaboration_tables[0]);
expect_true(
    Shuzijun_App_Content_API::purge_collaboration_data_for_fan_user(79) === false
        && strpos(implode("\n", $purge_db->executed_queries), 'START TRANSACTION') === false,
    '合作表不完整时不得误报清理成功或继续删号'
);
$core_delete_blocked = false;
try {
    Shuzijun_App_Content_API::prepare_fan_user_deletion(79);
} catch (RuntimeException $error) {
    $core_delete_blocked = $error->getMessage()
        === 'fan_user_deletion_privacy_cleanup_failed';
}
expect_true(
    $core_delete_blocked
        && in_array(
            array('yishu_fan_security_audit', array('account_deletion_cleanup_failed')),
            $GLOBALS['yishu_test_fired_actions'],
            true
        ),
    'WordPress core/admin 删号在合作 PII 清理失败时必须于不可逆删除前终止'
);
$purge_db->existing_tables = $collaboration_tables;
$purge_db->table_probe_failures = array($collaboration_tables[1]);
expect_true(
    Shuzijun_App_Content_API::purge_collaboration_data_for_fan_user(80) === false,
    '物理表探测出错时必须失败关闭，不得把查询错误当成无数据'
);
$purge_db->existing_tables = array();
$purge_db->table_probe_failures = array();
$purge_db->executed_queries = array();
expect_true(
    Shuzijun_App_Content_API::purge_collaboration_data_for_fan_user(81) === true
        && !$purge_db->executed_queries,
    '确认三张物理表均不存在时可安全视为无历史合作数据'
);
$purge_db->collaboration_request_ids = array();
unset($GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::COLLABORATION_SCHEMA_OPTION]);

$apple_now = time();
$apple_nonce_hash = str_repeat('a', 64);
$GLOBALS['yishu_test_filters']['yishu_fan_apple_data_key'] = static function (): string {
    return hash('sha256', 'contract-test-apple-data-key', true);
};
$GLOBALS['yishu_test_filters']['yishu_fan_apple_identity_verifier'] = static function (
    $value,
    string $token,
    string $expectedNonceHash
) use ($apple_now): array {
    return array(
        'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
        'aud' => Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID,
        'iat' => $apple_now,
        'exp' => $apple_now + 300,
        'sub' => '000123.test-apple-subject',
        'nonce' => $expectedNonceHash,
    );
};
$GLOBALS['yishu_test_filters']['yishu_fan_apple_code_exchange'] = static function (
    $value,
    string $authorizationCode
): array {
    return array(
        'idToken' => 'test-exchanged-identity-token',
        'refreshToken' => 'test-refresh-token-never-persisted-in-plaintext',
    );
};
$verified_apple = invoke_plugin_method('verify_and_exchange_apple_credential', array(
    'test-client-identity-token',
    'test-single-use-authorization-code',
    $apple_nonce_hash,
));
expect_true(
    is_array($verified_apple)
        && preg_match('/^[a-f0-9]{64}$/', (string) ($verified_apple['subjectHash'] ?? '')) === 1
        && (int) ($verified_apple['issuedAt'] ?? 0) === $apple_now
        && ($verified_apple['refreshToken'] ?? '') === 'test-refresh-token-never-persisted-in-plaintext',
    'Apple 认证测试注入必须同时验证 identity token 和单次 authorization code 交换'
);
$wrong_apple_audience = invoke_plugin_method('normalize_verified_apple_claims', array(array(
    'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
    'aud' => array(Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID),
    'iat' => $apple_now,
    'exp' => $apple_now + 300,
    'sub' => '000123.test-apple-subject',
    'nonce' => $apple_nonce_hash,
), $apple_nonce_hash));
expect_error_code(
    'fan_apple_credential_invalid',
    $wrong_apple_audience,
    'Apple identity token audience 必须是唯一的字符串 client ID'
);
$encrypted_refresh = invoke_plugin_method(
    'encrypt_apple_refresh_token',
    array('test-refresh-token-never-persisted-in-plaintext')
);
expect_true(
    is_array($encrypted_refresh)
        && strpos(json_encode($encrypted_refresh), 'test-refresh-token') === false
        && invoke_plugin_method('decrypt_apple_refresh_token', array($encrypted_refresh))
            === 'test-refresh-token-never-persisted-in-plaintext',
    'Apple refresh token 必须使用 authenticated encryption 加密存储'
);
$official_notification_shape = invoke_plugin_method(
    'normalize_fan_apple_notification_claims',
    array(array(
        'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
        'aud' => Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID,
        'iat' => $apple_now,
        'jti' => 'official-event-0001',
        // firebase/php-jwt decodes nested JSON objects as stdClass.
        'events' => (object) array(
            'type' => 'consent-revoked',
            'sub' => '000123.test-apple-subject',
            'event_time' => $apple_now,
        ),
    ), $apple_now)
);
expect_true(
    is_array($official_notification_shape)
        && count($official_notification_shape['events'] ?? array()) === 1
        && ($official_notification_shape['events'][0]['type'] ?? '') === 'consent-revoked'
        && (int) ($official_notification_shape['events'][0]['eventTime'] ?? 0) === $apple_now
        && preg_match(
            '/^[a-f0-9]{64}$/',
            (string) ($official_notification_shape['events'][0]['subjectHash'] ?? '')
        ) === 1,
    'Apple S2S 官方单事件 object 形状必须在验签后归一化'
);

$notification_payload_one = str_repeat('a', 40) . '.' . str_repeat('b', 40) . '.' . str_repeat('c', 40);
$notification_payload_two = str_repeat('d', 40) . '.' . str_repeat('e', 40) . '.' . str_repeat('f', 40);
$GLOBALS['yishu_test_filters']['yishu_fan_apple_notification_verifier'] = static function (
    $value,
    string $payload
) use ($notification_payload_one, $apple_now): array {
    return array(
        'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
        'aud' => Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID,
        'iat' => $apple_now,
        'jti' => $payload === $notification_payload_one
            ? 'contract-durable-event-one'
            : 'contract-durable-event-two',
        'events' => (object) array(
            'type' => 'account-deleted',
            'sub' => '000123.durable-inbox-subject',
            'event_time' => $apple_now,
        ),
    );
};
$GLOBALS['yishu_test_lock_results'] = array(
    'yishu_rate_limit_' => '0',
    'yishu_apple_event_' => '1',
);
$GLOBALS['yishu_test_scheduled'] = array();
$notification_response_one = Shuzijun_App_Content_API::handle_fan_apple_notification(
    new WP_REST_Request(array('payload' => $notification_payload_one))
);
$notification_response_duplicate = Shuzijun_App_Content_API::handle_fan_apple_notification(
    new WP_REST_Request(array('payload' => $notification_payload_one))
);
$notification_response_two = Shuzijun_App_Content_API::handle_fan_apple_notification(
    new WP_REST_Request(array('payload' => $notification_payload_two))
);
$durable_event_options = array_filter(
    $GLOBALS['yishu_test_options'],
    static function ($value, string $key): bool {
        return strpos($key, Shuzijun_App_Content_API::FAN_APPLE_EVENT_OPTION_PREFIX) === 0;
    },
    ARRAY_FILTER_USE_BOTH
);
expect_true(
    $notification_response_one instanceof WP_REST_Response
        && $notification_response_duplicate instanceof WP_REST_Response
        && $notification_response_two instanceof WP_REST_Response
        && count($durable_event_options) === 2
        && count(array_filter(
            $durable_event_options,
            static fn ($record): bool => is_array($record)
                && ($record['status'] ?? '') === 'pending'
        )) === 2,
    '已验签 S2S 必须在限流锁忙时仍入 durable inbox 并 200，重复 jti 幂等，不同 jti 分别持久化'
);
foreach (array_keys($durable_event_options) as $durable_event_option) {
    unset($GLOBALS['yishu_test_options'][$durable_event_option]);
}
$GLOBALS['yishu_test_lock_results'] = array();

// Stateful regression harness for the revoke boundary and durable S2S inbox.
$state_subject_hash = str_repeat('b', 64);
$state_tombstone_name = Shuzijun_App_Content_API::FAN_APPLE_TOMBSTONE_OPTION_PREFIX
    . $state_subject_hash;
$state_event_time = time() - 30;
$state_tombstone = array(
    'version' => 1,
    'eventTime' => $state_event_time,
    'expires' => time() + 3600,
    'generation' => str_repeat('c', 32),
);
$GLOBALS['yishu_test_options'][$state_tombstone_name] = $state_tombstone;
expect_error_code(
    'fan_apple_authorization_revoked',
    invoke_plugin_method(
        'authorize_apple_subject_after_tombstone_under_lock',
        array($state_subject_hash, $state_event_time)
    ),
    'S2S event_time 之前或同时的 Apple 凭据必须持续被拒绝'
);
expect_true(
    invoke_plugin_method(
        'authorize_apple_subject_after_tombstone_under_lock',
        array($state_subject_hash, $state_event_time + 1)
    ) === true
        && invoke_plugin_method(
            'authorize_apple_subject_after_tombstone_under_lock',
            array($state_subject_hash, $state_event_time + 2)
        ) === true
        && ($GLOBALS['yishu_test_options'][$state_tombstone_name] ?? null) === $state_tombstone,
    '真正新 Apple 授权可多次放行，但 tombstone 必须保留到 TTL 以继续拦截旧请求'
);
expect_error_code(
    'fan_apple_authorization_revoked',
    invoke_plugin_method(
        'authorize_apple_subject_after_tombstone_under_lock',
        array($state_subject_hash, $state_event_time - 1)
    ),
    '新授权放行后才进入锁的旧请求仍必须被 tombstone 拒绝'
);
expect_true(
    invoke_plugin_method('apple_event_should_remove_owner', array(200, 100)) === false
        && invoke_plugin_method('apple_event_should_remove_owner', array(100, 100)) === true
        && invoke_plugin_method('apple_event_should_remove_owner', array(50, 100)) === true
        && invoke_plugin_method('apple_event_should_remove_owner', array(0, 100)) === true,
    '延迟 S2S 事件只能删除未使用更新 Apple 凭据重新授权的账号'
);
$GLOBALS['yishu_test_options'][$state_tombstone_name] = array('version' => 1);
expect_error_code(
    'fan_apple_account_conflict',
    invoke_plugin_method(
        'authorize_apple_subject_after_tombstone_under_lock',
        array($state_subject_hash, time())
    ),
    '畸形 tombstone 必须失败关闭且不得自动删除'
);
expect_true(
    array_key_exists($state_tombstone_name, $GLOBALS['yishu_test_options']),
    '畸形 tombstone 需保留等待安全人工处理'
);

$state_event_name = Shuzijun_App_Content_API::FAN_APPLE_EVENT_OPTION_PREFIX
    . str_repeat('d', 64);
$state_event_generation = str_repeat('e', 32);
$state_pending_event = array(
    'version' => 1,
    'status' => 'pending',
    'receivedAt' => time(),
    'events' => array(array(
        'type' => 'account-deleted',
        'subjectHash' => $state_subject_hash,
        'eventTime' => time() - 5,
    )),
    'attempts' => 0,
    'nextAttempt' => time(),
    'generation' => $state_event_generation,
);
$GLOBALS['yishu_test_options'][$state_event_name] = $state_pending_event;
$GLOBALS['yishu_test_scheduled'] = array();
$GLOBALS['yishu_test_lock_result'] = '0';
Shuzijun_App_Content_API::process_fan_apple_event(
    $state_event_name,
    $state_event_generation
);
expect_true(
    ($GLOBALS['yishu_test_options'][$state_event_name] ?? null) === $state_pending_event
        && count(array_filter(
            $GLOBALS['yishu_test_scheduled'],
            static fn ($event): bool => ($event['hook'] ?? '') === 'yishu_process_fan_apple_event'
        )) === 1,
    'S2S inbox 处理锁忙时必须保留 pending 原记录并计划后台重试'
);
$GLOBALS['yishu_test_lock_result'] = '1';
$GLOBALS['yishu_test_scheduled'] = array();
Shuzijun_App_Content_API::cleanup_fan_apple_event(
    $state_event_name,
    $state_event_generation
);
expect_true(
    array_key_exists($state_event_name, $GLOBALS['yishu_test_options'])
        && count(array_filter(
            $GLOBALS['yishu_test_scheduled'],
            static fn ($event): bool => ($event['hook'] ?? '') === 'yishu_process_fan_apple_event'
        )) === 1,
    'pending S2S inbox 不得被 cleanup 删除，只能重新调度处理'
);
$state_processed_event = array(
    'version' => 1,
    'status' => 'processed',
    'processedAt' => time() - 120,
    'expires' => time() - 1,
    'generation' => $state_event_generation,
);
$GLOBALS['yishu_test_options'][$state_event_name] = $state_processed_event;
Shuzijun_App_Content_API::cleanup_fan_apple_event(
    $state_event_name,
    $state_event_generation
);
expect_true(
    !array_key_exists($state_event_name, $GLOBALS['yishu_test_options']),
    '只有 processed 且过了保留期的 S2S marker 才可 cleanup'
);
$state_expired_tombstone = array(
    'version' => 1,
    'eventTime' => time() - 120,
    'expires' => time() - 1,
    'generation' => str_repeat('f', 32),
);
$GLOBALS['yishu_test_options'][$state_tombstone_name] = $state_expired_tombstone;
Shuzijun_App_Content_API::cleanup_fan_apple_tombstone(
    $state_tombstone_name,
    str_repeat('f', 32)
);
expect_true(
    !array_key_exists($state_tombstone_name, $GLOBALS['yishu_test_options']),
    '过期 tombstone 必须按 generation 安全清理'
);
$GLOBALS['yishu_test_lock_result'] = '1';

$valid_permissions = invoke_plugin_method(
    'sanitize_fan_permissions',
    array(array('gallery_full', 'video_view', 'gallery_full'))
);
expect_same(array('gallery_full', 'video_view'), $valid_permissions, '粉丝权限必须去重');
$unknown_permission = invoke_plugin_method(
    'sanitize_fan_permissions',
    array(array('manage_yishu_app_content'))
);
expect_error_code('fan_permission_unknown', $unknown_permission, '粉丝权限不得提权到内容管理');

$temporary_password = invoke_plugin_method('generate_temporary_password');
expect_true(
    is_string($temporary_password)
        && preg_match('/^Tmp-[A-Za-z0-9_-]{24}-9!$/', $temporary_password) === 1,
    '临时密码必须使用固定强随机契约'
);
expect_true(
    invoke_plugin_method('is_invitation_douyin_id', array('invite_' . str_repeat('a', 24))) === true
        && invoke_plugin_method('is_invitation_douyin_id', array('invite_' . str_repeat('a', 23))) === false,
    '邀请占位抖音 ID 必须是 invite_ 加 24 位小写十六进制'
);
$invitation_created = time() - 60;
$normalized_invitation = invoke_plugin_method('normalize_fan_invitation', array(array(
    'createdAt' => gmdate('c', $invitation_created),
    'expiresAt' => gmdate('c', $invitation_created + 86400),
    'createdBy' => 1,
    'generation' => str_repeat('d', 32),
    'preapproved' => true,
    'placeholderDouyinID' => 'invite_' . str_repeat('b', 24),
)));
expect_true(
    is_array($normalized_invitation)
        && $normalized_invitation['expiresTimestamp'] - $normalized_invitation['createdTimestamp'] === 86400,
    '管理员邀请必须严格限定 24 小时'
);
$overlong_invitation = invoke_plugin_method('normalize_fan_invitation', array(array(
    'createdAt' => gmdate('c', $invitation_created),
    'expiresAt' => gmdate('c', $invitation_created + 86401),
    'createdBy' => 1,
    'generation' => str_repeat('e', 32),
    'preapproved' => true,
    'placeholderDouyinID' => 'invite_' . str_repeat('c', 24),
)));
expect_error_code('fan_invitation_invalid', $overlong_invitation, '邀请有效期不得超过 24 小时');

$invitation_meta_start = strpos(
    $plugin_source,
    'self::FAN_META_INVITATION, array(',
    strpos($plugin_source, 'private static function create_single_fan_invitation')
);
$invitation_meta_end = $invitation_meta_start === false
    ? false
    : strpos($plugin_source, 'self::FAN_META_REVIEW, array(', $invitation_meta_start);
$invitation_meta_source = ($invitation_meta_start === false || $invitation_meta_end === false)
    ? ''
    : substr($plugin_source, $invitation_meta_start, $invitation_meta_end - $invitation_meta_start);
expect_true(
    strpos($plugin_source, 'Version: 1.5.13') !== false
        && Shuzijun_App_Content_API::FAN_CAPABILITY === 'manage_yishu_fan_accounts'
        && Shuzijun_App_Content_API::FAN_INVITATION_TTL === 86400
        && Shuzijun_App_Content_API::FAN_ONBOARDING_SESSION_TTL === 600
        && strpos($plugin_source, "'/app-admin/fans/invitations'") !== false
        && substr_count(
            $plugin_source,
            "'permission_callback' => array(__CLASS__, 'can_manage_fans')"
        ) >= 3
        && strpos($plugin_source, "'permission_callback' => array(__CLASS__, 'can_complete_fan_invitation')") !== false,
    '邀请与审批路由必须使用独立粉丝管理权限'
);

$locked_packages = is_array($composer_lock) ? ($composer_lock['packages'] ?? array()) : array();
$jwt_packages = array_values(array_filter($locked_packages, static function ($package): bool {
    return is_array($package) && ($package['name'] ?? '') === 'firebase/php-jwt';
}));
$jwt_loaded = invoke_plugin_method('load_apple_jwt_library');
expect_true(
    count($jwt_packages) === 1 && ($jwt_packages[0]['version'] ?? '') === 'v7.1.0',
    'Apple JWT 依赖必须由 composer.lock 唯一锁定为 firebase/php-jwt 7.1.0'
);
expect_true(
    is_file(dirname(__DIR__) . '/vendor/autoload.php')
        && $jwt_loaded === true
        && class_exists('Firebase\\JWT\\JWT', false)
        && class_exists('Firebase\\JWT\\JWK', false),
    'Apple JWT 验签必须使用已部署的 Composer autoload，不得手写 RSA/JWK'
);
$rsa_fixture = openssl_pkey_new(array(
    'private_key_bits' => 2048,
    'private_key_type' => OPENSSL_KEYTYPE_RSA,
));
$rsa_fixture_private = '';
$rsa_fixture_exported = $rsa_fixture !== false
    && openssl_pkey_export($rsa_fixture, $rsa_fixture_private);
$rsa_fixture_details = $rsa_fixture !== false ? openssl_pkey_get_details($rsa_fixture) : false;
$base64url = static function (string $value): string {
    return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
};
expect_true(
    $rsa_fixture_exported === true
        && is_array($rsa_fixture_details)
        && isset($rsa_fixture_details['rsa']['n'], $rsa_fixture_details['rsa']['e']),
    '合同环境必须能生成本地 RSA 验签回归样本'
);
$GLOBALS['yishu_test_jwks_force_calls'] = 0;
$GLOBALS['yishu_test_filters']['yishu_fan_apple_jwks'] = static function (
    $value,
    bool $forceRefresh
) use (
    $rsa_fixture_details,
    $base64url
): array {
    if ($forceRefresh) {
        $GLOBALS['yishu_test_jwks_force_calls']++;
    }
    return array('keys' => array(
        // An unrelated/future key must not invalidate Apple's usable RS256
        // signing key or poison the last-known-good verifier cache.
        array(
            'kty' => 'EC',
            'kid' => 'future-unrelated-key',
            'use' => 'sig',
            'alg' => 'ES256',
        ),
        array(
            'kty' => 'RSA',
            'kid' => 'contract-rs256-key',
            'use' => 'sig',
            'alg' => 'RS256',
            'n' => $base64url((string) $rsa_fixture_details['rsa']['n']),
            'e' => $base64url((string) $rsa_fixture_details['rsa']['e']),
        )
    ));
};
$signed_fixture_token = Firebase\JWT\JWT::encode(array(
    'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
    'aud' => Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID,
    'iat' => $apple_now,
    'exp' => $apple_now + 300,
    'sub' => '000123.real-rs256-contract-subject',
    'nonce' => $apple_nonce_hash,
), $rsa_fixture_private, 'RS256', 'contract-rs256-key');
$decoded_fixture_claims = invoke_plugin_method(
    'decode_apple_rs256_token',
    array($signed_fixture_token, 'fan_apple_credential_invalid')
);
expect_true(
    is_array($decoded_fixture_claims)
        && ($decoded_fixture_claims['sub'] ?? '') === '000123.real-rs256-contract-subject'
        && $GLOBALS['yishu_test_jwks_force_calls'] === 0,
    '真实 RS256/JWK 本地样本必须通过并确实取得已验签 JWT header'
);
$tampered_fixture_parts = explode('.', $signed_fixture_token);
$tampered_fixture_parts[2] = str_repeat('A', strlen((string) ($tampered_fixture_parts[2] ?? '')));
$tampered_fixture_token = implode('.', $tampered_fixture_parts);
expect_error_code(
    'fan_apple_credential_invalid',
    invoke_plugin_method(
        'decode_apple_rs256_token',
        array($tampered_fixture_token, 'fan_apple_credential_invalid')
    ),
    '已知 kid 的伪造签名必须失败关闭'
);
expect_same(
    0,
    $GLOBALS['yishu_test_jwks_force_calls'],
    '已知 kid 的伪造签名不得触发 JWKS 强制刷新'
);
$unknown_kid_token = Firebase\JWT\JWT::encode(array(
    'iss' => Shuzijun_App_Content_API::FAN_APPLE_ISSUER,
    'aud' => Shuzijun_App_Content_API::FAN_APPLE_CLIENT_ID,
    'iat' => $apple_now,
    'exp' => $apple_now + 300,
    'sub' => '000123.unknown-kid-contract-subject',
), $rsa_fixture_private, 'RS256', 'contract-unknown-key');
expect_error_code(
    'fan_apple_credential_invalid',
    invoke_plugin_method(
        'decode_apple_rs256_token',
        array($unknown_kid_token, 'fan_apple_credential_invalid', false)
    ),
    '限流错误路径的未知 kid 必须仅用当前密钥失败关闭'
);
expect_same(
    0,
    $GLOBALS['yishu_test_jwks_force_calls'],
    '限流错误路径的未知 kid 不得触发 JWKS 强制刷新'
);
expect_error_code(
    'fan_apple_credential_invalid',
    invoke_plugin_method(
        'decode_apple_rs256_token',
        array($unknown_kid_token, 'fan_apple_credential_invalid', true)
    ),
    '普通认证路径的未知 kid 刷新后仍无匹配密钥时必须失败关闭'
);
expect_same(
    1,
    $GLOBALS['yishu_test_jwks_force_calls'],
    '只有未知 kid 可触发一次受控 JWKS 强制刷新'
);
if (function_exists('sodium_memzero') && $rsa_fixture_private !== '') {
    sodium_memzero($rsa_fixture_private);
}

$apple_challenge_start = strpos($plugin_source, 'public static function create_fan_apple_challenge');
$apple_challenge_end = strpos($plugin_source, 'public static function authenticate_fan_with_apple', $apple_challenge_start);
$apple_challenge_source = ($apple_challenge_start === false || $apple_challenge_end === false)
    ? ''
    : substr($plugin_source, $apple_challenge_start, $apple_challenge_end - $apple_challenge_start);
$apple_delete_start = strpos($plugin_source, 'public static function delete_fan_apple_account');
$apple_delete_end = strpos($plugin_source, 'public static function handle_fan_apple_notification', $apple_delete_start);
$apple_delete_source = ($apple_delete_start === false || $apple_delete_end === false)
    ? ''
    : substr($plugin_source, $apple_delete_start, $apple_delete_end - $apple_delete_start);
$apple_login_start = strpos($plugin_source, 'private static function login_or_create_apple_fan');
$apple_login_end = strpos($plugin_source, 'private static function fan_apple_onboarding_response', $apple_login_start);
$apple_login_source = ($apple_login_start === false || $apple_login_end === false)
    ? ''
    : substr($plugin_source, $apple_login_start, $apple_login_end - $apple_login_start);
$apple_onboarding_payload_source = plugin_method_source(
    $plugin_source,
    'fan_apple_onboarding_payload'
);
$normalized_apple_migration_setup = invoke_plugin_method(
    'normalize_fan_apple_setup',
    array(array(
        'version' => 1,
        'generation' => str_repeat('a', 32),
        'createdAt' => gmdate('c'),
        'douyinMigration' => true,
    ))
);
expect_true(
    is_array($normalized_apple_migration_setup)
        && !empty($normalized_apple_migration_setup['douyinMigration'])
        && strpos($apple_login_source, "'douyinMigration' => true") !== false
        && $apple_onboarding_payload_source !== ''
        && strpos($apple_onboarding_payload_source, "'isDouyinMigration' => \$is_douyin_migration") !== false
        && strpos($apple_onboarding_payload_source, "'displayName' => ''") !== false
        && strpos($apple_onboarding_payload_source, "'preservedStatus' => null") !== false
        && strpos($apple_onboarding_payload_source, "array('pending', 'active', 'rejected', 'suspended')") !== false
        && strpos($apple_registration_completion_source, "\$is_douyin_migration") !== false
        && strpos($apple_registration_completion_source, 'sanitize_fan_permissions') !== false
        && strpos($apple_registration_completion_source, 'FAN_META_STATUS') !== false
        && strpos($apple_registration_completion_source, 'FAN_META_PERMISSIONS') !== false
        && strpos($apple_registration_completion_source, "array('gallery_full', 'video_view')") !== false,
    'Apple 存量空抖音 ID 迁移必须保留已校验状态与权限，新账号仍使用安全默认权限'
);
$apple_s2s_delete_start = strpos($plugin_source, 'private static function remove_fan_for_apple_subject_hash');
$apple_s2s_delete_end = strpos($plugin_source, 'public static function can_delete_fan_account', $apple_s2s_delete_start);
$apple_s2s_delete_source = ($apple_s2s_delete_start === false || $apple_s2s_delete_end === false)
    ? ''
    : substr($plugin_source, $apple_s2s_delete_start, $apple_s2s_delete_end - $apple_s2s_delete_start);
$apple_notification_start = strpos($plugin_source, 'public static function handle_fan_apple_notification');
$apple_notification_end = strpos($plugin_source, 'private static function remove_fan_for_apple_subject_hash', $apple_notification_start);
$apple_notification_source = ($apple_notification_start === false || $apple_notification_end === false)
    ? ''
    : substr($plugin_source, $apple_notification_start, $apple_notification_end - $apple_notification_start);
$apple_event_worker_start = strpos($plugin_source, 'public static function process_fan_apple_event');
$apple_event_worker_end = strpos($plugin_source, 'public static function cleanup_fan_apple_event', $apple_event_worker_start);
$apple_event_worker_source = ($apple_event_worker_start === false || $apple_event_worker_end === false)
    ? ''
    : substr($plugin_source, $apple_event_worker_start, $apple_event_worker_end - $apple_event_worker_start);
$revocation_queue_start = strpos($plugin_source, 'private static function queue_fan_apple_revocation');
$revocation_queue_end = strpos($plugin_source, 'public static function retry_fan_apple_revocation', $revocation_queue_start);
$revocation_queue_source = ($revocation_queue_start === false || $revocation_queue_end === false)
    ? ''
    : substr($plugin_source, $revocation_queue_start, $revocation_queue_end - $revocation_queue_start);
expect_true(
    strpos($plugin_source, "'/fan/apple-challenge'") !== false
        && strpos($plugin_source, "'/fan/apple-auth'") !== false
        && strpos($plugin_source, "'/fan/complete-apple-registration'") !== false
        && strpos($plugin_source, "'/fan/apple-complete-profile'") === false
        && strpos($plugin_source, "'/fan/apple-delete'") !== false
        && strpos($plugin_source, "'/fan/apple-notifications'") !== false
        && $apple_challenge_source !== ''
        && strpos($apple_challenge_source, "'nonceHash' => hash('sha256', \$nonce)") !== false
        && strpos($apple_challenge_source, "'stateHash' => hash('sha256', \$state)") !== false
        && strpos($apple_challenge_source, "'installHash' => hash('sha256', \$install_id)") !== false
        && strpos($plugin_source, 'consume_fan_apple_challenge') !== false
        && strpos($plugin_source, 'private static function acquire_named_fan_lock_with_timeout') !== false
        && strpos($plugin_source, 'SELECT GET_LOCK(%s, %d)') !== false,
    'Apple challenge 必须服务端生成、绑定安装/state/purpose 并原子单次消费'
);
expect_true(
    strpos($plugin_source, "'https://appleid.apple.com/auth/token'") !== false
        && strpos($plugin_source, "'grant_type' => 'authorization_code'") !== false
        && strpos($plugin_source, "'https://appleid.apple.com/auth/keys'") !== false
        && strpos($plugin_source, "JWK::parseKeySet(\$filtered, 'RS256')") !== false
        && strpos($plugin_source, "(string) (\$headers->alg ?? '') !== 'RS256'") !== false
        && strpos($plugin_source, 'Version: 1.5.13') !== false,
    'Apple 认证必须强制 authorization code 交换并用 RS256/JWKS 严格验证'
);
$apple_jwks_start = strpos($plugin_source, 'private static function fetch_apple_jwk_keys');
$apple_jwks_end = strpos($plugin_source, 'private static function decode_apple_rs256_token', $apple_jwks_start);
$apple_jwks_source = ($apple_jwks_start === false || $apple_jwks_end === false)
    ? ''
    : substr($plugin_source, $apple_jwks_start, $apple_jwks_end - $apple_jwks_start);
$apple_decode_start = $apple_jwks_end;
$apple_decode_end = strpos($plugin_source, 'private static function verify_apple_identity_token', $apple_decode_start);
$apple_decode_source = ($apple_decode_start === false || $apple_decode_end === false)
    ? ''
    : substr($plugin_source, $apple_decode_start, $apple_decode_end - $apple_decode_start);
$apple_jwks_parse_position = strpos($apple_jwks_source, 'JWK::parseKeySet');
$apple_jwks_cache_position = strpos($apple_jwks_source, 'set_transient');
expect_true(
    $apple_jwks_source !== ''
        && strpos($apple_jwks_source, 'yishu_fan_apple_jwks_v2') !== false
        && strpos($apple_jwks_source, "(string) (\$key['kty'] ?? '') !== 'RSA'") !== false
        && strpos($apple_jwks_source, 'continue;') !== false
        && strpos($apple_jwks_source, '$allow_remote') !== false
        && strpos($apple_jwks_source, 'acquire_named_fan_lock_with_timeout') !== false
        && strpos($apple_jwks_source, 'yishu_fan_apple_jwks_refresh_state_v1') !== false
        && $apple_jwks_parse_position !== false
        && $apple_jwks_cache_position !== false
        && $apple_jwks_parse_position < $apple_jwks_cache_position,
    'Apple JWKS 只能在筛选且成功解析 RS256 密钥后更新 last-known-good 缓存'
);
expect_true(
    $apple_decode_source !== ''
        && strpos($apple_decode_source, '$allow_force_refresh') !== false
        && strpos($apple_decode_source, '"kid" invalid, unable to lookup correct key') !== false
        && strpos($apple_decode_source, 'refresh_apple_jwk_keys_after_unknown_kid') !== false
        && strpos($apple_decode_source, 'fetch_apple_jwk_keys(false, (bool) $allow_force_refresh)') !== false,
    '仅未知 kid 可单飞强制刷新 JWKS，限流错误路径不得发起外联'
);
expect_true(
    $apple_delete_source !== ''
        && strpos($apple_delete_source, 'verify_and_exchange_apple_credential') !== false
        && strpos($apple_delete_source, "'subjectHash'") !== false
        && strpos($apple_delete_source, 'fan_session_context_is_current_from_database') !== false
        && strpos($apple_delete_source, 'revoke_apple_refresh_token') !== false
        && strpos($apple_delete_source, 'queue_fan_apple_revocation') !== false
        && $revocation_queue_source !== ''
        && strpos($revocation_queue_source, "'encryptedRefreshToken'") !== false
        && strpos($revocation_queue_source, "'userID'") === false
        && strpos($revocation_queue_source, "'douyinID'") === false
        && strpos($revocation_queue_source, "'subjectHash'") === false,
    'Apple 删号必须同主体近期重认证，撤销失败仅进入无法回链用户的加密有界队列'
);
$fresh_revoke_position = strpos(
    $apple_delete_source,
    'revoke_apple_refresh_token($fresh_refresh_token)'
);
$fresh_encrypt_position = strpos(
    $apple_delete_source,
    'encrypt_apple_refresh_token($fresh_refresh_token)'
);
expect_true(
    $fresh_revoke_position !== false
        && $fresh_encrypt_position !== false
        && $fresh_revoke_position < $fresh_encrypt_position
        && strpos($apple_delete_source, 'return $fresh_encrypted') === false
        && strpos($apple_delete_source, "'apple_revocation_queue_unavailable'") !== false,
    'Apple fresh refresh token 必须先尝试撤销，加密或队列故障不得阻断本地删号'
);
$apple_login_tombstone_position = strpos(
    $apple_login_source,
    'authorize_apple_subject_after_tombstone_under_lock'
);
$apple_login_resolve_position = strpos(
    $apple_login_source,
    'resolve_apple_subject_owner_under_lock'
);
$apple_s2s_tombstone_position = strpos(
    $apple_s2s_delete_source,
    'persist_apple_subject_tombstone_under_lock'
);
$apple_s2s_resolve_position = strpos(
    $apple_s2s_delete_source,
    'resolve_apple_subject_owner_under_lock'
);
$apple_local_delete_tombstone_position = strpos(
    $apple_delete_source,
    'persist_apple_subject_tombstone_under_lock'
);
$apple_local_delete_remove_position = strpos($apple_delete_source, 'remove_fan_user');
expect_true(
    $apple_login_source !== ''
        && $apple_s2s_delete_source !== ''
        && strpos($plugin_source, "'issuedAt' => min(") !== false
        && strpos($plugin_source, "'eventTime' => \$event_time") !== false
        && $apple_login_tombstone_position !== false
        && $apple_login_resolve_position !== false
        && $apple_login_tombstone_position < $apple_login_resolve_position
        && $apple_s2s_tombstone_position !== false
        && $apple_s2s_resolve_position !== false
        && $apple_s2s_tombstone_position < $apple_s2s_resolve_position
        && strpos($apple_s2s_delete_source, 'FAN_META_APPLE_AUTH_IAT') !== false
        && strpos($apple_s2s_delete_source, 'apple_event_should_remove_owner') !== false
        && strpos($apple_login_source, 'FAN_META_APPLE_AUTH_IAT') !== false
        && strpos($apple_delete_source, "acquire_named_fan_lock('apple_sub'") !== false
        && $apple_local_delete_tombstone_position !== false
        && $apple_local_delete_remove_position !== false
        && $apple_local_delete_tombstone_position < $apple_local_delete_remove_position
        && strpos($plugin_source, "\$issued_at <= (int) \$tombstone['eventTime']") !== false
        && strpos($plugin_source, "'yishu_cleanup_fan_apple_tombstone'") !== false,
    'Apple S2S 撤销必须在 subject 锁内先写 event_time tombstone，旧 iat 登录不得并发复活账号'
);
$apple_inbox_persist_position = strpos($apple_notification_source, 'add_option($event_option, $record');
$apple_inbox_schedule_position = $apple_inbox_persist_position === false
    ? false
    : strpos(
        $apple_notification_source,
        'schedule_fan_apple_event_record',
        $apple_inbox_persist_position
    );
expect_true(
    $apple_notification_source !== ''
        && $apple_event_worker_source !== ''
        && strpos($apple_notification_source, 'if (is_wp_error($limit)) { return $limit; }') === false
        && strpos($apple_notification_source, '!is_wp_error($limit)') !== false
        && strpos($apple_notification_source, 'A valid Apple-signed event must always reach the durable inbox') !== false
        && $apple_inbox_persist_position !== false
        && $apple_inbox_schedule_position !== false
        && $apple_inbox_persist_position < $apple_inbox_schedule_position
        && strpos($apple_notification_source, "'status' => 'pending'") !== false
        && strpos($apple_notification_source, 'remove_fan_for_apple_subject_hash') === false
        && strpos($apple_event_worker_source, 'remove_fan_for_apple_subject_hash') !== false
        && strpos($apple_event_worker_source, "\$record['nextAttempt'] = time() + \$delay") !== false
        && strpos($apple_event_worker_source, "'status' => 'processed'") !== false
        && strpos($plugin_source, 'public static function ensure_fan_apple_event_schedule') !== false
        && strpos($plugin_source, 'FAN_APPLE_EVENT_CURSOR_OPTION') !== false
        && strpos($plugin_source, 'public static function ensure_fan_apple_tombstone_schedule') !== false
        && strpos($plugin_source, 'FAN_APPLE_TOMBSTONE_CURSOR_OPTION') !== false,
    'Apple S2S 必须先写 durable pending inbox 再响应，后台重试后才转 processed，init sweeper 修复丢失的调度'
);
expect_true(
    strpos($plugin_source, 'FAN_META_APPLE_SUB_HASH') !== false
        && strpos($plugin_source, "hash_hmac(\n            'sha256'") !== false
        && strpos($plugin_source, 'FAN_APPLE_OPTION_PREFIX . $subject_hash') !== false
        && strpos($plugin_source, "FAN_META_STATUS, 'pending'") !== false
        && strpos($plugin_source, 'FAN_META_APPLE_SETUP') !== false
        && strpos($plugin_source, "\$status === 'active'") !== false
        && strpos($plugin_source, "'apple_onboarding'") !== false,
    'Apple sub 必须 HMAC 唯一预留，完成昵称与 consent 后仍须管理员审批'
);
expect_true(
    strpos($plugin_source, 'YISHU_APPLE_DATA_KEY_PATH') !== false
        && strpos($plugin_source, "'yishu/apple-subject/v1'") !== false
        && strpos($plugin_source, "'yishu/apple-refresh/v1'") !== false
        && strpos($plugin_source, 'is_link($configured_path)') !== false
        && strpos($plugin_source, "wp_salt('secure_auth')") === false
        && strpos($plugin_source, "wp_salt('auth')\n        );\n    }\n\n    private static function apple_subject_hash") === false,
    'Apple subject 与 refresh token 必须派生自稳定专用密钥，不得随 WordPress salts 轮换断链'
);
$apple_owner_resolver_start = strpos(
    $plugin_source,
    'private static function valid_apple_subject_owner'
);
$apple_owner_resolver_end = strpos(
    $plugin_source,
    'private static function apple_registration_is_complete',
    $apple_owner_resolver_start
);
$apple_owner_resolver_source = ($apple_owner_resolver_start === false
    || $apple_owner_resolver_end === false)
    ? ''
    : substr(
        $plugin_source,
        $apple_owner_resolver_start,
        $apple_owner_resolver_end - $apple_owner_resolver_start
    );
$apple_owner_core_end = strpos(
    $apple_owner_resolver_source,
    "if (!\$core_valid || \$pending_generation === '')"
);
$apple_owner_core_source = $apple_owner_core_end === false
    ? ''
    : substr($apple_owner_resolver_source, 0, $apple_owner_core_end);
$apple_registration_readiness_start = strpos(
    $plugin_source,
    'private static function apple_registration_is_complete'
);
$apple_registration_readiness_end = strpos(
    $plugin_source,
    'private static function cleanup_partial_apple_user_for_generation',
    $apple_registration_readiness_start
);
$apple_registration_readiness_source = ($apple_registration_readiness_start === false
    || $apple_registration_readiness_end === false)
    ? ''
    : substr(
        $plugin_source,
        $apple_registration_readiness_start,
        $apple_registration_readiness_end - $apple_registration_readiness_start
    );
expect_true(
    $apple_owner_resolver_source !== ''
        && $apple_owner_core_source !== ''
        && strpos($apple_owner_core_source, 'FAN_META_APPLE_SUB_HASH') !== false
        && strpos($apple_owner_core_source, 'fan_account_source') !== false
        && strpos($apple_owner_core_source, 'FAN_META_UUID') === false
        && strpos($apple_owner_core_source, 'FAN_META_STATUS') === false
        && strpos($apple_owner_core_source, 'FAN_META_CREDENTIAL_EPOCH') === false
        && strpos($apple_owner_core_source, 'FAN_META_APPLE_REFRESH_TOKEN') === false
        && strpos($apple_owner_resolver_source, 'valid_encrypted_apple_refresh_token') !== false
        && strpos($apple_owner_resolver_source, 'normalize_fan_apple_setup') !== false
        && strpos($apple_owner_resolver_source, 'FAN_META_CODE') === false
        && strpos($apple_owner_resolver_source, 'FAN_META_DOUYIN_ID') === false
        && strpos($apple_owner_resolver_source, 'FAN_META_CONSENT') === false
        && $apple_registration_readiness_source !== ''
        && strpos($apple_registration_readiness_source, 'FAN_META_CODE') !== false
        && strpos($apple_registration_readiness_source, 'FAN_META_DOUYIN_ID') !== false
        && strpos($apple_registration_readiness_source, 'normalize_required_douyin_id') !== false
        && strpos($apple_registration_readiness_source, "\$douyin_id !== ''") === false
        && strpos($apple_registration_readiness_source, 'FAN_META_CONSENT') !== false
        && strpos($plugin_source, '!self::apple_registration_is_complete($owner)') !== false
        && strpos($plugin_source, '!self::apple_account_runtime_is_valid($owner)') !== false
        && strpos($plugin_source, "'yishu_cleanup_fan_apple_pending_account'") !== false
        && substr_count($plugin_source, 'resolve_apple_subject_owner_under_lock') >= 3,
    'Apple sub 核心所有权只依赖唯一 subject 映射，登录 readiness 与创建中恢复仍失败关闭'
);
$revocation_sweeper_start = strpos(
    $plugin_source,
    'public static function ensure_fan_apple_revocation_schedule'
);
$revocation_sweeper_end = strpos(
    $plugin_source,
    'private static function is_invitation_douyin_id',
    $revocation_sweeper_start
);
$revocation_sweeper_source = ($revocation_sweeper_start === false
    || $revocation_sweeper_end === false)
    ? ''
    : substr(
        $plugin_source,
        $revocation_sweeper_start,
        $revocation_sweeper_end - $revocation_sweeper_start
    );
expect_true(
    $revocation_sweeper_source !== ''
        && strpos($revocation_sweeper_source, 'FAN_APPLE_REVOCATION_CURSOR_OPTION') !== false
        && strpos($revocation_sweeper_source, 'option_name > %s') !== false
        && strpos($revocation_sweeper_source, 'LIMIT 50') !== false
        && strpos($revocation_sweeper_source, 'LIMIT 10') === false
        && strpos($revocation_sweeper_source, '$expires <= $now') !== false,
    'Apple 匿名撤销队列必须轮询全部任务并销毁过期密文，不得被前 10 项遮挡'
);
$apple_session_start = strpos($plugin_source, 'public static function fan_session()');
$apple_session_end = strpos($plugin_source, 'public static function logout_fan()', $apple_session_start);
$apple_session_source = ($apple_session_start === false || $apple_session_end === false)
    ? ''
    : substr($plugin_source, $apple_session_start, $apple_session_end - $apple_session_start);
$fan_admin_profile_start = strpos($plugin_source, 'private static function fan_admin_profile');
$fan_admin_profile_end = strpos($plugin_source, 'public static function secure_rest_response', $fan_admin_profile_start);
$fan_admin_profile_source = ($fan_admin_profile_start === false || $fan_admin_profile_end === false)
    ? ''
    : substr($plugin_source, $fan_admin_profile_start, $fan_admin_profile_end - $fan_admin_profile_start);
$fan_update_start = strpos($plugin_source, 'public static function update_fan_access');
$fan_update_end = strpos($plugin_source, 'private static function authenticate_content_manager', $fan_update_start);
$fan_update_source = ($fan_update_start === false || $fan_update_end === false)
    ? ''
    : substr($plugin_source, $fan_update_start, $fan_update_end - $fan_update_start);
expect_true(
    $apple_session_source !== ''
        && strpos($apple_session_source, "(\$context['scope'] ?? '') === 'apple_onboarding'") !== false
        && strpos($apple_session_source, 'self::fan_apple_onboarding_payload(') !== false
        && strpos($apple_session_source, "array('appleRegistration' => \$registration)") !== false
        && strpos(
            $apple_session_source,
            "} else {\n            \$payload = array('profile' => self::fan_profile"
        ) !== false,
    'Apple onboarding 的 /fan/session 只能返回 appleRegistration，不得与完整 profile 并存'
);
expect_true(
    $fan_admin_profile_source !== ''
        && strpos($fan_admin_profile_source, "'identityCode'") !== false
        && strpos($fan_admin_profile_source, "'douyinID'") !== false
        && strpos($plugin_source, "'accountSource' => \$source") !== false
        && strpos($plugin_source, "'requiresAppleRegistration' => \$source === 'apple'") !== false
        && strpos($plugin_source, 'fan_has_required_douyin_id') !== false
        && $fan_update_source !== ''
        && strpos($fan_update_source, "\$status === 'active'") !== false
        && strpos($fan_update_source, 'FAN_META_APPLE_SETUP') !== false
        && strpos($fan_update_source, 'normalize_required_douyin_id') !== false
        && strpos($fan_update_source, "'fan_account_setup_required'") !== false,
    '管理目录必须标记未完成资料，并拒绝批准未填抖音 ID 的账号'
);
expect_true(
    is_string($backup_proxy_source)
        && strpos($backup_proxy_source, 'location /wp-json/shuzijun/v1/') !== false
        && strpos($backup_proxy_source, 'proxy_pass https://101.43.79.80;') !== false,
    'Apple 在内的整个状态型 API namespace 在备用节点必须继续代理主节点'
);
expect_true(
    is_string($privacy_policy_source)
        && strpos($privacy_policy_source, 'identity token 和 authorization code 仅用于当次验证') !== false
        && strpos($privacy_policy_source, '不会持久化') !== false
        && strpos($privacy_policy_source, '加密的 Apple refresh token') !== false
        && strpos($privacy_policy_source, '最长 7 天后销毁') !== false
        && strpos($privacy_policy_source, '最长 30 天保留') !== false
        && strpos($privacy_policy_source, '旧授权并发重建账号') !== false
        && strpos($privacy_policy_source, 'Apple 是 Apple ID 登录身份验证与通知交付的处理方') !== false
        && strpos($privacy_policy_source, 'Apple Push Notification service（APNs）') !== false
        && strpos($privacy_policy_source, '推送设备绑定最长 90 天') !== false
        && strpos($privacy_policy_source, '推送内容与投递状态最长保留 30 天') !== false
        && strpos($privacy_policy_source, '消息通知是可选功能') !== false
        && strpos($privacy_policy_source, '抖音 ID 是注册') !== false
        && strpos($privacy_policy_source, '未填写时不能完成新账号申请或获得内容访问') !== false
        && strpos($privacy_policy_source, '尚未完成 Apple 账号申请的用户也可删除') !== false
        && strpos($privacy_policy_source, '管理员内容上传') !== false
        && strpos($privacy_policy_source, '照片、视频和封面') !== false
        && strpos($privacy_policy_source, '哈希化网络指纹') !== false
        && strpos($privacy_policy_source, '不用于跟踪或广告') !== false
        && strpos($privacy_policy_source, 'mailto:369476120@qq.com') !== false
        && strpos($privacy_policy_source, 'mailto:sariki@me.com') !== false
        && strpos($privacy_policy_source, '合作邀约、待发邮件记录和关联审计') !== false,
    'Build 33 公开隐私政策必须与 Apple 即时验证、加密撤销凭据和自主删除实现一致'
);
$rate_limit_start = strpos($plugin_source, 'private static function rate_limit');
$rate_limit_end = strpos($plugin_source, 'private static function generate_unique_identity_code', $rate_limit_start);
$rate_limit_source = ($rate_limit_start === false || $rate_limit_end === false)
    ? ''
    : substr($plugin_source, $rate_limit_start, $rate_limit_end - $rate_limit_start);
expect_true(
    $rate_limit_source !== ''
        && strpos($rate_limit_source, "acquire_named_fan_lock('rate_limit'") !== false
        && strpos($rate_limit_source, 'get_transient($key)') !== false
        && strpos($rate_limit_source, 'set_transient($key, $count + 1') !== false
        && strpos($rate_limit_source, 'release_named_fan_lock($lock)') !== false,
    '公开 Apple/粉丝认证限流计数必须在跨请求 MySQL 锁内原子更新'
);
expect_true(
    strpos(
        $plugin_source,
        "add_filter('wp_authenticate_user', array(__CLASS__, 'block_fan_wordpress_login')"
    ) !== false
        && strpos($plugin_source, "'fan_wordpress_login_restricted'") !== false
        && strpos($plugin_source, 'self::FAN_META_UUID, true') !== false
        && strpos($plugin_source, 'user_can($user, self::CAPABILITY)') !== false
        && strpos($plugin_source, 'user_can($user, self::FAN_CAPABILITY)') !== false
        && strpos($plugin_source, 'user_can($user, self::PUSH_CAPABILITY)') !== false
        && strpos($plugin_source, 'user_can($user, self::COLLABORATION_CAPABILITY)') !== false,
    '粉丝账号不得使用 WordPress 常规登录，Application Password 只对四类专用管理 capability 开放'
);
expect_true(
    $invitation_meta_source !== ''
        && strpos($invitation_meta_source, 'temporaryPassword') === false
        && strpos($invitation_meta_source, "'createdAt'") !== false
        && strpos($invitation_meta_source, "'expiresAt'") !== false
        && strpos($invitation_meta_source, "'createdBy'") !== false
        && strpos($invitation_meta_source, "'generation'") !== false
        && strpos($invitation_meta_source, "'preapproved'") !== false,
    '服务端只能一次返回临时密码，不得将明文写入邀请 meta'
);
expect_true(
    strpos($plugin_source, "'scope' => \$scope") !== false
        && strpos($plugin_source, "'credentialEpoch' => \$credential_epoch") !== false
        && strpos($plugin_source, "\$credential_epoch !== self::fan_credential_epoch") !== false
        && strpos($plugin_source, "(\$context['scope'] ?? '') !== 'normal'") !== false
        && substr_count($plugin_source, "'requiresAccountSetup'") >= 2
        && substr_count($plugin_source, "'invitationExpiresAt'") >= 2,
    '邀请会话必须有限权 scope、逐请求凭据世代校验和明确的资料状态'
);
expect_true(
    strpos($plugin_source, "add_action('yishu_cleanup_fan_invitation'") !== false
        && strpos($plugin_source, "'yishu_cleanup_fan_invitation'") !== false
        && strpos($plugin_source, "['generation']") !== false
        && strpos($plugin_source, 'wp_schedule_single_event') !== false,
    '每个邀请必须带不可变 generation 并安排自动过期清理'
);
expect_true(
    strpos($plugin_source, 'SELECT GET_LOCK(%s, %d)') !== false
        && strpos($plugin_source, 'acquire_named_fan_lock_with_timeout') !== false
        && strpos($plugin_source, 'SELECT RELEASE_LOCK(%s)') !== false
        && strpos($plugin_source, 'START TRANSACTION') !== false
        && strpos($plugin_source, "query('COMMIT')") !== false
        && strpos($plugin_source, "query('ROLLBACK')") !== false
        && strpos($plugin_source, "\$placeholder = (string) \$invitation['placeholderDouyinID']") !== false
        && substr_count($plugin_source, 'reservation_owner_from_database') >= 3,
    '邀请领取必须使用原子数据库锁、事务和不可变占位预留'
);
$invitation_transaction_method_source = plugin_method_source(
    $plugin_source,
    'complete_fan_invitation'
);
$transaction_start = strpos(
    $invitation_transaction_method_source,
    "query('START TRANSACTION')"
);
$transaction_commit = $transaction_start === false
    ? false
    : strpos(
        $invitation_transaction_method_source,
        "query('COMMIT')",
        $transaction_start
    );
$transaction_source = ($transaction_start === false || $transaction_commit === false)
    ? ''
    : substr(
        $invitation_transaction_method_source,
        $transaction_start,
        $transaction_commit - $transaction_start
    );
expect_true(
    $transaction_source !== ''
        && strpos($transaction_source, 'set_fan_meta_in_transaction') !== false
        && strpos($transaction_source, 'delete_fan_meta_in_transaction') !== false
        && strpos($transaction_source, 'update_user_meta(') === false
        && strpos($transaction_source, 'delete_user_meta(') === false
        && strpos($transaction_source, 'update_option(') === false
        && strpos($transaction_source, 'delete_option(') === false
        && strpos($transaction_source, 'get_user_meta(') === false
        && strpos($transaction_source, 'get_option(') === false
        && strpos($transaction_source, 'wp_update_user(') === false
        && strpos($transaction_source, 'wp_set_password(') === false
        && strpos($transaction_source, 'revoke_all_fan_sessions(') === false,
    '邀请事务内只能直接写 InnoDB，不得在 COMMIT 前写穿 Redis 对象缓存'
);
expect_true(
    strpos($plugin_source, "'Cache-Control', 'private, no-store, max-age=0'") !== false
        && strpos($plugin_source, "'Pragma', 'no-cache'") !== false
        && strpos($plugin_source, 'rest_convert_error_to_response') !== false,
    '邀请凭据成功和错误响应都必须禁止缓存'
);

$recovery_created = time() - 60;
$normalized_recovery = invoke_plugin_method('normalize_fan_password_recovery', array(array(
    'createdAt' => gmdate('c', $recovery_created),
    'expiresAt' => gmdate('c', $recovery_created + 900),
    'createdBy' => 7,
    'generation' => str_repeat('b', 32),
)));
expect_true(
    is_array($normalized_recovery)
        && $normalized_recovery['expiresTimestamp'] - $normalized_recovery['createdTimestamp'] === 900,
    '密码恢复凭据必须严格限定为 15 分钟'
);
$overlong_recovery = invoke_plugin_method('normalize_fan_password_recovery', array(array(
    'createdAt' => gmdate('c', $recovery_created),
    'expiresAt' => gmdate('c', $recovery_created + 901),
    'createdBy' => 7,
    'generation' => str_repeat('b', 32),
)));
expect_error_code(
    'fan_password_recovery_invalid',
    $overlong_recovery,
    '密码恢复凭据不得超过 15 分钟'
);
$claimed_recovery = invoke_plugin_method('normalize_fan_password_recovery', array(array(
    'createdAt' => gmdate('c', $recovery_created),
    'expiresAt' => gmdate('c', $recovery_created + 900),
    'createdBy' => 7,
    'generation' => str_repeat('c', 32),
    'claimedAt' => gmdate('c', $recovery_created + 30),
    'claimedInstallHash' => str_repeat('d', 64),
    'claimNonce' => str_repeat('f', 32),
    'claimedSessionID' => str_repeat('e', 32),
)));
expect_true(
    is_array($claimed_recovery)
        && $claimed_recovery['claimedInstallHash'] === str_repeat('d', 64)
        && $claimed_recovery['claimNonce'] === str_repeat('f', 32)
        && $claimed_recovery['claimedSessionID'] === str_repeat('e', 32),
    '恢复凭据必须能绑定唯一安装与唯一会话'
);
expect_error_code(
    'fan_password_recovery_invalid',
    invoke_plugin_method('normalize_fan_password_recovery', array(array(
        'createdAt' => gmdate('c', $recovery_created),
        'expiresAt' => gmdate('c', $recovery_created + 900),
        'createdBy' => 7,
        'generation' => str_repeat('c', 32),
        'claimedAt' => gmdate('c', $recovery_created + 30),
        'claimedInstallHash' => str_repeat('d', 63),
        'claimNonce' => str_repeat('f', 32),
        'claimedSessionID' => str_repeat('e', 32),
    ))),
    '恢复凭据不得接受不完整的绑定标记'
);
$preliminary_recovery = invoke_plugin_method('normalize_fan_password_recovery', array(array(
    'createdAt' => gmdate('c', $recovery_created),
    'expiresAt' => gmdate('c', $recovery_created + 900),
    'createdBy' => 7,
    'generation' => str_repeat('a', 32),
    'claimedAt' => gmdate('c', $recovery_created + 30),
    'claimedInstallHash' => str_repeat('b', 64),
    'claimNonce' => str_repeat('c', 32),
    'claimedSessionID' => '',
)));
expect_true(
    is_array($preliminary_recovery)
        && $preliminary_recovery['claimedSessionID'] === ''
        && $preliminary_recovery['claimNonce'] === str_repeat('c', 32),
    '先于 token 持久化的安装绑定可以安全重试'
);

$recovery_meta_start = strpos($plugin_source, "\$recovery = array(", strpos(
    $plugin_source,
    'public static function create_fan_password_recovery'
));
$recovery_meta_end = $recovery_meta_start === false
    ? false
    : strpos($plugin_source, '$lock_owner = self::acquire_fan_lock', $recovery_meta_start);
$recovery_meta_source = ($recovery_meta_start === false || $recovery_meta_end === false)
    ? ''
    : substr($plugin_source, $recovery_meta_start, $recovery_meta_end - $recovery_meta_start);
expect_true(
    strpos($plugin_source, "'/app-admin/fans/(?P<uuid>[a-f0-9-]{36})/password-recovery'") !== false
        && strpos($plugin_source, "'/fan/complete-password-recovery'") !== false
        && strpos($plugin_source, "'/fan/change-password'") !== false
        && strpos($plugin_source, "'/fan/sessions'") !== false
        && strpos($plugin_source, "'/fan/sessions/revoke'") !== false
        && strpos($plugin_source, "'permission_callback' => array(__CLASS__, 'can_manage_fans')") !== false
        && strpos($plugin_source, "'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session')") !== false,
    '密码与会话管理路由必须使用管理员专用 capability 或粉丝正常会话'
);
expect_true(
    $recovery_meta_source !== ''
        && strpos($recovery_meta_source, 'temporaryPassword') === false
        && strpos($recovery_meta_source, "'createdAt'") !== false
        && strpos($recovery_meta_source, "'expiresAt'") !== false
        && strpos($recovery_meta_source, "'createdBy'") !== false
        && strpos($recovery_meta_source, "'generation'") !== false
        && strpos($plugin_source, 'self::FAN_META_PASSWORD_RECOVERY,') !== false
        && strpos($plugin_source, 'self::FAN_META_CREDENTIAL_EPOCH,') !== false
        && strpos($plugin_source, 'self::revoke_all_fan_sessions($user_id);') !== false,
    '恢复凭据只能返回一次，不得持久化明文，并必须旋转凭据世代和撤销旧会话'
);
expect_true(
    strpos($plugin_source, "'password_recovery'") !== false
        && strpos($plugin_source, 'FAN_PASSWORD_RECOVERY_SESSION_TTL') !== false
        && substr_count($plugin_source, "'requiresPasswordChange'") >= 2
        && substr_count($plugin_source, "'passwordRecoveryExpiresAt'") >= 2
        && strpos($plugin_source, "'sessionID' => \$session_id") !== false
        && strpos($plugin_source, "'installationCode' => \$install_code") !== false
        && strpos($plugin_source, "'isCurrent'") !== false,
    '恢复会话必须有限权 scope，设备列表只返回不含 token/hash 的公开会话字段'
);
$recovery_login_start = strpos($plugin_source, 'private static function login_recovering_fan');
$recovery_login_end = strpos($plugin_source, 'public static function can_access_fan_session', $recovery_login_start);
$recovery_login_source = ($recovery_login_start === false || $recovery_login_end === false)
    ? ''
    : substr($plugin_source, $recovery_login_start, $recovery_login_end - $recovery_login_start);
expect_true(
    $recovery_login_source !== ''
        && strpos($recovery_login_source, 'fan_password_matches_database')
            < strpos($recovery_login_source, 'normalize_fan_password_recovery')
        && strpos($recovery_login_source, "'claimedInstallHash'") !== false
        && strpos($recovery_login_source, "'claimNonce'") !== false
        && strpos($recovery_login_source, "'claimedSessionID'") !== false
        && strpos($recovery_login_source, 'revoke_fan_session_by_public_id') !== false
        && strpos($recovery_login_source, 'hash_equals') !== false
        && strpos($recovery_login_source, 'update_user_meta_verified')
            < strpos($recovery_login_source, 'issue_fan_session'),
    '恢复登录必须先恒定校验密码，再原子绑定且只签发一个恢复会话'
);
$recovery_completion_start = strpos($plugin_source, 'public static function complete_fan_password_recovery');
$recovery_completion_end = strpos($plugin_source, 'public static function change_fan_password', $recovery_completion_start);
$recovery_completion_source = ($recovery_completion_start === false || $recovery_completion_end === false)
    ? ''
    : substr($plugin_source, $recovery_completion_start, $recovery_completion_end - $recovery_completion_start);
expect_true(
    $recovery_completion_source !== ''
        && substr_count($recovery_completion_source, "'claimedSessionID'") >= 2
        && substr_count($recovery_completion_source, "'claimedInstallHash'") >= 2
        && strpos($recovery_completion_source, "'claimNonce'") !== false
        && strpos(
            $recovery_completion_source,
            "fan_session_context_is_current_from_database(\n                    \$context,\n                    'password_recovery'"
        ) !== false
        && strpos($plugin_source, 'FAN_SESSION_OPTION_PREFIX . $token_hash') !== false
        && strpos($plugin_source, 'maybe_unserialize($serialized_session)') !== false
        && strpos($plugin_source, "(\$fresh_session['credentialEpoch'] ?? 1)") !== false,
    '密码恢复必须在用户锁内重读 token option，并复核 claim、安装和凭据世代'
);
$deletion_start = strpos($plugin_source, 'public static function delete_fan_account');
$deletion_end = strpos($plugin_source, 'public static function create_fan_invitations', $deletion_start);
$deletion_source = ($deletion_start === false || $deletion_end === false)
    ? ''
    : substr($plugin_source, $deletion_start, $deletion_end - $deletion_start);
expect_true(
    strpos($plugin_source, "'/fan/delete'") !== false
        && strpos(
            $plugin_source,
            "'permission_callback' => array(__CLASS__, 'can_delete_fan_account')"
        ) !== false
        && strpos($plugin_source, "'fan_delete_failure'") !== false
        && strpos($plugin_source, "'fan_delete_net'") !== false
        && strpos($plugin_source, "get_param('currentPassword')") !== false
        && strpos($plugin_source, "get_param('installID')") !== false
        && $deletion_source !== ''
        && strpos($deletion_source, "\$scope === 'normal'") !== false
        && strpos($deletion_source, "\$scope === 'onboarding'") !== false
        && strpos($deletion_source, "\$scope === 'password_recovery'") !== false
        && strpos($deletion_source, 'fan_session_context_is_current_from_database') !== false
        && strpos($deletion_source, 'fan_password_matches_database') !== false
        && strpos($deletion_source, "'deleteMarkerGeneration'") !== false,
    '永久删除必须按 normal/onboarding/recovery scope 在锁内重验 marker、会话、安装、当前密码与限流'
);
expect_true(
    is_string($fan_smoke_source)
        && strpos($fan_smoke_source, 'mktemp -d /tmp/yishu-fan-api-smoke.XXXXXX') !== false
        && strpos(
            $fan_smoke_source,
            '^/tmp/yishu-fan-api-smoke\\.[A-Za-z0-9]+$'
        ) !== false
        && strpos($fan_smoke_source, 'rm -rf -- "$test_dir"') !== false,
    '生产 smoke 的一次性凭据文件必须仅在校验过的专用 mktemp 目录中整体清理'
);

$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
$_SERVER['HTTP_X_YISHU_CLIENT_IP'] = '203.0.113.24';
expect_same(
    hash('sha256', '203.0.113.24|https://www.shuzijun.com.cn/'),
    invoke_plugin_method('request_network_fingerprint'),
    '回环代理必须使用边缘层覆盖的真实客户端地址'
);
$_SERVER['REMOTE_ADDR'] = '198.51.100.40';
$_SERVER['HTTP_X_YISHU_CLIENT_IP'] = '203.0.113.99';
expect_same(
    hash('sha256', '198.51.100.40|https://www.shuzijun.com.cn/'),
    invoke_plugin_method('request_network_fingerprint'),
    '非受信来源不得伪造真实客户端地址'
);
unset($_SERVER['HTTP_X_YISHU_CLIENT_IP']);
expect_true(
    is_string($backup_proxy_source)
        && strpos($backup_proxy_source, 'set $yishu_client_ip $remote_addr;') !== false
        && strpos(
            $backup_proxy_source,
            'if ($remote_addr ~ ^(?:127\\.0\\.0\\.1|::1)$)'
        ) !== false
        && strpos(
            $backup_proxy_source,
            'set $yishu_client_ip $http_x_yishu_client_ip;'
        ) !== false
        && strpos(
            $backup_proxy_source,
            'proxy_set_header X-Yishu-Client-IP $yishu_client_ip;'
        ) !== false
        && strpos(
            $backup_proxy_source,
            'proxy_set_header X-Yishu-Client-IP $http_x_yishu_client_ip;'
        ) === false,
    '备用 www 仅允许内部回环链路保留客户端地址头'
);
expect_true(
    is_string($plugin_source)
        && strpos($plugin_source, 'FAN_SESSION_OPTION_PREFIX') !== false
        && strpos($plugin_source, 'get_option(self::FAN_SESSION_OPTION_PREFIX') !== false
        && strpos($plugin_source, "get_transient('yishu_fan_session_") === false,
    '粉丝会话哈希必须持久化，不能仅依赖 Redis 临时缓存'
);
expect_true(
    is_string($plugin_source)
        && strpos($plugin_source, 'FAN_META_INSTALLATIONS') !== false
        && strpos($plugin_source, 'resolve_install_code') !== false,
    '同一安装的记录码必须稳定保存'
);
expect_true(
    is_string($plugin_source)
        && strpos($plugin_source, "FAN_META_STATUS, 'pending'") !== false
        && strpos($plugin_source, "'permission_callback' => array(__CLASS__, 'can_access_app_content')") !== false
        && strpos($plugin_source, "'fan_approval_pending'") !== false
        && strpos($plugin_source, "array('pending', 'active', 'rejected', 'suspended')") !== false
        && strpos($plugin_source, "'Vary', 'Authorization, X-Yishu-Install-ID'") !== false
        && substr_count($plugin_source, "'Cache-Control', 'private, no-store, max-age=0'") >= 2,
    '新注册账号必须待审批，内容清单必须绑定已批准会话'
);

$fragment_url = invoke_plugin_method(
    'trusted_media_url',
    array('https://img.shuzijun.com.cn/images/a.webp#hidden')
);
expect_same('', $fragment_url, '带片段的媒体 URL 必须拒绝');

$optional_empty = invoke_plugin_method('sanitize_optional_media_url', array(null));
expect_same(null, $optional_empty, '关于页照片应允许清空');
$optional_invalid = invoke_plugin_method(
    'sanitize_optional_media_url',
    array('https://example.com/private.jpg')
);
expect_error_code('invalid_about_portrait', $optional_invalid, '关于页照片必须限制媒体域名');

$heroes = invoke_plugin_method(
    'sanitize_image_urls',
    array(
        array(
            'https://img.shuzijun.com.cn/images/hero.webp',
            'https://img.shuzijun.com.cn/images/hero.webp',
        ),
        5,
    )
);
expect_same(1, count($heroes), '主页重复图片必须去重');

$poster = valid_launch_poster('same-id');
$duplicate_posters = invoke_plugin_method(
    'sanitize_launch_posters',
    array(array($poster, $poster))
);
expect_error_code('duplicate_launch_poster', $duplicate_posters, '开屏海报 ID 必须唯一');

$overlong_poster = valid_launch_poster('long-copy');
$overlong_poster['subtitle'] = str_repeat('长', 241);
$overlong_result = invoke_plugin_method('sanitize_launch_posters', array(array($overlong_poster)));
expect_error_code('invalid_launch_poster', $overlong_result, '开屏文案必须限制长度');

$duplicate_dramas = invoke_plugin_method(
    'sanitize_dramas',
    array(array(valid_drama('same-id'), valid_drama('same-id')))
);
expect_error_code('duplicate_drama', $duplicate_dramas, '影视履历 ID 必须唯一');

$malformed_drama = invoke_plugin_method('sanitize_dramas', array(array('not-an-object')));
expect_error_code('invalid_drama', $malformed_drama, '影视履历不得静默忽略畸形项目');

$defaults = invoke_plugin_method('default_config');
$showreel_with_long_tag = $defaults['showreel'];
$showreel_with_long_tag['tags'] = array(str_repeat('长', 81));
$showreel_result = invoke_plugin_method(
    'sanitize_showreel',
    array($showreel_with_long_tag, $defaults['showreel'])
);
expect_error_code('showreel_tag_too_long', $showreel_result, 'Showreel 标签必须限制长度');
$showreel_with_invalid_tag = $defaults['showreel'];
$showreel_with_invalid_tag['tags'] = array(array('nested'));
$invalid_tag_result = invoke_plugin_method(
    'sanitize_showreel',
    array($showreel_with_invalid_tag, $defaults['showreel'])
);
expect_error_code('invalid_showreel_tag', $invalid_tag_result, 'Showreel 标签必须拒绝嵌套值');

$poster_with_invalid_date = valid_launch_poster('invalid-date');
$poster_with_invalid_date['startsAt'] = array('nested');
$invalid_date_result = invoke_plugin_method(
    'sanitize_launch_posters',
    array(array($poster_with_invalid_date))
);
expect_error_code('invalid_launch_poster', $invalid_date_result, '开屏日期必须拒绝嵌套值');

$valid_custom_hero = 'https://img.shuzijun.com.cn/images/custom-hero.webp';
$GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::OPTION_CONFIG] = array(
    'heroImages' => array($valid_custom_hero),
    'aboutPortraitURL' => 'https://example.com/injected.jpg',
    'launchPosters' => array(valid_launch_poster('duplicate'), valid_launch_poster('duplicate')),
    'showreel' => array('videoURL' => 'https://example.com/video.m3u8'),
    'dramas' => array(valid_drama('duplicate'), valid_drama('duplicate')),
);
$recovered_config = invoke_plugin_method('config');
expect_same(array($valid_custom_hero), $recovered_config['heroImages'], '有效模块不应被其他损坏模块覆盖');
expect_same(null, $recovered_config['aboutPortraitURL'], '损坏的关于页地址应回退默认值');
expect_same($defaults['launchPosters'], $recovered_config['launchPosters'], '损坏的开屏配置应独立回退');
expect_same($defaults['showreel'], $recovered_config['showreel'], '损坏的 Showreel 应独立回退');
expect_same($defaults['dramas'], $recovered_config['dramas'], '损坏的影视履历应独立回退');

require __DIR__ . '/push-worker-result-regression.php';
@unlink($authority_test_path);
fwrite(STDOUT, "plugin-contract-test: passed\n");
