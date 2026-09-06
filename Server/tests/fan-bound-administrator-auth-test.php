<?php
declare(strict_types=1);

// Executes the actual administrator and approved-fan gates from the production
// trait. Session-token verification and WordPress storage are test doubles;
// this does not replace the real WordPress/session integration suite.
define('ABSPATH', __DIR__ . '/');
final class WP_Error {
    public function __construct(...$arguments) {}
}
final class WP_User {
    public function __construct(public int $ID, public array $roles, public array $caps) {}
}
final class WP_REST_Request {
    public function __construct(private string $authorization) {}
    public function get_header(string $name): string {
        return strtolower($name) === 'authorization' ? $this->authorization : '';
    }
}
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function get_userdata(int $id) { return $GLOBALS['users'][$id] ?? false; }
function get_user_meta(int $id, string $key, bool $single) {
    return $GLOBALS['meta'][$id][$key] ?? '';
}
function user_can(WP_User $user, string $capability): bool {
    return ($user->caps[$capability] ?? false) === true;
}
function current_user_can(string $capability): bool {
    $user = get_userdata($GLOBALS['current_user_id']);
    return $user instanceof WP_User && user_can($user, $capability);
}
function wp_set_current_user(int $id): void { $GLOBALS['current_user_id'] = $id; }
function wp_get_current_user() { return get_userdata($GLOBALS['current_user_id']); }
function get_current_user_id(): int { return $GLOBALS['current_user_id']; }
function add_filter(...$arguments): void {}
function remove_filter(...$arguments): void {}
function wp_authenticate_application_password($input, string $username, string $password) {
    return $GLOBALS['legacy_user'] ?? new WP_Error();
}
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php';

final class BoundAdministratorHarness {
    use Shuzijun_App_Fan_Endpoints;
    const ROLE = 'yishu_content_manager';
    const CAPABILITY = 'manage_yishu_app_content';
    const FAN_CAPABILITY = 'manage_yishu_fan_accounts';
    const PUSH_CAPABILITY = 'manage_yishu_push_notifications';
    const COLLABORATION_CAPABILITY = 'manage_yishu_collaboration_requests';
    const FAN_META_INVITATION = 'invitation';
    const FAN_META_PASSWORD_RECOVERY = 'recovery';
    const FAN_META_APPLE_SETUP = 'apple_setup';
    const FAN_META_STATUS = 'status';
    const FAN_META_UUID = 'uuid';
    private static $fan_session_context = null;

    public static function manages(WP_REST_Request $request, string $capability): bool {
        return self::authenticate_manager_for_capability($request, $capability);
    }
    public static function context() { return self::$fan_session_context; }
    public static function can_manage_fans(WP_REST_Request $request): bool {
        return self::manages($request, self::FAN_CAPABILITY);
    }
    public static function account_authority_enabled(): bool { return $GLOBALS['authority']; }
    public static function collaboration_phase1_enabled(): bool { return $GLOBALS['collaboration']; }
    private static function authenticate_fan_session(WP_REST_Request $request) {
        ++$GLOBALS['auth_calls'];
        $context = $GLOBALS['authenticated_context'];
        if (is_array($context)) { wp_set_current_user((int) $context['userID']); }
        return $context;
    }
    private static function fan_has_required_douyin_id(int $id): bool {
        return ($GLOBALS['meta'][$id]['douyin_complete'] ?? false) === true;
    }
    private static function fan_permissions_for_user(int $id): array { return array('gallery_full'); }
}

