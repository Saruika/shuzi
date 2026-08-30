<?php
/**
 * Plugin Name: Shuzijun App Content API
 * Description: Versioned public content feed and least-privilege mobile publishing API for the Yi Shu app.
 * Version: 1.4.1
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

final class Shuzijun_App_Content_API {
    const OPTION_CONFIG = 'shuzijun_app_content_config';
    const OPTION_UPDATED = 'shuzijun_app_content_updated_at';
    const CAPABILITY = 'manage_yishu_app_content';
    const ROLE = 'yishu_content_manager';
    const FREE_PREVIEW_COUNT = 3;
    const FULL_GALLERY_FOR_APP = true;

    public static function init() {
        add_action('init', array(__CLASS__, 'ensure_roles'), 20);
        add_action('rest_api_init', array(__CLASS__, 'register_routes'));
        add_action('save_post_portfolio', array(__CLASS__, 'portfolio_changed'), 20, 3);
        add_action('template_redirect', array(__CLASS__, 'block_public_portfolio_pages'), 1);
        add_action('pre_get_posts', array(__CLASS__, 'hide_public_portfolio_queries'));
        add_action('wp_head', array(__CLASS__, 'hide_public_portfolio_section'));
        add_filter('rest_post_dispatch', array(__CLASS__, 'secure_rest_response'), 10, 3);
        add_filter('rest_pre_dispatch', array(__CLASS__, 'block_public_catalog_routes'), 10, 3);
        add_filter('wp_sitemaps_post_types', array(__CLASS__, 'remove_portfolios_from_sitemaps'));
        add_filter('theme_mod_hero_cta', array(__CLASS__, 'public_hero_cta'));
        add_filter('theme_mod_hero_cta_link', array(__CLASS__, 'public_hero_cta_link'));

        // Application Passwords are revocable, per-client credentials intended
        // for HTTPS REST clients. Keep the site's global disable policy and
        // restrict the dedicated content credential to this plugin's routes.
        add_filter('wp_is_application_passwords_available_for_user', array(__CLASS__, 'application_passwords_for_user'), 20, 2);
    }

    public static function ensure_roles() {
        $role = get_role(self::ROLE);
        if (!$role) {
            add_role(self::ROLE, '易姝 App 内容管理员', array(
                'read' => true,
                'upload_files' => true,
                self::CAPABILITY => true,
            ));
            $role = get_role(self::ROLE);
        }
        if ($role) {
            if (!$role->has_cap('read')) { $role->add_cap('read', true); }
            if (!$role->has_cap('upload_files')) { $role->add_cap('upload_files', true); }
            if (!$role->has_cap(self::CAPABILITY)) { $role->add_cap(self::CAPABILITY, true); }
        }
        $administrator = get_role('administrator');
        if ($administrator && !$administrator->has_cap(self::CAPABILITY)) {
            $administrator->add_cap(self::CAPABILITY, true);
        }
    }

    public static function application_passwords_for_user($available, $user) {
        return $user instanceof WP_User && user_can($user, self::CAPABILITY);
    }

    public static function register_routes() {
        register_rest_route('shuzijun/v1', '/app-content', array(
            array(
                'methods' => WP_REST_Server::READABLE,
                'callback' => array(__CLASS__, 'get_content'),
                'permission_callback' => '__return_true',
            ),
            array(
                'methods' => WP_REST_Server::EDITABLE,
                'callback' => array(__CLASS__, 'update_content'),
                'permission_callback' => array(__CLASS__, 'can_manage'),
            ),
        ));

        register_rest_route('shuzijun/v1', '/app-admin/session', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'session'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));

        register_rest_route('shuzijun/v1', '/app-content/premium', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'get_premium_content'),
            'permission_callback' => array(__CLASS__, 'can_access_premium'),
        ));

        register_rest_route('shuzijun/v1', '/app-content/portfolio/(?P<id>\d+)/gallery', array(
            'methods' => WP_REST_Server::EDITABLE,
            'callback' => array(__CLASS__, 'update_gallery'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
            'args' => array(
                'id' => array('required' => true, 'sanitize_callback' => 'absint'),
            ),
        ));

        register_rest_route('shuzijun/v1', '/app-content/portfolio', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_portfolio'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
    }

    public static function can_manage($request = null) {
        if (!self::authenticate_content_manager($request)) { return false; }
        if (!$request instanceof WP_REST_Request || $request->get_method() === 'GET') { return true; }

        // Bound authenticated mutation bursts by WordPress user, not by a
        // spoofable forwarding IP. Normal app publishing is far below this.
        $key = 'yishu_app_rate_' . get_current_user_id();
        $count = (int) get_transient($key);
        if ($count >= 120) {
            return new WP_Error(
                'yishu_rate_limited',
                '操作过于频繁，请稍后再试。',
                array('status' => 429)
            );
        }
        set_transient($key, $count + 1, MINUTE_IN_SECONDS);
        return true;
    }

    private static function authenticate_content_manager($request) {
        if (current_user_can(self::CAPABILITY)) { return true; }
        if (!$request instanceof WP_REST_Request) { return false; }

        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Basic\\s+([A-Za-z0-9+\\/=]{8,4096})$/', $authorization, $matches)) {
            return false;
        }
        $decoded = base64_decode($matches[1], true);
        if ($decoded === false || strlen($decoded) > 4096 || strpos($decoded, ':') === false) {
            return false;
        }
        list($username, $password) = explode(':', $decoded, 2);
        if (!$username || !$password || strlen($username) > 120 || strlen($password) > 256) {
            return false;
        }
        // A security plugin disables Application Passwords globally. Enable
        // verification only for this capability-scoped check, then immediately
        // restore the site's global policy.
        add_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        $user = wp_authenticate_application_password(null, $username, $password);
        remove_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        if (is_wp_error($user) || !$user instanceof WP_User || !user_can($user, self::CAPABILITY)) {
            return false;
        }
        wp_set_current_user($user->ID);
        return true;
    }

    public static function secure_rest_response($result, $server, $request) {
        if (!$request instanceof WP_REST_Request || strpos($request->get_route(), '/shuzijun/v1/') !== 0) {
            return $result;
        }
        if (is_wp_error($result)) { return $result; }
        $response = rest_ensure_response($result);
        $response->header('X-Content-Type-Options', 'nosniff');
        $response->header('X-Frame-Options', 'DENY');
        $response->header('Referrer-Policy', 'no-referrer');
        $response->header('X-Robots-Tag', 'noindex, nofollow');
        if ($request->get_route() !== '/shuzijun/v1/app-content' || $request->get_method() !== 'GET') {
            $response->header('Cache-Control', 'private, no-store');
        }
        return $response;
    }

    public static function block_public_catalog_routes($result, $server, $request) {
        if ($result !== null || !$request instanceof WP_REST_Request
            || self::authenticate_content_manager($request)) {
            return $result;
        }
        $route = $request->get_route();
        if (preg_match('#^/wp/v2/(portfolio|media)(?:/|$)#', $route)) {
            return new WP_Error('rest_no_route', '未找到匹配 URL 和请求方式的路由。', array('status' => 404));
        }
        return $result;
    }

    public static function block_public_portfolio_pages() {
        if (current_user_can(self::CAPABILITY)) { return; }
        // Attachment pages reveal the original upload URL and can remain in
        // search indexes even after a portfolio page is removed. The website
        // does not use attachment pages, so fail closed for all visitors.
        if (!is_singular('portfolio') && !is_post_type_archive('portfolio') && !is_attachment()) {
            return;
        }
        global $wp_query;
        $wp_query->set_404();
        status_header(404);
        nocache_headers();
        wp_die(
            esc_html__('此内容仅在易姝 App 内提供。', 'shuzijun'),
            esc_html__('页面不可用', 'shuzijun'),
            array('response' => 404)
        );
    }

    public static function remove_portfolios_from_sitemaps($post_types) {
        unset($post_types['portfolio']);
        return $post_types;
    }

    public static function hide_public_portfolio_queries($query) {
        if (is_admin() || current_user_can(self::CAPABILITY)
            || (defined('REST_REQUEST') && REST_REQUEST)) {
            return;
        }
        $post_type = $query->get('post_type');
        $is_portfolio_query = $post_type === 'portfolio'
            || (is_array($post_type) && in_array('portfolio', $post_type, true));
        if ($is_portfolio_query) {
            $query->set('post__in', array(0));
        }
    }

    public static function hide_public_portfolio_section() {
        if (current_user_can(self::CAPABILITY)) { return; }
        echo '<style id="yishu-private-portfolio">#portfolio{display:none!important}</style>';
    }

    public static function public_hero_cta($value) {
        return current_user_can(self::CAPABILITY) ? $value : '合作邀约';
    }

    public static function public_hero_cta_link($value) {
        return current_user_can(self::CAPABILITY) ? $value : '#contact';
    }

    public static function can_access_premium(WP_REST_Request $request) {
        if (self::authenticate_content_manager($request)) { return true; }

        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Bearer\\s+([A-Za-z0-9._-]+)$/', $authorization, $matches)) {
            return new WP_Error('premium_credential_required', '需要有效的 Apple 订阅凭证。', array('status' => 401));
        }
        $jws = $matches[1];
        if (strlen($jws) < 100 || strlen($jws) > 16384) {
            return new WP_Error('premium_credential_invalid', 'Apple 订阅凭证无效。', array('status' => 401));
        }
        $cache_key = 'yishu_entitlement_' . hash('sha256', $jws);
        if (get_transient($cache_key) === 'active') { return true; }

        if (!defined('YISHU_ENTITLEMENT_VERIFIER_URL') || !defined('YISHU_ENTITLEMENT_VERIFIER_TOKEN')) {
            return new WP_Error('premium_verifier_unavailable', '订阅校验服务尚未完成配置。', array('status' => 503));
        }
        $verifier_url = esc_url_raw((string) YISHU_ENTITLEMENT_VERIFIER_URL, array('https', 'http'));
        $verifier_host = strtolower((string) wp_parse_url($verifier_url, PHP_URL_HOST));
        $is_local_verifier = in_array($verifier_host, array('127.0.0.1', 'localhost', '::1'), true);
        if (!$verifier_url || (wp_parse_url($verifier_url, PHP_URL_SCHEME) !== 'https' && !$is_local_verifier)) {
            return new WP_Error('premium_verifier_insecure', '订阅校验服务配置不安全。', array('status' => 503));
        }

        $verification = wp_remote_post($verifier_url, array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array(
                'Content-Type' => 'application/json',
                'Accept' => 'application/json',
                'X-Yishu-Internal-Token' => (string) YISHU_ENTITLEMENT_VERIFIER_TOKEN,
            ),
            'body' => wp_json_encode(array('transactionJWS' => $jws)),
        ));
        if (is_wp_error($verification)) {
            return new WP_Error('premium_verifier_unavailable', '暂时无法校验订阅。', array('status' => 503));
        }
        $status = (int) wp_remote_retrieve_response_code($verification);
        $payload = json_decode((string) wp_remote_retrieve_body($verification), true);
        if ($status !== 200 || !is_array($payload) || empty($payload['active'])) {
            return new WP_Error('premium_entitlement_inactive', '订阅已失效或未通过校验。', array('status' => 403));
        }
        set_transient($cache_key, 'active', 5 * MINUTE_IN_SECONDS);
        return true;
    }

    public static function session() {
        $user = wp_get_current_user();
        $response = rest_ensure_response(array(
            'authenticated' => true,
            'username' => $user->user_login,
            'displayName' => $user->display_name,
            'role' => self::ROLE,
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function get_content($request = null) {
        $audience = self::authenticate_content_manager($request)
            ? 'admin'
            : (self::FULL_GALLERY_FOR_APP ? 'app' : 'public');
        $response = rest_ensure_response(self::manifest($audience));
        $response->header(
            'Cache-Control',
            $audience === 'public'
                ? 'public, max-age=60, stale-while-revalidate=300'
                : 'private, no-store'
        );
        return $response;
    }

    public static function get_premium_content() {
        $response = rest_ensure_response(self::manifest('premium'));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function update_content(WP_REST_Request $request) {
        $current = self::config();
        $incoming_heroes = $request->get_param('heroImages');
        $incoming_about_portrait = $request->get_param('aboutPortraitURL');
        $incoming_launch_posters = $request->get_param('launchPosters');
        $incoming_showreel = $request->get_param('showreel');
        $incoming_dramas = $request->get_param('dramas');

        if (is_array($incoming_heroes)) {
            $heroes = self::sanitize_image_urls($incoming_heroes, 5);
            if (is_wp_error($heroes)) { return $heroes; }
            $current['heroImages'] = $heroes;
        }
        if ($request->has_param('aboutPortraitURL')) {
            $about_portrait = self::sanitize_optional_media_url($incoming_about_portrait);
            if (is_wp_error($about_portrait)) { return $about_portrait; }
            $current['aboutPortraitURL'] = $about_portrait;
        }
        if (is_array($incoming_launch_posters)) {
            $launch_posters = self::sanitize_launch_posters($incoming_launch_posters);
            if (is_wp_error($launch_posters)) { return $launch_posters; }
            $current['launchPosters'] = $launch_posters;
        }
        if (is_array($incoming_showreel)) {
            $showreel = self::sanitize_showreel($incoming_showreel, $current['showreel']);
            if (is_wp_error($showreel)) { return $showreel; }
            $current['showreel'] = $showreel;
        }
        if (is_array($incoming_dramas)) {
            $dramas = self::sanitize_dramas($incoming_dramas);
            if (is_wp_error($dramas)) { return $dramas; }
            $current['dramas'] = $dramas;
        }

        update_option(self::OPTION_CONFIG, $current, false);
        self::mark_updated();
        $response = rest_ensure_response(self::manifest('admin'));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function update_gallery(WP_REST_Request $request) {
        $portfolio_id = absint($request['id']);
        if (get_post_type($portfolio_id) !== 'portfolio') {
            return new WP_Error('portfolio_not_found', '作品集不存在。', array('status' => 404));
        }

        $media_ids = $request->get_param('mediaIDs');
        if (!is_array($media_ids)) {
            return new WP_Error('invalid_media_ids', 'mediaIDs 必须是数组。', array('status' => 400));
        }
        $media_ids = array_values(array_unique(array_filter(array_map('absint', $media_ids))));
        if (count($media_ids) > 300) {
            return new WP_Error('too_many_media', '单个相册最多 300 张照片。', array('status' => 413));
        }
        $current_user_id = get_current_user_id();
        foreach ($media_ids as $media_id) {
            $attachment = get_post($media_id);
            if (!$attachment instanceof WP_Post
                || $attachment->post_type !== 'attachment'
                || $attachment->post_status === 'trash'
                || !wp_attachment_is_image($media_id)) {
                return new WP_Error('invalid_media', '相册只能包含有效图片。', array('status' => 400));
            }
            $already_attached = (int) $attachment->post_parent === $portfolio_id;
            $owns_attachment = (int) $attachment->post_author === $current_user_id;
            if (!$already_attached && !$owns_attachment && !current_user_can('edit_others_posts')) {
                return new WP_Error('media_not_owned', '不能将其他用户的媒体加入相册。', array('status' => 403));
            }
        }

        $previous_ids = json_decode((string) get_post_meta($portfolio_id, '_portfolio_gallery', true), true);
        $previous_ids = array_values(array_unique(array_filter(array_map('absint', (array) $previous_ids))));
        update_post_meta($portfolio_id, '_portfolio_gallery', wp_json_encode($media_ids));
        foreach ($media_ids as $media_id) {
            wp_update_post(array('ID' => $media_id, 'post_parent' => $portfolio_id));
        }
        foreach (array_diff($previous_ids, $media_ids) as $removed_id) {
            if ((int) wp_get_post_parent_id($removed_id) === $portfolio_id) {
                wp_update_post(array('ID' => $removed_id, 'post_parent' => 0));
            }
        }
        self::mark_updated();
        clean_post_cache($portfolio_id);

        $response = rest_ensure_response(array(
            'ok' => true,
            'portfolioID' => $portfolio_id,
            'mediaIDs' => $media_ids,
            'content' => self::manifest('admin'),
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function create_portfolio(WP_REST_Request $request) {
        $title = sanitize_text_field((string) $request->get_param('title'));
        $subtitle = sanitize_text_field((string) $request->get_param('subtitle'));
        $eyebrow = sanitize_text_field((string) $request->get_param('eyebrow'));

        if (!$title) {
            return new WP_Error('portfolio_title_required', '请填写相册名称。', array('status' => 400));
        }
        if (self::text_length($title) > 120 || self::text_length($subtitle) > 240 || self::text_length($eyebrow) > 120) {
            return new WP_Error('portfolio_text_too_long', '相册名称或介绍过长。', array('status' => 400));
        }

        $counts = wp_count_posts('portfolio');
        if ($counts && isset($counts->publish) && (int) $counts->publish >= 100) {
            return new WP_Error('portfolio_limit_reached', '相册数量已达上限。', array('status' => 409));
        }

        $slug = sanitize_title($title);
        if ($slug && get_page_by_path($slug, OBJECT, 'portfolio')) {
            return new WP_Error('portfolio_exists', '同名相册已经存在。', array('status' => 409));
        }

        $portfolio_id = wp_insert_post(array(
            'post_type' => 'portfolio',
            'post_status' => 'publish',
            'post_title' => $title,
            'post_name' => $slug,
            'post_content' => '',
        ), true);
        if (is_wp_error($portfolio_id)) { return $portfolio_id; }

        update_post_meta($portfolio_id, '_app_title', $title);
        update_post_meta($portfolio_id, '_app_subtitle', $subtitle ?: '易姝影像作品');
        update_post_meta($portfolio_id, '_app_eyebrow', $eyebrow ?: 'PORTFOLIO');
        update_post_meta($portfolio_id, '_portfolio_gallery', wp_json_encode(array()));
        self::mark_updated();
        clean_post_cache($portfolio_id);

        $response = new WP_REST_Response(array(
            'ok' => true,
            'portfolioID' => (int) $portfolio_id,
            'content' => self::manifest('admin'),
        ), 201);
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function portfolio_changed($post_id, $post, $update) {
        if (wp_is_post_revision($post_id) || wp_is_post_autosave($post_id)) { return; }
        if ($post instanceof WP_Post && $post->post_status === 'publish') {
            self::mark_updated();
        }
    }

    private static function mark_updated() {
        update_option(self::OPTION_UPDATED, time(), false);
    }

    private static function manifest($audience = 'public') {
        $config = self::config();
        $updated = (int) get_option(self::OPTION_UPDATED, 0);
        if ($updated < 1) { $updated = time(); }
        return array(
            'schemaVersion' => 1,
            'updatedAt' => gmdate('c', $updated),
            'heroImages' => $config['heroImages'],
            'aboutPortraitURL' => $config['aboutPortraitURL'],
            'launchPosters' => $config['launchPosters'],
            'showreel' => $config['showreel'],
            'dramas' => $config['dramas'],
            'portfolios' => self::portfolios($audience),
        );
    }

    private static function config() {
        $stored = get_option(self::OPTION_CONFIG, array());
        if (!is_array($stored)) { $stored = array(); }
        $defaults = self::default_config();

        // Options can outlive several plugin versions or be changed directly
        // in the database. Revalidate every stored field before publishing it;
        // an invalid section falls back independently instead of poisoning the
        // complete manifest consumed by the App.
        $heroes = isset($stored['heroImages']) && is_array($stored['heroImages'])
            ? self::sanitize_image_urls($stored['heroImages'], 5)
            : $defaults['heroImages'];
        if (is_wp_error($heroes)) { $heroes = $defaults['heroImages']; }

        $about_portrait = array_key_exists('aboutPortraitURL', $stored)
            ? self::sanitize_optional_media_url($stored['aboutPortraitURL'])
            : $defaults['aboutPortraitURL'];
        if (is_wp_error($about_portrait)) { $about_portrait = $defaults['aboutPortraitURL']; }

        $launch_posters = isset($stored['launchPosters']) && is_array($stored['launchPosters'])
            ? self::sanitize_launch_posters($stored['launchPosters'])
            : $defaults['launchPosters'];
        if (is_wp_error($launch_posters)) { $launch_posters = $defaults['launchPosters']; }

        $showreel_value = isset($stored['showreel']) && is_array($stored['showreel'])
            ? array_merge($defaults['showreel'], $stored['showreel'])
            : $defaults['showreel'];
        $showreel = self::sanitize_showreel($showreel_value, $defaults['showreel']);
        if (is_wp_error($showreel)) { $showreel = $defaults['showreel']; }

        $dramas = isset($stored['dramas']) && is_array($stored['dramas'])
            ? self::sanitize_dramas($stored['dramas'])
            : $defaults['dramas'];
        if (is_wp_error($dramas)) { $dramas = $defaults['dramas']; }

        return array(
            'heroImages' => $heroes,
            'aboutPortraitURL' => $about_portrait,
            'launchPosters' => $launch_posters,
            'showreel' => $showreel,
            'dramas' => $dramas,
        );
    }

    private static function default_config() {
        $hongguo = 'https://novelquickapp.com/s/wHlfrwqog1g/';
        return array(
            'heroImages' => array(
                'https://img.shuzijun.com.cn/images/hero-mobile-1.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-2.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-3.webp',
            ),
            'aboutPortraitURL' => null,
            'launchPosters' => array(
                array(
                    'id' => 'evergreen',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-launch-qipao-ivory-20260830.jpg',
                    'eyebrow' => 'YI SHU',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
            ),
            'showreel' => array(
                'eyebrow' => 'ACTOR SHOWREEL · 2026',
                'title' => '21 秒演员展映',
                'summary' => '温柔 · 克制 · 东方韵味',
                'durationLabel' => '00:21',
                'videoURL' => home_url('/wp-content/uploads/showreel/hls-20260826a/master.m3u8'),
                'posterURL' => home_url('/wp-content/uploads/showreel/yishu-showreel-poster.jpg?v=20260825e'),
                'tags' => array('古装', '情绪表达', '镜头表现'),
            ),
            'dramas' => array(
                array('id'=>'jingchunye','title'=>'京春夜','imageURL'=>'https://img.shuzijun.com.cn/images/drama-jingchunye.webp','destinationURL'=>$hongguo),
                array('id'=>'wangshengjiudian','title'=>'往生酒店','imageURL'=>'https://img.shuzijun.com.cn/images/drama-wangshengjiudian.webp','destinationURL'=>$hongguo),
                array('id'=>'nianxiadidi','title'=>'年下弟弟俯首称臣','imageURL'=>'https://img.shuzijun.com.cn/images/drama-nianxiadidi.webp','destinationURL'=>$hongguo),
                array('id'=>'xinhunye','title'=>'新婚夜，我和姐姐上错婚车嫁对郎','imageURL'=>'https://img.shuzijun.com.cn/images/drama-xinhunye.webp','destinationURL'=>$hongguo),
                array('id'=>'ouyangxiu','title'=>'遇见，我的欧阳修大人','imageURL'=>'https://img.shuzijun.com.cn/images/drama-ouyangxiu.webp','destinationURL'=>$hongguo),
            ),
        );
    }

    private static function portfolios($audience = 'public') {
        $posts = get_posts(array(
            'post_type' => 'portfolio',
            'post_status' => 'publish',
            'posts_per_page' => 100,
            'orderby' => 'date',
            'order' => 'ASC',
            'no_found_rows' => true,
        ));
        $result = array();
        foreach ($posts as $post) {
            $gallery = json_decode((string) get_post_meta($post->ID, '_portfolio_gallery', true), true);
            if (!is_array($gallery) || !$gallery) {
                $gallery = get_children(array(
                    'post_parent' => $post->ID,
                    'post_type' => 'attachment',
                    'post_mime_type' => 'image',
                    'orderby' => 'ID',
                    'order' => 'ASC',
                    'fields' => 'ids',
                ));
            }
            $images = array();
            foreach (array_values(array_unique(array_filter(array_map('absint', (array) $gallery)))) as $media_id) {
                if (!wp_attachment_is_image($media_id)) { continue; }
                $full = wp_get_attachment_image_url($media_id, 'full');
                $display = wp_get_attachment_image_url($media_id, 'large');
                if (!$full || !self::trusted_media_url($full)) { continue; }
                $attachment_meta = wp_get_attachment_metadata($media_id);
                $attached_file = (string) get_post_meta($media_id, '_wp_attached_file', true);
                $metadata_file = is_array($attachment_meta) && !empty($attachment_meta['file'])
                    ? (string) $attachment_meta['file']
                    : '';
                $large_meta = is_array($attachment_meta) && isset($attachment_meta['sizes']['large'])
                    ? $attachment_meta['sizes']['large']
                    : null;
                if ($attached_file && $metadata_file && basename($attached_file) !== basename($metadata_file)) {
                    $display = $full;
                } elseif (
                    is_array($large_meta)
                    && !empty($attachment_meta['width'])
                    && !empty($attachment_meta['height'])
                    && !empty($large_meta['width'])
                    && !empty($large_meta['height'])
                ) {
                    $full_is_landscape = $attachment_meta['width'] > $attachment_meta['height'];
                    $large_is_landscape = $large_meta['width'] > $large_meta['height'];
                    if ($full_is_landscape !== $large_is_landscape) {
                        $display = $full;
                    }
                }
                $images[] = array(
                    'id' => $media_id,
                    'url' => self::trusted_media_url($display) ? $display : $full,
                    'fullSizeURL' => $full,
                    'altText' => get_post_meta($media_id, '_wp_attachment_image_alt', true) ?: get_the_title($post),
                );
            }
            $total_image_count = count($images);
            // The public website and generic WordPress routes stay closed. The
            // App feed currently exposes the complete gallery while paid
            // subscriptions are paused for TestFlight product testing.
            if ($audience === 'public') {
                $images = array_slice($images, 0, self::FREE_PREVIEW_COUNT);
            } elseif ($audience === 'premium') {
                $protected_images = array();
                foreach ($images as $image) {
                    $display = apply_filters(
                        'shuzijun_app_protected_media_url',
                        '',
                        $image['url'],
                        $image['id'],
                        'display'
                    );
                    $full = apply_filters(
                        'shuzijun_app_protected_media_url',
                        '',
                        $image['fullSizeURL'],
                        $image['id'],
                        'full'
                    );
                    if (!self::trusted_media_url($display) || !self::trusted_media_url($full)) { continue; }
                    $image['url'] = $display;
                    $image['fullSizeURL'] = $full;
                    $protected_images[] = $image;
                }
                $images = $protected_images;
            }
            $metadata = self::portfolio_metadata($post);
            $result[] = array(
                'id' => (int) $post->ID,
                'title' => $metadata['title'],
                'subtitle' => $metadata['subtitle'],
                'eyebrow' => $metadata['eyebrow'],
                'slug' => $post->post_name,
                'websiteURL' => get_permalink($post),
                'coverURL' => $images ? $images[0]['url'] : null,
                'totalImageCount' => $total_image_count,
                'images' => $images,
            );
        }
        return $result;
    }

    private static function portfolio_metadata(WP_Post $post) {
        $title = wp_strip_all_tags(get_the_title($post));
        if (strpos($title, '婚纱') !== false) {
            $fallback = array('title'=>'婚纱','subtitle'=>'在柔光里，留下誓约般的静谧','eyebrow'=>'WEDDING · PORTRAIT');
        } elseif (strpos($title, '新中式') !== false) {
            $fallback = array('title'=>'新中式','subtitle'=>'古意与当代表达之间的留白','eyebrow'=>'NEW CHINESE · EDITORIAL');
        } elseif (strpos($title, '旗袍') !== false) {
            $fallback = array('title'=>'旗袍','subtitle'=>'庭院、窗影与东方美学','eyebrow'=>'QIPAO · STORY');
        } else {
            $fallback = array('title'=>$title,'subtitle'=>'易姝影像作品','eyebrow'=>'PORTFOLIO');
        }
        return array(
            'title' => sanitize_text_field(get_post_meta($post->ID, '_app_title', true) ?: $fallback['title']),
            'subtitle' => sanitize_text_field(get_post_meta($post->ID, '_app_subtitle', true) ?: $fallback['subtitle']),
            'eyebrow' => sanitize_text_field(get_post_meta($post->ID, '_app_eyebrow', true) ?: $fallback['eyebrow']),
        );
    }

    private static function sanitize_showreel($value, $fallback) {
        $video = self::trusted_media_url(isset($value['videoURL']) ? $value['videoURL'] : '');
        $poster = self::trusted_media_url(isset($value['posterURL']) ? $value['posterURL'] : '');
        if (!$video || !$poster) {
            return new WP_Error('invalid_showreel_url', 'Showreel 和海报必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
        }
        $tags = isset($value['tags']) && is_array($value['tags']) ? $value['tags'] : $fallback['tags'];
        $sanitized_tags = array();
        foreach (array_slice(array_values($tags), 0, 8) as $tag) {
            if (!is_scalar($tag)) {
                return new WP_Error('invalid_showreel_tag', 'Showreel 标签格式无效。', array('status' => 400));
            }
            $tag = sanitize_text_field($tag);
            if (self::text_length($tag) > 80) {
                return new WP_Error('showreel_tag_too_long', 'Showreel 标签过长。', array('status' => 400));
            }
            if ($tag !== '' && !in_array($tag, $sanitized_tags, true)) {
                $sanitized_tags[] = $tag;
            }
        }
        $eyebrow = sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : $fallback['eyebrow']);
        $title = sanitize_text_field(isset($value['title']) ? $value['title'] : $fallback['title']);
        $summary = sanitize_text_field(isset($value['summary']) ? $value['summary'] : $fallback['summary']);
        $duration = sanitize_text_field(isset($value['durationLabel']) ? $value['durationLabel'] : $fallback['durationLabel']);
        if (self::text_length($eyebrow) > 120 || self::text_length($title) > 160
            || self::text_length($summary) > 500 || self::text_length($duration) > 20) {
            return new WP_Error('showreel_text_too_long', 'Showreel 文案过长。', array('status' => 400));
        }
        return array(
            'eyebrow' => $eyebrow,
            'title' => $title,
            'summary' => $summary,
            'durationLabel' => $duration,
            'videoURL' => $video,
            'posterURL' => $poster,
            'tags' => $sanitized_tags,
        );
    }

    private static function sanitize_launch_posters($values) {
        if (count($values) > 12) {
            return new WP_Error('too_many_launch_posters', '开屏海报最多 12 张。', array('status' => 400));
        }
        $result = array();
        $seen_ids = array();
        foreach (array_slice(array_values($values), 0, 12) as $index => $value) {
            if (!is_array($value)) {
                return new WP_Error('invalid_launch_poster', '开屏海报格式无效。', array('status' => 400));
            }
            foreach (array('id', 'imageURL', 'eyebrow', 'title', 'subtitle', 'startsAt', 'endsAt') as $field) {
                if (isset($value[$field]) && !is_scalar($value[$field])) {
                    return new WP_Error('invalid_launch_poster', '开屏海报字段格式无效。', array('status' => 400));
                }
            }
            if (isset($value['displaySeconds'])
                && (!is_scalar($value['displaySeconds']) || !is_numeric($value['displaySeconds']))) {
                return new WP_Error('invalid_launch_poster', '开屏海报展示时长格式无效。', array('status' => 400));
            }
            $image = self::trusted_media_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $eyebrow = sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : '');
            $subtitle = sanitize_text_field(isset($value['subtitle']) ? $value['subtitle'] : '');
            $starts_at = isset($value['startsAt']) ? strtotime((string) $value['startsAt']) : false;
            $ends_at = isset($value['endsAt']) ? strtotime((string) $value['endsAt']) : false;
            if (!$image || !$title || self::text_length($title) > 160
                || self::text_length($eyebrow) > 120 || self::text_length($subtitle) > 240
                || $starts_at === false || $ends_at === false || $starts_at >= $ends_at) {
                return new WP_Error(
                    'invalid_launch_poster',
                    '每张开屏海报都需要图片、标题和有效的起止日期。',
                    array('status' => 400)
                );
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'launch-poster-' . ($index + 1); }
            if (self::text_length($id) > 80 || isset($seen_ids[$id])) {
                return new WP_Error('duplicate_launch_poster', '开屏海报 ID 必须唯一且不超过 80 个字符。', array('status' => 400));
            }
            $seen_ids[$id] = true;
            $display_seconds = isset($value['displaySeconds']) ? floatval($value['displaySeconds']) : 2.5;
            if (!is_finite($display_seconds)) { $display_seconds = 2.5; }
            $result[] = array(
                'id' => $id,
                'isEnabled' => isset($value['isEnabled']) ? rest_sanitize_boolean($value['isEnabled']) : true,
                'imageURL' => $image,
                'eyebrow' => $eyebrow,
                'title' => $title,
                'subtitle' => $subtitle,
                'startsAt' => gmdate('c', $starts_at),
                'endsAt' => gmdate('c', $ends_at),
                'displaySeconds' => max(1.5, min(5.0, $display_seconds)),
            );
        }
        return $result;
    }

    private static function sanitize_dramas($values) {
        if (count($values) > 50) {
            return new WP_Error('too_many_dramas', '影视履历最多 50 条。', array('status' => 400));
        }
        $result = array();
        $seen_ids = array();
        foreach (array_slice(array_values($values), 0, 50) as $index => $value) {
            if (!is_array($value)) {
                return new WP_Error('invalid_drama', '影视履历格式无效。', array('status' => 400));
            }
            foreach (array('id', 'title', 'imageURL', 'destinationURL') as $field) {
                if (isset($value[$field]) && !is_scalar($value[$field])) {
                    return new WP_Error('invalid_drama', '影视履历字段格式无效。', array('status' => 400));
                }
            }
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $image = self::trusted_media_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $destination = self::trusted_destination_url(isset($value['destinationURL']) ? $value['destinationURL'] : '');
            if (!$title || self::text_length($title) > 200 || !$image || !$destination) {
                return new WP_Error('invalid_drama', '每部短剧都需要合规标题、受信任海报和 HTTPS 跳转地址。', array('status' => 400));
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'drama-' . ($index + 1); }
            if (self::text_length($id) > 80 || isset($seen_ids[$id])) {
                return new WP_Error('duplicate_drama', '影视履历 ID 必须唯一且不超过 80 个字符。', array('status' => 400));
            }
            $seen_ids[$id] = true;
            $result[] = array('id'=>$id, 'title'=>$title, 'imageURL'=>$image, 'destinationURL'=>$destination);
        }
        return $result;
    }

    private static function sanitize_image_urls($values, $maximum) {
        if (count($values) > $maximum) {
            return new WP_Error('too_many_image_urls', '主页封面数量超过上限。', array('status' => 400));
        }
        $result = array();
        foreach (array_slice(array_values($values), 0, $maximum) as $value) {
            $url = self::trusted_media_url($value);
            if (!$url) {
                return new WP_Error('invalid_image_url', '主页封面必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
            }
            if (!in_array($url, $result, true)) { $result[] = $url; }
        }
        if (!$result) {
            return new WP_Error('missing_hero_image', '至少保留一张主页封面。', array('status' => 400));
        }
        return $result;
    }

    private static function https_url($value) {
        if (!is_string($value)) { return ''; }
        if (strlen((string) $value) > 2048) { return ''; }
        $url = esc_url_raw((string) $value, array('https'));
        if (wp_parse_url($url, PHP_URL_SCHEME) !== 'https') { return ''; }
        if (wp_parse_url($url, PHP_URL_USER) || wp_parse_url($url, PHP_URL_PASS)) { return ''; }
        if (wp_parse_url($url, PHP_URL_FRAGMENT)) { return ''; }
        $port = wp_parse_url($url, PHP_URL_PORT);
        return !$port || (int) $port === 443 ? $url : '';
    }

    private static function sanitize_optional_media_url($value) {
        if ($value === null || $value === '') { return null; }
        if (!is_string($value)) {
            return new WP_Error('invalid_about_portrait', '关于页照片格式无效。', array('status' => 400));
        }
        $url = self::trusted_media_url($value);
        if (!$url) {
            return new WP_Error('invalid_about_portrait', '关于页照片必须使用受信任的 HTTPS 媒体地址。', array('status' => 400));
        }
        return $url;
    }

    private static function trusted_media_url($value) {
        $url = self::https_url($value);
        if (!$url) { return ''; }
        $host = strtolower((string) wp_parse_url($url, PHP_URL_HOST));
        $home_host = strtolower((string) wp_parse_url(home_url('/'), PHP_URL_HOST));
        $hosts = array_filter(array_unique(array(
            $home_host,
            'shuzijun.com.cn',
            'www.shuzijun.com.cn',
            'img.shuzijun.com.cn',
        )));
        $hosts = apply_filters('shuzijun_app_allowed_media_hosts', $hosts);
        $hosts = array_map('strtolower', array_map('strval', (array) $hosts));
        return in_array($host, $hosts, true) ? $url : '';
    }

    private static function trusted_destination_url($value) {
        $url = self::https_url($value);
        if (!$url) { return ''; }
        $host = strtolower((string) wp_parse_url($url, PHP_URL_HOST));
        $hosts = array(
            'novelquickapp.com',
            'www.novelquickapp.com',
            'xhslink.com',
            'www.xhslink.com',
            'v.douyin.com',
            'www.douyin.com',
            'www.xiaohongshu.com',
        );
        $hosts = apply_filters('shuzijun_app_allowed_destination_hosts', $hosts);
        $hosts = array_map('strtolower', array_map('strval', (array) $hosts));
        return in_array($host, $hosts, true) ? $url : '';
    }

    private static function text_length($value) {
        return function_exists('mb_strlen') ? mb_strlen((string) $value, 'UTF-8') : strlen((string) $value);
    }
}

Shuzijun_App_Content_API::init();
