<?php
declare(strict_types=1);

// Loaded by plugin-contract-test.php. This transactional in-memory fixture
// models MySQL changed rows, unlike the generic harness's query() => 1 stub.
// No WordPress runtime, real account, database or network is accessed.
final class Yishu_Push_Ownership_Test_DB {
    public string $options = 'wp_options';
    public string $users = 'wp_users';
    public string $usermeta = 'wp_usermeta';
    public string $prefix = 'wp_';
    public string $last_error = '';
    public ?array $state = null;
    public int $devices = 0;
    public int $pending = 0;
    public int $option_id = 42;
    public string $fail_at = '';
    public bool $zero_update = false;
    public bool $corrupt_insert_owner = false;
    public array $operations = array();
    public array $affected_rows = array();
    public array $session_row = array();
    private ?array $snapshot = null;

    public function prepare(string $query, ...$arguments): array {
        return array('query' => $query, 'arguments' => $arguments);
    }

    public function esc_like(string $value): string { return $value; }

    public function get_var($prepared) {
        $this->last_error = '';
        $query = $prepared['query'];
        if (strpos($query, 'SHOW TABLES LIKE') !== false) {
            return $prepared['arguments'][0];
        }
        if (strpos($query, 'SELECT option_id FROM wp_options') !== false) {
            return (string) $this->option_id;
        }
        if (strpos($query, 'SELECT option_value FROM wp_options') !== false) {
            return $this->session_row['option_value'] ?? null;
        }
        if (strpos($query, 'SELECT ID FROM wp_users') !== false) {
            return '17';
        }
        if (strpos($query, 'SELECT meta_value FROM wp_usermeta') !== false) {
            return match ($prepared['arguments'][1]) {
                Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH => serialize(3),
                Shuzijun_App_Content_API::FAN_META_UUID => serialize('123e4567-e89b-42d3-a456-426614174000'),
                default => throw new RuntimeException('Unexpected ownership metadata read'),
            };
        }
        throw new RuntimeException('Unexpected ownership scalar read');
    }

    public function get_row($prepared, $output) {
        $this->last_error = '';
        if (strpos($prepared['query'], 'FROM wp_options') !== false) {
            return $this->session_row;
        }
        if (strpos($prepared['query'], 'FROM wp_yishu_push_install_states') === false) {
            throw new RuntimeException('Unexpected ownership row read');
        }
        $this->operations[] = 'read';
        if ($this->fail_at === 'read') {
            $this->last_error = 'simulated_read_failure';
            return null;
        }
        return $this->state;
    }

    public function get_results($prepared, $output): array {
        $this->last_error = '';
        if (strpos($prepared['query'], 'FROM wp_options') === false) {
            throw new RuntimeException('Unexpected ownership session scan');
        }
        return array();
    }

    public function query($prepared) {
        $query = is_array($prepared) ? $prepared['query'] : $prepared;
        $arguments = is_array($prepared) ? $prepared['arguments'] : array();
        $this->last_error = '';
        $operation = match (true) {
            $query === 'START TRANSACTION' => 'begin',
            $query === 'COMMIT' => 'commit',
            $query === 'ROLLBACK' => 'rollback',
            strpos($query, 'INSERT IGNORE INTO wp_yishu_push_install_states') !== false => 'insert',
            strpos($query, 'UPDATE wp_yishu_push_outbox') !== false => 'cancel',
            strpos($query, 'DELETE FROM wp_yishu_push_devices') !== false => 'delete',
            strpos($query, 'UPDATE wp_yishu_push_install_states') !== false => 'update',
            default => throw new RuntimeException('Unexpected ownership write'),
        };
        $this->operations[] = $operation;
        if ($this->fail_at === $operation) {
            $this->last_error = 'simulated_' . $operation . '_failure';
            return false;
        }
        switch ($operation) {
            case 'begin':
                $this->snapshot = array($this->state, $this->devices, $this->pending);
                $changed = 0;
                break;
            case 'commit':
                $this->snapshot = null;
                $changed = 0;
                break;
            case 'rollback':
                if ($this->snapshot !== null) {
                    [$this->state, $this->devices, $this->pending] = $this->snapshot;
                    $this->snapshot = null;
                }
                $changed = 0;
                break;
            case 'insert':
                $changed = $this->state === null ? 1 : 0;
                if ($changed === 1) {
                    $this->state = array(
                        'install_hash' => $arguments[0],
                        'fan_user_id' => $arguments[1] + ($this->corrupt_insert_owner ? 1 : 0),
                        'session_option_id' => $arguments[2],
                        'binding_generation' => 0,
                        'desired_state' => 'unbound',
                        'session_expires_at' => $arguments[3],
                        'created_at' => $arguments[4],
                        'updated_at' => $arguments[5],
                    );
                }
                break;
            case 'cancel':
                $changed = $this->pending;
                $this->pending = 0;
                break;
            case 'delete':
                $changed = $this->devices;
                $this->devices = 0;
                break;
            case 'update':
                $next = $this->state === null ? null : array_replace($this->state, array(
                    'fan_user_id' => $arguments[0],
                    'session_option_id' => $arguments[1],
                    'desired_state' => 'unbound',
                    'session_expires_at' => $arguments[2],
                    'updated_at' => $arguments[3],
                ));
                // Equal values really do mean zero rows changed, not failure.
                $changed = $this->zero_update || $next === $this->state ? 0 : 1;
                if ($changed === 1) { $this->state = $next; }
                break;
        }
        $this->affected_rows[] = array($operation, $changed);
        return $changed;
    }
}

