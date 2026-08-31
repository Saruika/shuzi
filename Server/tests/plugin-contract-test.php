<?php
declare(strict_types=1);

// Minimal WordPress-compatible harness for the plugin's pure validation layer.
// It intentionally does not connect to a database, network service or live site.
define('ABSPATH', __DIR__ . '/');
define('WP_ENVIRONMENT_TYPE', 'local');
define('YISHU_APPLE_TEST_MODE', true);
define('HOUR_IN_SECONDS', 3600);
define('DAY_IN_SECONDS', 86400);
define('MINUTE_IN_SECONDS', 60);

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

    public function __construct(array $parameters = array(), array $headers = array()) {
        $this->parameters = $parameters;
        $this->headers = array_change_key_case($headers, CASE_LOWER);
    }

    public function get_param(string $name) { return $this->parameters[$name] ?? null; }
    public function get_header(string $name): string {
        return (string) ($this->headers[strtolower($name)] ?? '');
    }
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

$GLOBALS['yishu_test_options'] = array();
$GLOBALS['yishu_test_filters'] = array();
$GLOBALS['yishu_test_scheduled'] = array();
$GLOBALS['yishu_test_lock_result'] = '1';
$GLOBALS['yishu_test_lock_results'] = array();

final class Yishu_Test_WPDB {
    public string $options = 'wp_options';
    public string $last_error = '';

    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }

    public function get_var($prepared) {
        if (!is_array($prepared)) { return null; }
        $query = (string) ($prepared['query'] ?? '');
        $arguments = (array) ($prepared['arguments'] ?? array());
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
        return null;
    }
}

$GLOBALS['wpdb'] = new Yishu_Test_WPDB();

function add_action(...$args): void {}
function add_filter(...$args): void {}
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
function wp_cache_delete(...$args): bool { return true; }
function rest_ensure_response($value): WP_REST_Response {
    return $value instanceof WP_REST_Response ? $value : new WP_REST_Response($value);
}
function wp_schedule_single_event($timestamp, string $hook, array $args = array(), bool $wp_error = false) {
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
function rest_sanitize_boolean($value): bool {
    if (is_string($value)) {
        return !in_array(strtolower($value), array('false', '0', ''), true);
    }
    return (bool) $value;
}

require dirname(__DIR__) . '/shuzijun-app-content.php';

$plugin_source = file_get_contents(dirname(__DIR__) . '/shuzijun-app-content.php');
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

function expect_true(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "plugin-contract-test: {$message}\n");
        exit(1);
    }
}

function expect_same($expected, $actual, string $message): void {
    expect_true($expected === $actual, $message);
}

function expect_error_code(string $code, $actual, string $message): void {
    expect_true($actual instanceof WP_Error, $message . '（未返回 WP_Error）');
    expect_same($code, $actual->get_error_code(), $message . '（错误代码不符）');
}

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
    strpos($plugin_source, 'Version: 1.5.8') !== false
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
        && strpos($plugin_source, 'Version: 1.5.8') !== false,
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
    'Apple sub 必须 HMAC 唯一预留，补齐抖音与 consent 后仍须管理员审批'
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
        && strpos($apple_session_source, "array('appleRegistration' => array(") !== false
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
        && strpos($plugin_source, "'requiresAppleRegistration' => \$source === 'apple' && !empty(\$setup)") !== false
        && $fan_update_source !== ''
        && strpos($fan_update_source, "\$status === 'active'") !== false
        && strpos($fan_update_source, 'FAN_META_APPLE_SETUP') !== false
        && strpos($fan_update_source, "'fan_account_setup_required'") !== false,
    '管理目录只显示 Apple 来源/完成状态，未补齐抖音的 Apple 账号不得被提前激活'
);
expect_true(
    is_string($backup_proxy_source)
        && strpos($backup_proxy_source, 'location ^~ /wp-json/shuzijun/v1/') !== false
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
        && strpos($privacy_policy_source, 'Apple 是 Apple ID 登录身份验证的处理方') !== false
        && strpos($privacy_policy_source, '尚未补填抖音 ID 的 Apple 待完成申请也可删除') !== false,
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
        && strpos($plugin_source, 'user_can($user, self::FAN_CAPABILITY)') !== false,
    '粉丝账号不得使用 WordPress 常规登录，subscriber 不得获得 Application Password'
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
$transaction_start = strpos($plugin_source, "query('START TRANSACTION')");
$transaction_commit = $transaction_start === false
    ? false
    : strpos($plugin_source, "query('COMMIT')", $transaction_start);
$transaction_source = ($transaction_start === false || $transaction_commit === false)
    ? ''
    : substr($plugin_source, $transaction_start, $transaction_commit - $transaction_start);
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

fwrite(STDOUT, "plugin-contract-test: passed\n");
