<?php
declare(strict_types=1);

// Only the network-isolated WordPress harness may run this synthetic fixture.
if (!class_exists('CollaborationWordPressSchemaHarness', false)
    || !defined('DB_NAME') || preg_match('/^yishu_wp_schema_test_[a-f0-9]{20}$/D', DB_NAME) !== 1) {
    throw new RuntimeException('Requires isolated WordPress storage');
}
final class CollaborationPayloadHarness {
    use Shuzijun_App_Collaboration;
    public const COLLABORATION_SCHEMA_OPTION = 'fixture_collaboration_schema_version';
    public const COLLABORATION_SCHEMA_VERSION = 2;
    public const FAN_META_UUID = '_fixture_uuid';
    public const COLLABORATION_OUTBOX_LEASE_SECONDS = 120;
    public const COLLABORATION_OUTBOX_MAX_ATTEMPTS = 5;
    public const COLLABORATION_EMAIL = 'fixture@example.invalid';
    private static $fan_session_context = array('userID' => 901, 'scope' => 'normal');
    // Authentication is tested separately. Here only the persistence path uses
    // synthetic authority; the production API entry and routes are not loaded.
    private static function collaboration_phase1_enabled() { return true; }
    private static function collaboration_mail_transport_ready() { return true; }
    private static function account_authority_enabled() { return true; }
    private static function acquire_fan_lock($id) { return 'fixture'; }
    private static function release_fan_lock($id, $lock) {}
    private static function acquire_named_fan_lock($kind, $name) { return 'fixture'; }
    private static function release_named_fan_lock($lock) {}
    private static function collaboration_fan_context_is_current_from_database($context, $locked = false) { return true; }
    private static function request_install_id($request) { return '11111111-2222-4333-8444-555555555555'; }
    private static function request_network_fingerprint() { return hash('sha256', 'synthetic-network'); }
    private static function rate_limit($kind, $identity, $limit, $period) { return true; }
    private static function is_uuid_v4($value) { return wp_is_uuid($value, 4); }
    private static function set_private_no_store_headers($response) { $response->header('Cache-Control', 'private, no-store'); }
    private static function schedule_collaboration_outbox_job($id, $timestamp) { return false; }
    public static function body($row) { return self::collaboration_mail_body($row); }
}

