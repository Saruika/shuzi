<?php
// Execute the real dormant worker with synthetic storage/transport only.
// No WordPress config, account, credential, email or network is loaded.
define('ABSPATH', __DIR__ . '/synthetic-wordpress-not-loaded/');
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-collaboration.php';
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-identity.php';
define('ARRAY_A', 'ARRAY_A');
final class WP_Error { public function __construct(...$arguments) {} }
function is_wp_error($value) { return $value instanceof WP_Error; }
function do_action(...$arguments) {}

// Optional: exercise the existing production GET_LOCK/RELEASE_LOCK methods
// through two local MySQL connections. No database is selected or mutated.
$worker_mysql = $worker_competitor = null;
$worker_origin = 'https://fixture.invalid/' . bin2hex(random_bytes(12));
function home_url($path = '') { global $worker_origin; return $worker_origin . $path; }
if (in_array('--mysql-lock', $argv, true)) {
    if (PHP_OS_FAMILY !== 'Linux' || !extension_loaded('mysqli') || posix_geteuid() !== 0) {
        throw new RuntimeException('Explicit Linux socket-root fixture required');
    }
    $worker_mysql = new mysqli('localhost', 'root', null, null, 0, '/var/run/mysqld/mysqld.sock');
    $worker_competitor = new mysqli('localhost', 'root', null, null, 0, '/var/run/mysqld/mysqld.sock');
}
final class ActualFanLock {
    use Shuzijun_App_Fan_Identity;
    public static function acquire($id) { return self::acquire_fan_lock($id); }
    public static function release($id, $name) { self::release_fan_lock($id, $name); }
}

$checks = 0;
function verify_worker($condition, $message) {
    global $checks;
    $checks++;
    if (!$condition) { throw new RuntimeException($message); }
}

final class WorkerDatabase {
    public $last_error = '';
    public $owner = '101';
    public $job_owner = '101';
    public $lookup_error = false;
    public $job_error = false;
    public $deleted = false;
    public $throw_claim = false;
    public $claimable = true;
    public $channel = 'work_mail';
    public $claims = 0;
    public $reads = 0;
    public $updates = 0;
    public function prepare($sql, ...$arguments) {
        global $worker_mysql;
        if ($worker_mysql && preg_match('/^SELECT (GET_LOCK|RELEASE_LOCK)/', $sql)) {
            return str_replace('%s', "'" . $worker_mysql->real_escape_string($arguments[0]) . "'", $sql);
        }
        return $sql;
    }
    public function get_var($sql) {
        global $worker_mysql;
        if ($worker_mysql && preg_match('/^SELECT (GET_LOCK|RELEASE_LOCK)/', $sql)) {
            $this->last_error = '';
            return $worker_mysql->query($sql)->fetch_row()[0];
        }
        verify_worker(strpos($sql, 'private_payload') === false, 'lookup must not read private payload');
        $this->last_error = $this->lookup_error ? 'synthetic_lookup_failure' : '';
        return $this->owner;
    }
    public function query($sql) {
        verify_worker(WorkerHarness::$locked, 'claim must hold deletion lock');
        $this->claims++;
        if ($this->throw_claim) { throw new RuntimeException('synthetic_claim_failure'); }
        return !$this->deleted && $this->claimable ? 1 : 0;
    }
    public function get_row($sql, $output) {
        verify_worker(WorkerHarness::$locked, 'payload read must hold deletion lock');
        $this->reads++;
        $this->last_error = $this->job_error ? 'synthetic_read_failure' : '';
        return array('id' => 1, 'request_id' => 1, 'fan_user_id' => $this->job_owner,
            'public_id' => '11111111-2222-4333-8444-555555555555', 'channel' => $this->channel,
            'attempts' => 1, 'private_payload' => 'synthetic-envelope');
    }
    public function update(...$arguments) {
        verify_worker(WorkerHarness::$locked, 'completion must hold deletion lock');
        $this->updates++;
        return 1;
    }
}

