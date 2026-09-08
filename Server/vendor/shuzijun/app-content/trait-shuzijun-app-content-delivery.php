<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Content_Delivery {
    private static $editorial_request_locks = array();

    private static function acquire_editorial_publication_lock() {
        return self::acquire_named_fan_lock('editorial', 'publication-and-account-deletion-v1');
    }

    /** Serialize native/WordPress REST media writes with account removal. */
    public static function guard_editorial_rest_write($response, $handler, $request) {
        if ($response !== null || !$request instanceof WP_REST_Request
            || in_array($request->get_method(), array('GET', 'HEAD', 'OPTIONS'), true)
            || !preg_match('#^(?:/shuzijun/v1/app-content(?:/|$)|/wp/v2/(?:media|portfolio)(?:/|$))#', $request->get_route())) {
            return $response;
        }
        $key = spl_object_id($request);
        if (isset(self::$editorial_request_locks[$key])) { return $response; }
        if (!self::account_authority_enabled() || !self::authenticate_content_manager($request)) {
            return new WP_Error('editorial_session_invalid', '管理登录状态已变更，请重新登录。', array('status' => 403));
        }
        $actor_id = get_current_user_id();
        $publication_lock = self::acquire_editorial_publication_lock();
        if (is_wp_error($publication_lock)) { return $publication_lock; }
        $actor_lock = self::acquire_fan_lock($actor_id);
        if (is_wp_error($actor_lock)) {
            self::release_named_fan_lock($publication_lock);
            return $actor_lock;
        }
        self::$editorial_request_locks[$key] = array($actor_id, $actor_lock, $publication_lock);
        // An earlier permission check may have raced with revoke/delete. Never
        // reuse its WP_User or bearer context after entering the write lock.
        clean_user_cache($actor_id);
        self::$fan_session_context = null;
        wp_set_current_user(0);
        if (trim((string) $request->get_header('authorization')) === '') { wp_set_current_user($actor_id); }
        $fan_bearer = preg_match('/^Bearer(?:\s|$)/i', trim((string) $request->get_header('authorization'))) === 1;
        if (!self::authenticate_content_manager($request) || get_current_user_id() !== $actor_id
            || ($fan_bearer && !self::fan_session_context_is_current_from_database(self::$fan_session_context, 'normal'))) {
            self::release_editorial_rest_write($response, $handler, $request);
            self::$fan_session_context = null;
            wp_set_current_user(0);
            return new WP_Error('editorial_session_invalid', '管理登录状态已变更，请重新登录。', array('status' => 403));
        }
        return $response;
    }

    public static function release_editorial_rest_write($response, $handler, $request) {
        if (!$request instanceof WP_REST_Request) { return $response; }
        $key = spl_object_id($request);
        if (isset(self::$editorial_request_locks[$key])) {
            list($actor_id, $actor_lock, $publication_lock) = self::$editorial_request_locks[$key];
            unset(self::$editorial_request_locks[$key]);
            self::release_fan_lock($actor_id, $actor_lock);
            self::release_named_fan_lock($publication_lock);
        }
        return $response;
    }

    public static function release_pending_editorial_rest_writes() {
        foreach (self::$editorial_request_locks as $key => $locks) {
            unset(self::$editorial_request_locks[$key]);
            self::release_fan_lock($locks[0], $locks[1]);
            self::release_named_fan_lock($locks[2]);
        }
    }

    public static function secure_rest_response($result, $server, $request) {
        if (!$request instanceof WP_REST_Request || strpos($request->get_route(), '/shuzijun/v1/') !== 0) {
            return $result;
        }
        $response = is_wp_error($result)
            ? rest_convert_error_to_response($result)
            : rest_ensure_response($result);
        $response->header('X-Content-Type-Options', 'nosniff');
        $response->header('X-Frame-Options', 'DENY');
        $response->header('Referrer-Policy', 'no-referrer');
        $response->header('X-Robots-Tag', 'noindex, nofollow');
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        if ($request->get_route() === '/shuzijun/v1/app-content') {
            $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
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
            'canManageFanAdministrators' => self::account_authority_enabled()
                && self::administrator_actor_has_full_app_capabilities($user),
        ));
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    public static function get_content($request = null) {
        if (self::authenticate_content_manager($request)) {
            $manifest = self::manifest('admin');
        } else {
            $context = self::$fan_session_context;
            $permissions = is_array($context) && isset($context['permissions'])
                ? (array) $context['permissions']
                : array();
            $manifest = self::manifest('app', $permissions);
        }
        $response = rest_ensure_response($manifest);
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        $response->header('Pragma', 'no-cache');
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

    // An absent flag preserves every existing album. Only an explicit hide
    // affects delivery; publishing/editing its photos never resets this flag.
    private static function portfolio_is_visible($id) {
        return (string) get_post_meta($id, '_app_is_hidden', true) !== '1';
    }

    public static function update_portfolio_visibility(WP_REST_Request $request) {
        if (!current_user_can(self::CAPABILITY) || !self::account_authority_enabled()) {
            return new WP_Error('portfolio_visibility_forbidden', '需要内容管理权限。', array('status' => 403));
        }
        // Use the route ID, never a body/query parameter that could override it.
        $route = $request->get_url_params();
        $id = absint($route['id'] ?? 0);
        $post = get_post($id);
        if (!$post instanceof WP_Post || $post->post_type !== 'portfolio' || $post->post_status !== 'publish') {
            return new WP_Error('portfolio_not_found', '作品集不存在。', array('status' => 404));
        }
        $body = $request->get_json_params();
        if (!is_array($body) || !isset($body['isVisible'], $body['expectedIsVisible'])
            || !is_bool($body['isVisible']) || !is_bool($body['expectedIsVisible'])) {
            return new WP_Error('invalid_visibility', '可见状态必须为布尔值。', array('status' => 400));
        }
        // The existing editorial REST lock serializes read/check/write and
        // revalidates the actor after role revocation/account deletion races.
        clean_post_cache($id);
        if (self::portfolio_is_visible($id) !== $body['expectedIsVisible']) {
            return new WP_Error('portfolio_visibility_conflict', '相册状态已变更，请刷新后重试。', array('status' => 409));
        }
        update_post_meta($id, '_app_is_hidden', $body['isVisible'] ? '0' : '1');
        clean_post_cache($id);
        if (self::portfolio_is_visible($id) !== $body['isVisible']) {
            return new WP_Error('portfolio_visibility_failed', '保存失败，请稍后重试。', array('status' => 500));
        }
        self::mark_updated();
        $response = rest_ensure_response(array('portfolioID' => $id, 'isVisible' => $body['isVisible'],
            'content' => self::manifest('admin')));
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

    private static function manifest($audience = 'public', $permissions = array()) {
        $config = self::config();
        $updated = (int) get_option(self::OPTION_UPDATED, 0);
        if ($updated < 1) { $updated = time(); }
        $is_unrestricted = in_array($audience, array('admin', 'premium'), true);
        $can_view_full_gallery = $is_unrestricted
            || ($audience === 'app' && in_array('gallery_full', (array) $permissions, true));
        $can_view_video = $is_unrestricted
            || ($audience === 'app' && in_array('video_view', (array) $permissions, true));
        $portfolio_audience = $can_view_full_gallery ? $audience : 'public';
        return array(
            'schemaVersion' => 1,
            // Only server-side authenticated management paths pass 'admin'.
            // Gallery/video entitlements do not confer editorial authority.
            'contentAudience' => $audience === 'admin' ? 'administrator' : 'viewer',
            'updatedAt' => gmdate('c', $updated),
            'heroImages' => $config['heroImages'],
            'aboutPortraitURL' => $config['aboutPortraitURL'],
            'launchPosters' => $config['launchPosters'],
            'showreel' => $can_view_video ? $config['showreel'] : null,
            'dramas' => $can_view_video ? $config['dramas'] : array(),
            'portfolios' => self::portfolios($portfolio_audience),
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

        $stored_launch_posters = isset($stored['launchPosters']) && is_array($stored['launchPosters'])
            ? $stored['launchPosters']
            : null;
        $launch_posters = is_array($stored_launch_posters)
            && !self::is_retired_launch_poster_config($stored_launch_posters)
            ? self::sanitize_launch_posters($stored_launch_posters)
            : $defaults['launchPosters'];
        if (is_wp_error($launch_posters)) { $launch_posters = $defaults['launchPosters']; }

        $showreel_value = isset($stored['showreel']) && is_array($stored['showreel'])
            ? array_merge(is_array($defaults['showreel']) ? $defaults['showreel'] : array(), $stored['showreel'])
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

    /** Server-owned deployment selection; never read from a request or option. */
    private static function app_service_environment() {
        if (!defined('YISHU_APP_SERVICE_ENVIRONMENT')) { return 'production'; }
        $mode = constant('YISHU_APP_SERVICE_ENVIRONMENT');
        return is_string($mode) && in_array($mode, array('production', 'review'), true) ? $mode : 'invalid';
    }

    private static function default_config() {
        // An empty/malformed review configuration must not publish production
        // media or resurrect production's default launch posters.
        if (self::app_service_environment() !== 'production') {
            return array('heroImages' => array(), 'aboutPortraitURL' => null,
                'launchPosters' => array(), 'showreel' => null, 'dramas' => array());
        }
        $hongguo = 'https://novelquickapp.com/s/qcN1w-iokyY/';
        return array(
            'heroImages' => array(
                'https://img.shuzijun.com.cn/images/hero-mobile-1.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-2.webp',
                'https://img.shuzijun.com.cn/images/hero-mobile-3.webp',
            ),
            'aboutPortraitURL' => null,
            'launchPosters' => array(
                array(
                    'id' => 'hanfu-lantern-01',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-01-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
                array(
                    'id' => 'hanfu-lantern-02',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-02-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
                    'title' => '易姝',
                    'subtitle' => '镜头之内，自有叙事。',
                    'startsAt' => '1970-01-01T00:00:00+00:00',
                    'endsAt' => '2100-01-01T00:00:00+00:00',
                    'displaySeconds' => 2.5,
                ),
                array(
                    'id' => 'hanfu-lantern-03',
                    'isEnabled' => true,
                    'imageURL' => 'https://www.shuzijun.com.cn/wp-content/uploads/2026/09/yishu-launch-hanfu-lantern-03-mobile-20260902b.jpg',
                    'eyebrow' => '东方美学',
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

    private static function is_retired_launch_poster_config($values) {
        if (count((array) $values) !== 1 || !is_array($values[0])) { return false; }
        $poster = $values[0];
        return isset($poster['id'], $poster['imageURL'])
            && (string) $poster['id'] === 'evergreen'
            && (string) $poster['imageURL']
                === 'https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-launch-qipao-ivory-20260830.jpg';
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
            $is_visible = self::portfolio_is_visible($post->ID);
            // Filter before building image URLs for every non-editor audience,
            // including full-gallery and legacy premium sessions.
            if (!$is_visible && $audience !== 'admin') { continue; }
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
                'isVisible' => $is_visible,
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
        $fallback = is_array($fallback) ? $fallback : array(
            'eyebrow' => '', 'title' => '', 'summary' => '', 'durationLabel' => '', 'tags' => array()
        );
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
        $parts = wp_parse_url($url);
        if (!is_array($parts) || ($parts['scheme'] ?? null) !== 'https') { return ''; }
        // Presence matters: PHP treats the user "0", an empty user/password,
        // an empty fragment and port 0 as false, not as missing components.
        foreach (array('user', 'pass', 'fragment') as $component) {
            if (array_key_exists($component, $parts)) { return ''; }
        }
        return !array_key_exists('port', $parts) || (int) $parts['port'] === 443 ? $url : '';
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
        $environment = self::app_service_environment();
        if ($environment !== 'production') {
            // In review, neither a database home URL nor an existing host
            // filter may broaden the fixed media boundary to production.
            return $environment === 'review' && $home_host === 'review.shuzijun.com.cn'
                && $host === 'review.shuzijun.com.cn' ? $url : '';
        }
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
    private static function apns_provider_configuration() {
        if (self::apple_test_mode_enabled()) {
            $test = apply_filters('yishu_apns_provider_configuration', null);
            if (is_array($test)
                && preg_match('/^[A-Z0-9]{10}$/D', (string) ($test['keyID'] ?? '')) === 1
                && preg_match('/^[A-Z0-9]{10}$/D', (string) ($test['teamID'] ?? '')) === 1
                && !empty($test['test'])) {
                return $test;
            }
        }
        $key_id = getenv('YISHU_APNS_KEY_ID');
        $team_id = getenv('YISHU_APNS_TEAM_ID');
        $key_id = is_string($key_id) ? trim($key_id) : '';
        $team_id = is_string($team_id) ? trim($team_id) : '';
        if (preg_match('/^[A-Z0-9]{10}$/D', $key_id) !== 1
            || preg_match('/^[A-Z0-9]{10}$/D', $team_id) !== 1) {
            return new WP_Error(
                'push_provider_unavailable',
                'APNs 提供者配置尚未完成。',
                array('status' => 503)
            );
        }
        $private_key = self::push_read_secure_file('YISHU_APNS_PRIVATE_KEY_PATH', 8192);
        if (is_wp_error($private_key)) {
            return new WP_Error(
                'push_provider_unavailable',
                'APNs 提供者配置尚未完成。',
                array('status' => 503)
            );
        }
        $handle = function_exists('openssl_pkey_get_private')
            ? @openssl_pkey_get_private($private_key)
            : false;
        $details = $handle ? @openssl_pkey_get_details($handle) : false;
        if (function_exists('sodium_memzero')) { sodium_memzero($private_key); }
        if (!$handle || !is_array($details)
            || (int) ($details['type'] ?? -1) !== OPENSSL_KEYTYPE_EC
            || (int) ($details['bits'] ?? 0) !== 256
            || !in_array(
                strtolower((string) ($details['ec']['curve_name'] ?? '')),
                array('prime256v1', 'secp256r1'),
                true
            )) {
            return new WP_Error(
                'push_provider_unavailable',
                'APNs 提供者密钥无效。',
                array('status' => 503)
            );
        }
        return array('keyID' => $key_id, 'teamID' => $team_id);
    }

    private static function apns_provider_token() {
        $cached = self::$apns_provider_token_cache;
        if (is_array($cached) && is_string($cached['token'] ?? null)
            && (int) ($cached['expires'] ?? 0) > time() + 60) {
            return (string) $cached['token'];
        }
        $configuration = self::apns_provider_configuration();
        if (is_wp_error($configuration)) { return $configuration; }
        if (!empty($configuration['test'])) { return 'test-provider-token'; }
        $cache_name = 'yishu_apns_jwt_' . substr(hash(
            'sha256',
            (string) $configuration['keyID'] . '|' . (string) $configuration['teamID']
        ), 0, 20);
        $cached_token = self::read_encrypted_apns_provider_token_cache($cache_name);
        if ($cached_token !== '') { return $cached_token; }
        $lock = self::acquire_named_fan_lock('apns_jwt', $cache_name);
        if (is_wp_error($lock)) {
            return new WP_Error(
                'push_provider_unavailable',
                'APNs 提供者签名正在刷新，请稍后重试。',
                array('status' => 503)
            );
        }
        try {
            $cached_token = self::read_encrypted_apns_provider_token_cache($cache_name);
            if ($cached_token !== '') { return $cached_token; }
            $token = self::generate_apns_provider_token($configuration);
            if (is_wp_error($token)) { return $token; }
            $expires = time() + 3000;
            $encrypted = self::encrypt_apns_provider_token_cache($token);
            if (is_wp_error($encrypted)
                || !set_transient($cache_name, array(
                    'version' => 1,
                    'encryptedToken' => $encrypted,
                    'expires' => $expires,
                ), 3000)) {
                return new WP_Error(
                    'push_provider_unavailable',
                    'APNs 提供者签名缓存暂时不可用。',
                    array('status' => 503)
                );
            }
            self::$apns_provider_token_cache = array(
                'token' => $token,
                'expires' => $expires,
            );
            return $token;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    private static function generate_apns_provider_token($configuration) {
        if (!is_array($configuration)
            || preg_match('/^[A-Z0-9]{10}$/D', (string) ($configuration['keyID'] ?? '')) !== 1
            || preg_match('/^[A-Z0-9]{10}$/D', (string) ($configuration['teamID'] ?? '')) !== 1) {
            return new WP_Error(
                'push_provider_unavailable',
                'APNs 提供者配置无效。',
                array('status' => 503)
            );
        }
        $private_key = self::push_read_secure_file('YISHU_APNS_PRIVATE_KEY_PATH', 8192);
        if (is_wp_error($private_key)) { return $private_key; }
        $header = self::base64url_encode(wp_json_encode(array(
            'alg' => 'ES256',
            'kid' => (string) $configuration['keyID'],
        ), JSON_UNESCAPED_SLASHES));
        $claims = self::base64url_encode(wp_json_encode(array(
            'iss' => (string) $configuration['teamID'],
            'iat' => time(),
        ), JSON_UNESCAPED_SLASHES));
        $signing_input = $header . '.' . $claims;
        $key = @openssl_pkey_get_private($private_key);
        if (function_exists('sodium_memzero')) { sodium_memzero($private_key); }
        $signature = '';
        $signed = $key && openssl_sign($signing_input, $signature, $key, OPENSSL_ALGO_SHA256);
        $raw = $signed ? self::apns_der_signature_to_raw($signature) : '';
        if (is_string($raw) && strlen($raw) === 64) {
            return $signing_input . '.' . self::base64url_encode($raw);
        }
        return new WP_Error(
            'push_provider_unavailable',
            'APNs 提供者签名暂时不可用。',
            array('status' => 503)
        );
    }

    private static function apns_provider_cache_encryption_key() {
        $master = self::push_data_master_key();
        if (is_wp_error($master)) { return $master; }
        $key = hash_hkdf(
            'sha256',
            $master,
            SODIUM_CRYPTO_SECRETBOX_KEYBYTES,
            'yishu/apns-provider-cache/v1',
            hash('sha256', self::PUSH_TOPIC, true)
        );
        sodium_memzero($master);
        return $key;
    }

    private static function encrypt_apns_provider_token_cache($token) {
        $token = (string) $token;
        if (strlen($token) < 32 || strlen($token) > 2048) {
            return new WP_Error('push_provider_unavailable', 'APNs 提供者签名无效。', array('status' => 503));
        }
        $key = self::apns_provider_cache_encryption_key();
        if (is_wp_error($key)) { return $key; }
        try {
            $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            $ciphertext = sodium_crypto_secretbox($token, $nonce, $key);
            $result = array(
                'nonce' => self::base64url_encode($nonce),
                'ciphertext' => self::base64url_encode($ciphertext),
            );
        } catch (Throwable $error) {
            $result = new WP_Error('push_provider_unavailable', 'APNs 提供者签名缓存不可用。', array('status' => 503));
        }
        sodium_memzero($key);
        return $result;
    }

    private static function read_encrypted_apns_provider_token_cache($cache_name) {
        $record = get_transient((string) $cache_name);
        if (!is_array($record) || (int) ($record['version'] ?? 0) !== 1
            || (int) ($record['expires'] ?? 0) <= time() + 60
            || !is_array($record['encryptedToken'] ?? null)) {
            return '';
        }
        $encrypted = $record['encryptedToken'];
        $decode = static function ($value) {
            if (!is_string($value) || preg_match('/^[A-Za-z0-9_-]+$/D', $value) !== 1) {
                return false;
            }
            $padding = (4 - (strlen($value) % 4)) % 4;
            return base64_decode(strtr($value . str_repeat('=', $padding), '-_', '+/'), true);
        };
        $nonce = $decode($encrypted['nonce'] ?? '');
        $ciphertext = $decode($encrypted['ciphertext'] ?? '');
        $key = self::apns_provider_cache_encryption_key();
        if (!is_string($nonce) || strlen($nonce) !== SODIUM_CRYPTO_SECRETBOX_NONCEBYTES
            || !is_string($ciphertext)
            || strlen($ciphertext) < 32 + SODIUM_CRYPTO_SECRETBOX_MACBYTES
            || strlen($ciphertext) > 2048 + SODIUM_CRYPTO_SECRETBOX_MACBYTES
            || is_wp_error($key)) {
            if (is_string($key)) { sodium_memzero($key); }
            return '';
        }
        try {
            $token = sodium_crypto_secretbox_open($ciphertext, $nonce, $key);
        } catch (Throwable $error) {
            $token = false;
        }
        sodium_memzero($key);
        if (!is_string($token) || strlen($token) < 32 || strlen($token) > 2048
            || preg_match('/^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$/D', $token) !== 1) {
            return '';
        }
        self::$apns_provider_token_cache = array(
            'token' => $token,
            'expires' => (int) $record['expires'],
        );
        return $token;
    }

    private static function base64url_encode($value) {
        return rtrim(strtr(base64_encode((string) $value), '+/', '-_'), '=');
    }

    private static function apns_der_signature_to_raw($der) {
        $der = (string) $der;
        $offset = 0;
        $read_length = static function () use (&$der, &$offset) {
            if ($offset >= strlen($der)) { return false; }
            $first = ord($der[$offset++]);
            if (($first & 0x80) === 0) { return $first; }
            $bytes = $first & 0x7f;
            if ($bytes < 1 || $bytes > 2 || $offset + $bytes > strlen($der)) { return false; }
            $length = 0;
            for ($index = 0; $index < $bytes; $index++) {
                $length = ($length << 8) | ord($der[$offset++]);
            }
            return $length;
        };
        if (strlen($der) < 8 || ord($der[$offset++]) !== 0x30) { return ''; }
        $sequence_length = $read_length();
        if ($sequence_length === false || $offset + $sequence_length !== strlen($der)) { return ''; }
        $parts = array();
        for ($part = 0; $part < 2; $part++) {
            if ($offset >= strlen($der) || ord($der[$offset++]) !== 0x02) { return ''; }
            $length = $read_length();
            if ($length === false || $length < 1 || $length > 33
                || $offset + $length > strlen($der)) { return ''; }
            $integer = substr($der, $offset, $length);
            $offset += $length;
            $integer = ltrim($integer, "\x00");
            if (strlen($integer) > 32) { return ''; }
            $parts[] = str_pad($integer, 32, "\x00", STR_PAD_LEFT);
        }
        return $offset === strlen($der) ? implode('', $parts) : '';
    }

    /** Cloud inbox text is never substituted until this transport boundary. */
    private static function push_apns_payload($notification) {
        $environment = self::app_service_environment();
        if ($environment === 'invalid') { return null; }
        if ($environment === 'review' && !self::trusted_media_url(home_url('/'))) { return null; }
        if (!is_array($notification) || !self::is_uuid_v4($notification['public_id'] ?? '')) {
            return null;
        }
        $sensitive = (int) ($notification['is_sensitive'] ?? 1) !== 0;
        $title = $sensitive ? 'Hi，梳子' : ($notification['title'] ?? null);
        $body = $sensitive ? '有新消息，请登录查看' : ($notification['body'] ?? null);
        if (!is_string($title) || !is_string($body)) { return null; }
        $payload = array(
            'aps' => array('alert' => array('title' => $title, 'body' => $body), 'sound' => 'default'),
            'notificationID' => (string) $notification['public_id'],
        );
        // Preserve the deployed production payload exactly for older clients.
        if ($environment === 'review') { $payload['serviceEnvironment'] = 'review'; }
        return wp_json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    }

    private static function send_push_to_apns($device_token, $notification) {
        $device_token = strtolower((string) $device_token);
        $deliver_before = is_array($notification) && is_scalar($notification['deliver_before'] ?? null)
            ? (string) $notification['deliver_before']
            : '';
        if (!self::valid_push_device_token($device_token)
            || !is_array($notification) || !self::is_uuid_v4($notification['public_id'] ?? '')
            || preg_match('/^[1-9][0-9]{0,9}$/D', $deliver_before) !== 1) {
            return array('outcome' => 'dead', 'code' => 'payload_invalid');
        }
        $apns_expiration = (int) $deliver_before;
        if ($apns_expiration <= time()) {
            return array('outcome' => 'dead', 'code' => 'expired');
        }
        if (self::apple_test_mode_enabled()) {
            $test = apply_filters(
                'yishu_apns_delivery_result',
                null,
                array(
                    'notificationID' => (string) $notification['public_id'],
                    'topic' => self::PUSH_TOPIC,
                )
            );
            if (is_array($test) && isset($test['outcome'], $test['code'])) { return $test; }
        }
        $provider_token = self::apns_provider_token();
        if (is_wp_error($provider_token)) {
            return array('outcome' => 'retry', 'code' => 'provider_unavailable');
        }
        if (!function_exists('curl_init') || !defined('CURL_HTTP_VERSION_2TLS')) {
            return array('outcome' => 'retry', 'code' => 'http2_unavailable');
        }
        $payload = self::push_apns_payload($notification);
        if (!is_string($payload) || strlen($payload) > 4096) {
            return array('outcome' => 'dead', 'code' => 'payload_too_large');
        }
        $handle = curl_init(self::PUSH_PRODUCTION_HOST . '/3/device/' . $device_token);
        if (!$handle) { return array('outcome' => 'retry', 'code' => 'transport_unavailable'); }
        // This absolute deadline was fixed when the notification was created.
        // A delayed worker/provider recovery must not grant another 24 hours.
        $options = array(
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $payload,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HEADER => false,
            CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2TLS,
            CURLOPT_CONNECTTIMEOUT => 8,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER => array(
                'authorization: bearer ' . $provider_token,
                'apns-topic: ' . self::PUSH_TOPIC,
                'apns-push-type: alert',
                'apns-priority: 10',
                'apns-expiration: ' . (string) $apns_expiration,
                'apns-collapse-id: ' . (string) $notification['public_id'],
                'content-type: application/json',
            ),
        );
        if (defined('CURLOPT_PROTOCOLS') && defined('CURLPROTO_HTTPS')) {
            $options[CURLOPT_PROTOCOLS] = CURLPROTO_HTTPS;
        }
        curl_setopt_array($handle, $options);
        $response_body = curl_exec($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        $transport_error = curl_errno($handle) !== 0;
        curl_close($handle);
        if ($transport_error) { return array('outcome' => 'retry', 'code' => 'transport_error'); }
        $decoded = is_string($response_body) && strlen($response_body) <= 4096
            ? json_decode($response_body, true)
            : null;
        $reason = is_array($decoded) ? sanitize_key((string) ($decoded['reason'] ?? '')) : '';
        $reason = preg_match('/^[a-z0-9_-]{1,64}$/D', $reason) === 1 ? $reason : 'apns_error';
        if ($status === 200) { return array('outcome' => 'sent', 'code' => ''); }
        if ($status === 410 || ($status === 400
            && in_array($reason, array('baddevicetoken', 'devicetokennotfortopic'), true))) {
            return array('outcome' => 'invalid', 'code' => $reason);
        }
        if ($status === 403
            && in_array($reason, array('expiredprovidertoken', 'invalidprovidertoken'), true)) {
            self::clear_apns_provider_token_cache();
            return array('outcome' => 'retry', 'code' => $reason);
        }
        if (in_array($status, array(408, 429, 500, 503), true)) {
            return array('outcome' => 'retry', 'code' => $reason);
        }
        return array('outcome' => 'dead', 'code' => $reason);
    }

    private static function clear_apns_provider_token_cache() {
        $configuration = self::apns_provider_configuration();
        self::$apns_provider_token_cache = null;
        if (is_wp_error($configuration) || !empty($configuration['test'])) { return; }
        $cache_name = 'yishu_apns_jwt_' . substr(hash(
            'sha256',
            (string) $configuration['keyID'] . '|' . (string) $configuration['teamID']
        ), 0, 20);
        delete_transient($cache_name);
    }

}