$key_path = dirname(ABSPATH) . '/payload-fixture-' . bin2hex(random_bytes(12));
try {
    check_wordpress_schema(CollaborationWordPressSchemaHarness::ensure_collaboration_storage(),
        'restore readiness after feature-disabled deletion fixture');
    file_put_contents($key_path, random_bytes(32));
    chmod($key_path, 0600);
    define('YISHU_COLLABORATION_DATA_KEY_PATH', $key_path);
    define('YISHU_COLLABORATION_DATA_KEY_ID', 'synthetic-fixture');
    $canary = 'SYNTHETIC-' . bin2hex(random_bytes(12));
    $request = new WP_REST_Request('POST');
    $input = array('submissionID' => wp_generate_uuid4(), 'contactName' => $canary,
        'contactMethod' => $canary . '@example.invalid', 'organization' => '合成组织',
        'projectType' => 'drama', 'city' => '合成城市', 'preferredDate' => '',
        'budget' => '合成预算', 'details' => "测试项目说明：\n" . $canary);
    foreach ($input as $key => $value) { $request->set_param($key, $value); }
    $queries = array();
    $capture = static function ($query) use (&$queries) { $queries[] = $query; return $query; };
    add_filter('query', $capture);
    try { $result = CollaborationPayloadHarness::create_collaboration_request($request); }
    finally { remove_filter('query', $capture); }
    check_wordpress_schema($result instanceof WP_REST_Response && $result->get_status() === 201,
        'actual submission transaction stores encrypted request: ' . (is_wp_error($result) ? $result->get_error_code() : get_debug_type($result)));
    check_wordpress_schema(!str_contains(implode("\n", $queries), $canary), 'SQL and query log contain no plaintext canary');
    $public_id = $result->get_data()['requestID'];
    $row = $wpdb->get_row($wpdb->prepare('SELECT * FROM fixture_yishu_collaboration_requests WHERE public_id = %s', $public_id), ARRAY_A);
    check_wordpress_schema(is_array($row) && str_starts_with($row['private_payload'], 'v1.synthetic-fixture.'), 'real row contains authenticated envelope');
    check_wordpress_schema(!str_contains(wp_json_encode($row), $canary), 'persisted row contains no plaintext canary');
    check_wordpress_schema(!array_key_exists('contact_name', $row) && !array_key_exists('details', $row), 'no legacy personal columns');
    $repeat = CollaborationPayloadHarness::create_collaboration_request($request);
    check_wordpress_schema($repeat instanceof WP_REST_Response && $repeat->get_status() === 200
        && $repeat->get_data()['requestID'] === $public_id, 'same submission is idempotent');
    $request->set_param('details', '不同的合成项目说明');
    $conflict = CollaborationPayloadHarness::create_collaboration_request($request);
    check_wordpress_schema(is_wp_error($conflict) && $conflict->get_error_code() === 'collaboration_idempotency_conflict', 'changed content cannot reuse submission ID');
    $list = CollaborationPayloadHarness::list_collaboration_requests(new WP_REST_Request('GET'));
    check_wordpress_schema($list instanceof WP_REST_Response && count($list->get_data()['requests']) === 1,
        'administrator list reads one encrypted request');
    $record = $list->get_data()['requests'][0];
    foreach (array('contactName', 'contactMethod', 'organization', 'projectType', 'city', 'budget', 'details') as $field) {
        check_wordpress_schema($record[$field] === $input[$field], 'administrator plaintext matches original: ' . $field);
    }
    check_wordpress_schema(!array_key_exists('private_payload', $record), 'API does not return internal envelope');
    $update = new WP_REST_Request('POST');
    $update->set_param('request_id', $public_id);
    $update->set_param('status', 'reviewing');
    $update->set_param('version', 1);
    $updated = CollaborationPayloadHarness::update_collaboration_request($update);
    check_wordpress_schema($updated instanceof WP_REST_Response
        && $updated->get_data()['request']['status'] === 'reviewing'
        && $updated->get_data()['request']['contactName'] === $canary, 'status update preserves decrypted request');
    $update->set_param('version', 2);
    $unchanged = CollaborationPayloadHarness::update_collaboration_request($update);
    check_wordpress_schema($unchanged instanceof WP_REST_Response
        && $unchanged->get_data()['request']['version'] === 2, 'idempotent status update reads encrypted payload');
    $body = CollaborationPayloadHarness::body($row);
    check_wordpress_schema(is_string($body) && str_contains($body, $input['contactMethod']) && str_contains($body, $input['details']),
        'mail body retains full collaboration information');
    $swapped = $row;
    $swapped['fan_user_id'] = 902;
    check_wordpress_schema(is_wp_error(CollaborationPayloadHarness::body($swapped)), 'mail refuses swapped owner');
    $job_id = (int) $wpdb->get_var($wpdb->prepare('SELECT id FROM fixture_yishu_collaboration_outbox WHERE request_id = %d', $row['id']));
    $mail_calls = 0;
    $accept = false;
    $capture_mail = static function ($short_circuit, $attributes) use (&$mail_calls, &$accept, $input) {
        ++$mail_calls;
        check_wordpress_schema(str_contains($attributes['message'], $input['contactMethod'])
            && str_contains($attributes['message'], $input['details']), 'worker supplies full decrypted body');
        return $accept; // No PHPMailer or real transport is invoked.
    };
    add_filter('pre_wp_mail', $capture_mail, 99, 2);
    try {
        check_wordpress_schema(!CollaborationPayloadHarness::process_collaboration_outbox($job_id), 'transport rejection stays retryable');
        $failed_job = $wpdb->get_row($wpdb->prepare('SELECT * FROM fixture_yishu_collaboration_outbox WHERE id = %d', $job_id), ARRAY_A);
        check_wordpress_schema($failed_job['status'] === 'pending' && $failed_job['last_error_code'] === 'mail_rejected', 'outbox stores only neutral failure code');
        check_wordpress_schema(!str_contains(wp_json_encode($failed_job), $canary), 'outbox never stores decrypted contact');
        $wpdb->update('fixture_yishu_collaboration_outbox', array('next_attempt_at' => gmdate('Y-m-d H:i:s')), array('id' => $job_id));
        $accept = true;
        check_wordpress_schema(CollaborationPayloadHarness::process_collaboration_outbox($job_id), 'accepted fixture transport commits delivery');
        check_wordpress_schema(!CollaborationPayloadHarness::process_collaboration_outbox($job_id) && $mail_calls === 2,
            'completed job is not sent again');
    } finally { remove_filter('pre_wp_mail', $capture_mail, 99); }
    $wpdb->update('fixture_yishu_collaboration_requests', array('private_payload' => 'damaged'), array('public_id' => $public_id));
    $bad_list = CollaborationPayloadHarness::list_collaboration_requests(new WP_REST_Request('GET'));
    check_wordpress_schema(is_wp_error($bad_list) && $bad_list->get_error_code() === 'collaboration_storage_unavailable',
        'damaged ciphertext is not presented as a blank successful request');
    // Re-open only the synthetic outbox row to exercise the unreadable-body
    // branch; this is not a production retry/reset operation.
    $wpdb->update('fixture_yishu_collaboration_outbox', array('status' => 'pending', 'attempts' => 0,
        'next_attempt_at' => gmdate('Y-m-d H:i:s')), array('id' => $job_id));
    $unexpected_mail_calls = 0;
    $refuse_unreadable_mail = static function () use (&$unexpected_mail_calls) { ++$unexpected_mail_calls; return false; };
    add_filter('pre_wp_mail', $refuse_unreadable_mail, 99);
    try {
        check_wordpress_schema(!CollaborationPayloadHarness::process_collaboration_outbox($job_id), 'worker refuses damaged private payload');
        check_wordpress_schema($unexpected_mail_calls === 0, 'unreadable payload never reaches mail transport');
        check_wordpress_schema($wpdb->get_var($wpdb->prepare('SELECT last_error_code FROM fixture_yishu_collaboration_outbox WHERE id = %d', $job_id))
            === 'private_payload_unavailable', 'payload failure is distinguishable from a mail outage without contact data');
    } finally { remove_filter('pre_wp_mail', $refuse_unreadable_mail, 99); }
    $update->set_param('status', 'closed');
    $bad_update = CollaborationPayloadHarness::update_collaboration_request($update);
    check_wordpress_schema(is_wp_error($bad_update), 'damaged payload refuses administrative mutation');
    check_wordpress_schema($wpdb->get_var($wpdb->prepare('SELECT status FROM fixture_yishu_collaboration_requests WHERE public_id = %s', $public_id)) === 'reviewing',
        'failed encrypted status update leaves original state');
    unlink($key_path);
    check_wordpress_schema(is_wp_error(CollaborationPayloadHarness::list_collaboration_requests(new WP_REST_Request('GET'))),
        'missing key does not become a successful empty inbox');
    check_wordpress_schema(CollaborationPayloadHarness::purge_collaboration_data_for_fan_user(901),
        'unreadable ciphertext and unavailable key still permit user deletion');
    check_wordpress_schema((int) $wpdb->get_var('SELECT COUNT(*) FROM fixture_yishu_collaboration_requests') === 0,
        'synthetic request removed');
    // Schema upgrades must never silently accept or drop legacy personal data.
    $wpdb->query('ALTER TABLE fixture_yishu_collaboration_requests ADD details text NULL');
    delete_option(CollaborationWordPressSchemaHarness::COLLABORATION_SCHEMA_OPTION);
    check_wordpress_schema(!CollaborationWordPressSchemaHarness::ensure_collaboration_storage(), 'legacy plaintext schema requires explicit migration');
    $wpdb->query('ALTER TABLE fixture_yishu_collaboration_requests DROP COLUMN details');
    check_wordpress_schema(CollaborationWordPressSchemaHarness::ensure_collaboration_storage(), 'encrypted schema ready after fixture cleanup');
} finally {
    if (is_file($key_path)) { unlink($key_path); }
}
