<?php
declare(strict_types=1);

// Real publication trait, synthetic WordPress only. No network, accounts or production storage.
define('ABSPATH', __DIR__ . '/synthetic-wordpress-not-loaded/');
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-public-experience.php';
final class WP_Post {
    public function __construct(public int $ID, public string $post_type = 'portfolio',
        public string $post_status = 'publish') {}
}
final class WP_Error {}
final class PublicResponse {
    public array $headers = array();
    public function __construct(public array $data) {}
    public function header($key, $value) { $this->headers[$key] = $value; }
}
$posts = array(10 => new WP_Post(10), 11 => new WP_Post(11));
$attachments = array(); $metadata = array(); $image_sources = array(); $meta = array();
$allow = true; $authority = true; $nonce_valid = true; $revision = false; $autosave = false;
$actor = 9; $locks = 0; $marked = 0; $writes = 0; $filters = array(); $sizes = array(); $checks = 0;
function check_public($condition, $message) {
    global $checks; $checks++;
    if (!$condition) { throw new RuntimeException($message); }
}
function get_posts($args) { global $posts; return array_values($posts); }
function get_post($id) { global $posts, $attachments; return $posts[$id] ?? $attachments[$id] ?? null; }
function get_post_meta($id, $key, $single = true) { global $meta; return $meta[$id][$key] ?? ''; }
function update_post_meta($id, $key, $value) { global $meta, $writes; $meta[$id][$key] = $value; $writes++; return true; }
function get_children($args) { return array(); }
function get_option($name, $default) { return 1000; }
function absint($value) { return abs((int) $value); }
function wp_attachment_is_image($id) { global $attachments; return isset($attachments[$id]); }
function wp_get_attachment_metadata($id) { global $metadata; return $metadata[$id] ?? false; }
function wp_get_attachment_image_src($id, $size) { global $image_sources; return $image_sources[$id][$size] ?? false; }
function wp_get_attachment_image_url($id, $size) { return 'https://img.shuzijun.com.cn/original-' . $id . '.jpg'; }
function wp_get_original_image_url($id) { return wp_get_attachment_image_url($id, 'full'); }
function wp_parse_url($url, $part) { return parse_url($url, $part); }
function sanitize_text_field($text) { return strip_tags((string) $text); }
function wp_html_excerpt($text, $limit, $suffix) { return mb_substr($text, 0, $limit) . (mb_strlen($text) > $limit ? $suffix : ''); }
function rest_ensure_response($value) { return new PublicResponse($value); }
function current_user_can(...$args) { global $allow; return $allow; }
function wp_is_post_revision($id) { global $revision; return $revision; }
function wp_is_post_autosave($id) { global $autosave; return $autosave; }
function wp_verify_nonce(...$args) { global $nonce_valid; return $nonce_valid; }
function wp_unslash($value) { return $value; }
function wp_json_encode($value) { return json_encode($value); }
function get_current_user_id() { global $actor; return $actor; }
function clean_user_cache($id) {}
function wp_set_current_user($id) { global $actor; $actor = $id; }
function is_wp_error($value) { return $value instanceof WP_Error; }
function add_filter($hook, $callback) { global $filters; $filters[$hook] = $callback; }
function add_image_size(...$args) { global $sizes; $sizes[] = $args; }
final class PublicHarness {
    use Shuzijun_App_Public_Experience;
    const CAPABILITY = 'fixture_manage';
    const OPTION_UPDATED = 'fixture_updated';
    public static function account_authority_enabled() { global $authority; return $authority; }
    private static function portfolio_is_visible($id) { return get_post_meta($id, '_app_is_hidden') !== '1'; }
    private static function portfolio_metadata($post) { return array('title' => get_post_meta($post->ID, 'test_title') ?: 'Album ' . $post->ID,
        'subtitle' => get_post_meta($post->ID, 'test_subtitle') ?: 'Description'); }
    private static function trusted_media_url($url) {
        return is_string($url) && str_starts_with($url, 'https://img.shuzijun.com.cn/') ? $url : '';
    }
    private static function acquire_editorial_publication_lock() { global $locks; $locks++; return 'publication'; }
    private static function acquire_fan_lock($id) { global $locks; $locks++; return 'actor'; }
    private static function release_named_fan_lock($name) { global $locks; $locks--; }
    private static function release_fan_lock($id, $name) { global $locks; $locks--; }
    private static function mark_updated() { global $marked; $marked++; }
}
function install_public_image($id, $width = 1600, $height = 2400) {
    global $attachments, $metadata, $image_sources, $meta;
    $attachments[$id] = new WP_Post($id, 'attachment', 'inherit');
    $meta[$id] = array('_wp_attached_file' => '2026/original-' . $id . '.jpg', '_wp_attachment_image_alt' => 'Photo ' . $id);
    $metadata[$id] = array('file' => '2026/original-' . $id . '.jpg', 'width' => $width, 'height' => $height,
        'sizes' => array('large' => array('file' => 'preview-' . $id . '.jpg', 'width' => 1024, 'height' => 1536)));
    $image_sources[$id]['large'] = array('https://img.shuzijun.com.cn/wp-content/uploads/preview-' . $id . '.jpg', 1024, 1536, true);
}
foreach (range(1, 8) as $id) { install_public_image($id); }
$meta[10]['_portfolio_gallery'] = json_encode(range(1, 8));
$meta[11]['_portfolio_gallery'] = json_encode(array(8));
$payload = static fn() => PublicHarness::get_public_experience()->data;
check_public($payload()['albums'] === array(), 'all existing albums default private');
check_public($payload()['contentAudience'] === 'public', 'distinct public audience');
check_public(array_keys($payload()) === array('schemaVersion', 'contentAudience', 'updatedAt', 'albums'), 'closed root DTO');
$meta[10]['_yishu_public_preview_media'] = array(2, 1);
$result = $payload();
check_public(array_column($result['albums'][0]['images'], 'id') === array(2, 1), 'only explicit selected IDs in saved order');
check_public(array_keys($result['albums'][0]) === array('id', 'title', 'subtitle', 'images'), 'closed album DTO');
check_public(array_keys($result['albums'][0]['images'][0]) === array('id', 'url', 'altText'), 'no original or private fields');
check_public(!str_contains(json_encode($result), 'original-'), 'never exposes original URL');
check_public(PublicHarness::get_public_experience()->headers['Cache-Control'] === 'no-store, max-age=0', 'no shared caching');
$posts = array_reverse($posts, true);
check_public(count($payload()['albums']) === 1 && $payload()['albums'][0]['id'] === 10, 'reordering does not opt in another album');
$meta[10]['_app_is_hidden'] = '1';
check_public($payload()['albums'] === array(), 'hidden album omitted');
$meta[10]['_app_is_hidden'] = '';
$posts[10]->post_status = 'draft';
check_public($payload()['albums'] === array(), 'draft album omitted even with selected IDs');
$posts[10]->post_status = 'publish';
$meta[10]['_portfolio_gallery'] = json_encode(array(1));
check_public(array_column($payload()['albums'][0]['images'], 'id') === array(1), 'removed membership cannot remain publicly exposed');
$meta[10]['_portfolio_gallery'] = json_encode(range(1, 8));
$meta[10]['_yishu_public_preview_media'] = array(1);
$saved_source = $image_sources[1]['large'];
$image_sources[1]['large'][3] = false;
check_public($payload()['albums'] === array(), 'original fallback from WordPress rejected');
$image_sources[1]['large'] = $saved_source;
$metadata[1]['sizes']['large']['width'] = 500;
check_public($payload()['albums'] === array(), 'cropped/wrong dimension preview rejected');
install_public_image(1);
$metadata[1]['sizes']['large']['height'] = 1800;
check_public($payload()['albums'] === array(), 'oversized derivative rejected');
install_public_image(1);
$meta[1]['_wp_attached_file'] = 'replacement.jpg';
check_public($payload()['albums'] === array(), 'stale attachment metadata rejected');
install_public_image(1);
$metadata[1]['width'] = 'broken';
check_public($payload()['albums'] === array(), 'malformed original dimensions fail closed');
install_public_image(1);
foreach (array('https://img.shuzijun.com.cn/preview-1.jpg',
    'https://img.shuzijun.com.cn/wp-content/uploads/preview-1.jpg?token=not-a-secret',
    'https://img.shuzijun.com.cn/wp-content/uploads/../preview-1.jpg',
    'https://img.shuzijun.com.cn/wp-content/uploads/%2e%2e/preview-1.jpg') as $bad_url) {
    $image_sources[1]['large'][0] = $bad_url;
    check_public($payload()['albums'] === array(), 'public URLs reject paths and queries outside the client contract');
}
install_public_image(1);
$image_sources[1]['large'][0] = 'https://other.invalid/preview-1.jpg';
check_public($payload()['albums'] === array(), 'untrusted host rejected');
install_public_image(1);
$attachments[1]->post_status = 'trash';
check_public($payload()['albums'] === array(), 'trashed media rejected');
$attachments[1]->post_status = 'inherit';
foreach (array(array('1'), array(1, 1), range(1, 7), 'bad') as $invalid) {
    $meta[10]['_yishu_public_preview_media'] = $invalid;
    check_public($payload()['albums'] === array(), 'malformed saved selection fails closed');
}
$meta[10]['_yishu_public_preview_media'] = array();
$save = static function ($ids, $expected = null) use (&$meta, &$posts) {
    $_POST = array('yishu_public_experience_present' => '1', 'yishu_public_experience_nonce' => 'synthetic-nonce',
        'yishu_public_experience_revision' => $expected ?? hash('sha256', json_encode($meta[10]['_yishu_public_preview_media'])),
        'yishu_public_experience_images' => $ids);
    PublicHarness::save_public_experience_selection(10, $posts[10], true);
};
$allow = false; $save(array('1'));
check_public($writes === 0, 'non-administrator cannot select public photos');
$allow = true; $nonce_valid = false; $save(array('1'));
check_public($writes === 0, 'invalid nonce rejected');
$nonce_valid = true; $authority = false; $save(array('1'));
check_public($writes === 0, 'standby cannot write selection');
$authority = true; $revision = true; $save(array('1'));
check_public($writes === 0, 'revision save does not opt in');
$revision = false; $autosave = true; $save(array('1'));
check_public($writes === 0, 'autosave does not opt in');
$autosave = false;
foreach (array(array('1', '1'), array('0'), array('-1'), array('1x'), array(array('1')), array_map('strval', range(1, 7)), array('99')) as $invalid) {
    $save($invalid);
    check_public($writes === 0 && $locks === 0, 'invalid selection rejected and locks released');
}
$save(array('1'), str_repeat('0', 64));
check_public($writes === 0 && $locks === 0, 'stale editor rejected');
$save(array('2', '1'));
check_public($writes === 1 && $marked === 1 && $locks === 0, 'explicit selection stored under locks');
check_public($meta[10]['_yishu_public_preview_media'] === array(2, 1), 'integer fixed IDs stored, no dynamic rank');
$save(array('2', '1'));
check_public($writes === 1, 'idempotent selection unchanged');
$meta[10]['test_title'] = str_repeat('标题', 100);
$meta[10]['test_subtitle'] = str_repeat('说明', 300);
$meta[1]['_wp_attachment_image_alt'] = str_repeat('照片', 300);
$bounded = $payload()['albums'][0];
check_public(mb_strlen($bounded['title']) === 160 && mb_strlen($bounded['subtitle']) === 400
    && mb_strlen($bounded['images'][1]['altText']) === 400, 'public text bounded without changing member originals');
check_public(mb_strlen($meta[10]['test_title']) === 200, 'original title untouched');
$saved_posts = $posts;
foreach (range(100, 140) as $id) {
    $posts[$id] = new WP_Post($id);
    $meta[$id]['_yishu_public_preview_media'] = array(1);
    $meta[$id]['_portfolio_gallery'] = json_encode(array(1));
}
check_public(count($payload()['albums']) === 30, 'public catalogue cannot exceed 30 albums');
$posts = $saved_posts;
$save(array());
check_public($writes === 2 && $payload()['albums'] === array(), 'clear selection revokes public exposure');
PublicHarness::register_public_preview_image_size();
check_public($sizes === array(array('yishu-public-preview', 1600, 1600, false)), 'future upload derivative is uncropped 1600px');
echo "Public experience regression: $checks checks passed.\n";
