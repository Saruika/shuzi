<?php

defined('ABSPATH') || exit;

/** A separate, opt-in catalogue. Never reuse the authenticated manifest's legacy "public" audience. */
trait Shuzijun_App_Public_Experience {
    private static $public_selection_save_error = false;

    private static function public_bounded_text($text, $maximum) {
        return wp_html_excerpt(sanitize_text_field($text), $maximum, '');
    }

    public static function register_public_preview_image_size() {
        // Affects future uploads only. Existing originals are never regenerated in an HTTP request.
        add_image_size('yishu-public-preview', 1600, 1600, false);
    }

    private static function public_selection_ids($portfolio_id) {
        $stored = get_post_meta($portfolio_id, '_yishu_public_preview_media', true);
        if (!is_array($stored) || count($stored) > 6) { return array(); }
        $ids = array();
        foreach ($stored as $id) {
            if (!is_int($id) || $id <= 0 || in_array($id, $ids, true)) { return array(); }
            $ids[] = $id;
        }
        return $ids;
    }

    private static function public_album_gallery_ids($portfolio_id) {
        $gallery = json_decode((string) get_post_meta($portfolio_id, '_portfolio_gallery', true), true);
        if (!is_array($gallery) || !$gallery) {
            $gallery = get_children(array('post_parent' => $portfolio_id, 'post_type' => 'attachment',
                'post_mime_type' => 'image', 'orderby' => 'ID', 'order' => 'ASC', 'fields' => 'ids'));
        }
        return array_slice(array_values(array_unique(array_filter(array_map('absint', (array) $gallery)))), 0, 300);
    }

    private static function public_preview_image($media_id) {
        $post = get_post($media_id);
        if (!$post instanceof WP_Post || $post->post_type !== 'attachment'
            || $post->post_status === 'trash' || !wp_attachment_is_image($media_id)) { return null; }
        $meta = wp_get_attachment_metadata($media_id);
        $attached = (string) get_post_meta($media_id, '_wp_attached_file', true);
        if (!is_array($meta) || !is_int($meta['width'] ?? null) || !is_int($meta['height'] ?? null)
            || $meta['width'] < 1 || $meta['height'] < 1 || $meta['width'] > 65535 || $meta['height'] > 65535
            || !is_string($meta['file'] ?? null) || !$meta['file'] || !$attached || basename($attached) !== basename($meta['file'])
            || !isset($meta['sizes']) || !is_array($meta['sizes'])) { return null; }
        $original_ratio = (float) $meta['width'] / (float) $meta['height'];
        $candidates = array();
        foreach (array_slice($meta['sizes'], 0, 24, true) as $name => $size) {
            if (!is_array($size) || !is_string($size['file'] ?? null) || !$size['file']
                || !is_int($size['width'] ?? null) || !is_int($size['height'] ?? null)) { continue; }
            $width = (int) $size['width'];
            $height = (int) $size['height'];
            $long_edge = max($width, $height);
            // Reject small/cropped previews and original aliases. No full-size fallback.
            if ($long_edge < 640 || $long_edge > 1600 || min($width, $height) <= 0
                || basename($size['file']) === basename($attached)
                || abs(($width / $height) / $original_ratio - 1) > 0.02) { continue; }
            $source = wp_get_attachment_image_src($media_id, $name);
            if (!is_array($source) || empty($source[3]) || (int) $source[1] !== $width || (int) $source[2] !== $height) { continue; }
            $url = self::trusted_media_url($source[0]);
            $path = (string) wp_parse_url($url, PHP_URL_PATH);
            if (!$url || $url === wp_get_attachment_image_url($media_id, 'full')
                || $url === wp_get_original_image_url($media_id)
                || wp_parse_url($url, PHP_URL_QUERY) !== null
                || strpos($path, '/wp-content/uploads/') !== 0
                || preg_match('/%2e|%2f|%5c|%25|\\\\/i', $path)
                || in_array('..', explode('/', $path), true) || in_array('.', explode('/', $path), true)
                || basename($path) !== basename($size['file'])) { continue; }
            $candidates[$long_edge] = $url;
        }
        if (!$candidates) { return null; }
        krsort($candidates, SORT_NUMERIC);
        return array('id' => (int) $media_id, 'url' => reset($candidates),
            'altText' => self::public_bounded_text(get_post_meta($media_id, '_wp_attachment_image_alt', true), 400));
    }

