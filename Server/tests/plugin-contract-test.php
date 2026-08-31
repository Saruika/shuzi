<?php
declare(strict_types=1);

// Minimal WordPress-compatible harness for the plugin's pure validation layer.
// It intentionally does not connect to a database, network service or live site.
define('ABSPATH', __DIR__ . '/');

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
class WP_REST_Request {}
class WP_REST_Response {}

$GLOBALS['yishu_test_options'] = array();

function add_action(...$args): void {}
function add_filter(...$args): void {}
function apply_filters(string $hook, $value, ...$args) { return $value; }
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function get_option(string $name, $default = false) {
    return array_key_exists($name, $GLOBALS['yishu_test_options'])
        ? $GLOBALS['yishu_test_options'][$name]
        : $default;
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
$backup_proxy_source = file_get_contents(
    dirname(__DIR__) . '/nginx/shuzijun-account-api-backup-proxy.conf'
);

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
    strpos($plugin_source, 'Version: 1.5.6') !== false
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
    strpos($plugin_source, 'SELECT GET_LOCK(%s, 0)') !== false
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
