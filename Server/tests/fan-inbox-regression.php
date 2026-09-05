<?php
declare(strict_types=1);

// Included by plugin-contract-test.php. These fixtures execute the real inbox
// callbacks using transactional, user-scoped rows. No WP runtime, live account,
// database, device token, mail or network provider is used.
final class Yishu_Fan_Inbox_Test_DB {
    public string $options = 'wp_options';
    public string $users = 'wp_users';
    public string $usermeta = 'wp_usermeta';
    public string $prefix = 'wp_';
    public string $last_error = '';
    public array $notifications = array();
    public array $recipients = array();
    public array $sessions = array();
    public array $meta = array();
    public array $existing_users = array(17, 18);
    public array $operations = array();
    public string $fail_at = '';
    public bool $zero_read_update = false;
    public ?int $last_list_limit = null;
    private ?array $snapshot = null;

    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }
    public function esc_like(string $value): string { return $value; }

    private function operation(string $operation): bool {
        $this->last_error = '';
        $this->operations[] = $operation;
        if ($this->fail_at !== $operation) { return true; }
        $this->last_error = 'simulated_inbox_failure';
        return false;
    }
    private function require_sql(string $query, array $clauses): void {
        foreach ($clauses as $clause) {
            if (strpos($query, $clause) === false) {
                throw new RuntimeException('Inbox fixture received a query without its required boundary: ' . $clause);
            }
        }
    }
    private function visible_rows(int $user_id, string $now): array {
        $rows = array();
        foreach ($this->recipients as $recipient) {
            $row = $this->notifications[$recipient['notification_id']] ?? null;
            if ($recipient['fan_user_id'] !== $user_id || $row === null || $row['expires_at'] <= $now) { continue; }
            $rows[] = $row + array('read_at' => $recipient['read_at']);
        }
        usort($rows, static fn(array $a, array $b): int => $b['id'] <=> $a['id']);
        return $rows;
    }
    private function joined_query(string $query): void {
        $this->require_sql($query, array(
            'FROM wp_yishu_push_recipients r',
            'INNER JOIN wp_yishu_push_notifications n ON n.id = r.notification_id',
            'WHERE r.fan_user_id = %d', 'n.expires_at > %s',
        ));
    }
    public function get_var($prepared) {
        $query = $prepared['query'];
        $args = $prepared['arguments'];
        if (strpos($query, 'GET_LOCK') !== false) {
            return $this->operation('lock') ? '1' : '0';
        }
        if (strpos($query, 'RELEASE_LOCK') !== false) {
            $this->operation('unlock');
            return '1';
        }
        if (strpos($query, 'SHOW TABLES LIKE') !== false) {
            $this->operation('table');
            return $args[0];
        }
        if (strpos($query, 'SELECT option_value FROM wp_options') !== false) {
            $this->require_sql($query, array('WHERE option_name = %s', 'FOR UPDATE'));
            if (!$this->operation('session')) { return null; }
            return isset($this->sessions[$args[0]]) ? serialize($this->sessions[$args[0]]) : null;
        }
        if (strpos($query, 'SELECT ID FROM wp_users') !== false) {
            $this->require_sql($query, array('WHERE ID = %d', 'FOR UPDATE'));
            if (!$this->operation('user')) { return null; }
            return in_array($args[0], $this->existing_users, true) ? (string) $args[0] : null;
        }
        if (strpos($query, 'SELECT meta_value FROM wp_usermeta') !== false) {
            $this->require_sql($query, array('WHERE user_id = %d AND meta_key = %s', 'FOR UPDATE'));
            if (!$this->operation('meta:' . $args[1])) { return null; }
            return array_key_exists($args[1], $this->meta[$args[0]] ?? array())
                ? serialize($this->meta[$args[0]][$args[1]]) : null;
        }
        if (strpos($query, 'SELECT COUNT(*)') !== false) {
            $this->joined_query($query);
            $this->require_sql($query, array('r.read_at IS NULL'));
            if (!$this->operation('count')) { return null; }
            return (string) count(array_filter($this->visible_rows($args[0], $args[1]),
                static fn(array $row): bool => $row['read_at'] === null));
        }
        throw new RuntimeException('Unexpected inbox scalar query');
    }
    public function get_results($prepared, $output) {
        $query = $prepared['query'];
        $args = $prepared['arguments'];
        $this->joined_query($query);
        $this->require_sql($query, array('n.id < %d', 'ORDER BY n.id DESC LIMIT %d'));
        if (!$this->operation('list')) { return null; }
        $this->last_list_limit = $args[3];
        $rows = array_filter($this->visible_rows($args[0], $args[1]),
            static fn(array $row): bool => $row['id'] < $args[2]);
        return array_slice(array_values($rows), 0, $args[3]);
    }
    public function get_row($prepared, $output) {
        $query = $prepared['query'];
        $args = $prepared['arguments'];
        $this->joined_query($query);
        $this->require_sql($query, array('n.public_id = %s', 'LIMIT 1 FOR UPDATE'));
        if (!$this->operation('detail')) { return null; }
        foreach ($this->visible_rows($args[0], $args[2]) as $row) {
            if ($row['public_id'] === $args[1]) { return $row; }
        }
        return null;
    }
    public function query($prepared) {
        $query = is_array($prepared) ? $prepared['query'] : $prepared;
        $args = is_array($prepared) ? $prepared['arguments'] : array();
        if (in_array($query, array('START TRANSACTION', 'COMMIT', 'ROLLBACK'), true)) {
            $operation = array('START TRANSACTION' => 'begin', 'COMMIT' => 'commit', 'ROLLBACK' => 'rollback')[$query];
            if (!$this->operation($operation)) { return false; }
            if ($operation === 'begin') { $this->snapshot = array($this->notifications, $this->recipients); }
            elseif ($operation === 'rollback' && $this->snapshot !== null) {
                [$this->notifications, $this->recipients] = $this->snapshot;
                $this->snapshot = null;
            } else { $this->snapshot = null; }
            return 0;
        }
        if (strpos($query, 'UPDATE wp_yishu_push_recipients SET read_at') !== false) {
            $this->require_sql($query, array('WHERE notification_id = %d AND fan_user_id = %d AND read_at IS NULL'));
            if (!$this->operation('mark_read')) { return false; }
            if ($this->zero_read_update) { return 0; }
            $key = $args[2] . ':' . $args[1];
            if (!isset($this->recipients[$key]) || $this->recipients[$key]['read_at'] !== null) { return 0; }
            $this->recipients[$key]['read_at'] = $args[0];
            return 1;
        }
        if (strpos($query, 'DELETE FROM wp_yishu_push_recipients WHERE fan_user_id') !== false) {
            if (!$this->operation('purge_recipients')) { return false; }
            return $this->delete_recipients(static fn(array $row): bool => $row['fan_user_id'] === $args[0]);
        }
        if (strpos($query, 'DELETE n FROM wp_yishu_push_notifications n') !== false) {
            $this->require_sql($query, array('LEFT JOIN wp_yishu_push_recipients r ON r.notification_id = n.id', 'WHERE r.id IS NULL'));
            if (!$this->operation('purge_orphans')) { return false; }
            $live = array_column($this->recipients, 'notification_id');
            $before = count($this->notifications);
            $this->notifications = array_filter($this->notifications,
                static fn(array $row): bool => in_array($row['id'], $live, true));
            return $before - count($this->notifications);
        }
        if (strpos($query, 'DELETE r FROM wp_yishu_push_recipients r') !== false) {
            $this->require_sql($query, array('INNER JOIN wp_yishu_push_notifications n ON n.id = r.notification_id', 'WHERE n.expires_at <= %s'));
            if (!$this->operation('expire_recipients')) { return false; }
            return $this->delete_recipients(fn(array $row): bool => $this->notifications[$row['notification_id']]['expires_at'] <= $args[0]);
        }
        if (strpos($query, 'DELETE FROM wp_yishu_push_notifications WHERE expires_at') !== false) {
            if (!$this->operation('expire_notifications')) { return false; }
            $before = count($this->notifications);
            $this->notifications = array_filter($this->notifications,
                static fn(array $row): bool => $row['expires_at'] > $args[0]);
            return $before - count($this->notifications);
        }
        // No devices/jobs exist in this fixture. Only the known maintenance
        // statements may report zero affected rows; inbox reads never reach here.
        foreach (array('UPDATE wp_yishu_push_install_states', 'DELETE FROM wp_yishu_push_install_states',
            'DELETE FROM wp_yishu_push_devices', 'DELETE d FROM wp_yishu_push_devices d',
            'UPDATE wp_yishu_push_outbox', 'DELETE FROM wp_yishu_push_outbox', 'DELETE o FROM wp_yishu_push_outbox o') as $prefix) {
            if (strpos($query, $prefix) === 0) { $this->operation('maintenance_empty'); return 0; }
        }
        throw new RuntimeException('Unexpected inbox write');
    }
    private function delete_recipients(callable $predicate): int {
        $before = count($this->recipients);
        $this->recipients = array_filter($this->recipients, static fn(array $row): bool => !$predicate($row));
        return $before - count($this->recipients);
    }
}

