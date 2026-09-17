<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Game_Leaderboard {
    private static function game_table_name() {
        global $wpdb;
        if (!isset($wpdb->prefix) || preg_match('/^[A-Za-z0-9_]+$/D', $wpdb->prefix) !== 1) { return ''; }
        return $wpdb->prefix . 'yishu_game_leaderboard';
    }

    /** Explicit deployment action only: HTTP reads and writes never create tables. */
    public static function ensure_game_leaderboard_storage() {
        if (PHP_SAPI !== 'cli' || !self::account_authority_enabled()) { return false; }
        if (self::game_leaderboard_storage_ready()) { return true; }
        $lock = self::acquire_named_fan_lock('game_schema', 'life-v1');
        if (is_wp_error($lock)) { return false; }
        try {
            if (self::game_leaderboard_storage_ready()) { return true; }
            global $wpdb;
            $table = self::game_table_name();
            if ($table === '' || !method_exists($wpdb, 'get_charset_collate')) { return false; }
            if (!function_exists('dbDelta')) { require_once ABSPATH . 'wp-admin/includes/upgrade.php'; }
            if (!function_exists('dbDelta')) { return false; }
            $charset = $wpdb->get_charset_collate();
            $sql = $wpdb->prepare("CREATE TABLE %i (
                fan_user_id bigint(20) unsigned NOT NULL,
                rules_version varchar(32) NOT NULL,
                score int(11) NOT NULL,
                ending_id varchar(64) NOT NULL,
                origin varchar(32) NOT NULL,
                answered smallint(5) unsigned NOT NULL,
                achieved_at datetime NOT NULL,
                PRIMARY KEY  (fan_user_id),
                KEY score_time_user (score, achieved_at, fan_user_id)
            ) ENGINE=InnoDB {$charset};", $table);
            dbDelta($sql);
            if (!empty($wpdb->last_error) || !self::game_leaderboard_storage_ready()) { return false; }
            return update_option(self::GAME_SCHEMA_OPTION, self::GAME_SCHEMA_VERSION, false)
                || (int) get_option(self::GAME_SCHEMA_OPTION, 0) === self::GAME_SCHEMA_VERSION;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    private static function game_leaderboard_storage_ready() {
        global $wpdb;
        $table = self::game_table_name();
        if ($table === '' || !isset($wpdb->users, $wpdb->usermeta)
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'esc_like')) { return false; }
        $status = $wpdb->get_row($wpdb->prepare('SHOW TABLE STATUS LIKE %s', $wpdb->esc_like($table)), ARRAY_A);
        if (!is_array($status) || !empty($wpdb->last_error)
            || ($status['Name'] ?? '') !== $table || strtoupper((string) ($status['Engine'] ?? '')) !== 'INNODB') {
            return false;
        }
        $columns = $wpdb->get_results($wpdb->prepare('SHOW COLUMNS FROM %i', $table), ARRAY_A);
        if (!is_array($columns) || !empty($wpdb->last_error)) { return false; }
        $types = array(
            'fan_user_id' => '/^bigint(?:\(20\))? unsigned$/D',
            'rules_version' => '/^varchar\(32\)$/D',
            'score' => '/^int(?:\(11\))?$/D',
            'ending_id' => '/^varchar\(64\)$/D',
            'origin' => '/^varchar\(32\)$/D',
            'answered' => '/^smallint(?:\(5\))? unsigned$/D',
            'achieved_at' => '/^datetime$/D',
        );
        if (count($columns) !== count($types)) { return false; }
        foreach ($columns as $column) {
            $field = $column['Field'] ?? '';
            if (!isset($types[$field]) || ($column['Null'] ?? '') !== 'NO'
                || preg_match($types[$field], strtolower((string) ($column['Type'] ?? ''))) !== 1) { return false; }
            unset($types[$field]);
        }
        if ($types) { return false; }
        $indexes = $wpdb->get_results($wpdb->prepare('SHOW INDEX FROM %i', $table), ARRAY_A);
        if (!is_array($indexes) || !empty($wpdb->last_error)) { return false; }
        $actual = array();
        foreach ($indexes as $index) {
            $name = $index['Key_name'] ?? '';
            if (!is_string($name) || !isset($index['Seq_in_index'], $index['Column_name'], $index['Non_unique'])) { return false; }
            if (($index['Sub_part'] ?? null) !== null) { return false; }
            $actual[$name]['columns'][(int) $index['Seq_in_index']] = $index['Column_name'];
            $actual[$name]['unique'] = (int) $index['Non_unique'] === 0;
        }
        foreach (array('PRIMARY' => array('fan_user_id'),
            'score_time_user' => array('score', 'achieved_at', 'fan_user_id')) as $name => $expected) {
            if (!isset($actual[$name])) { return false; }
            ksort($actual[$name]['columns']);
            if (array_values($actual[$name]['columns']) !== $expected
                || $actual[$name]['unique'] !== ($name === 'PRIMARY')) { return false; }
        }
        return true;
    }

    public static function can_access_game_leaderboard(WP_REST_Request $request) {
        self::$fan_session_context = null;
        if (!self::account_authority_enabled()) { return self::game_unavailable(); }
        // Unlike can_access_app_content(), this never admits Basic/WP managers.
        return self::can_access_approved_fan_content($request);
    }

    public static function get_game_leaderboard(WP_REST_Request $request) {
        return self::with_game_actor('read', function ($user_id, $rules) {
            return self::game_leaderboard_response($user_id, $rules);
        });
    }

    public static function submit_game_score(WP_REST_Request $request) {
        // Authenticate and charge this operation once before reading/validating
        // its body, including malformed and over-size attempts by approved fans.
        return self::with_game_actor('submit', function ($user_id, $rules) use ($request) {
            $bytes = (string) $request->get_body();
            if (strlen($bytes) > 4096) {
                return new WP_Error('game_payload_too_large', '本局记录过大。', array('status' => 413));
            }
            // Preserve JSON object/array identity: associative decoding would
            // turn {"0":0,"1":1,...} into a PHP list and admit a non-array trace.
            try { $body = json_decode($bytes, false, 16, JSON_THROW_ON_ERROR); }
            catch (Throwable $error) { return self::game_invalid_request(); }
            if (!($body instanceof stdClass) || !is_array($body->choices ?? null)) {
                return self::game_invalid_request();
            }
            $body = get_object_vars($body);
            $keys = array_keys($body); sort($keys);
            if ($keys !== array('choices', 'consent', 'origin', 'rulesVersion')
                || ($body['rulesVersion'] ?? null) !== Shuzijun_Game_Rules::VERSION
                || ($body['consent'] ?? null) !== true) { return self::game_invalid_request(); }
            // Only choices/origin reach the interpreter. Scores, names and IDs supplied
            // by a client are rejected; the full trajectory is never stored or logged.
            try { $result = $rules->replay($body['origin'], $body['choices']); }
            catch (InvalidArgumentException $error) { return self::game_invalid_request(); }
            catch (Throwable $error) { return self::game_unavailable(); }
            global $wpdb;
            $table = self::game_table_name();
            $existing = $wpdb->get_row($wpdb->prepare(
                'SELECT score, rules_version FROM %i WHERE fan_user_id = %d LIMIT 1', $table, $user_id
            ), ARRAY_A);
            if (!empty($wpdb->last_error) || ($existing !== null && !is_array($existing))) { return self::game_unavailable(); }
            if ($existing !== null && ($existing['rules_version'] ?? '') !== Shuzijun_Game_Rules::VERSION) {
                return self::game_unavailable();
            }
            if ($existing === null) {
                $saved = $wpdb->query($wpdb->prepare(
                    'INSERT INTO %i (fan_user_id, rules_version, score, ending_id, origin, answered, achieved_at)
                     VALUES (%d, %s, %d, %s, %s, %d, %s)',
                    $table, $user_id, Shuzijun_Game_Rules::VERSION, $result['score'],
                    $result['endingID'], $result['origin'], $result['answered'], gmdate('Y-m-d H:i:s')
                ));
                if ($saved !== 1 || !empty($wpdb->last_error)) { return self::game_unavailable(); }
            } elseif ($result['score'] > (int) $existing['score']) {
                // Same-score retries preserve the earlier record and its tie order.
                $saved = $wpdb->query($wpdb->prepare(
                    'UPDATE %i SET score = %d, ending_id = %s, origin = %s, answered = %d, achieved_at = %s
                     WHERE fan_user_id = %d AND rules_version = %s AND score < %d',
                    $table, $result['score'], $result['endingID'], $result['origin'], $result['answered'],
                    gmdate('Y-m-d H:i:s'), $user_id, Shuzijun_Game_Rules::VERSION, $result['score']
                ));
                if ($saved !== 1 || !empty($wpdb->last_error)) { return self::game_unavailable(); }
            }
            return self::game_leaderboard_response($user_id, $rules);
        });
    }

    public static function delete_game_score(WP_REST_Request $request) {
        return self::with_game_actor('delete', function ($user_id, $rules) use ($request) {
            $body = trim((string) $request->get_body());
            if ($body !== '' && $body !== '{}') { return self::game_invalid_request(); }
            if (!self::purge_game_leaderboard_for_fan_user($user_id)) { return self::game_unavailable(); }
            return self::game_leaderboard_response($user_id, $rules);
        });
    }

    private static function with_game_actor($operation, $callback) {
        $context = self::$fan_session_context;
        if (!is_array($context) || ($context['scope'] ?? '') !== 'normal'
            || (int) ($context['userID'] ?? 0) <= 0 || !self::account_authority_enabled()) {
            return new WP_Error('fan_session_required', '请重新登录。', array('status' => 401));
        }
        $user_id = (int) $context['userID'];
        $limit = self::rate_limit('game_' . $operation, (string) $user_id, $operation === 'read' ? 60 : 12, MINUTE_IN_SECONDS);
        if (is_wp_error($limit)) { return $limit; }
        $lock = self::acquire_fan_lock($user_id);
        if (is_wp_error($lock)) { return $lock; }
        try {
            if (!self::game_actor_is_current($context)) {
                return new WP_Error('game_session_changed', '账号状态已变更，请重新登录。', array('status' => 403));
            }
            if (!self::game_leaderboard_storage_ready()) { return self::game_unavailable(); }
            try { $rules = Shuzijun_Game_Rules::bundled(); }
            catch (Throwable $error) { return self::game_unavailable(); }
            return $callback($user_id, $rules);
        } finally {
            self::release_fan_lock($user_id, $lock);
        }
    }

    private static function game_actor_is_current($context) {
        if (!self::fan_session_context_is_current_from_database($context, 'normal')) { return false; }
        global $wpdb;
        $user_id = (int) $context['userID'];
        if ((int) $wpdb->get_var($wpdb->prepare('SELECT ID FROM %i WHERE ID = %d LIMIT 1', $wpdb->users, $user_id)) !== $user_id
            || !empty($wpdb->last_error)) { return false; }
        $status = self::fan_meta_from_database($user_id, self::FAN_META_STATUS, '');
        if ($status !== 'active' || !empty($wpdb->last_error)) { return false; }
        $uuid = self::fan_meta_from_database($user_id, self::FAN_META_UUID, '');
        if (!is_string($uuid) || $uuid === '' || !empty($wpdb->last_error)) { return false; }
        foreach (array(self::FAN_META_INVITATION, self::FAN_META_PASSWORD_RECOVERY, self::FAN_META_APPLE_SETUP) as $key) {
            $value = self::fan_meta_from_database($user_id, $key, null);
            if (!empty($value) || !empty($wpdb->last_error)) { return false; }
        }
        return self::fan_has_required_douyin_id($user_id) && empty($wpdb->last_error);
    }

    /** Internal literals only; the final composed statement prepares every value/identifier. */
    private static function game_visible_query_parts($projection, $tail = '', $tail_values = array()) {
        global $wpdb;
        $sql = 'SELECT ' . $projection . ' FROM %i b INNER JOIN %i u ON u.ID = b.fan_user_id
            WHERE b.rules_version = %s
            AND EXISTS (SELECT 1 FROM %i s WHERE s.user_id = b.fan_user_id AND s.meta_key = %s AND s.meta_value = %s)
            AND EXISTS (SELECT 1 FROM %i f WHERE f.user_id = b.fan_user_id AND f.meta_key = %s AND f.meta_value <> %s) ' . $tail;
        return array($sql, array_merge(array(
            self::game_table_name(), $wpdb->users, Shuzijun_Game_Rules::VERSION,
            $wpdb->usermeta, self::FAN_META_STATUS, 'active', $wpdb->usermeta, self::FAN_META_UUID, '',
        ), $tail_values));
    }

    private static function game_leaderboard_response($user_id, $rules) {
        global $wpdb;
        $projection = 'b.fan_user_id, b.rules_version, b.score, b.ending_id,
            b.origin, b.answered, b.achieved_at, u.display_name';
        $top = self::game_visible_query_parts($projection,
            'ORDER BY b.score DESC, b.achieved_at ASC, b.fan_user_id ASC LIMIT %d', array(100));
        $own = self::game_visible_query_parts($projection, 'AND b.fan_user_id = %d LIMIT 1', array($user_id));
        $before = self::game_visible_query_parts('COUNT(*)',
            'AND (b.score > candidate.score OR (b.score = candidate.score
            AND (b.achieved_at < candidate.achieved_at OR (b.achieved_at = candidate.achieved_at
            AND b.fan_user_id < candidate.fan_user_id))))');
        // One consistent-read statement covers the list and own rank. Another
        // user's withdrawal/suspension cannot mix two snapshots into a page.
        // UNION deduplicates an own row already in the top 100; only that row
        // needs the correlated count. No transaction or session state is changed.
        $sql = 'SELECT candidate.fan_user_id, candidate.rules_version, candidate.score, candidate.ending_id,
            candidate.origin, candidate.answered, candidate.achieved_at, candidate.display_name,
            CASE WHEN candidate.fan_user_id = %d THEN (' . $before[0] . ') + 1 ELSE 0 END AS own_rank
            FROM ((' . $top[0] . ') UNION (' . $own[0] . ')) AS candidate
            ORDER BY candidate.score DESC, candidate.achieved_at ASC, candidate.fan_user_id ASC LIMIT %d';
        $values = array_merge(array($user_id), $before[1], $top[1], $own[1], array(101));
        $rows = $wpdb->get_results($wpdb->prepare($sql, $values), ARRAY_A);
        if (!is_array($rows) || count($rows) > 101 || !empty($wpdb->last_error)) { return self::game_unavailable(); }
        $entries = array();
        $mine = null;
        foreach ($rows as $index => $row) {
            $is_me = (int) ($row['fan_user_id'] ?? 0) === (int) $user_id;
            $own_rank = filter_var($row['own_rank'] ?? null, FILTER_VALIDATE_INT);
            if ($own_rank === false || ($is_me && ($mine !== null || $own_rank < 1
                    || ($index < 100 ? $own_rank !== $index + 1 : $own_rank <= 100)))
                || (!$is_me && ($own_rank !== 0 || $index >= 100))) { return self::game_unavailable(); }
            $entry = self::game_public_entry($row, $is_me ? $own_rank : $index + 1, $user_id, $rules);
            if ($entry === null) { return self::game_unavailable(); }
            if ($index < 100) { $entries[] = $entry; }
            if ($is_me) { $mine = $entry; }
        }
        $response = rest_ensure_response(array('rulesVersion' => Shuzijun_Game_Rules::VERSION,
            'entries' => $entries, 'myEntry' => $mine));
        $response->header('Cache-Control', 'private, no-store, max-age=0');
        $response->header('Pragma', 'no-cache');
        $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        return $response;
    }

    private static function game_public_entry($row, $rank, $user_id, $rules) {
        $title = $rules->ending_title($row['ending_id'] ?? '');
        $origin = $rules->origin_name($row['origin'] ?? '');
        $score = filter_var($row['score'] ?? null, FILTER_VALIDATE_INT);
        $answered = filter_var($row['answered'] ?? null, FILTER_VALIDATE_INT);
        $time = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s', (string) ($row['achieved_at'] ?? ''), new DateTimeZone('UTC'));
        if ($title === null || $origin === null || $score === false || $score < -16777216 || $score > 16777215
            || $answered === false || $answered < 1 || $answered > 108 || !$time
            || $time->format('Y-m-d H:i:s') !== ($row['achieved_at'] ?? '') || $rank < 1) { return null; }
        return array('rank' => (int) $rank,
            'displayName' => self::game_public_display_name($row['display_name'] ?? ''), 'score' => $score,
            'endingTitle' => $title, 'originName' => $origin, 'answered' => $answered,
            'achievedAt' => $time->format('Y-m-d\TH:i:s\Z'),
            'isMe' => (int) ($row['fan_user_id'] ?? 0) === (int) $user_id);
    }

    private static function game_public_display_name($value) {
        $name = trim(sanitize_text_field((string) $value));
        // Match entire machine-generated fallback values, not fragments of a
        // person's nickname. Check before truncation so a long login/email
        // cannot turn into a public partial identifier. No extra PII is stored.
        if (filter_var($name, FILTER_VALIDATE_EMAIL) !== false
            || preg_match('/^(?:HS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}'
                . '|IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}'
                . '|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'
                . '|(?:fan_(?:apple_)?)?[a-f0-9]{32}'
                . '|受邀粉丝 [ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4})$/iuD', $name) === 1) {
            return '玩家';
        }
        return preg_match('/^.{1,40}/us', $name, $match) === 1 ? $match[0] : '玩家';
    }

    /** Caller owns the same per-user lock used by score writes and account deletion. */
    public static function purge_game_leaderboard_for_fan_user($user_id) {
        global $wpdb;
        $table = self::game_table_name();
        if ((int) $user_id <= 0 || $table === '' || !method_exists($wpdb, 'esc_like')) { return false; }
        $found = $wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)));
        if (!empty($wpdb->last_error)) { return false; }
        // Older installations have no game table. A missing feature must not
        // disable account deletion; an inaccessible existing table must fail shut.
        if ($found === null) { return true; }
        if ($found !== $table || !self::game_leaderboard_storage_ready()) { return false; }
        $deleted = $wpdb->query($wpdb->prepare('DELETE FROM %i WHERE fan_user_id = %d', $table, (int) $user_id));
        return $deleted !== false && empty($wpdb->last_error);
    }

    private static function game_invalid_request() {
        return new WP_Error('game_submission_invalid', '本局记录无效或尚未结束，请完成游戏后再提交。', array('status' => 400));
    }

    private static function game_unavailable() {
        return new WP_Error('game_leaderboard_unavailable', '排行榜暂时不可用，不影响本地游戏。', array('status' => 503));
    }
}
