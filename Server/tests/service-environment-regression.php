<?php
declare(strict_types=1);

// Pure execution of the real delivery trait. No WordPress installation, DB,
// photo download, mail, device token or network provider is used.
define('ABSPATH', __DIR__ . '/');
$mode = $argv[1] ?? 'unset';
if (!in_array($mode, array('unset', 'production', 'review', 'invalid', 'wrong-home'), true)) {
    throw new RuntimeException('Unknown fixture mode');
}
if ($mode !== 'unset') {
    define('YISHU_APP_SERVICE_ENVIRONMENT', $mode === 'wrong-home' ? 'review' : $mode);
}
$home = $mode === 'review' ? 'https://review.shuzijun.com.cn' : 'https://www.shuzijun.com.cn';
$stored = array();
$filter_calls = 0;
$checks = 0;
set_error_handler(static function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});
class WP_Error { public function __construct(...$arguments) {} }
function is_wp_error($value) { return $value instanceof WP_Error; }
function wp_parse_url($url, $component = -1) { return parse_url($url, $component); }
function home_url($path = '/') { global $home; return $home . $path; }
function get_option($key, $default = false) { global $stored; return $stored; }
function esc_url_raw($value, $protocols = null) { return trim((string) $value); }
function sanitize_text_field($value) { return trim(strip_tags((string) $value)); }
function sanitize_key($value) { return preg_replace('/[^a-z0-9_-]/', '', strtolower((string) $value)); }
function rest_sanitize_boolean($value) { return (bool) $value; }
function wp_json_encode($value, $flags = 0) { return json_encode($value, $flags | JSON_THROW_ON_ERROR); }
function apply_filters($name, $value) {
    global $filter_calls;
    $filter_calls++;
    // Model an inherited filter that incorrectly adds another source.
    return array_merge($value, array('other.example.invalid'));
}
require_once dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php';
class DeliveryEnvironmentFixture {
    use Shuzijun_App_Content_Delivery;
    const OPTION_CONFIG = 'fixture-only';
    private static function text_length($value) { return mb_strlen((string) $value); }
    private static function is_uuid_v4($value) {
        return is_string($value) && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $value) === 1;
    }
    public static function invoke($name, ...$arguments) { return self::$name(...$arguments); }
}
function check($condition, $label) {
    global $checks;
    if (!$condition) { throw new RuntimeException($label); }
    $checks++;
}
$production = in_array($mode, array('unset', 'production'), true);
$review = $mode === 'review';
$config = DeliveryEnvironmentFixture::invoke('config');
check(count($config['heroImages']) === ($production ? 3 : 0), 'Default heroes stay in their environment');
check(count($config['launchPosters']) === ($production ? 3 : 0), 'No production poster fallback in review');
check(is_array($config['showreel']) === $production, 'Review has no unconfigured showreel');
foreach (array('www.shuzijun.com.cn', 'shuzijun.com.cn', 'img.shuzijun.com.cn', 'other.example.invalid') as $host) {
    $url = 'https://' . $host . '/image.webp';
    check((DeliveryEnvironmentFixture::invoke('trusted_media_url', $url) === $url) === $production,
        'Review cannot accept production or filter-added media');
}
$url = 'https://review.shuzijun.com.cn/image.webp';
check((DeliveryEnvironmentFixture::invoke('trusted_media_url', $url) === $url) === $review,
    'Only a correctly configured review host accepts its media');
foreach (array('http://review.shuzijun.com.cn/x', 'https://review.shuzijun.com.cn:444/x',
    'https://0@review.shuzijun.com.cn/x', 'https://:@review.shuzijun.com.cn/x',
    'https://review.shuzijun.com.cn:0/x',
    'https://review.shuzijun.com.cn/x#',
    'https://someone@review.shuzijun.com.cn/x', 'https://review.shuzijun.com.cn/x#secret',
    'https://review.shuzijun.com.cn.other.invalid/x') as $unsafe) {
    check(DeliveryEnvironmentFixture::invoke('trusted_media_url', $unsafe) === '', 'Malformed source rejected: ' . $unsafe);
}
if (!$production) { check($filter_calls === 0, 'Filters cannot broaden isolated source policy'); }

$stored = array('heroImages' => array('https://img.shuzijun.com.cn/old.webp'),
    'aboutPortraitURL' => 'https://www.shuzijun.com.cn/old.webp',
    'showreel' => array('videoURL' => 'https://www.shuzijun.com.cn/old.mp4',
        'posterURL' => 'https://www.shuzijun.com.cn/old.webp'));
$revalidated = DeliveryEnvironmentFixture::invoke('config');
check(($revalidated['aboutPortraitURL'] !== null) === $production, 'Stored portrait revalidated');
check(is_array($revalidated['showreel']) === $production, 'Stored video cannot revive foreign defaults');
check(count($revalidated['heroImages']) === ($production ? 1 : 0), 'Stored hero sources revalidated');

if ($review) {
    $stored = array('heroImages' => array($url), 'aboutPortraitURL' => $url,
        'showreel' => array('videoURL' => 'https://review.shuzijun.com.cn/showreel.mp4',
            'posterURL' => $url, 'title' => 'Review clip', 'tags' => array('Fixture')));
    $configured = DeliveryEnvironmentFixture::invoke('config');
    check($configured['heroImages'] === array($url), 'Review administrator can configure heroes');
    check($configured['showreel']['title'] === 'Review clip', 'Null default does not break first video configuration');
    check($configured['showreel']['tags'] === array('Fixture'), 'Configured video metadata retained');
}
$message = array('public_id' => '11111111-2222-4333-8444-555555555555', 'is_sensitive' => 1,
    'title' => 'private fixture title', 'body' => 'private fixture text');
$payload = DeliveryEnvironmentFixture::invoke('push_apns_payload', $message);
if ($mode === 'invalid' || $mode === 'wrong-home') {
    check($payload === null, 'Unknown environment cannot emit notification');
} else {
    $decoded = json_decode($payload, true, 512, JSON_THROW_ON_ERROR);
    check(($decoded['serviceEnvironment'] ?? null) === ($production ? null : 'review'), 'Push routing environment is explicit only in review');
    check($decoded['aps']['alert']['body'] === '有新消息，请登录查看', 'Sensitive body stays out of APNs');
    check(count($decoded) === ($production ? 2 : 3), 'No identity or private payload fields added');
}
echo "service-environment-regression ($mode): $checks checks passed\n";
