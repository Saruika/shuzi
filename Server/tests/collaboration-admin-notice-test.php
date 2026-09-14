<?php
// Synthetic worker test: no WordPress configuration, real account or transport.
define('ABSPATH', __DIR__ . '/synthetic-not-loaded/');
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php';
final class WP_Error {}
function is_wp_error($value) { return $value instanceof WP_Error; }
function get_users($query) {
    check_notice($query['capability'] === 'manage_fixture_collaboration', 'capability-limited recipients');
    return NoticeHarness::$users;
}
function clean_user_cache($id) {}
function user_can($id, $capability) { return !in_array($id, NoticeHarness::$revoked, true); }
$checks = 0;
function check_notice($valid, $label) {
    global $checks;
    $checks++;
    if (!$valid) { throw new RuntimeException($label); }
}
final class NoticeHarness {
    use Shuzijun_App_Collaboration;
    const PUSH_MAX_RECIPIENTS = 100;
    const COLLABORATION_CAPABILITY = 'manage_fixture_collaboration';
    const FAN_META_STATUS = 'status';
    const FAN_META_UUID = 'uuid';
    public static $users = array(101, 102);
    public static $revoked = array();
    public static $inactive = array();
    public static $fail = null;
    public static $saved = array();
    public static $enabled = true;
    public static function collaboration_phase1_enabled() { return self::$enabled; }
    private static function push_storage_ready() { return true; }
    private static function fan_meta_from_database($id, $key, $default) {
        return $key === 'status' ? (in_array($id, self::$inactive, true) ? 'suspended' : 'active')
            : sprintf('11111111-2222-4333-a444-%012d', $id);
    }
    private static function persist_targeted_push_notification($input, $actor) {
        check_notice($actor === 0, 'private system actor only');
        check_notice(count($input['userIDs']) === 1, 'per-recipient transaction');
        check_notice(self::is_uuid_v4($input['idempotencyKey']), 'valid stable UUID');
        check_notice($input['sensitive'] === true, 'generic system banner');
        check_notice(strpos($input['body'], 'PRIVATE') === false, 'no contact/project payload in inbox');
        $id = $input['userIDs'][0];
        if (self::$fail === $id) { return new WP_Error; }
        $key = $input['idempotencyKey'];
        if (isset(self::$saved[$key])) {
            check_notice(self::$saved[$key] === $input, 'identical idempotent replay');
        }
        self::$saved[$key] = $input;
        return true;
    }
    public static function run($id) {
        return self::deliver_collaboration_admin_notice(array('public_id' => $id,
            'private_payload' => 'PRIVATE contact and budget must never be decrypted for a notice'));
    }
}
$request = '11111111-2222-4333-a444-555555555555';
NoticeHarness::$fail = 102;
check_notice(NoticeHarness::run($request) === false, 'partial failure retries');
check_notice(count(NoticeHarness::$saved) === 1, 'first recipient persisted');
NoticeHarness::$fail = null;
check_notice(NoticeHarness::run($request) === true, 'retry completes');
check_notice(count(NoticeHarness::$saved) === 2, 'retry did not duplicate first recipient');
check_notice(NoticeHarness::run($request) === true, 'worker crash replay');
check_notice(count(NoticeHarness::$saved) === 2, 'crash replay did not duplicate either recipient');
NoticeHarness::$saved = array();
NoticeHarness::$revoked = array(101);
check_notice(NoticeHarness::run($request) === true, 'remaining eligible administrator is notified');
check_notice(count(NoticeHarness::$saved) === 1, 'revoked administrator excluded');
NoticeHarness::$inactive = array(102);
check_notice(NoticeHarness::run($request) === false, 'no active administrator must not falsely succeed');
NoticeHarness::$users = range(1, 101);
check_notice(NoticeHarness::run($request) === false, 'recipient limit does not silently truncate');
NoticeHarness::$enabled = false;
check_notice(NoticeHarness::run($request) === false, 'release gate still applies');
check_notice(NoticeHarness::run('../invalid') === false, 'invalid reference rejected');
echo "collaboration-admin-notice: {$checks} assertions passed\n";
