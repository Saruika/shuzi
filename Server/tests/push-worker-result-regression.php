<?php
declare(strict_types=1);

// Executed last: WP_CLI is deliberately defined only after normal-hook tests.
// Every database/provider operation stays in memory; no WP/APNs/network I/O.
final class Yishu_Push_Worker_Result_DB {
    public string $prefix = 'wp_';
    public string $options = 'wp_options';
    public string $users = 'wp_users';
    public string $usermeta = 'wp_usermeta';
    public string $last_error = '';
    public int $cleanup_count = 0;
    public int $cleanup_fail_at = 0;
    public bool $cleanup_throw = false;
    public bool $selection_fail = false;
    public bool $legacy_bulk_clears_current_lease = false;
    public string $fail = '';
    public array $ids = array();
    public array $jobs = array();
    public array $states = array();
    public array $sessions = array();
    public array $claims = array();
    public array $operations = array();
    public bool $device_present = true;
    private ?array $snapshot = null;
    private int $current_id = 0;
    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }
    public function esc_like(string $value): string { return $value; }
    public function get_var($prepared) {
        $this->last_error = '';
        $query = $prepared['query']; $args = $prepared['arguments'];
        if (strpos($query, 'SHOW TABLES LIKE') !== false) { return $args[0]; }
        if (strpos($query, 'GET_LOCK') !== false || strpos($query, 'RELEASE_LOCK') !== false) { return '1'; }
        if (strpos($query, 'SELECT ID FROM wp_users') !== false) { return '17'; }
        if (strpos($query, 'SELECT option_value FROM wp_options') !== false) {
            return serialize($this->sessions[$this->current_id]);
        }
        if (strpos($query, 'SELECT meta_value FROM wp_usermeta') !== false) {
            return serialize(match ($args[1]) {
                Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH => 1,
                Shuzijun_App_Content_API::FAN_META_STATUS => 'active',
                Shuzijun_App_Content_API::FAN_META_UUID => '123e4567-e89b-42d3-a456-426614174000',
                default => throw new RuntimeException('Unexpected worker metadata query'),
            });
        }
        throw new RuntimeException('Unexpected worker scalar query');
    }
    public function get_col($prepared) {
        $this->last_error = '';
        if ($this->selection_fail) { $this->last_error = 'fixture selection failed'; return null; }
        expect_true(strpos($prepared['query'], "status = 'pending'") !== false
            && strpos($prepared['query'], 'LIMIT 20') !== false, '发送成功的任务不得再次成为待发送选择');
        return $this->ids;
    }
    public function get_results($prepared, $output): array { return array(); }
    public function get_row($prepared, $output) {
        $this->last_error = '';
        $query = $prepared['query'];
        if (strpos($query, 'SELECT o.fan_user_id, o.install_hash') !== false) {
            $job = $this->jobs[$this->current_id] ?? array();
            return array('fan_user_id' => $job['fan_user_id'] ?? 0, 'install_hash' => $job['install_hash'] ?? '');
        }
        if (strpos($query, 'SELECT install_hash FROM wp_yishu_push_install_states') !== false) {
            return array('install_hash' => $this->jobs[$this->current_id]['install_hash']);
        }
        if (strpos($query, 'SELECT o.id, o.fan_user_id') !== false) {
            return array_replace($this->jobs[$this->current_id], array('attempts' => 1));
        }
        if (strpos($query, 'SELECT option_name, option_value FROM wp_options') !== false) {
            $session = $this->sessions[$this->current_id];
            return array('option_name' => Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . $session['tokenHash'],
                'option_value' => serialize($session));
        }
        throw new RuntimeException('Unexpected worker row query');
    }
    public function query($prepared) {
        $this->last_error = ''; // A later success would erase an unchecked error.
        $query = is_array($prepared) ? $prepared['query'] : $prepared;
        $args = is_array($prepared) ? $prepared['arguments'] : array();
        if ($query === 'START TRANSACTION') {
            $this->snapshot = array($this->states, $this->device_present);
            $this->operations[] = 'begin'; return 0;
        }
        if ($query === 'COMMIT') {
            $this->operations[] = 'commit';
            if ($this->fail === 'commit') { return false; }
            $this->snapshot = null; return 0;
        }
        if ($query === 'ROLLBACK') {
            $this->operations[] = 'rollback';
            if ($this->snapshot !== null) { [$this->states, $this->device_present] = $this->snapshot; }
            $this->snapshot = null; return 0;
        }
        if (strpos($query, "SET status = 'processing', attempts = attempts + 1") !== false) {
            $id = (int) $args[3]; $this->current_id = $id; $this->claims[] = $id;
            if ($this->fail === 'claim:' . $id) { return false; }
            if ($this->fail === 'claim-throw:' . $id) { throw new RuntimeException('private fixture diagnostic'); }
            if ($this->fail === 'claim-many:' . $id) { return 2; }
            if (($this->states[$id]['status'] ?? '') !== 'pending') { return 0; }
            $this->states[$id] = array('status' => 'processing', 'lease_token' => $args[0]);
            return 1;
        }
        if (strpos($query, 'WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d') !== false
            && strpos($query, "SET status = 'dead'") !== false) {
            if ($this->fail === 'invalidation') { return false; }
            $exclude = !$this->legacy_bulk_clears_current_lease && strpos($query, 'AND id <> %d') !== false
                ? (int) end($args) : 0;
            foreach ($this->states as $id => $state) {
                if ($id !== $exclude && in_array($state['status'], array('pending', 'processing'), true)) {
                    $this->states[$id] = array('status' => 'dead', 'lease_token' => null);
                }
            }
            return 1;
        }
        if (strpos($query, 'DELETE FROM wp_yishu_push_devices') !== false && strpos($query, 'WHERE install_hash = %s') !== false) {
            if ($this->fail === 'device-delete') { return false; }
            $this->device_present = false; return 1;
        }
        if (strpos($query, "SET desired_state = 'unbound'") !== false) { return 1; }
        if (strpos($query, 'attempts = CASE WHEN attempts > 0') !== false) { return 1; }
        $this->cleanup_count++;
        expect_true($this->cleanup_count <= 9, '维护必须只有9条已审语句');
        if ($this->cleanup_throw) { throw new RuntimeException('private fixture diagnostic'); }
        if ($this->cleanup_count === $this->cleanup_fail_at) {
            $this->last_error = 'fixture maintenance failed'; return false;
        }
        return 0;
    }
    public function update($table, array $data, array $where, array $formats, array $where_formats) {
        if ($this->fail === 'writeback') { return false; }
        $id = $where['id'];
        if (($this->states[$id]['lease_token'] ?? null) !== $where['lease_token']) { return 0; }
        $this->states[$id] = array_replace($this->states[$id], $data);
        return 1;
    }
}