$inbox_saved = array(
    'db' => $GLOBALS['wpdb'], 'options' => $GLOBALS['yishu_test_options'],
    'filters' => $GLOBALS['yishu_test_filters'], 'scheduled' => $GLOBALS['yishu_test_scheduled'],
    'routes' => $GLOBALS['yishu_test_registered_routes'],
    'role' => file_get_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH),
    'apns_key_id' => getenv('YISHU_APNS_KEY_ID'),
);
$inbox_schema = new ReflectionProperty(Shuzijun_App_Content_API::class, 'push_schema_verified');
$inbox_schema->setAccessible(true);
$inbox_saved['schema'] = $inbox_schema->getValue();
$inbox_context_property = new ReflectionProperty(Shuzijun_App_Content_API::class, 'fan_session_context');
$inbox_context_property->setAccessible(true);
$inbox_saved['context'] = $inbox_context_property->getValue();
try {
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, "authority\n");
    $GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::PUSH_SCHEMA_OPTION] = Shuzijun_App_Content_API::PUSH_SCHEMA_VERSION;
    // Migration/schema-shape tests are independent. Exercise the callbacks after
    // that gate without introducing broader WordPress/user function stubs.
    $inbox_schema->setValue(null, true);
    $inbox_install = 'b402f570-8a03-427d-87b1-1821f206015b';
    $inbox_context = array(
        'userID' => 17, 'scope' => 'normal', 'expires' => time() + HOUR_IN_SECONDS,
        'credentialEpoch' => 3, 'authMethod' => 'password', 'recentAuthUntil' => 0,
        'sessionID' => str_repeat('7', 32), 'installHash' => hash('sha256', $inbox_install),
        'tokenHash' => hash('sha256', 'inbox-fixture-session-identifier'),
    );
    $inbox_uuid = static fn(int $id): string => 'bb329060-dbd5-4117-9876-' . str_pad((string) $id, 12, '0', STR_PAD_LEFT);
    $inbox_factory = static function () use ($inbox_context, $inbox_uuid): Yishu_Fan_Inbox_Test_DB {
        $db = new Yishu_Fan_Inbox_Test_DB();
        $db->sessions[Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $inbox_context['tokenHash']] = $inbox_context;
        $db->meta[17] = array(
            Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH => 3,
            Shuzijun_App_Content_API::FAN_META_UUID => 'ba329060-dbd5-4117-9876-111111111117',
            Shuzijun_App_Content_API::FAN_META_STATUS => 'active',
            Shuzijun_App_Content_API::FAN_META_DOUYIN_ID => 'inbox_fixture_17',
        );
        foreach (array(40, 30, 20, 15, 10, 5) as $id) {
            $db->notifications[$id] = array(
                'id' => $id, 'public_id' => $inbox_uuid($id), 'title' => 'Fixture title ' . $id,
                'body' => 'Private fixture body ' . $id, 'is_sensitive' => 1,
                'created_at' => gmdate('Y-m-d H:i:s', time() - HOUR_IN_SECONDS),
                'expires_at' => gmdate('Y-m-d H:i:s', time() + ($id === 5 ? -60 : DAY_IN_SECONDS)),
            );
            $owner = $id === 40 ? 18 : 17;
            $db->recipients[$owner . ':' . $id] = array(
                'notification_id' => $id, 'fan_user_id' => $owner,
                'read_at' => $id === 20 ? gmdate('Y-m-d H:i:s', time() - 600) : null,
            );
        }
        $db->recipients['18:15'] = array('notification_id' => 15, 'fan_user_id' => 18, 'read_at' => null);
        return $db;
    };
    $inbox_call = static function (Yishu_Fan_Inbox_Test_DB $db, string $method, array $parameters = array(), ?array $context = null)
        use ($inbox_context_property, $inbox_context, $inbox_install) {
        $GLOBALS['wpdb'] = $db;
        $inbox_context_property->setValue(null, $context ?? $inbox_context);
        return invoke_plugin_method($method, array(new WP_REST_Request(
            $parameters, array('X-Yishu-Install-ID' => $inbox_install), '',
            $method === 'mark_fan_notification_read' ? 'POST' : 'GET'
        )));
    };

    $GLOBALS['yishu_test_registered_routes'] = array();
    Shuzijun_App_Content_API::register_routes();
    $inbox_routes = array_values(array_filter($GLOBALS['yishu_test_registered_routes'],
        static fn(array $route): bool => strpos($route['route'], '/fan/notifications') === 0));
    expect_same(3, count($inbox_routes), '粉丝消息只能注册列表、详情与显式已读三个路由');
    expect_same(array('GET', 'GET', 'POST'), array_column(array_column($inbox_routes, 'arguments'), 'methods'), '只有显式已读允许 POST，粉丝不得发送或回复');
    expect_same(array('list_fan_notifications', 'get_fan_notification', 'mark_fan_notification_read'),
        array_map(static fn(array $route): string => $route['arguments']['callback'][1], $inbox_routes), '收件箱不得混入管理员发送回调');
    foreach ($inbox_routes as $route) {
        expect_same('can_access_normal_fan_session', $route['arguments']['permission_callback'][1], '每个收件箱路由必须有普通完整会话权限门禁');
        $denied = invoke_plugin_method($route['arguments']['permission_callback'][1], array(new WP_REST_Request()));
        expect_error_code('fan_session_required', $denied, '匿名用户访问收件箱必须拒绝');
        expect_same(401, $denied->get_error_data()['status'], '匿名收件箱返回 401');
    }
    $inbox_context_property->setValue(null, null);
    expect_error_code('fan_session_required', invoke_plugin_method('list_fan_notifications', array(new WP_REST_Request())), '遗漏权限上下文时 callback 本身也失败关闭');

    $db = $inbox_factory();
    $before = $db->recipients;
    $first = $inbox_call($db, 'list_fan_notifications', array('limit' => 2));
    expect_true($first instanceof WP_REST_Response, '无设备、无系统通知许可仍可读取云端消息');
    expect_same(array($inbox_uuid(30), $inbox_uuid(20)), array_column($first->data['notifications'], 'notificationID'), '列表必须过滤他人和过期消息，并按 ID 降序');
    expect_same('20', $first->data['nextCursor'], '分页游标为末条稳定 ID 字符串');
    expect_same(3, $first->data['unreadCount'], '未读总数排除他人、已读和已过期消息');
    expect_same($before, $db->recipients, '列表读取不隐式标为已读');
    expect_same('private, no-store, max-age=0', $first->headers['Cache-Control'], '私信响应不得缓存到共享或磁盘缓存');
    expect_same('Authorization, X-Yishu-Install-ID', $first->headers['Vary'], '响应缓存变化包含用户与安装身份');
    $db->notifications[35] = array_replace($db->notifications[30], array('id' => 35, 'public_id' => $inbox_uuid(35)));
    $db->recipients['17:35'] = array('notification_id' => 35, 'fan_user_id' => 17, 'read_at' => null);
    $next = $inbox_call($db, 'list_fan_notifications', array('limit' => 2, 'cursor' => $first->data['nextCursor']));
    expect_same(array($inbox_uuid(15), $inbox_uuid(10)), array_column($next->data['notifications'], 'notificationID'), '两页间有新消息插入也不得重复或跳过旧消息');
    expect_same(null, $next->data['nextCursor'], '最后一页不返回多余游标');
    $empty = $inbox_call($db, 'list_fan_notifications', array('cursor' => '1'));
    expect_same(array(), $empty->data['notifications'], '空页仍是有效收件箱响应');
    expect_same(null, $empty->data['nextCursor'], '空页没有下一页');
    expect_same(4, $empty->data['unreadCount'], '分页位置不影响全收件箱未读总数');
    expect_same(21, $db->last_list_limit, '默认只取 20 条加 1 条下一页探测，不全量查询');
    expect_true($inbox_call($db, 'list_fan_notifications', array('limit' => '50')) instanceof WP_REST_Response, '字符串最大页大小 50 是有效请求');
    expect_same(51, $db->last_list_limit, '最大页大小仍有界为 50 条加 1 条探测');
    expect_true(!in_array('maintenance_empty', $db->operations, true), '读取云端消息不访问或绑定推送设备');

    $db = $inbox_factory();
    $before = $db->recipients;
    $detail = $inbox_call($db, 'get_fan_notification', array('notificationID' => $inbox_uuid(15)));
    expect_same('Private fixture body 15', $detail->data['notification']['body'], '本人详情返回云端保存的敏感原文');
    expect_same(true, $detail->data['notification']['sensitive'], '敏感标记保持真实');
    expect_same(null, $detail->data['notification']['readAt'], '打开详情不自动确认已读');
    expect_same($before, $db->recipients, '详情 GET 必须无已读副作用');
    expect_true(preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/D', $detail->data['notification']['createdAt']) === 1, '云端时间明确编码为 UTC ISO8601');
    $read = $inbox_call($db, 'mark_fan_notification_read', array('notificationID' => $inbox_uuid(15)));
    expect_true(is_string($read->data['notification']['readAt']), '显式已读请求记录已读时间');
    expect_same(null, $db->recipients['18:15']['read_at'], '共享广播也不得标记其他收件人的已读时间');
    $count_updates = count(array_filter($db->operations, static fn(string $op): bool => $op === 'mark_read'));
    $read_again = $inbox_call($db, 'mark_fan_notification_read', array('notificationID' => $inbox_uuid(15)));
    expect_same($read->data, $read_again->data, '重复已读请求必须保持原时间并幂等返回');
    expect_same($count_updates, count(array_filter($db->operations, static fn(string $op): bool => $op === 'mark_read')), '幂等已读不得重复执行 UPDATE');
    expect_same(2, $inbox_call($db, 'list_fan_notifications')->data['unreadCount'], '只有显式已读才减少未读数');
    $other_context = array_replace($inbox_context, array('userID' => 18,
        'tokenHash' => hash('sha256', 'inbox-other-fixture-session'), 'sessionID' => str_repeat('9', 32)));
    $db->sessions[Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $other_context['tokenHash']] = $other_context;
    $db->meta[18] = array_replace($db->meta[17], array(
        Shuzijun_App_Content_API::FAN_META_UUID => 'ba329060-dbd5-4117-9876-111111111118',
        Shuzijun_App_Content_API::FAN_META_DOUYIN_ID => 'inbox_fixture_18',
    ));
    $other_inbox = $inbox_call($db, 'list_fan_notifications', array(), $other_context);
    expect_same(array($inbox_uuid(40), $inbox_uuid(15)), array_column($other_inbox->data['notifications'], 'notificationID'), '切换身份后只读取新用户收件关系，不沿用旧用户 ID');
    expect_same(2, $other_inbox->data['unreadCount'], '另一账号独立保留自己的广播未读状态');
    foreach (array($inbox_uuid(40), $inbox_uuid(5), $inbox_uuid(999), 'not-a-uuid') as $id) {
        foreach (array('get_fan_notification', 'mark_fan_notification_read') as $method) {
            $result = $inbox_call($db, $method, array('notificationID' => $id));
            expect_error_code('fan_notification_not_found', $result, '他人、不存在、过期和非法消息 ID 统一隐藏');
            expect_same(404, $result->get_error_data()['status'], '不可访问的消息统一返回 404');
        }
    }

    foreach (array('pending', 'active') as $status) {
        $db = $inbox_factory();
        $db->meta[17][Shuzijun_App_Content_API::FAN_META_STATUS] = $status;
        expect_true($inbox_call($db, 'list_fan_notifications') instanceof WP_REST_Response, '完整待审批或已批准账号可收到管理消息：' . $status);
    }
    foreach (array('paused', 'rejected', 'restricted', '') as $status) {
        $db = $inbox_factory();
        $db->meta[17][Shuzijun_App_Content_API::FAN_META_STATUS] = $status;
        expect_error_code('fan_inbox_unavailable', $inbox_call($db, 'list_fan_notifications'), '锁内必须重新验证实际账号状态：' . $status);
        expect_true(in_array('rollback', $db->operations, true), '资格变化必须回滚并结束事务');
    }
    foreach (array(Shuzijun_App_Content_API::FAN_META_INVITATION,
        Shuzijun_App_Content_API::FAN_META_PASSWORD_RECOVERY, Shuzijun_App_Content_API::FAN_META_APPLE_SETUP) as $key) {
        $db = $inbox_factory();
        $db->meta[17][$key] = array('pending' => true);
        expect_error_code('fan_inbox_unavailable', $inbox_call($db, 'list_fan_notifications'), '邀请、恢复或 Apple 设置未完成不得读消息：' . $key);
    }
    foreach (array('', 'invalid id') as $douyin) {
        $db = $inbox_factory();
        $db->meta[17][Shuzijun_App_Content_API::FAN_META_DOUYIN_ID] = $douyin;
        expect_error_code('fan_inbox_unavailable', $inbox_call($db, 'list_fan_notifications'), '抖音 ID 缺失或未规范化不得读消息');
    }
    $db = $inbox_factory();
    $db->existing_users = array(18);
    expect_error_code('fan_inbox_unavailable', $inbox_call($db, 'list_fan_notifications'), '权限检查后账号已删除必须在锁内拒绝');
    foreach (array('epoch', 'expired', 'revoked', 'scope', 'install', 'session') as $failure) {
        $db = $inbox_factory();
        $session_key = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $inbox_context['tokenHash'];
        if ($failure === 'epoch') { $db->meta[17][Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH] = 4; }
        elseif ($failure === 'expired') { $db->sessions[$session_key]['expires'] = time() - 1; }
        elseif ($failure === 'revoked') { unset($db->sessions[$session_key]); }
        elseif ($failure === 'scope') { $db->sessions[$session_key]['scope'] = 'apple_onboarding'; }
        elseif ($failure === 'install') { $db->sessions[$session_key]['installHash'] = hash('sha256', 'other-install'); }
        else { $db->sessions[$session_key]['sessionID'] = str_repeat('8', 32); }
        expect_error_code('fan_session_invalid', $inbox_call($db, 'list_fan_notifications'), '权限检查后会话变化必须重新鉴权失败：' . $failure);
        expect_true(!in_array('list', $db->operations, true), '失效会话不得执行消息查询');
    }
    $db = $inbox_factory();
    expect_error_code('fan_session_invalid', $inbox_call($db, 'list_fan_notifications', array(),
        array_replace($inbox_context, array('installHash' => hash('sha256', 'different-install')))), 'GET 安装 header 与当前会话必须一致');
    expect_same(array(), $db->operations, '错误安装不得进入数据库或获取锁');
    expect_error_code('fan_session_required', $inbox_call($db, 'list_fan_notifications', array(),
        array_replace($inbox_context, array('scope' => 'onboarding'))), '受限会话不得借用普通收件箱 callback');
    foreach (array(array('limit' => 0), array('limit' => 51), array('limit' => array(2)), array('limit' => '02'),
        array('cursor' => 2), array('cursor' => '-1'), array('cursor' => '9223372036854775808'), array('cursor' => '1 OR 1')) as $parameters) {
        $db = $inbox_factory();
        expect_error_code('fan_inbox_page_invalid', $inbox_call($db, 'list_fan_notifications', $parameters), '分页参数严格验证数值类型及上限');
        expect_same(array(), $db->operations, '无效分页不应访问数据库');
    }

    foreach (array('begin', 'session', 'user', 'meta:' . Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH,
        'meta:' . Shuzijun_App_Content_API::FAN_META_STATUS, 'list', 'count', 'commit') as $failure) {
        $db = $inbox_factory();
        $db->fail_at = $failure;
        $before = $db->recipients;
        expect_error_code('push_storage_unavailable', $inbox_call($db, 'list_fan_notifications'), '列表数据库错误不得伪装为空收件箱：' . $failure);
        expect_same($before, $db->recipients, '失败不得改变已读状态');
        if ($failure !== 'begin') { expect_true(in_array('rollback', $db->operations, true), '已开始的失败事务必须回滚'); }
        expect_same('unlock', end($db->operations), '失败后必须释放用户锁');
    }
    foreach (array('detail', 'mark_read', 'commit', 'zero_read') as $failure) {
        $db = $inbox_factory();
        if ($failure === 'zero_read') { $db->zero_read_update = true; }
        else { $db->fail_at = $failure; }
        $before = $db->recipients;
        expect_error_code('push_storage_unavailable', $inbox_call($db, 'mark_fan_notification_read', array('notificationID' => $inbox_uuid(15))), '已读操作失败必须报告存储失败：' . $failure);
        expect_same($before, $db->recipients, 'UPDATE 或 COMMIT 失败必须回滚本人及其他收件人状态');
        expect_true(in_array('rollback', $db->operations, true), '已读失败必须回滚');
        expect_same('unlock', end($db->operations), '已读失败必须释放用户锁');
    }
    $db = $inbox_factory();
    $db->fail_at = 'lock';
    expect_error_code('fan_setup_busy', $inbox_call($db, 'list_fan_notifications'), '用户锁不可用不得绕过隔离');
    expect_true(!in_array('begin', $db->operations, true) && !in_array('list', $db->operations, true), '未取得锁不得打开事务或读取消息');

    $inbox_sensitive = $inbox_factory()->notifications[30];
    $inbox_original = $inbox_sensitive;
    $apns = json_decode(invoke_plugin_method('push_apns_payload', array($inbox_sensitive)), true);
    expect_same(array('title' => 'Hi，梳子', 'body' => '有新消息，请登录查看'), $apns['aps']['alert'], '敏感 APNs 横幅只有通用提示');
    expect_same($inbox_sensitive['public_id'], $apns['notificationID'], 'APNs 只附带路由需要的公共消息 UUID');
    expect_same(array('aps', 'notificationID'), array_keys($apns), 'APNs 不携带收件人资料或敏感字段');
    expect_true(strpos(json_encode($apns), $inbox_sensitive['body']) === false, '敏感原文不得进入 APNs payload');
    expect_same($inbox_original, $inbox_sensitive, '传输脱敏不应覆盖云端原始消息');
    $public = array_replace($inbox_sensitive, array('is_sensitive' => 0));
    $public_apns = json_decode(invoke_plugin_method('push_apns_payload', array($public)), true);
    expect_same($public['body'], $public_apns['aps']['alert']['body'], '明确非敏感消息可显示公开正文');
    expect_same(null, invoke_plugin_method('push_apns_payload', array(array_replace($public, array('public_id' => 'invalid')))), '非法消息 UUID 不得生成推送');

    $GLOBALS['yishu_test_filters']['yishu_apns_provider_configuration'] = static function () {
        return new WP_Error('fixture_provider_disabled', '', array('status' => 503));
    };
    $GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static function () {
        throw new RuntimeException('Inbox retention test must never attempt APNs delivery');
    };
    // Provider test filters accept successful configurations only. Clear this
    // process-local setting as well, so an inherited real key cannot be used.
    putenv('YISHU_APNS_KEY_ID');
    $db = $inbox_factory();
    $GLOBALS['wpdb'] = $db;
    expect_same(false, invoke_plugin_method('sweep_push_outbox'), 'APNs 不可用时 worker 如实报告投递不可用，但不跳过保留期清理或尝试发送');
    expect_true(!isset($db->notifications[5]) && !isset($db->recipients['17:5']), '过期正文及对应收件记录一起删除');
    expect_true(isset($db->notifications[15]) && isset($db->recipients['18:15']), '保留期清理不得删除尚未过期的广播');
    $db = $inbox_factory();
    $GLOBALS['wpdb'] = $db;
    expect_same(true, invoke_plugin_method('purge_push_data_for_fan_user', array(17)), '删号清理必须清除本人的云端收件记录');
    expect_same(array('18:40', '18:15'), array_keys($db->recipients), '删除本人不影响其他粉丝的收件记录');
    expect_same(array(40, 15), array_keys($db->notifications), '仅清理无收件人的正文，共享消息保留给其他人');
    foreach (array('purge_recipients', 'purge_orphans', 'commit') as $failure) {
        $db = $inbox_factory();
        $db->fail_at = $failure;
        $GLOBALS['wpdb'] = $db;
        $before = array($db->notifications, $db->recipients);
        expect_same(false, invoke_plugin_method('purge_push_data_for_fan_user', array(17)), '删号消息清理遇到数据库失败必须返回失败');
        expect_same($before, array($db->notifications, $db->recipients), '删号事务失败不得误删其他人正文或遗留半清理');
        expect_true(in_array('rollback', $db->operations, true), '删号失败必须回滚');
    }
} finally {
    $GLOBALS['wpdb'] = $inbox_saved['db'];
    $GLOBALS['yishu_test_options'] = $inbox_saved['options'];
    $GLOBALS['yishu_test_filters'] = $inbox_saved['filters'];
    $GLOBALS['yishu_test_scheduled'] = $inbox_saved['scheduled'];
    $GLOBALS['yishu_test_registered_routes'] = $inbox_saved['routes'];
    putenv($inbox_saved['apns_key_id'] === false ? 'YISHU_APNS_KEY_ID' : 'YISHU_APNS_KEY_ID=' . $inbox_saved['apns_key_id']);
    $inbox_schema->setValue(null, $inbox_saved['schema']);
    $inbox_context_property->setValue(null, $inbox_saved['context']);
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, $inbox_saved['role']);
}