$ownership_original_db = $GLOBALS['wpdb'];
$ownership_original_options = $GLOBALS['yishu_test_options'];
$ownership_original_role = file_get_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH);
$ownership_schema_property = new ReflectionProperty(Shuzijun_App_Content_API::class, 'push_schema_verified');
$ownership_schema_property->setAccessible(true);
$ownership_original_schema = $ownership_schema_property->getValue();
try {
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, "authority\n");
    $GLOBALS['yishu_test_options'][Shuzijun_App_Content_API::PUSH_SCHEMA_OPTION]
        = Shuzijun_App_Content_API::PUSH_SCHEMA_VERSION;
    // Schema validation has its own contracts; this suite exercises the
    // transaction after that gate, including real zero-affected-row results.
    $ownership_schema_property->setValue(null, true);
    $ownership_context = $legacy_session + array('tokenHash' => $legacy_token_hash);
    $ownership_invoke = static function (Yishu_Push_Ownership_Test_DB $db) use ($ownership_context): bool {
        $GLOBALS['wpdb'] = $db;
        return invoke_plugin_method('advance_push_install_ownership_for_session', array($ownership_context));
    };

    $ownership_new = new Yishu_Push_Ownership_Test_DB();
    expect_same(true, $ownership_invoke($ownership_new), '新安装首次登录：INSERT=1 后等值 UPDATE=0 不得误报账号存储失败');
    expect_same(42, $ownership_new->state['session_option_id'], '新安装必须持久保存已验证的会话行 ID');
    expect_same(17, $ownership_new->state['fan_user_id'], '新安装所有者必须与登录用户一致');
    expect_same('unbound', $ownership_new->state['desired_state'], '登录成功不得隐式绑定推送设备');
    expect_same(0, $ownership_new->state['binding_generation'], '新安装从零绑定世代开始');
    expect_true(in_array('commit', $ownership_new->operations, true)
        && !in_array('rollback', $ownership_new->operations, true), '新安装所有权必须提交成功');
    expect_true(in_array(array('cancel', 0), $ownership_new->affected_rows, true)
        && in_array(array('delete', 0), $ownership_new->affected_rows, true), '空 outbox / device 的零影响行数也是清理成功');

    // Assert the fixture itself cannot regress into an always-one SQL stub.
    $ownership_equal_update = $ownership_new->prepare(
        'UPDATE wp_yishu_push_install_states SET fan_user_id = %d',
        17, 42, $ownership_new->state['session_expires_at'],
        $ownership_new->state['updated_at'], $legacy_install_hash
    );
    expect_same(0, $ownership_new->query($ownership_equal_update), '数据库替身必须真实模拟等值 UPDATE 返回 0');
    $ownership_previous_state = array_replace($ownership_new->state, array(
        'session_option_id' => 41,
        'binding_generation' => 7,
        'desired_state' => 'bound',
        'updated_at' => '2026-01-01 00:00:00',
    ));
    $ownership_existing = static function () use ($ownership_previous_state): Yishu_Push_Ownership_Test_DB {
        $db = new Yishu_Push_Ownership_Test_DB();
        $db->state = $ownership_previous_state;
        $db->devices = 1;
        $db->pending = 2;
        return $db;
    };

    $ownership_old = $ownership_existing();
    expect_same(true, $ownership_invoke($ownership_old), '旧安装重新登录必须推进至新的会话所有者');
    expect_same(42, $ownership_old->state['session_option_id'], '旧安装会话 ID 必须严格推进');
    expect_same(7, $ownership_old->state['binding_generation'], '推进登录所有者不得回退已使用的绑定世代');
    expect_same('unbound', $ownership_old->state['desired_state'], '新会话必须先解除旧设备绑定');
    expect_same(0, $ownership_old->devices, '重新登录必须移除旧会话设备');
    expect_same(0, $ownership_old->pending, '重新登录必须取消旧会话待发通知');
    expect_true(in_array(array('insert', 0), $ownership_old->affected_rows, true)
        && in_array(array('update', 1), $ownership_old->affected_rows, true), '已有安装须区分 INSERT IGNORE=0 与实际所有者 UPDATE=1');

    $ownership_same = $ownership_existing();
    $ownership_same->state['session_option_id'] = 42;
    $ownership_same_before = $ownership_same->state;
    expect_same(true, $ownership_invoke($ownership_same), '同一会话重试必须幂等成功');
    expect_same($ownership_same_before, $ownership_same->state, '幂等重试不得重置已绑定状态');
    expect_same(1, $ownership_same->devices, '幂等重试不得移除当前设备');
    expect_same(2, $ownership_same->pending, '幂等重试不得取消当前待发通知');

    foreach (array('stale', 'wrong_owner', 'zero_update', 'insert', 'read', 'cancel', 'delete', 'update', 'commit') as $ownership_failure) {
        $db = $ownership_existing();
        if ($ownership_failure === 'stale') { $db->state['session_option_id'] = 43; }
        elseif ($ownership_failure === 'wrong_owner') {
            $db->state['session_option_id'] = 42;
            $db->state['fan_user_id'] = 18;
        } elseif ($ownership_failure === 'zero_update') { $db->zero_update = true; }
        else { $db->fail_at = $ownership_failure; }
        $before = array($db->state, $db->devices, $db->pending);
        expect_same(false, $ownership_invoke($db), '旧所有者推进异常必须失败关闭：' . $ownership_failure);
        expect_same($before, array($db->state, $db->devices, $db->pending), '失败必须回滚安装、设备与待发通知：' . $ownership_failure);
        expect_true(in_array('rollback', $db->operations, true), '失败不得遗留开启的事务：' . $ownership_failure);
    }
    foreach (array('insert', 'read', 'cancel', 'delete', 'commit', 'corrupt_owner') as $ownership_failure) {
        $db = new Yishu_Push_Ownership_Test_DB();
        if ($ownership_failure === 'corrupt_owner') { $db->corrupt_insert_owner = true; }
        else { $db->fail_at = $ownership_failure; }
        expect_same(false, $ownership_invoke($db), '新安装写入/锁内所有者异常不得登录成功：' . $ownership_failure);
        expect_same(null, $db->state, '新安装失败必须撤销已插入的所有权：' . $ownership_failure);
        expect_true(in_array('rollback', $db->operations, true), '新安装失败必须回滚：' . $ownership_failure);
    }

    // Legacy migration shares the INSERT path but runs inside its caller's
    // transaction; verify it independently rather than only the login path.
    $ownership_legacy_invoke = static function (Yishu_Push_Ownership_Test_DB $db) use ($ownership_context, $legacy_row, $legacy_install_hash) {
        $GLOBALS['wpdb'] = $db;
        $db->session_row = $legacy_row;
        $db->query('START TRANSACTION');
        $result = invoke_plugin_method('initialize_legacy_push_install_state', array($ownership_context, 42, $legacy_install_hash));
        $db->query($result === true ? 'COMMIT' : 'ROLLBACK');
        return $result;
    };
    $ownership_legacy_new = new Yishu_Push_Ownership_Test_DB();
    expect_same(true, $ownership_legacy_invoke($ownership_legacy_new), '旧会话首次创建安装所有权不得因等值 UPDATE=0 误报存储故障');
    expect_same(42, $ownership_legacy_new->state['session_option_id'], '旧会话首次迁移须保存权威所有者');
    $ownership_legacy_old = $ownership_existing();
    expect_same(true, $ownership_legacy_invoke($ownership_legacy_old), '旧会话迁移必须可以推进更早的安装所有者');
    expect_same(7, $ownership_legacy_old->state['binding_generation'], '旧会话迁移不得回退绑定世代');
    expect_same(0, $ownership_legacy_old->devices, '旧会话推进须撤下过期设备');
    foreach (array('zero_update', 'update', 'cancel', 'delete') as $ownership_failure) {
        $db = $ownership_existing();
        if ($ownership_failure === 'zero_update') { $db->zero_update = true; }
        else { $db->fail_at = $ownership_failure; }
        expect_error_code('push_storage_unavailable', $ownership_legacy_invoke($db), '旧会话实际推进/清理失败不能放行：' . $ownership_failure);
        expect_same($ownership_previous_state, $db->state, '旧会话迁移失败后调用者须可完整回滚安装状态');
        expect_same(1, $db->devices, '旧会话迁移失败后调用者须可恢复设备');
        expect_same(2, $db->pending, '旧会话迁移失败后调用者须可恢复待发通知');
    }
    $ownership_legacy_corrupt = new Yishu_Push_Ownership_Test_DB();
    $ownership_legacy_corrupt->corrupt_insert_owner = true;
    expect_error_code('push_storage_unavailable', $ownership_legacy_invoke($ownership_legacy_corrupt), '旧会话新插入行的所有者异常不得借 INSERT 成功绕过验证');
    expect_same(null, $ownership_legacy_corrupt->state, '异常旧会话所有者必须能被撤销');
    fwrite(STDOUT, "push-ownership-regression: first-install, handoff, idempotency, legacy migration and rollback contracts passed\n");
} finally {
    $GLOBALS['wpdb'] = $ownership_original_db;
    $GLOBALS['yishu_test_options'] = $ownership_original_options;
    $ownership_schema_property->setValue(null, $ownership_original_schema);
    file_put_contents(YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH, $ownership_original_role);
}