$worker_saved = array('db' => $GLOBALS['wpdb'], 'options' => $GLOBALS['yishu_test_options'],
    'filters' => $GLOBALS['yishu_test_filters'], 'scheduled' => $GLOBALS['yishu_test_scheduled'],
    'role' => file_get_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH));
$worker_schema = new ReflectionProperty(Shuzijun_App_Content_API::class, 'push_schema_verified');
$worker_schema->setAccessible(true);
$worker_saved['schema'] = $worker_schema->getValue();
try {
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, "authority\n");
    $worker_schema->setValue(null, true);
    $GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::PUSH_SCHEMA_OPTION] = Shuzijun_App_Content_API::PUSH_SCHEMA_VERSION;
    $GLOBALS['yishu_test_filters']['yishu_apns_provider_configuration'] = static function (): array {
        return array('keyID' => 'TESTKEY123', 'teamID' => 'TESTTEAM12', 'test' => true);
    };
    $worker_key = random_bytes(32);
    $GLOBALS['yishu_test_filters']['yishu_push_data_key'] = static fn(): string => $worker_key;
    $GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static fn(): array => array('outcome' => 'sent', 'code' => '');
    $new_worker = static function (): Yishu_Push_Worker_Result_DB {
        $GLOBALS['yishu_test_scheduled'] = array();
        $GLOBALS['yishu_test_schedule_failure'] = false;
        $db = new Yishu_Push_Worker_Result_DB(); $GLOBALS['wpdb'] = $db; return $db;
    };
    for ($point = 1; $point <= 9; $point++) {
        $db = $new_worker(); $db->cleanup_fail_at = $point;
        expect_same(false, invoke_plugin_method('sweep_push_outbox'), '第' . $point . '条清理失败不能被后续成功覆盖');
        expect_same($point, $db->cleanup_count, '清理失败应立即停止后续语句');
        expect_same(array(), $db->claims, '清理失败不得领取发送任务');
    }
    $db = $new_worker(); expect_same(true, invoke_plugin_method('sweep_push_outbox'), '空队列维护和下次调度应成功');
    expect_same(9, $db->cleanup_count, '所有清理都执行且零影响行数正常');
    $db = $new_worker(); $GLOBALS['yishu_test_schedule_failure'] = true;
    expect_same(false, invoke_plugin_method('sweep_push_outbox'), '最后调度失败必须上报失败');
    $db = $new_worker(); $db->selection_fail = true;
    expect_same(false, invoke_plugin_method('sweep_push_outbox'), '候选任务读取失败必须上报失败');

    $add_job = static function (Yishu_Push_Worker_Result_DB $db, int $id): void {
        $token = bin2hex(random_bytes(32));
        $cipher = invoke_plugin_method('encrypt_push_device_token', array($token));
        expect_true(is_array($cipher), '纯fixture设备加密应成功');
        $install = hash('sha256', 'worker-contract-install');
        $db->jobs[$id] = array(
            'id' => $id, 'fan_user_id' => 17, 'install_hash' => $install, 'outbox_install_hash' => $install,
            'token_hash' => $cipher['tokenHash'], 'token_ciphertext' => $cipher['ciphertext'],
            'binding_generation' => 1, 'device_generation' => 1, 'owner_generation' => 1,
            'session_option_id' => 42, 'owner_session_option_id' => 42, 'owner_user_id' => 17,
            'desired_state' => 'bound', 'session_expires_at' => gmdate('Y-m-d H:i:s', time() + 600),
            'deliver_before' => time() + 600, 'public_id' => '123e4567-e89b-42d3-a456-426614174000',
            'title' => 'Fixture', 'body' => 'Private fixture', 'is_sensitive' => 1,
        );
        $db->sessions[$id] = array('userID' => 17, 'installHash' => $install, 'scope' => 'normal',
            'tokenHash' => hash('sha256', 'fixture-session'), 'sessionID' => str_repeat('9', 32),
            'credentialEpoch' => 1, 'authMethod' => 'password', 'recentAuthUntil' => 0, 'expires' => time() + 600);
        $db->states[$id] = array('status' => 'pending', 'lease_token' => null);
    };
    foreach (array('sent', 'retry', 'dead', 'invalid') as $outcome) {
        $db = $new_worker(); $add_job($db, 7); $db->ids = array(7);
        $GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static fn(): array => array('outcome' => $outcome, 'code' => 'fixture');
        expect_same(true, invoke_plugin_method('sweep_push_outbox'), '已可靠持久化' . $outcome . '应算正常处理而非手机送达');
        expect_same(match ($outcome) { 'sent' => 'sent', 'retry' => 'pending', default => 'dead' }, $db->states[7]['status'], '必须保存准确任务终态');
        if ($outcome === 'invalid') { expect_same(false, $db->device_present, '无效token删除必须真正提交'); }
    }
    $GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static fn(): array => array('outcome' => 'invalid', 'code' => 'fixture');
    $db = $new_worker(); $add_job($db, 7); $add_job($db, 8); $db->ids = array(7);
    expect_same(true, invoke_plugin_method('sweep_push_outbox'), '无效绑定终止同安装其他任务，但必须保留当前租约直至完成');
    expect_same('dead', $db->states[7]['status'], '当前任务显式完成dead');
    expect_same('dead', $db->states[8]['status'], '同安装其他待处理任务同样终止');
    $db = $new_worker(); $add_job($db, 7); $db->ids = array(7); $db->legacy_bulk_clears_current_lease = true;
    expect_same(false, invoke_plugin_method('sweep_push_outbox'), '旧bulk清当前lease语义负控应导致writeback零行失败');
    expect_same(true, $db->device_present, '旧问题回滚会保留无效token，不能冒称删除成功');
    expect_same('processing', $db->states[7]['status'], '失败保留已领取任务供租约恢复');
    foreach (array('writeback', 'commit', 'invalidation', 'device-delete') as $failure) {
        $db = $new_worker(); $add_job($db, 7); $db->ids = array(7); $db->fail = $failure;
        expect_same(false, invoke_plugin_method('sweep_push_outbox'), '终态事务失败必须上报：' . $failure);
        expect_true(in_array('rollback', $db->operations, true), '失败事务必须回滚');
        expect_same(true, $db->device_present, '失败不能部分删除设备');
    }
    $GLOBALS['yishu_test_filters']['yishu_apns_delivery_result'] = static fn(): array => array('outcome' => 'sent', 'code' => '');
    foreach (array('claim:7', 'claim-many:7', 'claim-throw:7') as $failure) {
        $db = $new_worker(); $add_job($db, 7); $add_job($db, 8); $db->ids = array(7, 8); $db->fail = $failure;
        expect_same(false, invoke_plugin_method('sweep_push_outbox'), '单任务失败必须聚合而不阻断其他任务');
        expect_same('sent', $db->states[8]['status'], '后续任务仍正常处理');
    }
    $db = $new_worker(); $add_job($db, 7); $db->ids = array(7); $db->states[7]['status'] = 'sent';
    expect_same(true, invoke_plugin_method('sweep_push_outbox'), '已接受任务claim0是安全跳过');
    expect_same('sent', $db->states[7]['status'], '已接受任务不能因轮询重发');
    $db = $new_worker(); $db->cleanup_throw = true;
    expect_same(false, invoke_plugin_method('run_push_outbox_sweep'), '普通cron异常转换false且不泄漏诊断');

    if (!class_exists('WP_CLI')) {
        class WP_CLI {
            public static function error($message): void { throw new RuntimeException((string) $message); }
        }
    }
    if (!defined('WP_CLI')) { define('WP_CLI', true); }
    foreach (array('query', 'throw', 'schedule') as $failure) {
        $db = $new_worker();
        if ($failure === 'query') { $db->cleanup_fail_at = 1; }
        if ($failure === 'throw') { $db->cleanup_throw = true; }
        if ($failure === 'schedule') { $GLOBALS['yishu_test_schedule_failure'] = true; }
        try {
            invoke_plugin_method('run_push_outbox_sweep');
            expect_true(false, 'CLI失败必须显式转为非零退出错误');
        } catch (RuntimeException $error) {
            expect_same('Push outbox sweep failed.', $error->getMessage(), 'CLI仅输出固定无敏感内容错误');
        }
    }
    $db = $new_worker();
    expect_same(true, invoke_plugin_method('run_push_outbox_sweep'), 'CLI成功wrapper保持安静并返回true');
    fwrite(STDOUT, "push-worker-result-regression: cleanup faults, durable outcomes, lease fence, rollback and CLI propagation passed\n");
} finally {
    $GLOBALS['wpdb'] = $worker_saved['db']; $GLOBALS['yishu_test_options'] = $worker_saved['options'];
    $GLOBALS['yishu_test_filters'] = $worker_saved['filters']; $GLOBALS['yishu_test_scheduled'] = $worker_saved['scheduled'];
    $GLOBALS['yishu_test_schedule_failure'] = false;
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, $worker_saved['role']);
    $worker_schema->setValue(null, $worker_saved['schema']);
}