$checks = 0;
function expect_bound_admin(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function reset_bound_admin_fixture(): void {
    $GLOBALS['current_user_id'] = 0;
    $GLOBALS['authority'] = true;
    $GLOBALS['collaboration'] = false;
    $GLOBALS['auth_calls'] = 0;
    $GLOBALS['authenticated_context'] = array('userID' => 17, 'scope' => 'normal');
    $GLOBALS['users'] = array(17 => new WP_User(17, array('subscriber', BoundAdministratorHarness::ROLE), array(
        BoundAdministratorHarness::CAPABILITY => true,
        BoundAdministratorHarness::FAN_CAPABILITY => true,
        BoundAdministratorHarness::PUSH_CAPABILITY => true,
        BoundAdministratorHarness::COLLABORATION_CAPABILITY => true,
        'manage_options' => true, // Even an incidental WP cap is outside this App bearer gate.
    )));
    $GLOBALS['meta'] = array(17 => array('uuid' => 'fixture-user', 'status' => 'active', 'douyin_complete' => true));
    unset($GLOBALS['legacy_user']);
}

// Random per execution; no hard-coded token, password or production account.
$request = new WP_REST_Request('Bearer ' . bin2hex(random_bytes(24)));
foreach (array(
    BoundAdministratorHarness::CAPABILITY, BoundAdministratorHarness::FAN_CAPABILITY,
    BoundAdministratorHarness::PUSH_CAPABILITY, BoundAdministratorHarness::COLLABORATION_CAPABILITY,
) as $capability) {
    reset_bound_admin_fixture();
    expect_bound_admin(BoundAdministratorHarness::manages($request, $capability), 'bound role grants only its actual App capability');
    expect_bound_admin($GLOBALS['auth_calls'] === 1, 'session is authenticated before the role is considered');
}
reset_bound_admin_fixture();
expect_bound_admin(!BoundAdministratorHarness::manages($request, 'manage_options'), 'bearer cannot become a WordPress super administrator');
reset_bound_admin_fixture();
$GLOBALS['users'][17]->roles = array('subscriber');
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'unbound ordinary fan cannot manage');
expect_bound_admin(BoundAdministratorHarness::can_access_app_content($request) === true, 'ordinary approved fan still sees content');
expect_bound_admin(BoundAdministratorHarness::context()['userID'] === 17, 'ordinary content retains its own fan context');
reset_bound_admin_fixture();
$GLOBALS['users'][17]->caps[BoundAdministratorHarness::CAPABILITY] = false;
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'role name alone cannot invent a capability');
foreach (array('pending', 'rejected', 'suspended', '') as $status) {
    reset_bound_admin_fixture();
    $GLOBALS['meta'][17]['status'] = $status;
    expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'approval is mandatory for a bound administrator');
    expect_bound_admin($GLOBALS['current_user_id'] === 0 && BoundAdministratorHarness::context() === null, 'failed approval clears privileged request state');
    expect_bound_admin(is_wp_error(BoundAdministratorHarness::can_access_app_content($request)), 'administrator role cannot bypass the normal content approval gate');
}
foreach (array('invitation', 'recovery', 'apple_setup') as $field) {
    reset_bound_admin_fixture();
    $GLOBALS['meta'][17][$field] = array('incomplete' => true);
    expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'incomplete setup cannot unlock management');
}
reset_bound_admin_fixture();
$GLOBALS['meta'][17]['douyin_complete'] = false;
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'Douyin ID remains mandatory');
foreach (array('onboarding', 'password_recovery', 'apple_onboarding', '') as $scope) {
    reset_bound_admin_fixture();
    $GLOBALS['authenticated_context']['scope'] = $scope;
    expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'restricted sessions cannot manage');
}
reset_bound_admin_fixture();
wp_set_current_user(17);
$GLOBALS['authenticated_context'] = new WP_Error();
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'invalid bearer cannot borrow an already populated WordPress user');
expect_bound_admin($GLOBALS['current_user_id'] === 0, 'invalid session clears current user');
reset_bound_admin_fixture();
wp_set_current_user(17);
$GLOBALS['users'][18] = new WP_User(18, array('subscriber'), array());
$GLOBALS['meta'][18] = array('uuid' => 'other-fixture-user', 'status' => 'active', 'douyin_complete' => true);
$GLOBALS['authenticated_context'] = array('userID' => 18, 'scope' => 'normal');
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'a valid ordinary bearer cannot borrow another current WP administrator');
expect_bound_admin($GLOBALS['current_user_id'] === 18, 'the request identity is the actual bearer owner');
reset_bound_admin_fixture();
expect_bound_admin(BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'initial bound role works');
$GLOBALS['users'][17]->roles = array('subscriber');
expect_bound_admin(!BoundAdministratorHarness::manages($request, BoundAdministratorHarness::CAPABILITY), 'next request rechecks a removed binding');
reset_bound_admin_fixture();
$GLOBALS['legacy_user'] = $GLOBALS['users'][17];
$legacy = new WP_REST_Request('Basic ' . base64_encode('fixture:' . bin2hex(random_bytes(16))));
expect_bound_admin(!BoundAdministratorHarness::manages($legacy, BoundAdministratorHarness::CAPABILITY), 'a bound fan cannot substitute an Application Password for its App session');
wp_set_current_user(17);
expect_bound_admin(!BoundAdministratorHarness::manages(new WP_REST_Request(''), BoundAdministratorHarness::CAPABILITY), 'a bound fan cannot substitute a WP cookie for its App session');
unset($GLOBALS['meta'][17]['uuid']);
expect_bound_admin(BoundAdministratorHarness::manages($legacy, BoundAdministratorHarness::CAPABILITY), 'existing administrator Application Password path remains supported');
expect_bound_admin($GLOBALS['auth_calls'] === 0, 'legacy authentication does not enter the fan-session gate');
expect_bound_admin(BoundAdministratorHarness::manages(new WP_REST_Request(''), BoundAdministratorHarness::CAPABILITY), 'existing non-fan WP administrator cookie remains supported');
foreach (array('Basic invalid', 'BearerX invalid', 'Digest invalid') as $header) {
    expect_bound_admin(!BoundAdministratorHarness::manages(new WP_REST_Request($header), BoundAdministratorHarness::CAPABILITY), 'explicit malformed credentials cannot borrow a populated WP administrator');
}
reset_bound_admin_fixture();
expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) === true, 'full bound App manager can allocate App administration');
foreach (array(BoundAdministratorHarness::CAPABILITY, BoundAdministratorHarness::FAN_CAPABILITY,
    BoundAdministratorHarness::PUSH_CAPABILITY) as $capability) {
    reset_bound_admin_fixture();
    $GLOBALS['users'][17]->caps[$capability] = false;
    expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) !== true, 'partial App capabilities cannot be amplified by delegation');
}
reset_bound_admin_fixture();
$GLOBALS['users'][17]->caps[BoundAdministratorHarness::COLLABORATION_CAPABILITY] = false;
expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) === true, 'dormant collaboration capability does not block ordinary App administration');
$GLOBALS['collaboration'] = true;
expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) !== true, 'enabled collaboration must be part of full administrator authority');
reset_bound_admin_fixture();
$GLOBALS['authority'] = false;
expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) !== true, 'standby cannot allocate administrator identities');
reset_bound_admin_fixture();
$GLOBALS['users'][17]->roles = array('subscriber');
expect_bound_admin(BoundAdministratorHarness::can_manage_fan_administrators($request) !== true, 'fan capability data alone cannot replace actual role binding');
expect_bound_admin(is_wp_error(BoundAdministratorHarness::update_fan_administrator($request)), 'mutation callback itself rejects an ordinary caller before storage access');
echo 'fan-bound-administrator-auth-test: passed assertions=' . $checks . PHP_EOL;