    public static function get_public_experience() {
        $albums = array();
        $posts = get_posts(array('post_type' => 'portfolio', 'post_status' => 'publish', 'posts_per_page' => 100,
            'orderby' => 'date', 'order' => 'ASC', 'no_found_rows' => true,
            'meta_query' => array(array('key' => '_yishu_public_preview_media', 'compare' => 'EXISTS'))));
        foreach ($posts as $post) {
            if (!$post instanceof WP_Post || $post->post_type !== 'portfolio' || $post->post_status !== 'publish'
                || !self::portfolio_is_visible($post->ID)) { continue; }
            $selected = self::public_selection_ids($post->ID);
            if (!$selected) { continue; }
            $gallery = self::public_album_gallery_ids($post->ID);
            $images = array();
            foreach ($selected as $media_id) {
                if (!in_array($media_id, $gallery, true)) { continue; }
                $image = self::public_preview_image($media_id);
                if ($image !== null) { $images[] = $image; }
            }
            if (!$images) { continue; }
            $metadata = self::portfolio_metadata($post);
            $title = self::public_bounded_text($metadata['title'], 160);
            if ($title === '') { continue; }
            $albums[] = array('id' => (int) $post->ID, 'title' => $title,
                'subtitle' => self::public_bounded_text($metadata['subtitle'], 400), 'images' => $images);
            if (count($albums) >= 30) { break; }
        }
        $response = rest_ensure_response(array('schemaVersion' => 1, 'contentAudience' => 'public',
            'updatedAt' => gmdate('c', max(0, (int) get_option(self::OPTION_UPDATED, 0))), 'albums' => $albums));
        // Withdrawal must not leave a shared CDN catalogue serving a retired selection.
        $response->header('Cache-Control', 'no-store, max-age=0');
        return $response;
    }

    public static function register_public_experience_meta_box($post) {
        if (!self::account_authority_enabled() || !current_user_can(self::CAPABILITY)
            || !$post instanceof WP_Post || !current_user_can('edit_post', $post->ID)) { return; }
        add_meta_box('yishu-public-experience', '公开体验区精选照片',
            array(__CLASS__, 'render_public_experience_meta_box'), 'portfolio', 'normal', 'default');
    }

    public static function render_public_experience_meta_box($post) {
        if (!$post instanceof WP_Post || !current_user_can(self::CAPABILITY)
            || !current_user_can('edit_post', $post->ID)) { return; }
        $selected = self::public_selection_ids($post->ID);
        wp_nonce_field('yishu_public_experience_' . $post->ID, 'yishu_public_experience_nonce');
        echo '<input type="hidden" name="yishu_public_experience_present" value="1">';
        echo '<input type="hidden" name="yishu_public_experience_revision" value="'
            . esc_attr(hash('sha256', wp_json_encode($selected))) . '">';
        echo '<p>默认不公开。仅下方明确勾选的照片会向无需登录的访客展示，每本相册最多 6 张；完整相册仍需审批。取消全部勾选即可撤回公开展示。</p>';
        echo '<p>只使用现有的 640–1600 像素等比例预览图，不发布原图。相册须已发布且未隐藏；调整相册顺序不会自动更换公开照片。</p>';
        foreach (self::public_album_gallery_ids($post->ID) as $media_id) {
            $image = self::public_preview_image($media_id);
            $is_selected = in_array($media_id, $selected, true);
            echo '<label style="display:inline-flex;vertical-align:top;flex-direction:column;gap:6px;margin:8px;max-width:160px">';
            echo '<input type="checkbox" name="yishu_public_experience_images[]" value="' . esc_attr((string) $media_id) . '"'
                . checked($is_selected, true, false) . disabled($image === null, true, false) . '>';
            if ($image !== null) {
                echo '<img src="' . esc_url($image['url']) . '" alt="' . esc_attr($image['altText'])
                    . '" style="width:140px;height:180px;object-fit:contain" loading="lazy">';
            }
            echo '<span>图片 ' . esc_html((string) $media_id)
                . ($image === null ? '：缺少合规预览图，暂不可公开' : '') . '</span></label>';
        }
    }

