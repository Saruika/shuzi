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