final class WorkerHarness {
    use Shuzijun_App_Collaboration;
    const COLLABORATION_OUTBOX_LEASE_SECONDS = 120;
    const COLLABORATION_OUTBOX_MAX_ATTEMPTS = 5;
    public static $enabled = true;
    public static $locked = false;
    public static $busy = false;
    public static $delete_before_lock = false;
    public static $locks = 0;
    public static $releases = 0;
    public static $mail_calls = 0;
    public static $mail_result = true;
    public static $mail_throws = false;
    public static $actual_lock = null;
    public static $failures = 0;
    public static $audits = 0;
    public static $notice_calls = 0;
    public static $notice_result = true;
    public static function collaboration_phase1_enabled() { return self::$enabled; }
    public static function account_authority_enabled() { return true; }
    private static function collaboration_mail_transport_ready() { return true; }
    private static function collaboration_storage_ready() { return true; }
    private static function collaboration_tables() {
        return array('requests' => 'fixture_requests', 'outbox' => 'fixture_outbox');
    }
    private static function acquire_fan_lock($owner) {
        global $wpdb, $worker_mysql;
        verify_worker($owner === 101, 'lock exact validated owner');
        self::$locks++;
        if (self::$busy) { return new WP_Error; }
        if (self::$delete_before_lock) { $wpdb->deleted = true; }
        if ($worker_mysql) {
            self::$actual_lock = ActualFanLock::acquire($owner);
            verify_worker(!is_wp_error(self::$actual_lock), 'actual production lock acquired');
        }
        self::$locked = true;
        return 'synthetic-owner-lock';
    }
    private static function release_fan_lock($owner, $lock) {
        global $worker_competitor;
        verify_worker($owner === 101 && $lock === 'synthetic-owner-lock', 'release same lock');
        if (self::$actual_lock !== null) {
            ActualFanLock::release($owner, self::$actual_lock);
            $escaped = $worker_competitor->real_escape_string(self::$actual_lock);
            verify_worker((string) $worker_competitor->query("SELECT GET_LOCK('{$escaped}', 0)")->fetch_row()[0] === '1',
                'real lock released for competing connection');
            $worker_competitor->query("SELECT RELEASE_LOCK('{$escaped}')");
            self::$actual_lock = null;
        }
        self::$locked = false;
        self::$releases++;
    }
    private static function collaboration_work_email() { return 'fixture@example.invalid'; }
    private static function deliver_collaboration_admin_notice($job) {
        verify_worker(self::$locked, 'administrator notice must serialize with account deletion');
        self::$notice_calls++;
        return self::$notice_result;
    }
    private static function collaboration_mail_body($job) {
        verify_worker(self::$locked, 'decryption must hold deletion lock');
        return 'Synthetic body';
    }
    private static function fail_collaboration_outbox_job(...$arguments) {
        verify_worker(self::$locked, 'failure accounting must hold deletion lock');
        self::$failures++;
    }
    private static function record_collaboration_audit(...$arguments) {
        verify_worker(self::$locked, 'audit must hold deletion lock');
        self::$audits++;
    }
}

function wp_mail(...$arguments) {
    global $worker_competitor;
    verify_worker(WorkerHarness::$locked, 'delivery must serialize with account deletion');
    if ($worker_competitor) {
        $escaped = $worker_competitor->real_escape_string(WorkerHarness::$actual_lock);
        verify_worker((string) $worker_competitor->query("SELECT GET_LOCK('{$escaped}', 0)")->fetch_row()[0] === '0',
            'competing deletion connection cannot acquire account lock during mail');
    }
    WorkerHarness::$mail_calls++;
    if (WorkerHarness::$mail_throws) { throw new RuntimeException('synthetic_transport_failure'); }
    return WorkerHarness::$mail_result;
}

function reset_worker() {
    global $wpdb;
    $wpdb = new WorkerDatabase;
    WorkerHarness::$enabled = true;
    WorkerHarness::$locked = WorkerHarness::$busy = WorkerHarness::$delete_before_lock = false;
    WorkerHarness::$locks = WorkerHarness::$releases = WorkerHarness::$mail_calls = 0;
    WorkerHarness::$failures = WorkerHarness::$audits = 0;
    WorkerHarness::$mail_result = true;
    WorkerHarness::$mail_throws = false;
}

