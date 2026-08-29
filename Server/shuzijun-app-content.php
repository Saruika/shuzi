<?php
/**
 * Plugin Name: Shuzijun App Content API
 * Description: Versioned public content feed and least-privilege mobile publishing API for the Yi Shu app.
 * Version: 1.2.0
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

final class Shuzijun_App_Content_API {
    const OPTION_CONFIG = 'shuzijun_app_content_config';
    const OPTION_UPDATED = 'shuzijun_app_content_updated_at';
    const CAPABILITY = 'manage_yishu_app_content';
    const ROLE = 'yishu_content_manager';

    public static function init() {
        add_action('init', array(__CLASS__, 'ensure_roles'), 20);
        add_action('rest_api_init', array(__CLASS__, 'register_routes'));
        add_action('save_post_portfolio', array(__CLASS__, 'portfolio_changed'), 20, 3);

        // Application Passwords are revocable, per-client credentials intended
        // for HTTPS REST clients. Restrict them to the dedicated content role.
        add_filter('wp_is_application_passwords_available', '__return_true', 20);
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

    public static function can_manage() {
        return current_user_can(self::CAPABILITY);
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

    public static function get_content() {
        $response = rest_ensure_response(self::manifest());
        $response->header('Cache-Control', 'public, max-age=60, stale-while-revalidate=300');
        return $response;
    }

    public static function update_content(WP_REST_Request $request) {
        $current = self::config();
        $incoming_heroes = $request->get_param('heroImages');
        $incoming_launch_posters = $request->get_param('launchPosters');
        $incoming_showreel = $request->get_param('showreel');
        $incoming_dramas = $request->get_param('dramas');

        if (is_array($incoming_heroes)) {
            $heroes = self::sanitize_image_urls($incoming_heroes, 5);
            if (is_wp_error($heroes)) { return $heroes; }
            $current['heroImages'] = $heroes;
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
        $response = rest_ensure_response(self::manifest());
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
        foreach ($media_ids as $media_id) {
            if (get_post_type($media_id) !== 'attachment') {
                return new WP_Error('invalid_media', '包含无效媒体。', array('status' => 400));
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
            'content' => self::manifest(),
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
        if (strlen($title) > 120 || strlen($subtitle) > 240 || strlen($eyebrow) > 120) {
            return new WP_Error('portfolio_text_too_long', '相册名称或介绍过长。', array('status' => 400));
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
            'content' => self::manifest(),
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

    private static function manifest() {
        $config = self::config();
        $updated = (int) get_option(self::OPTION_UPDATED, 0);
        if ($updated < 1) { $updated = time(); }
        return array(
            'schemaVersion' => 1,
            'updatedAt' => gmdate('c', $updated),
            'heroImages' => $config['heroImages'],
            'launchPosters' => $config['launchPosters'],
            'showreel' => $config['showreel'],
            'dramas' => $config['dramas'],
            'portfolios' => self::portfolios(),
        );
    }

    private static function config() {
        $stored = get_option(self::OPTION_CONFIG, array());
        if (!is_array($stored)) { $stored = array(); }
        $defaults = self::default_config();
        return array(
            'heroImages' => isset($stored['heroImages']) && is_array($stored['heroImages'])
                ? array_values($stored['heroImages'])
                : $defaults['heroImages'],
            'launchPosters' => isset($stored['launchPosters']) && is_array($stored['launchPosters'])
                ? array_values($stored['launchPosters'])
                : $defaults['launchPosters'],
            'showreel' => isset($stored['showreel']) && is_array($stored['showreel'])
                ? array_merge($defaults['showreel'], $stored['showreel'])
                : $defaults['showreel'],
            'dramas' => isset($stored['dramas']) && is_array($stored['dramas'])
                ? array_values($stored['dramas'])
                : $defaults['dramas'],
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
            'launchPosters' => array(
                array(
                    'id' => 'evergreen',
                    'isEnabled' => true,
                    'imageURL' => 'https://img.shuzijun.com.cn/images/hero-mobile-1.webp',
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

    private static function portfolios() {
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
                $full = wp_get_attachment_image_url($media_id, 'full');
                $display = wp_get_attachment_image_url($media_id, 'large');
                if (!$full) { continue; }
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
                    'url' => $display ?: $full,
                    'fullSizeURL' => $full,
                    'altText' => get_post_meta($media_id, '_wp_attachment_image_alt', true) ?: get_the_title($post),
                );
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
            $fallback = array('title'=>'旗袍','subtitle'=>'庭院、窗影与东方女性的克制','eyebrow'=>'QIPAO · STORY');
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
        $video = self::https_url(isset($value['videoURL']) ? $value['videoURL'] : '');
        $poster = self::https_url(isset($value['posterURL']) ? $value['posterURL'] : '');
        if (!$video || !$poster) {
            return new WP_Error('invalid_showreel_url', 'Showreel 和海报必须使用有效 HTTPS 地址。', array('status' => 400));
        }
        $tags = isset($value['tags']) && is_array($value['tags']) ? $value['tags'] : $fallback['tags'];
        $tags = array_slice(array_values(array_filter(array_map('sanitize_text_field', $tags))), 0, 8);
        return array(
            'eyebrow' => sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : $fallback['eyebrow']),
            'title' => sanitize_text_field(isset($value['title']) ? $value['title'] : $fallback['title']),
            'summary' => sanitize_text_field(isset($value['summary']) ? $value['summary'] : $fallback['summary']),
            'durationLabel' => sanitize_text_field(isset($value['durationLabel']) ? $value['durationLabel'] : $fallback['durationLabel']),
            'videoURL' => $video,
            'posterURL' => $poster,
            'tags' => $tags,
        );
    }

    private static function sanitize_launch_posters($values) {
        $result = array();
        foreach (array_slice(array_values($values), 0, 12) as $index => $value) {
            if (!is_array($value)) { continue; }
            $image = self::https_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $starts_at = isset($value['startsAt']) ? strtotime((string) $value['startsAt']) : false;
            $ends_at = isset($value['endsAt']) ? strtotime((string) $value['endsAt']) : false;
            if (!$image || !$title || $starts_at === false || $ends_at === false || $starts_at >= $ends_at) {
                return new WP_Error(
                    'invalid_launch_poster',
                    '每张开屏海报都需要图片、标题和有效的起止日期。',
                    array('status' => 400)
                );
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'launch-poster-' . ($index + 1); }
            $display_seconds = isset($value['displaySeconds']) ? floatval($value['displaySeconds']) : 2.5;
            $result[] = array(
                'id' => $id,
                'isEnabled' => isset($value['isEnabled']) ? rest_sanitize_boolean($value['isEnabled']) : true,
                'imageURL' => $image,
                'eyebrow' => sanitize_text_field(isset($value['eyebrow']) ? $value['eyebrow'] : ''),
                'title' => $title,
                'subtitle' => sanitize_text_field(isset($value['subtitle']) ? $value['subtitle'] : ''),
                'startsAt' => gmdate('c', $starts_at),
                'endsAt' => gmdate('c', $ends_at),
                'displaySeconds' => max(1.5, min(5.0, $display_seconds)),
            );
        }
        return $result;
    }

    private static function sanitize_dramas($values) {
        $result = array();
        foreach (array_slice(array_values($values), 0, 50) as $index => $value) {
            if (!is_array($value)) { continue; }
            $title = sanitize_text_field(isset($value['title']) ? $value['title'] : '');
            $image = self::https_url(isset($value['imageURL']) ? $value['imageURL'] : '');
            $destination = self::https_url(isset($value['destinationURL']) ? $value['destinationURL'] : '');
            if (!$title || !$image || !$destination) {
                return new WP_Error('invalid_drama', '每部短剧都需要标题、HTTPS 海报和跳转地址。', array('status' => 400));
            }
            $id = sanitize_key(isset($value['id']) ? $value['id'] : '');
            if (!$id) { $id = 'drama-' . ($index + 1); }
            $result[] = array('id'=>$id, 'title'=>$title, 'imageURL'=>$image, 'destinationURL'=>$destination);
        }
        return $result;
    }

    private static function sanitize_image_urls($values, $maximum) {
        $result = array();
        foreach (array_slice(array_values($values), 0, $maximum) as $value) {
            $url = self::https_url($value);
            if (!$url) {
                return new WP_Error('invalid_image_url', '主页封面必须使用有效 HTTPS 地址。', array('status' => 400));
            }
            $result[] = $url;
        }
        if (!$result) {
            return new WP_Error('missing_hero_image', '至少保留一张主页封面。', array('status' => 400));
        }
        return $result;
    }

    private static function https_url($value) {
        $url = esc_url_raw((string) $value, array('https'));
        return wp_parse_url($url, PHP_URL_SCHEME) === 'https' ? $url : '';
    }
}

Shuzijun_App_Content_API::init();
