<?php
declare(strict_types=1);

// Included only by the network-isolated real WordPress harness. All identifiers
// and contact fields below are synthetic; no production user is created/read.
if (!class_exists('CollaborationWordPressSchemaHarness', false)
    || !defined('DB_NAME')
    || preg_match('/^yishu_wp_schema_test_[a-f0-9]{20}$/D', DB_NAME) !== 1) {
    throw new RuntimeException('Requires the isolated WordPress database harness');
}
$seed_deletion = static function (int $fan): void {
    global $wpdb;
    $now = gmdate('Y-m-d H:i:s');
    check_wordpress_schema($wpdb->insert('fixture_yishu_collaboration_requests', array(
        'public_id' => wp_generate_uuid4(), 'submission_id' => wp_generate_uuid4(),
        'fan_user_id' => $fan, 'install_hash' => hash('sha256', 'fixture-install-' . $fan),
        'network_hash' => hash('sha256', 'fixture-network'), 'contact_name' => 'Synthetic Contact',
        'contact_method' => 'fixture@example.invalid', 'project_type' => 'fixture',
        'details' => 'Synthetic deletion fixture only', 'payload_hash' => hash('sha256', 'fixture-payload'),
        'created_at' => $now, 'updated_at' => $now,
    )) === 1, 'seed synthetic request');
    $request_id = (int) $wpdb->insert_id;
    check_wordpress_schema($wpdb->insert('fixture_yishu_collaboration_outbox', array(
        'request_id' => $request_id, 'channel' => 'work_mail',
        'dedupe_key' => hash('sha256', 'fixture-job-' . $request_id),
        'next_attempt_at' => $now, 'created_at' => $now, 'updated_at' => $now,
    )) === 1, 'seed synthetic pending delivery');
    check_wordpress_schema($wpdb->insert('fixture_yishu_collaboration_audit', array(
        'request_id' => $request_id, 'actor_type' => 'fan', 'actor_id' => $fan,
        'event' => 'fixture_created', 'result' => 'ok', 'metadata_json' => '{}', 'created_at' => $now,
    )) === 1, 'seed synthetic audit');
};
$deletion_rows = static function (): array {
    global $wpdb;
    $rows = array();
    foreach (array('requests', 'outbox', 'audit') as $kind) {
        $rows[$kind] = $wpdb->get_results('SELECT * FROM fixture_yishu_collaboration_' . $kind . ' ORDER BY id', ARRAY_A);
        check_wordpress_schema(is_array($rows[$kind]) && $wpdb->last_error === '', 'read complete synthetic deletion state');
    }
    return $rows;
};
$purge_fixture = static fn(int $fan): bool => CollaborationWordPressSchemaHarness::purge_collaboration_data_for_fan_user($fan);
$seed_deletion(700001);
$seed_deletion(700002);
$initial_deletion_rows = $deletion_rows();
// A rollback/disabled feature and missing option must not strand existing data.
CollaborationWordPressSchemaHarness::$fixture_enabled = false;
delete_option(CollaborationWordPressSchemaHarness::COLLABORATION_SCHEMA_OPTION);
foreach (array('lookup', 'audit', 'outbox', 'requests', 'commit') as $fault) {
    $injected = 0;
    $reject_deletion = static function ($query) use ($fault, &$injected) {
        $matched = match ($fault) {
            'lookup' => str_starts_with($query, 'SELECT id FROM fixture_yishu_collaboration_requests'),
            'audit' => str_starts_with($query, 'DELETE a FROM fixture_yishu_collaboration_audit'),
            'outbox' => str_starts_with($query, 'DELETE o FROM fixture_yishu_collaboration_outbox'),
            'requests' => str_starts_with($query, 'DELETE FROM fixture_yishu_collaboration_requests'),
            'commit' => $query === 'COMMIT',
        };
        if ($matched) { ++$injected; return 'SYNTHETIC_FIXTURE_INVALID_SQL'; }
        return $query;
    };
    add_filter('query', $reject_deletion, 99);
    try {
        check_wordpress_schema(!$purge_fixture(700001), 'synthetic deletion error returns failure: ' . $fault);
        check_wordpress_schema($injected === 1, 'exactly one real deletion query was rejected');
    } finally {
        remove_filter('query', $reject_deletion, 99);
    }
    check_wordpress_schema($deletion_rows() === $initial_deletion_rows, 'rollback preserves every row after ' . $fault);
}

// Transactions cannot roll back a MyISAM child table. Refuse incompatible
// physical storage BEFORE any DELETE, even when the ready option is missing.
check_wordpress_schema($wpdb->query('ALTER TABLE fixture_yishu_collaboration_audit ENGINE=MyISAM') !== false,
    'set up non-transactional synthetic child table');
$delete_queries = 0;
$observe_deletes = static function ($query) use (&$delete_queries) {
    if (str_starts_with($query, 'DELETE ')) { ++$delete_queries; }
    return $query;
};
add_filter('query', $observe_deletes, 99);
try {
    check_wordpress_schema(!$purge_fixture(700001), 'non-transactional deletion must fail before partial erasure');
    check_wordpress_schema($delete_queries === 0, 'incompatible schema never starts erasing data');
} finally {
    remove_filter('query', $observe_deletes, 99);
    $wpdb->query('ALTER TABLE fixture_yishu_collaboration_audit ENGINE=InnoDB');
}
check_wordpress_schema($deletion_rows() === $initial_deletion_rows, 'engine rejection preserves all users');
check_wordpress_schema($purge_fixture(700001), 'delete succeeds while feature disabled and schema option missing');
$remaining = $deletion_rows();
foreach ($remaining as $kind => $rows) {
    check_wordpress_schema(count($rows) === 1 && $rows[0] === $initial_deletion_rows[$kind][1],
        'delete removes only target fan and preserves other fan: ' . $kind);
}
check_wordpress_schema($purge_fixture(700001) && $deletion_rows() === $remaining, 'repeated deletion is idempotent');
check_wordpress_schema(!$purge_fixture(0) && !$purge_fixture(-1), 'invalid user identifiers are rejected');
check_wordpress_schema($purge_fixture(700002), 'clean up remaining synthetic fan');
foreach ($deletion_rows() as $rows) { check_wordpress_schema($rows === array(), 'all synthetic fan data removed'); }
CollaborationWordPressSchemaHarness::$fixture_enabled = true;
unset($seed_deletion, $deletion_rows, $purge_fixture, $initial_deletion_rows, $remaining);
