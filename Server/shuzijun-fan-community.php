<?php
/**
 * Plugin Name: Shuzijun Fan Community API
 * Description: Moderated fan interaction, automatic social sync and APNs registration for the Yi Shu app.
 * Version: 1.0.0
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

final class Shuzijun_Fan_Community_API {
    const OPTION_CONFIG = 'shuzijun_fan_community_config';
    const OPTION_MODERATION = 'shuzijun_fan_moderation';
    const OPTION_UPDATED = 'shuzijun_fan_community_updated_at';
    const OPTION_SYNC_STATE = 'shuzijun_fan_social_sync_state';
    const OPTION_DB_VERSION = 'shuzijun_fan_db_version';
    const DB_VERSION = '1';
    const CAPABILITY = 'manage_yishu_app_content';
    const LETTER_POST_TYPE = 'yishu_fan_letter';
    const SYNC_HOOK = 'shuzijun_fan_social_sync';

    public static function init() {
        add_filter('cron_schedules', array(__CLASS__, 'cron_schedules'));
        add_action('init', array(__CLASS__, 'register_letter_type'), 15);
        add_action('init', array(__CLASS__, 'ensure_schema'), 25);
        add_action('init', array(__CLASS__, 'ensure_sync_schedule'), 30);
        add_action(self::SYNC_HOOK, array(__CLASS__, 'run_social_sync'));
        add_action('rest_api_init', array(__CLASS__, 'register_routes'));
        add_filter('rest_post_dispatch', array(__CLASS__, 'secure_rest_response'), 20, 3);
    }

    public static function cron_schedules($schedules) {
        if (!isset($schedules['yishu_ten_minutes'])) {
            $schedules['yishu_ten_minutes'] = array(
                'interval' => 10 * MINUTE_IN_SECONDS,
                'display' => '易姝社交平台每十分钟同步',
            );
        }
        return $schedules;
    }

    public static function ensure_sync_schedule() {
        if (!wp_next_scheduled(self::SYNC_HOOK)) {
            wp_schedule_event(time() + 120, 'yishu_ten_minutes', self::SYNC_HOOK);
        }
    }

    public static function register_letter_type() {
        register_post_type(self::LETTER_POST_TYPE, array(
            'labels' => array('name' => '易姝粉丝信'),
            'public' => false,
            'publicly_queryable' => false,
            'show_ui' => false,
            'show_in_rest' => false,
            'exclude_from_search' => true,
            'supports' => array('title', 'editor'),
            'capability_type' => 'post',
            'map_meta_cap' => true,
        ));
    }

    public static function ensure_schema() {
        if ((string) get_option(self::OPTION_DB_VERSION, '') === self::DB_VERSION) { return; }
        global $wpdb;
        require_once ABSPATH . 'wp-admin/includes/upgrade.php';
        $table = self::actions_table();
        $charset = $wpdb->get_charset_collate();
        dbDelta("CREATE TABLE {$table} (
            id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
            subject_type varchar(16) NOT NULL,
            subject_id varchar(64) NOT NULL,
            actor_hash char(64) NOT NULL,
            action_value varchar(32) NOT NULL,
            created_at datetime NOT NULL,
            updated_at datetime NOT NULL,
            PRIMARY KEY  (id),
            UNIQUE KEY subject_actor (subject_type, subject_id, actor_hash),
            KEY subject_value (subject_type, subject_id, action_value)
        ) {$charset};");
        update_option(self::OPTION_DB_VERSION, self::DB_VERSION, false);
    }

    private static function actions_table() {
        global $wpdb;
        return $wpdb->prefix . 'yishu_fan_actions';
    }

    public static function register_routes() {
        register_rest_route('shuzijun/v1', '/fan-community', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'get_community'),
            'permission_callback' => '__return_true',
        ));
        register_rest_route('shuzijun/v1', '/fan-community/reactions', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'react'),
            'permission_callback' => '__return_true',
        ));
        register_rest_route('shuzijun/v1', '/fan-community/votes', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'vote'),
            'permission_callback' => '__return_true',
        ));
        register_rest_route('shuzijun/v1', '/fan-community/letters', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'submit_letter'),
            'permission_callback' => '__return_true',
        ));
        register_rest_route('shuzijun/v1', '/fan-community/devices', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'register_push_device'),
            'permission_callback' => '__return_true',
        ));

        register_rest_route('shuzijun/v1', '/app-admin/fan-community', array(
            'methods' => WP_REST_Server::READABLE,
            'callback' => array(__CLASS__, 'admin_dashboard'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
        register_rest_route('shuzijun/v1', '/app-admin/fan-community/settings', array(
            'methods' => WP_REST_Server::EDITABLE,
            'callback' => array(__CLASS__, 'update_settings'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
        register_rest_route('shuzijun/v1', '/app-admin/fan-community/posts', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_note'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
        register_rest_route('shuzijun/v1', '/app-admin/fan-community/polls', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'create_poll'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
        ));
        register_rest_route('shuzijun/v1', '/app-admin/fan-community/letters/(?P<id>\d+)/status', array(
            'methods' => WP_REST_Server::EDITABLE,
            'callback' => array(__CLASS__, 'update_letter_status'),
            'permission_callback' => array(__CLASS__, 'can_manage'),
            'args' => array('id' => array('required' => true, 'sanitize_callback' => 'absint')),
        ));
        register_rest_route('shuzijun/v1', '/social-sync/events', array(
            'methods' => WP_REST_Server::CREATABLE,
            'callback' => array(__CLASS__, 'receive_signed_events'),
            'permission_callback' => array(__CLASS__, 'verify_social_webhook'),
        ));
    }

    public static function can_manage($request = null) {
        if (!self::authenticate_manager($request)) { return false; }
        if (!$request instanceof WP_REST_Request || $request->get_method() === 'GET') { return true; }
        $key = 'yishu_fan_admin_rate_' . get_current_user_id();
        $count = (int) get_transient($key);
        if ($count >= 120) {
            return new WP_Error('yishu_rate_limited', '操作过于频繁，请稍后再试。', array('status' => 429));
        }
        set_transient($key, $count + 1, MINUTE_IN_SECONDS);
        return true;
    }

    private static function authenticate_manager($request) {
        if (current_user_can(self::CAPABILITY)) { return true; }
        if (!$request instanceof WP_REST_Request) { return false; }
        $authorization = trim((string) $request->get_header('authorization'));
        if (!preg_match('/^Basic\s+([A-Za-z0-9+\/=]{8,4096})$/', $authorization, $matches)) { return false; }
        $decoded = base64_decode($matches[1], true);
        if ($decoded === false || strlen($decoded) > 4096 || strpos($decoded, ':') === false) { return false; }
        list($username, $password) = explode(':', $decoded, 2);
        if (!$username || !$password || strlen($username) > 120 || strlen($password) > 256) { return false; }
        add_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        $user = wp_authenticate_application_password(null, $username, $password);
        remove_filter('wp_is_application_passwords_available', '__return_true', PHP_INT_MAX);
        if (is_wp_error($user) || !$user instanceof WP_User || !user_can($user, self::CAPABILITY)) { return false; }
        wp_set_current_user($user->ID);
        return true;
    }

    public static function secure_rest_response($result, $server, $request) {
        if (!$request instanceof WP_REST_Request
            || strpos($request->get_route(), '/shuzijun/v1/fan-community') !== 0
                && strpos($request->get_route(), '/shuzijun/v1/app-admin/fan-community') !== 0
                && strpos($request->get_route(), '/shuzijun/v1/social-sync') !== 0) {
            return $result;
        }
        if (is_wp_error($result)) { return $result; }
        $response = rest_ensure_response($result);
        $response->header('Cache-Control', 'private, no-store');
        $response->header('X-Content-Type-Options', 'nosniff');
        $response->header('X-Frame-Options', 'DENY');
        $response->header('Referrer-Policy', 'no-referrer');
        $response->header('X-Robots-Tag', 'noindex, nofollow');
        return $response;
    }

    public static function get_community(WP_REST_Request $request) {
        return self::private_response(self::community_manifest($request));
    }

    private static function private_response($data) {
        $response = rest_ensure_response($data);
        $response->header('Cache-Control', 'private, no-store');
        return $response;
    }

    private static function community_manifest($request = null) {
        $config = self::config();
        $actor_hash = $request instanceof WP_REST_Request ? self::actor_hash($request, false) : '';
        $posts = array();
        foreach ($config['posts'] as $post) {
            $counts = self::action_counts('post', $post['id']);
            $selected = $actor_hash ? self::selected_action('post', $post['id'], $actor_hash) : '';
            $post['authorName'] = '易姝';
            $post['managerLabel'] = '狐狸姐姐管理';
            $post['reactions'] = array(
                self::reaction_manifest('heart', '喜欢', 'heart.fill', $counts, $selected),
                self::reaction_manifest('flower', '送花', 'camera.macro', $counts, $selected),
                self::reaction_manifest('cheer', '加油', 'sparkles', $counts, $selected),
            );
            unset($post['sourceID']);
            $posts[] = $post;
        }

        $polls = array();
        foreach ($config['polls'] as $poll) {
            $counts = self::action_counts('poll', $poll['id']);
            $selected = $actor_hash ? self::selected_action('poll', $poll['id'], $actor_hash) : '';
            $options = array();
            foreach ($poll['options'] as $option) {
                $options[] = array(
                    'id' => $option['id'],
                    'label' => $option['label'],
                    'voteCount' => isset($counts[$option['id']]) ? (int) $counts[$option['id']] : 0,
                    'isSelected' => $selected === $option['id'],
                );
            }
            $polls[] = array(
                'id' => $poll['id'],
                'question' => $poll['question'],
                'isOpen' => !empty($poll['isOpen']),
                'publishedAt' => $poll['publishedAt'],
                'options' => $options,
            );
        }

        $updated = (int) get_option(self::OPTION_UPDATED, 0);
        if ($updated < 1) { $updated = time(); }
        return array(
            'schemaVersion' => 1,
            'updatedAt' => gmdate('c', $updated),
            'features' => $config['features'],
            'posts' => $posts,
            'polls' => $polls,
            'lettersNotice' => $config['features']['lettersEnabled']
                ? '粉丝信不会公开展示。狐狸姐姐审核并整理后，再转交给易姝。'
                : '审核规则尚未准备完成，粉丝信入口会保持关闭。',
        );
    }

    private static function reaction_manifest($id, $label, $system_image, $counts, $selected) {
        return array(
            'id' => $id,
            'label' => $label,
            'systemImage' => $system_image,
            'count' => isset($counts[$id]) ? (int) $counts[$id] : 0,
            'isSelected' => $selected === $id,
        );
    }

    private static function action_counts($type, $id) {
        global $wpdb;
        $rows = $wpdb->get_results($wpdb->prepare(
            'SELECT action_value, COUNT(*) AS total FROM ' . self::actions_table()
                . ' WHERE subject_type = %s AND subject_id = %s GROUP BY action_value',
            $type,
            $id
        ), ARRAY_A);
        $result = array();
        foreach ((array) $rows as $row) { $result[$row['action_value']] = (int) $row['total']; }
        return $result;
    }

    private static function selected_action($type, $id, $actor_hash) {
        global $wpdb;
        return (string) $wpdb->get_var($wpdb->prepare(
            'SELECT action_value FROM ' . self::actions_table()
                . ' WHERE subject_type = %s AND subject_id = %s AND actor_hash = %s LIMIT 1',
            $type,
            $id,
            $actor_hash
        ));
    }

    public static function react(WP_REST_Request $request) {
        if (strlen($request->get_body()) > 2048) {
            return new WP_Error('request_too_large', '请求内容过大。', array('status' => 413));
        }
        $config = self::config();
        if (empty($config['features']['reactionsEnabled'])) {
            return new WP_Error('reactions_disabled', '固定回应暂未开放。', array('status' => 403));
        }
        $actor_hash = self::actor_hash($request);
        if (is_wp_error($actor_hash)) { return $actor_hash; }
        $limited = self::rate_limit($actor_hash, 'reaction', 30, MINUTE_IN_SECONDS);
        if (is_wp_error($limited)) { return $limited; }
        $post_id = self::clean_id($request->get_param('postID'));
        $reaction_id = self::clean_id($request->get_param('reactionID'));
        if (!in_array($reaction_id, array('heart', 'flower', 'cheer'), true)
            || !self::find_by_id($config['posts'], $post_id)) {
            return new WP_Error('invalid_reaction', '无法识别这条回应。', array('status' => 422));
        }
        self::upsert_action('post', $post_id, $actor_hash, $reaction_id);
        return self::private_response(self::community_manifest($request));
    }

    public static function vote(WP_REST_Request $request) {
        if (strlen($request->get_body()) > 2048) {
            return new WP_Error('request_too_large', '请求内容过大。', array('status' => 413));
        }
        $config = self::config();
        if (empty($config['features']['pollsEnabled'])) {
            return new WP_Error('polls_disabled', '投票暂未开放。', array('status' => 403));
        }
        $actor_hash = self::actor_hash($request);
        if (is_wp_error($actor_hash)) { return $actor_hash; }
        $limited = self::rate_limit($actor_hash, 'vote', 20, MINUTE_IN_SECONDS);
        if (is_wp_error($limited)) { return $limited; }
        $poll_id = self::clean_id($request->get_param('pollID'));
        $option_id = self::clean_id($request->get_param('optionID'));
        $poll = self::find_by_id($config['polls'], $poll_id);
        if (!$poll || empty($poll['isOpen']) || !self::find_by_id($poll['options'], $option_id)) {
            return new WP_Error('invalid_vote', '无法识别这个投票选项。', array('status' => 422));
        }
        self::upsert_action('poll', $poll_id, $actor_hash, $option_id);
        return self::private_response(self::community_manifest($request));
    }

    private static function upsert_action($type, $id, $actor_hash, $value) {
        global $wpdb;
        $now = current_time('mysql', true);
        $wpdb->query($wpdb->prepare(
            'INSERT INTO ' . self::actions_table()
                . ' (subject_type, subject_id, actor_hash, action_value, created_at, updated_at)'
                . ' VALUES (%s, %s, %s, %s, %s, %s)'
                . ' ON DUPLICATE KEY UPDATE action_value = VALUES(action_value), updated_at = VALUES(updated_at)',
            $type,
            $id,
            $actor_hash,
            $value,
            $now,
            $now
        ));
    }

    public static function submit_letter(WP_REST_Request $request) {
        if (strlen($request->get_body()) > 4096) {
            return new WP_Error('request_too_large', '请求内容过大。', array('status' => 413));
        }
        $config = self::config();
        $moderation = self::moderation();
        if (empty($config['features']['lettersEnabled']) || empty($moderation['isReady'])) {
            return new WP_Error('letters_disabled', '粉丝信审核服务尚未准备完成。', array('status' => 503));
        }
        if (!$request->get_param('consent')) {
            return new WP_Error('consent_required', '请先确认粉丝信的审核与保存说明。', array('status' => 422));
        }
        $actor_hash = self::actor_hash($request);
        if (is_wp_error($actor_hash)) { return $actor_hash; }
        $limited = self::rate_limit($actor_hash, 'letter-five-minutes', 1, 5 * MINUTE_IN_SECONDS);
        if (is_wp_error($limited)) { return $limited; }
        $global_limited = self::global_rate_limit('letters', 200, HOUR_IN_SECONDS);
        if (is_wp_error($global_limited)) { return $global_limited; }
        $day_key = 'yishu_fan_letters_day_' . substr($actor_hash, 0, 32) . '_' . gmdate('Ymd');
        $daily = (int) get_transient($day_key);
        if ($daily >= 3) {
            return new WP_Error('letter_daily_limit', '今天已经收到你的来信，请明天再写。', array('status' => 429));
        }

        $nickname = self::clean_text($request->get_param('nickname'), 24);
        $message = self::clean_multiline_text($request->get_param('message'), 600);
        if (self::text_length($message) < 10) {
            return new WP_Error('letter_too_short', '粉丝信至少需要 10 个字。', array('status' => 422));
        }
        $bucket = self::moderate_text($message, $moderation);
        if ($bucket === 'block') {
            self::record_blocked_attempt($actor_hash);
            return new WP_Error('letter_not_accepted', '这段内容暂时无法提交，请修改后再试。', array('status' => 422));
        }

        $receipt = wp_generate_uuid4();
        $post_id = wp_insert_post(array(
            'post_type' => self::LETTER_POST_TYPE,
            'post_status' => 'pending',
            'post_title' => $nickname ? $nickname : '匿名粉丝',
            'post_content' => $message,
        ), true);
        if (is_wp_error($post_id)) {
            return new WP_Error('letter_storage_failed', '暂时无法保存粉丝信，请稍后再试。', array('status' => 503));
        }
        update_post_meta($post_id, '_yishu_receipt_id', $receipt);
        update_post_meta($post_id, '_yishu_actor_hash', $actor_hash);
        update_post_meta($post_id, '_yishu_letter_status', 'pending');
        update_post_meta($post_id, '_yishu_moderation_bucket', $bucket);
        set_transient($day_key, $daily + 1, DAY_IN_SECONDS + HOUR_IN_SECONDS);
        return self::private_response(array(
            'accepted' => true,
            'receiptID' => $receipt,
            'message' => '狐狸姐姐已经收到，会在审核整理后转交给易姝。',
        ));
    }

    private static function moderate_text($message, $moderation) {
        $normalized = self::normalize_for_matching($message);
        foreach ($moderation['blockTerms'] as $term) {
            if (strpos($normalized, self::normalize_for_matching($term)) !== false) { return 'block'; }
        }
        foreach ($moderation['reviewTerms'] as $term) {
            if (strpos($normalized, self::normalize_for_matching($term)) !== false) { return 'review'; }
        }
        return 'clear';
    }

    private static function normalize_for_matching($value) {
        $value = (string) $value;
        if (class_exists('Normalizer')) {
            $normalized = Normalizer::normalize($value, Normalizer::FORM_KC);
            if (is_string($normalized)) { $value = $normalized; }
        }
        $value = function_exists('mb_strtolower') ? mb_strtolower($value, 'UTF-8') : strtolower($value);
        return preg_replace('/[\p{Z}\p{P}\p{S}\s]+/u', '', $value);
    }

    private static function record_blocked_attempt($actor_hash) {
        $key = 'yishu_fan_blocked_' . substr($actor_hash, 0, 32);
        set_transient($key, (int) get_transient($key) + 1, DAY_IN_SECONDS);
    }

    public static function register_push_device(WP_REST_Request $request) {
        if (strlen($request->get_body()) > 2048) {
            return new WP_Error('request_too_large', '请求内容过大。', array('status' => 413));
        }
        $actor_hash = self::actor_hash($request);
        if (is_wp_error($actor_hash)) { return $actor_hash; }
        $limited = self::rate_limit($actor_hash, 'push-device', 10, HOUR_IN_SECONDS);
        if (is_wp_error($limited)) { return $limited; }
        $token = strtolower(trim((string) $request->get_param('token')));
        $environment = (string) $request->get_param('environment');
        $preferences = $request->get_param('preferences');
        if (!preg_match('/^[0-9a-f]{64,200}$/', $token)
            || !in_array($environment, array('sandbox', 'production'), true)
            || !is_array($preferences)) {
            return new WP_Error('invalid_push_device', '推送设备信息无效。', array('status' => 422));
        }
        $body = array(
            'token' => $token,
            'environment' => $environment,
            'preferences' => array(
                'newWorks' => !empty($preferences['newWorks']),
                'live' => !empty($preferences['live']),
            ),
        );
        $result = self::push_provider_request('/v1/devices', $body);
        if (is_wp_error($result)) { return $result; }
        return self::private_response(array('registered' => true));
    }

    public static function admin_dashboard(WP_REST_Request $request) {
        $config = self::config();
        $moderation = self::moderation();
        $manifest = self::community_manifest();
        return self::private_response(array(
            'features' => $config['features'],
            'moderation' => $moderation,
            'posts' => $manifest['posts'],
            'polls' => $manifest['polls'],
            'letters' => self::admin_letters(),
            'pushReady' => self::push_provider_ready(),
            'activePushDevices' => self::active_push_devices(),
            'sourceStatus' => self::source_status(),
        ));
    }

    public static function update_settings(WP_REST_Request $request) {
        $config = self::config();
        $incoming_features = $request->get_param('features');
        $incoming_moderation = $request->get_param('moderation');
        if (is_array($incoming_moderation)) {
            $moderation = array(
                'blockTerms' => self::sanitize_terms(isset($incoming_moderation['blockTerms']) ? $incoming_moderation['blockTerms'] : array()),
                'reviewTerms' => self::sanitize_terms(isset($incoming_moderation['reviewTerms']) ? $incoming_moderation['reviewTerms'] : array()),
            );
            $moderation['isReady'] = count($moderation['blockTerms']) + count($moderation['reviewTerms']) > 0;
            update_option(self::OPTION_MODERATION, $moderation, false);
        } else {
            $moderation = self::moderation();
        }
        if (is_array($incoming_features)) {
            $features = array(
                'reactionsEnabled' => !empty($incoming_features['reactionsEnabled']),
                'pollsEnabled' => !empty($incoming_features['pollsEnabled']),
                'lettersEnabled' => !empty($incoming_features['lettersEnabled']),
            );
            if ($features['lettersEnabled'] && empty($moderation['isReady'])) {
                return new WP_Error('moderation_not_ready', '必须先配置拦截词或人工复核词，才能开启粉丝信。', array('status' => 422));
            }
            $config['features'] = $features;
        }
        update_option(self::OPTION_CONFIG, $config, false);
        self::mark_updated();
        return self::admin_dashboard($request);
    }

    public static function create_note(WP_REST_Request $request) {
        $text = self::clean_multiline_text($request->get_param('text'), 500);
        if (self::text_length($text) < 1) {
            return new WP_Error('note_empty', '请填写动态内容。', array('status' => 422));
        }
        $config = self::config();
        array_unshift($config['posts'], array(
            'id' => 'note-' . str_replace('-', '', wp_generate_uuid4()),
            'kind' => 'note',
            'text' => $text,
            'externalURL' => null,
            'publishedAt' => gmdate('c'),
            'sourceID' => '',
        ));
        $config['posts'] = array_slice($config['posts'], 0, 100);
        update_option(self::OPTION_CONFIG, $config, false);
        self::mark_updated();
        return self::admin_dashboard($request);
    }

    public static function create_poll(WP_REST_Request $request) {
        $question = self::clean_text($request->get_param('question'), 120);
        $incoming = $request->get_param('options');
        $labels = array();
        foreach ((array) $incoming as $label) {
            $label = self::clean_text($label, 40);
            if ($label !== '' && !in_array($label, $labels, true)) { $labels[] = $label; }
        }
        $labels = array_slice($labels, 0, 4);
        if ($question === '' || count($labels) < 2) {
            return new WP_Error('invalid_poll', '投票需要一个问题和 2 至 4 个不同选项。', array('status' => 422));
        }
        $options = array();
        foreach ($labels as $index => $label) {
            $options[] = array('id' => 'option-' . ($index + 1), 'label' => $label);
        }
        $config = self::config();
        array_unshift($config['polls'], array(
            'id' => 'poll-' . str_replace('-', '', wp_generate_uuid4()),
            'question' => $question,
            'isOpen' => true,
            'publishedAt' => gmdate('c'),
            'options' => $options,
        ));
        $config['polls'] = array_slice($config['polls'], 0, 30);
        update_option(self::OPTION_CONFIG, $config, false);
        self::mark_updated();
        return self::admin_dashboard($request);
    }

    public static function update_letter_status(WP_REST_Request $request) {
        $post_id = absint($request['id']);
        $post = get_post($post_id);
        $status = sanitize_key((string) $request->get_param('status'));
        if (!$post || $post->post_type !== self::LETTER_POST_TYPE
            || !in_array($status, array('pending', 'delivered', 'archived'), true)) {
            return new WP_Error('invalid_letter_status', '无法识别这封粉丝信或状态。', array('status' => 422));
        }
        update_post_meta($post_id, '_yishu_letter_status', $status);
        return self::admin_dashboard($request);
    }

    private static function admin_letters() {
        $posts = get_posts(array(
            'post_type' => self::LETTER_POST_TYPE,
            'post_status' => array('pending', 'publish', 'draft', 'private'),
            'posts_per_page' => 100,
            'orderby' => 'date',
            'order' => 'DESC',
            'no_found_rows' => true,
        ));
        $result = array();
        foreach ($posts as $post) {
            $result[] = array(
                'id' => (int) $post->ID,
                'receiptID' => (string) get_post_meta($post->ID, '_yishu_receipt_id', true),
                'nickname' => $post->post_title,
                'message' => $post->post_content,
                'status' => (string) get_post_meta($post->ID, '_yishu_letter_status', true),
                'moderationBucket' => (string) get_post_meta($post->ID, '_yishu_moderation_bucket', true),
                'submittedAt' => mysql_to_rfc3339($post->post_date_gmt),
            );
        }
        return $result;
    }

    public static function verify_social_webhook(WP_REST_Request $request) {
        if (!defined('YISHU_SOCIAL_WEBHOOK_SECRET') || strlen((string) YISHU_SOCIAL_WEBHOOK_SECRET) < 32) {
            return new WP_Error('social_webhook_unavailable', '自动同步回调尚未配置。', array('status' => 503));
        }
        $provided = strtolower(trim((string) $request->get_header('x-yishu-signature')));
        $expected = hash_hmac('sha256', $request->get_body(), (string) YISHU_SOCIAL_WEBHOOK_SECRET);
        if (!preg_match('/^[0-9a-f]{64}$/', $provided) || !hash_equals($expected, $provided)) {
            return new WP_Error('social_webhook_unauthorized', '签名无效。', array('status' => 401));
        }
        return true;
    }

    public static function receive_signed_events(WP_REST_Request $request) {
        $events = $request->get_param('events');
        if (!is_array($events)) {
            return new WP_Error('invalid_social_events', '事件格式无效。', array('status' => 422));
        }
        $accepted = self::process_social_events('webhook', $events, false);
        if (is_wp_error($accepted)) { return $accepted; }
        return self::private_response(array('accepted' => $accepted));
    }

    public static function run_social_sync() {
        if (get_transient('yishu_social_sync_lock')) { return; }
        set_transient('yishu_social_sync_lock', 1, 8 * MINUTE_IN_SECONDS);
        try {
            self::poll_douyin_official();
            self::poll_signed_social_feed();
        } finally {
            delete_transient('yishu_social_sync_lock');
        }
    }

    private static function poll_douyin_official() {
        $access_token = defined('YISHU_DOUYIN_ACCESS_TOKEN') ? (string) YISHU_DOUYIN_ACCESS_TOKEN : '';
        $access_token = (string) apply_filters('yishu_douyin_access_token', $access_token);
        $open_id = defined('YISHU_DOUYIN_OPEN_ID') ? (string) YISHU_DOUYIN_OPEN_ID : '';
        if (!$access_token || !$open_id) {
            self::update_source_state('douyin', array('ready' => false, 'lastError' => '等待抖音创作者授权与 video.list 权限'));
            return;
        }
        $url = add_query_arg(array('open_id' => $open_id, 'cursor' => 0, 'count' => 20), 'https://open.douyin.com/video/list/');
        $response = wp_remote_get($url, array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array('access-token' => $access_token, 'Accept' => 'application/json'),
        ));
        if (is_wp_error($response) || (int) wp_remote_retrieve_response_code($response) !== 200) {
            self::update_source_state('douyin', array('ready' => true, 'lastError' => '抖音官方接口请求失败'));
            return;
        }
        $payload = json_decode((string) wp_remote_retrieve_body($response), true);
        $list = isset($payload['data']['list']) && is_array($payload['data']['list']) ? $payload['data']['list'] : array();
        if (isset($payload['data']['error_code']) && (int) $payload['data']['error_code'] !== 0) {
            self::update_source_state('douyin', array('ready' => true, 'lastError' => '抖音授权已失效或权限不足'));
            return;
        }
        $events = array();
        foreach ($list as $item) {
            $id = isset($item['item_id']) ? (string) $item['item_id'] : '';
            $url = isset($item['share_url']) ? (string) $item['share_url'] : '';
            if (!$id || !$url) { continue; }
            $events[] = array(
                'id' => $id,
                'kind' => 'douyin',
                'text' => isset($item['title']) && $item['title'] ? $item['title'] : '易姝发布了新的抖音作品。',
                'url' => $url,
                'publishedAt' => gmdate('c', isset($item['create_time']) ? (int) $item['create_time'] : time()),
            );
        }
        self::process_social_events('douyin', $events, true);
        self::update_source_state('douyin', array('ready' => true, 'lastSuccess' => gmdate('c'), 'lastError' => ''));
    }

    private static function poll_signed_social_feed() {
        if (!defined('YISHU_SOCIAL_SYNC_FEED_URL') || !defined('YISHU_SOCIAL_SYNC_FEED_TOKEN')) {
            self::update_source_state('signedFeed', array('ready' => false, 'lastError' => '等待小红书与直播合规数据适配器'));
            return;
        }
        $url = esc_url_raw((string) YISHU_SOCIAL_SYNC_FEED_URL, array('https'));
        $token = (string) YISHU_SOCIAL_SYNC_FEED_TOKEN;
        if (!$url || strlen($token) < 32) {
            self::update_source_state('signedFeed', array('ready' => false, 'lastError' => '自动同步适配器配置无效'));
            return;
        }
        $response = wp_remote_get($url, array(
            'timeout' => 12,
            'redirection' => 0,
            'sslverify' => true,
            'headers' => array('X-Yishu-Internal-Token' => $token, 'Accept' => 'application/json'),
        ));
        if (is_wp_error($response) || (int) wp_remote_retrieve_response_code($response) !== 200) {
            self::update_source_state('signedFeed', array('ready' => true, 'lastError' => '自动同步适配器请求失败'));
            return;
        }
        $payload = json_decode((string) wp_remote_retrieve_body($response), true);
        $events = isset($payload['events']) && is_array($payload['events']) ? $payload['events'] : array();
        self::process_social_events('signedFeed', $events, true);
        self::update_source_state('signedFeed', array('ready' => true, 'lastSuccess' => gmdate('c'), 'lastError' => ''));
    }

    private static function process_social_events($source, $events, $baseline_on_first) {
        $state = get_option(self::OPTION_SYNC_STATE, array());
        if (!is_array($state)) { $state = array(); }
        $source_state = isset($state[$source]) && is_array($state[$source]) ? $state[$source] : array();
        $seen = isset($source_state['seen']) && is_array($source_state['seen']) ? $source_state['seen'] : array();
        $initialized = !empty($source_state['initialized']);
        $clean_events = array();
        foreach (array_slice($events, 0, 100) as $event) {
            $clean = self::sanitize_social_event($event);
            if ($clean) { $clean_events[] = $clean; }
        }
        usort($clean_events, function($a, $b) { return $a['timestamp'] <=> $b['timestamp']; });
        $accepted = 0;
        foreach ($clean_events as $event) {
            $dedupe = $event['kind'] . ':' . $event['id'];
            if (isset($seen[$dedupe])) { continue; }
            $seen[$dedupe] = time();
            if (!$initialized && $baseline_on_first) { continue; }
            self::append_social_post($event);
            self::send_push_event($event);
            $accepted++;
        }
        if (count($seen) > 500) {
            asort($seen, SORT_NUMERIC);
            $seen = array_slice($seen, -500, null, true);
        }
        $source_state['seen'] = $seen;
        $source_state['initialized'] = true;
        $source_state['lastSuccess'] = gmdate('c');
        $state[$source] = $source_state;
        update_option(self::OPTION_SYNC_STATE, $state, false);
        return $accepted;
    }

    private static function sanitize_social_event($event) {
        if (!is_array($event)) { return null; }
        $id = isset($event['id']) ? preg_replace('/[^A-Za-z0-9._:-]/', '', (string) $event['id']) : '';
        $kind = isset($event['kind']) ? sanitize_key((string) $event['kind']) : '';
        $text = self::clean_multiline_text(isset($event['text']) ? $event['text'] : '', 300);
        $url = self::trusted_social_url(isset($event['url']) ? $event['url'] : '');
        $published = isset($event['publishedAt']) ? strtotime((string) $event['publishedAt']) : false;
        $state = isset($event['state']) ? sanitize_key((string) $event['state']) : 'started';
        if (!$id || strlen($id) > 160 || !in_array($kind, array('douyin', 'xiaohongshu', 'live'), true)
            || !$text || !$url || !$published || $published > time() + 5 * MINUTE_IN_SECONDS
            || $published < time() - YEAR_IN_SECONDS || ($kind === 'live' && $state !== 'started')) {
            return null;
        }
        return array(
            'id' => $id,
            'kind' => $kind,
            'text' => $text,
            'url' => $url,
            'publishedAt' => gmdate('c', $published),
            'timestamp' => $published,
        );
    }

    private static function append_social_post($event) {
        $config = self::config();
        foreach ($config['posts'] as $post) {
            if (isset($post['sourceID']) && $post['sourceID'] === $event['kind'] . ':' . $event['id']) { return; }
        }
        array_unshift($config['posts'], array(
            'id' => $event['kind'] . '-' . substr(hash('sha256', $event['id']), 0, 24),
            'kind' => $event['kind'],
            'text' => $event['text'],
            'externalURL' => $event['url'],
            'publishedAt' => $event['publishedAt'],
            'sourceID' => $event['kind'] . ':' . $event['id'],
        ));
        $config['posts'] = array_slice($config['posts'], 0, 100);
        update_option(self::OPTION_CONFIG, $config, false);
        self::mark_updated();
    }

    private static function send_push_event($event) {
        $titles = array(
            'douyin' => '易姝发布了新的抖音作品',
            'xiaohongshu' => '易姝发布了新的小红书作品',
            'live' => '易姝开始直播了',
        );
        self::push_provider_request('/v1/events', array(
            'eventID' => $event['kind'] . ':' . $event['id'],
            'kind' => $event['kind'],
            'title' => $titles[$event['kind']],
            'body' => $event['text'],
            'url' => $event['url'],
        ));
    }

    private static function push_provider_request($path, $body) {
        if (!self::push_provider_ready()) {
            return new WP_Error('push_provider_unavailable', '推送服务尚未完成配置。', array('status' => 503));
        }
        $base = untrailingslashit((string) YISHU_PUSH_PROVIDER_URL);
        $host = strtolower((string) wp_parse_url($base, PHP_URL_HOST));
        $scheme = strtolower((string) wp_parse_url($base, PHP_URL_SCHEME));
        if (!in_array($host, array('127.0.0.1', 'localhost', '::1'), true) || $scheme !== 'http') {
            return new WP_Error('push_provider_insecure', '推送服务必须使用本机回环地址。', array('status' => 503));
        }
        $response = wp_remote_post($base . $path, array(
            'timeout' => 30,
            'redirection' => 0,
            'headers' => array(
                'Content-Type' => 'application/json',
                'Accept' => 'application/json',
                'X-Yishu-Internal-Token' => (string) YISHU_PUSH_PROVIDER_TOKEN,
            ),
            'body' => wp_json_encode($body),
        ));
        if (is_wp_error($response)) {
            return new WP_Error('push_provider_unavailable', '暂时无法连接推送服务。', array('status' => 503));
        }
        $status = (int) wp_remote_retrieve_response_code($response);
        $payload = json_decode((string) wp_remote_retrieve_body($response), true);
        if ($status < 200 || $status >= 300 || !is_array($payload)) {
            return new WP_Error('push_provider_failed', '推送服务未接受请求。', array('status' => 503));
        }
        return $payload;
    }

    private static function push_provider_ready() {
        return defined('YISHU_PUSH_PROVIDER_URL') && defined('YISHU_PUSH_PROVIDER_TOKEN')
            && strlen((string) YISHU_PUSH_PROVIDER_TOKEN) >= 32;
    }

    private static function active_push_devices() {
        $cached = get_transient('yishu_push_provider_health');
        if (is_array($cached)) { return isset($cached['activeDevices']) ? (int) $cached['activeDevices'] : 0; }
        if (!self::push_provider_ready()) { return 0; }
        $base = untrailingslashit((string) YISHU_PUSH_PROVIDER_URL);
        $response = wp_remote_get($base . '/healthz', array('timeout' => 2, 'redirection' => 0));
        $payload = !is_wp_error($response) ? json_decode((string) wp_remote_retrieve_body($response), true) : null;
        if (!is_array($payload) || empty($payload['ok'])) { return 0; }
        set_transient('yishu_push_provider_health', $payload, MINUTE_IN_SECONDS);
        return isset($payload['activeDevices']) ? (int) $payload['activeDevices'] : 0;
    }

    private static function source_status() {
        $state = get_option(self::OPTION_SYNC_STATE, array());
        return is_array($state) ? $state : array();
    }

    private static function update_source_state($source, $changes) {
        $state = get_option(self::OPTION_SYNC_STATE, array());
        if (!is_array($state)) { $state = array(); }
        $current = isset($state[$source]) && is_array($state[$source]) ? $state[$source] : array();
        $state[$source] = array_merge($current, $changes, array('lastChecked' => gmdate('c')));
        update_option(self::OPTION_SYNC_STATE, $state, false);
    }

    private static function config() {
        $stored = get_option(self::OPTION_CONFIG, array());
        if (!is_array($stored)) { $stored = array(); }
        $defaults = self::default_config();
        return array(
            'features' => isset($stored['features']) && is_array($stored['features'])
                ? array_merge($defaults['features'], $stored['features']) : $defaults['features'],
            'posts' => isset($stored['posts']) && is_array($stored['posts'])
                ? array_values($stored['posts']) : $defaults['posts'],
            'polls' => isset($stored['polls']) && is_array($stored['polls'])
                ? array_values($stored['polls']) : $defaults['polls'],
        );
    }

    private static function default_config() {
        return array(
            'features' => array(
                'reactionsEnabled' => true,
                'pollsEnabled' => true,
                'lettersEnabled' => false,
            ),
            'posts' => array(array(
                'id' => 'welcome-20260829',
                'kind' => 'note',
                'text' => '很高兴在这里见到你。以后作品、片场小记和直播提醒，都会慢慢放在这里。',
                'externalURL' => null,
                'publishedAt' => '2026-08-29T00:00:00+00:00',
                'sourceID' => '',
            )),
            'polls' => array(array(
                'id' => 'next-content-20260829',
                'question' => '下一次最想看到哪一类内容？',
                'isOpen' => true,
                'publishedAt' => '2026-08-29T00:00:00+00:00',
                'options' => array(
                    array('id' => 'costume', 'label' => '古风写真'),
                    array('id' => 'daily', 'label' => '片场日常'),
                    array('id' => 'behind-scenes', 'label' => '影视花絮'),
                ),
            )),
        );
    }

    private static function moderation() {
        $stored = get_option(self::OPTION_MODERATION, array());
        if (!is_array($stored)) { $stored = array(); }
        $block = self::sanitize_terms(isset($stored['blockTerms']) ? $stored['blockTerms'] : array());
        $review = self::sanitize_terms(isset($stored['reviewTerms']) ? $stored['reviewTerms'] : array());
        return array(
            'blockTerms' => $block,
            'reviewTerms' => $review,
            'isReady' => count($block) + count($review) > 0,
        );
    }

    private static function sanitize_terms($terms) {
        $result = array();
        foreach (array_slice((array) $terms, 0, 400) as $term) {
            $term = self::clean_text($term, 40);
            if (self::text_length($term) >= 2 && !in_array($term, $result, true)) { $result[] = $term; }
        }
        return $result;
    }

    private static function actor_hash(WP_REST_Request $request, $required = true) {
        $installation = strtolower(trim((string) $request->get_header('x-yishu-installation')));
        if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', $installation)) {
            return $required
                ? new WP_Error('installation_required', '设备安装标识无效。', array('status' => 422))
                : '';
        }
        return hash_hmac('sha256', $installation, wp_salt('nonce'));
    }

    private static function rate_limit($actor_hash, $scope, $limit, $ttl) {
        $key = 'yishu_fan_' . sanitize_key($scope) . '_' . substr($actor_hash, 0, 32);
        $count = (int) get_transient($key);
        if ($count >= $limit) {
            return new WP_Error('fan_rate_limited', '操作过于频繁，请稍后再试。', array('status' => 429));
        }
        set_transient($key, $count + 1, $ttl);
        return true;
    }

    private static function global_rate_limit($scope, $limit, $ttl) {
        $key = 'yishu_fan_global_' . sanitize_key($scope);
        $count = (int) get_transient($key);
        if ($count >= $limit) {
            return new WP_Error('fan_service_busy', '提交人数较多，请稍后再试。', array('status' => 429));
        }
        set_transient($key, $count + 1, $ttl);
        return true;
    }

    private static function find_by_id($items, $id) {
        foreach ((array) $items as $item) {
            if (isset($item['id']) && (string) $item['id'] === (string) $id) { return $item; }
        }
        return null;
    }

    private static function clean_id($value) {
        return substr(preg_replace('/[^A-Za-z0-9_-]/', '', (string) $value), 0, 64);
    }

    private static function clean_text($value, $limit) {
        $value = sanitize_text_field(wp_check_invalid_utf8((string) $value));
        return self::text_substr(trim($value), 0, $limit);
    }

    private static function clean_multiline_text($value, $limit) {
        $value = sanitize_textarea_field(wp_check_invalid_utf8((string) $value));
        return self::text_substr(trim($value), 0, $limit);
    }

    private static function text_length($value) {
        return function_exists('mb_strlen') ? mb_strlen((string) $value, 'UTF-8') : strlen((string) $value);
    }

    private static function text_substr($value, $start, $length) {
        return function_exists('mb_substr')
            ? mb_substr((string) $value, $start, $length, 'UTF-8')
            : substr((string) $value, $start, $length);
    }

    private static function trusted_social_url($value) {
        $url = esc_url_raw((string) $value, array('https'));
        if (!$url || wp_parse_url($url, PHP_URL_SCHEME) !== 'https'
            || wp_parse_url($url, PHP_URL_USER) || wp_parse_url($url, PHP_URL_PASS)) { return ''; }
        $port = wp_parse_url($url, PHP_URL_PORT);
        if ($port && (int) $port !== 443) { return ''; }
        $host = strtolower((string) wp_parse_url($url, PHP_URL_HOST));
        $allowed = array(
            'douyin.com', 'www.douyin.com', 'v.douyin.com', 'live.douyin.com',
            'iesdouyin.com', 'www.iesdouyin.com',
            'xiaohongshu.com', 'www.xiaohongshu.com',
            'xhslink.com', 'www.xhslink.com',
        );
        return in_array($host, $allowed, true) ? $url : '';
    }

    private static function mark_updated() {
        update_option(self::OPTION_UPDATED, time(), false);
    }
}

Shuzijun_Fan_Community_API::init();
