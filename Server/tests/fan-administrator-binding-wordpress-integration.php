<?php
declare(strict_types=1);

// Only included after the real WP fixture verifies its isolated random DB.
if (!defined('DB_NAME') || !isset($database, $wpdb) || DB_NAME !== $database
    || !str_starts_with(DB_NAME, 'yishu_wp_schema_test_')
    || $wpdb->get_var('SELECT DATABASE()') !== $database) {
    throw new RuntimeException('Requires the isolated WordPress fixture');
}
$binding_before_checks = $checks;
$marker_dir = sys_get_temp_dir() . '/yishu-binding-authority-' . bin2hex(random_bytes(10));
if (!mkdir($marker_dir, 0700)) { throw new RuntimeException('Temporary marker directory unavailable'); }
$marker = $marker_dir . '/role';
try {
    file_put_contents($marker, "authority\n");
    chmod($marker, 0644);
    chown($marker, getmyuid());
    chgrp($marker, getmygid());
    define('YISHU_APPLE_TEST_MODE', true);
    define('WP_ENVIRONMENT_TYPE', 'local');
    define('YISHU_ACCOUNT_ROLE_MARKER_TEST_PATH', $marker);
    check_wordpress_schema(Shuzijun_App_Content_API::account_authority_enabled(), 'only temporary authority marker is used');

    $make_fan = static function (bool $administrator = false): array {
        $fan_id = wp_insert_user(array('user_login' => 'binding_' . bin2hex(random_bytes(8)),
            'user_pass' => bin2hex(random_bytes(24)), 'role' => 'subscriber'));
        check_wordpress_schema(is_int($fan_id) && $fan_id > 0, 'create isolated binding fixture user');
        $fan_uuid = wp_generate_uuid4();
        update_user_meta($fan_id, Shuzijun_App_Content_API::FAN_META_UUID, $fan_uuid);
        update_user_meta($fan_id, Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
        update_user_meta($fan_id, Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, 'fixture_' . bin2hex(random_bytes(5)));
        update_user_meta($fan_id, Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH, 1);
        if ($administrator) { get_userdata($fan_id)->add_role(Shuzijun_App_Content_API::ROLE); }
        $fan_token = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
        $fan_install = wp_generate_uuid4();
        $fan_option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . hash('sha256', $fan_token);
        add_option($fan_option, array('userID' => $fan_id, 'expires' => time() + 600,
            'installHash' => hash('sha256', $fan_install), 'scope' => 'normal',
            'credentialEpoch' => 1, 'authMethod' => 'password', 'recentAuthUntil' => 0), '', false);
        return array('id' => $fan_id, 'uuid' => $fan_uuid, 'token' => $fan_token, 'install' => $fan_install);
    };
    $binding_request = static function (array $actor, array $target, $desired, $expected): WP_REST_Request {
        $binding_request = new WP_REST_Request('PATCH', '/shuzijun/v1/app-admin/fans/' . $target['uuid'] . '/administrator');
        $binding_request->set_header('Authorization', 'Bearer ' . $actor['token']);
        $binding_request->set_header('X-Yishu-Install-ID', $actor['install']);
        $binding_request->set_url_params(array('uuid' => $target['uuid']));
        $binding_request->set_param('administrator', $desired);
        $binding_request->set_param('expectedAdministrator', $expected);
        $binding_request->set_param('expectedRevision', (int) get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_REVISION, true));
        return $binding_request;
    };
    $assert_binding_error = static function ($result, string $code, string $label): void {
        check_wordpress_schema(is_wp_error($result) && $result->get_error_code() === $code, $label);
    };
    $bound = static function (array $fan): bool {
        clean_user_cache($fan['id']);
        return in_array(Shuzijun_App_Content_API::ROLE, get_userdata($fan['id'])->roles, true);
    };
    $actor = $make_fan(true);
    $target = $make_fan();
    $ordinary = $make_fan();
    $read_request = static function (array $caller, array $subject): WP_REST_Request {
        $read = new WP_REST_Request('GET', '/shuzijun/v1/app-admin/fans/' . $subject['uuid']);
        $read->set_header('Authorization', 'Bearer ' . $caller['token']);
        $read->set_header('X-Yishu-Install-ID', $caller['install']);
        $read->set_url_params(array('uuid' => $subject['uuid']));
        return $read;
    };
    $read = $read_request($actor, $target);
    check_wordpress_schema(Shuzijun_App_Content_API::can_manage_fans($read) === true, 'full actor may read exact fan');
    check_wordpress_schema(Shuzijun_App_Content_API::session()->get_data()['canManageFanAdministrators'] === true,
        'session advertises full administrator allocation capability');
    $read->set_query_params(array('uuid' => $ordinary['uuid']));
    $read_response = Shuzijun_App_Content_API::get_fan_access($read);
    check_wordpress_schema($read_response instanceof WP_REST_Response
        && $read_response->get_data()['user']['userID'] === $target['uuid'], 'query cannot redirect exact user refresh');
    check_wordpress_schema($read_response->get_data()['user']['administratorBound'] === false
        && $read_response->get_data()['user']['administratorRevision'] === 0, 'fresh read supplies binding and revision');
    check_wordpress_schema($read_response->get_headers()['Cache-Control'] === 'private, no-store', 'user refresh is not cacheable');
    $assert_binding_error(Shuzijun_App_Content_API::get_fan_access($read_request($ordinary, $target)),
        'fan_admin_forbidden', 'ordinary user cannot read administrative profile');
    check_wordpress_schema(Shuzijun_App_Content_API::session()->get_data()['canManageFanAdministrators'] === false,
        'ordinary current user never advertises allocation capability');
    Shuzijun_App_Content_API::can_manage_fans($read);
    file_put_contents($marker, "standby\n");
    check_wordpress_schema(Shuzijun_App_Content_API::session()->get_data()['canManageFanAdministrators'] === false,
        'standby session does not advertise writes');
    file_put_contents($marker, "authority\n");
    $invalid_read = $read_request($actor, $target);
    $invalid_read->set_url_params(array('uuid' => 'invalid'));
    $assert_binding_error(Shuzijun_App_Content_API::get_fan_access($invalid_read), 'fan_not_found', 'malformed target rejects refresh');
    update_user_meta($ordinary['id'], Shuzijun_App_Content_API::FAN_META_UUID, $target['uuid']);
    $assert_binding_error(Shuzijun_App_Content_API::get_fan_access($read), 'fan_not_found', 'duplicate identity rejects refresh');
    update_user_meta($ordinary['id'], Shuzijun_App_Content_API::FAN_META_UUID, $ordinary['uuid']);
    $call = static function (array $caller, array $subject, $desired, $expected) use ($binding_request) {
        wp_set_current_user(0);
        return Shuzijun_App_Content_API::update_fan_administrator($binding_request($caller, $subject, $desired, $expected));
    };
    $assert_binding_error($call($ordinary, $target, true, false), 'fan_admin_forbidden', 'ordinary fan cannot promote users');
    get_userdata($actor['id'])->add_cap(Shuzijun_App_Content_API::PUSH_CAPABILITY, false);
    $assert_binding_error($call($actor, $target, true, false), 'fan_admin_forbidden', 'partial App manager cannot grant full administration');
    get_userdata($actor['id'])->remove_cap(Shuzijun_App_Content_API::PUSH_CAPABILITY);
    $assert_binding_error($call($actor, $actor, false, true), 'fan_admin_self_change', 'self demotion cannot lock out the final administrator');
    foreach (array('true', 1, null, array()) as $malformed) {
        $assert_binding_error($call($actor, $target, $malformed, false), 'fan_admin_input_invalid', 'administrator must be a JSON boolean');
        $assert_binding_error($call($actor, $target, true, $malformed), 'fan_admin_input_invalid', 'expected state must be a JSON boolean');
    }
    foreach (array('pending', 'rejected', 'suspended') as $status) {
        update_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_STATUS, $status);
        $assert_binding_error($call($actor, $target, true, false), 'fan_admin_setup_required', 'approval cannot be bypassed by promotion');
    }
    update_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
    foreach (array(Shuzijun_App_Content_API::FAN_META_INVITATION,
        Shuzijun_App_Content_API::FAN_META_PASSWORD_RECOVERY, Shuzijun_App_Content_API::FAN_META_APPLE_SETUP) as $meta_key) {
        update_user_meta($target['id'], $meta_key, array('incomplete' => true));
        $assert_binding_error($call($actor, $target, true, false), 'fan_admin_setup_required', 'unfinished account cannot be promoted');
        delete_user_meta($target['id'], $meta_key);
    }
    $douyin = get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, true);
    update_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, '');
    $assert_binding_error($call($actor, $target, true, false), 'fan_admin_setup_required', 'Douyin ID remains mandatory');
    update_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, $douyin);
    update_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ACCOUNT_SOURCE, 'apple');
    $assert_binding_error($call($actor, $target, true, false), 'fan_admin_setup_required', 'Apple account without consent cannot be promoted');
    delete_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ACCOUNT_SOURCE);

    $duplicate_cap_id = add_user_meta($target['id'], $wpdb->get_blog_prefix() . 'capabilities', array('subscriber' => true));
    check_wordpress_schema(is_int($duplicate_cap_id) && $duplicate_cap_id > 0, 'create one isolated duplicate capability row');
    try { $assert_binding_error($call($actor, $target, true, false), 'fan_admin_update_failed', 'ambiguous duplicate capability records cannot be promoted'); }
    finally { delete_metadata_by_mid('user', $duplicate_cap_id); }
    check_wordpress_schema(!$bound($target), 'duplicate metadata failure did not change effective role');

    $grant_request = $binding_request($actor, $target, true, false);
    $grant_request->set_header('Content-Type', 'application/json');
    $grant_request->set_body(wp_json_encode(array('uuid' => $ordinary['uuid'],
        'administrator' => true, 'expectedAdministrator' => false, 'expectedRevision' => 0)));
    $grant = Shuzijun_App_Content_API::update_fan_administrator($grant_request);
    check_wordpress_schema($grant instanceof WP_REST_Response && $grant->get_data()['user']['administratorBound'] === true, 'grant returns bound state');
    check_wordpress_schema($grant->get_data()['user']['userID'] === $target['uuid'] && !$bound($ordinary), 'JSON body cannot redirect a binding operation away from its URL target');
    check_wordpress_schema($bound($target) && user_can($target['id'], Shuzijun_App_Content_API::FAN_CAPABILITY), 'actual WP role grants App administration');
    check_wordpress_schema(!user_can($target['id'], 'manage_options') && !user_can($target['id'], 'promote_users'), 'grant cannot manage WordPress itself');
    $delegated = $call($target, $ordinary, true, false);
    check_wordpress_schema($delegated instanceof WP_REST_Response && $bound($ordinary), 'a newly bound administrator can assign another administrator');
    check_wordpress_schema($call($target, $ordinary, false, true) instanceof WP_REST_Response && !$bound($ordinary), 'new administrator can revoke delegated administration');
    $audit = get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT, true);
    check_wordpress_schema(count($audit) === 1 && $audit[0]['actorID'] === $actor['id'] && $audit[0]['administrator'] === true, 'grant and real actor are audited');
    $assert_binding_error($call($actor, $target, false, false), 'fan_admin_conflict', 'stale expected state cannot overwrite newer binding');
    check_wordpress_schema($bound($target), 'conflict preserves binding');
    $noop = $call($actor, $target, true, true);
    check_wordpress_schema($noop instanceof WP_REST_Response && get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT, true) === $audit, 'same-state request does not duplicate audit');
    $revoke = $call($actor, $target, false, true);
    check_wordpress_schema($revoke instanceof WP_REST_Response && !$bound($target), 'revoke removes only App role');
    check_wordpress_schema(get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_UUID, true) === $target['uuid'], 'revocation preserves fan identity');
    $content = $binding_request($target, $target, false, false);
    check_wordpress_schema(Shuzijun_App_Content_API::can_access_app_content($content) === true, 'revoked administrator retains approved fan access');
    check_wordpress_schema(Shuzijun_App_Content_API::can_manage_fan_administrators($content) !== true, 'same existing session loses administrator power immediately');
    $stale_revision = $binding_request($actor, $target, true, false);
    $stale_revision->set_param('expectedRevision', 0);
    $assert_binding_error(Shuzijun_App_Content_API::update_fan_administrator($stale_revision), 'fan_admin_conflict', 'grant-revoke ABA cannot revive an obsolete promotion request');
    check_wordpress_schema(!$bound($target), 'stale revision leaves revoked role unchanged');
    foreach (array('2', -1, null, true, 2.5) as $malformed_revision) {
        $invalid_revision = $binding_request($actor, $target, true, false);
        $invalid_revision->set_param('expectedRevision', $malformed_revision);
        $assert_binding_error(Shuzijun_App_Content_API::update_fan_administrator($invalid_revision), 'fan_admin_input_invalid', 'revision must be an explicit nonnegative JSON integer');
    }

    $audit_failure = $make_fan();
    $fail_audit = static function ($query) {
        return str_starts_with(strtoupper(ltrim($query)), 'INSERT') && str_contains($query, Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT)
            ? 'DELIBERATE ISOLATED FIXTURE SQL FAILURE' : $query;
    };
    add_filter('query', $fail_audit);
    try {
        $assert_binding_error($call($actor, $audit_failure, true, false), 'fan_admin_update_failed', 'audit write failure fails closed');
    } finally { remove_filter('query', $fail_audit); }
    check_wordpress_schema(!$bound($audit_failure), 'failed audit rolls back actual capability update');
    check_wordpress_schema(get_user_meta($audit_failure['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT, true) === '', 'failed transaction leaves no false success audit');
    check_wordpress_schema(get_user_meta($audit_failure['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_REVISION, true) === '', 'failed transaction does not advance revision');
    $fail_revision = static function ($query) {
        return str_starts_with(strtoupper(ltrim($query)), 'INSERT') && str_contains($query, Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_REVISION)
            ? 'DELIBERATE ISOLATED FIXTURE SQL FAILURE' : $query;
    };
    add_filter('query', $fail_revision);
    try { $assert_binding_error($call($actor, $audit_failure, true, false), 'fan_admin_update_failed', 'revision write failure rolls back role and audit'); }
    finally { remove_filter('query', $fail_revision); }
    check_wordpress_schema(!$bound($audit_failure) && get_user_meta($audit_failure['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT, true) === '', 'role and audit are atomic with revision');

    $revoked_during_lock = false;
    $revoke_actor = static function ($query) use ($actor, &$revoked_during_lock) {
        if (!$revoked_during_lock && str_contains($query, 'GET_LOCK')) {
            $revoked_during_lock = true;
            get_userdata($actor['id'])->remove_role(Shuzijun_App_Content_API::ROLE);
        }
        return $query;
    };
    add_filter('query', $revoke_actor);
    try {
        $assert_binding_error($call($actor, $target, true, false), 'fan_admin_forbidden', 'actor revoked between authentication and lock cannot promote');
    } finally {
        remove_filter('query', $revoke_actor);
        get_userdata($actor['id'])->add_role(Shuzijun_App_Content_API::ROLE);
    }
    check_wordpress_schema($revoked_during_lock && !$bound($target), 'fresh locked revalidation prevents stale actor mutation');

    $authority_changed = false;
    $change_authority = static function ($query) use ($marker, &$authority_changed) {
        if (!$authority_changed && str_contains($query, 'GET_LOCK')) {
            $authority_changed = true;
            file_put_contents($marker, "standby\n");
        }
        return $query;
    };
    add_filter('query', $change_authority);
    try { $assert_binding_error($call($actor, $target, true, false), 'fan_admin_forbidden', 'authority is rechecked after acquiring the account locks'); }
    finally {
        remove_filter('query', $change_authority);
        file_put_contents($marker, "authority\n");
    }
    check_wordpress_schema($authority_changed && !$bound($target), 'authority change never grants a role on standby');

    $other_connection = new PDO('mysql:unix_socket=' . $socket . ';dbname=' . $database, 'root', '', array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
    $lock_name = 'yishu_fan_' . substr(hash('sha256', home_url('/') . '|0'), 0, 48);
    $hold = $other_connection->prepare('SELECT GET_LOCK(?, 0)');
    $hold->execute(array($lock_name));
    check_wordpress_schema((int) $hold->fetchColumn() === 1, 'a second real DB connection holds the binding lock');
    try { $assert_binding_error($call($actor, $target, true, false), 'fan_setup_busy', 'concurrent binding fails without mutation'); }
    finally {
        $release = $other_connection->prepare('SELECT RELEASE_LOCK(?)');
        $release->execute(array($lock_name));
    }
    check_wordpress_schema(!$bound($target), 'lock contention preserved original binding');
    file_put_contents($marker, "standby\n");
    $assert_binding_error($call($actor, $target, true, false), 'fan_admin_forbidden', 'standby cannot change administrator binding');
    file_put_contents($marker, "authority\n");

    $role = get_role(Shuzijun_App_Content_API::ROLE);
    $role->add_cap('manage_options', true);
    try { $assert_binding_error($call($actor, $target, true, false), 'fan_admin_update_failed', 'unexpected site capability in role prevents grants'); }
    finally { $role->remove_cap('manage_options'); }
    check_wordpress_schema(!$bound($target), 'unsafe shared role was never assigned');
    get_userdata($target['id'])->add_cap('edit_posts', true);
    $assert_binding_error($call($actor, $target, true, false), 'fan_admin_role_conflict', 'independent site permissions are not overwritten');
    get_userdata($target['id'])->remove_cap('edit_posts');

    add_action('rest_api_init', array(Shuzijun_App_Content_API::class, 'register_routes'));
    $server = rest_get_server();
    $read_route = $server->dispatch($read_request($actor, $target));
    check_wordpress_schema($read_route->get_status() === 200 && $read_route->get_data()['user']['userID'] === $target['uuid'],
        'registered GET route reads exact fan profile');
    $anonymous_read = $server->dispatch(new WP_REST_Request('GET', '/shuzijun/v1/app-admin/fans/' . $target['uuid']));
    check_wordpress_schema($anonymous_read->get_status() >= 400, 'GET route denies anonymous profile reads');
    wp_set_current_user(0);
    $anonymous = new WP_REST_Request('PATCH', '/shuzijun/v1/app-admin/fans/' . $target['uuid'] . '/administrator');
    $anonymous->set_param('administrator', true);
    $anonymous->set_param('expectedAdministrator', false);
    check_wordpress_schema($server->dispatch($anonymous)->get_status() >= 400 && !$bound($target), 'actual REST route denies anonymous writes');
    $routed = $server->dispatch($binding_request($actor, $target, true, false));
    check_wordpress_schema($routed->get_status() === 200 && $bound($target), 'actual REST route grants with approved bearer administrator');
    for ($iteration = 0; $iteration < 52; ++$iteration) {
        $current = $bound($target);
        check_wordpress_schema($call($actor, $target, !$current, $current) instanceof WP_REST_Response, 'repeated role changes preserve transaction continuity');
    }
    $bounded_audit = get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_AUDIT, true);
    check_wordpress_schema(count($bounded_audit) === 50, 'audit retention is bounded to the last fifty changes');
    check_wordpress_schema($bounded_audit[49]['administrator'] === $bound($target), 'latest committed audit matches role');
    check_wordpress_schema($bounded_audit[49]['revision'] === (int) get_user_meta($target['id'], Shuzijun_App_Content_API::FAN_META_ADMIN_BINDING_REVISION, true)
        && $bounded_audit[49]['revision'] > 50, 'revision remains monotonic when old audit records are pruned');
    $engine_before_binding = $bound($target);
    check_wordpress_schema($wpdb->query("ALTER TABLE {$wpdb->usermeta} ENGINE=MyISAM") !== false, 'change only the disposable fixture metadata engine');
    try { $assert_binding_error($call($actor, $target, !$engine_before_binding, $engine_before_binding), 'fan_admin_update_failed', 'nontransactional metadata storage rejects role writes'); }
    finally { check_wordpress_schema($wpdb->query("ALTER TABLE {$wpdb->usermeta} ENGINE=InnoDB") !== false, 'restore only the disposable fixture engine'); }
    check_wordpress_schema($bound($target) === $engine_before_binding, 'engine failure preserves role');
    check_wordpress_schema(!Shuzijun_App_Content_API::collaboration_phase1_enabled(), 'role API did not change collaboration fuse');
    wp_set_current_user(0);
    fwrite(STDOUT, 'fan-administrator-binding-wordpress: ' . ($checks - $binding_before_checks)
        . " assertions passed; actual roles, transactions, locks and REST dispatch; no live accounts\n");
} finally {
    if (is_file($marker)) { unlink($marker); }
    rmdir($marker_dir);
}