    private static function public_selection_save_failed() {
        if (self::$public_selection_save_error) { return; }
        self::$public_selection_save_error = true;
        add_filter('redirect_post_location', static function ($url) {
            return add_query_arg('yishu_public_selection_error', '1', $url);
        });
    }

    public static function public_experience_admin_notice() {
        if (!current_user_can(self::CAPABILITY) || !isset($_GET['yishu_public_selection_error'])) { return; }
        echo '<div class="notice notice-error"><p>公开照片选择未保存。请刷新页面后重试，并确认最多选择 6 张有效预览图；现有公开设置未被修改。</p></div>';
    }

    public static function save_public_experience_selection($post_id, $post, $update) {
        if (!$post instanceof WP_Post || $post->post_type !== 'portfolio'
            || wp_is_post_revision($post_id) || wp_is_post_autosave($post_id)
            || (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE)
            || !isset($_POST['yishu_public_experience_present'])) { return; }
        if (!self::account_authority_enabled() || !current_user_can(self::CAPABILITY)
            || !current_user_can('edit_post', $post_id)
            || !isset($_POST['yishu_public_experience_nonce']) || !is_string($_POST['yishu_public_experience_nonce'])
            || !wp_verify_nonce(wp_unslash($_POST['yishu_public_experience_nonce']), 'yishu_public_experience_' . $post_id)) {
            self::public_selection_save_failed();
            return;
        }
        $values = $_POST['yishu_public_experience_images'] ?? array();
        $revision = $_POST['yishu_public_experience_revision'] ?? null;
        if (!is_array($values) || count($values) > 6 || !is_string($revision)) {
            self::public_selection_save_failed(); return;
        }
        $selected = array();
        foreach ($values as $value) {
            if (!is_string($value) || !preg_match('/^[1-9][0-9]{0,9}$/D', $value)
                || in_array((int) $value, $selected, true)) { self::public_selection_save_failed(); return; }
            $selected[] = (int) $value;
        }
        $actor_id = get_current_user_id();
        $publication_lock = self::acquire_editorial_publication_lock();
        if (is_wp_error($publication_lock)) { self::public_selection_save_failed(); return; }
        $actor_lock = self::acquire_fan_lock($actor_id);
        if (is_wp_error($actor_lock)) {
            self::release_named_fan_lock($publication_lock);
            self::public_selection_save_failed(); return;
        }
        try {
            clean_user_cache($actor_id);
            wp_set_current_user(0);
            wp_set_current_user($actor_id);
            if (!self::account_authority_enabled() || !current_user_can(self::CAPABILITY)
                || !current_user_can('edit_post', $post_id)
                || !hash_equals(hash('sha256', wp_json_encode(self::public_selection_ids($post_id))), $revision)) {
                self::public_selection_save_failed(); return;
            }
            $gallery = self::public_album_gallery_ids($post_id);
            foreach ($selected as $media_id) {
                if (!in_array($media_id, $gallery, true) || self::public_preview_image($media_id) === null) {
                    self::public_selection_save_failed(); return;
                }
            }
            if ($selected === self::public_selection_ids($post_id)) { return; }
            if (update_post_meta($post_id, '_yishu_public_preview_media', $selected) === false) {
                self::public_selection_save_failed(); return;
            }
            self::mark_updated();
        } finally {
            self::release_fan_lock($actor_id, $actor_lock);
            self::release_named_fan_lock($publication_lock);
        }
    }
}