reset_worker();
verify_worker(WorkerHarness::process_collaboration_outbox(1) === true, 'successful worker');
verify_worker(WorkerHarness::$mail_calls === 1 && WorkerHarness::$audits === 1, 'one mail and accepted audit');
verify_worker(!WorkerHarness::$locked && WorkerHarness::$releases === 1, 'success releases lock');

reset_worker();
WorkerHarness::$enabled = false;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'disabled worker remains disabled');
verify_worker(WorkerHarness::$locks === 0 && $wpdb->claims === 0, 'disabled has no lock/write');

foreach (array(null, '', '0', 0, -1, '01', true, 101.0, '101junk', '99999999999999999999999') as $invalid) {
    reset_worker();
    $wpdb->owner = $invalid;
    verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'invalid owner rejected');
    verify_worker(WorkerHarness::$locks === 0 && $wpdb->claims === 0, 'invalid owner cannot claim');
}

reset_worker();
$wpdb->lookup_error = true;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'owner query failure rejected');
verify_worker(WorkerHarness::$locks === 0 && $wpdb->claims === 0, 'lookup error cannot claim');

reset_worker();
WorkerHarness::$busy = true;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'busy deletion lock deferred');
verify_worker($wpdb->claims === 0 && WorkerHarness::$mail_calls === 0 && WorkerHarness::$releases === 0,
    'contention does not spend attempts, send or release another owner lock');

reset_worker();
WorkerHarness::$delete_before_lock = true;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'delete committed before acquisition');
verify_worker($wpdb->reads === 0 && WorkerHarness::$mail_calls === 0 && WorkerHarness::$releases === 1,
    'removed job cannot be read, decrypted or sent');

foreach (array('changed-owner', 'read-error', 'claim-failed', 'mail-false', 'mail-exception') as $scenario) {
    reset_worker();
    if ($scenario === 'changed-owner') { $wpdb->job_owner = '102'; }
    if ($scenario === 'read-error') { $wpdb->job_error = true; }
    if ($scenario === 'claim-failed') { $wpdb->claimable = false; }
    if ($scenario === 'mail-false') { WorkerHarness::$mail_result = false; }
    if ($scenario === 'mail-exception') { WorkerHarness::$mail_throws = true; }
    verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'failure is not accepted');
    verify_worker(!WorkerHarness::$locked && WorkerHarness::$releases === 1, 'failure releases lock');
    verify_worker($wpdb->updates === 0 && WorkerHarness::$audits === 0, 'no false sent state');
    if (in_array($scenario, array('changed-owner', 'read-error', 'claim-failed'), true)) {
        verify_worker(WorkerHarness::$mail_calls === 0, 'invalid refreshed job cannot send');
    }
}

reset_worker();
$wpdb->throw_claim = true;
try {
    WorkerHarness::process_collaboration_outbox(1);
    verify_worker(false, 'synthetic storage exception must propagate');
} catch (RuntimeException $error) {
    verify_worker($error->getMessage() === 'synthetic_claim_failure', 'expected storage exception');
}
verify_worker(!WorkerHarness::$locked && WorkerHarness::$releases === 1 && WorkerHarness::$mail_calls === 0,
    'unexpected storage exception still releases lock without mail');
reset_worker();
$wpdb->channel = 'admin_notice';
WorkerHarness::$notice_result = false;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === false, 'failed notice remains retryable');
verify_worker(WorkerHarness::$failures === 1 && WorkerHarness::$mail_calls === 0, 'notice failure never sends mail');
reset_worker();
$wpdb->channel = 'admin_notice';
WorkerHarness::$notice_result = true;
verify_worker(WorkerHarness::process_collaboration_outbox(1) === true, 'administrator channel independently succeeds');
verify_worker(WorkerHarness::$audits === 1 && WorkerHarness::$mail_calls === 0, 'administrator success audited without email');
echo "collaboration-outbox-deletion: passed {$checks} assertions\n";
if ($worker_mysql) {
    $worker_mysql->close();
    $worker_competitor->close();
    echo "collaboration-outbox-deletion: actual two-connection MySQL locks passed; no database selected\n";
}
