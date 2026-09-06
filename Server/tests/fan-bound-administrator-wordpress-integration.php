<?php
declare(strict_types=1);

// Included only by the network-isolated, randomly named database fixture.
// Use the actual WP users/roles/options and production session verifier. Do not
// load the plugin entry or register production hooks/routes/cron jobs.
if (!defined('DB_NAME') || !isset($database, $wpdb)
    || DB_NAME !== $database || !str_starts_with(DB_NAME, 'yishu_wp_schema_test_')
    || $wpdb->get_var('SELECT DATABASE()') !== $database) {
    throw new RuntimeException('Requires the isolated WordPress fixture');
}
require dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php';
Shuzijun_App_Content_API::ensure_roles();
$before_checks = $checks;
$manager_gate = new ReflectionMethod(Shuzijun_App_Content_API::class, 'authenticate_manager_for_capability');
$manages = static function (WP_REST_Request $request, string $capability) use ($manager_gate): bool {
    return $manager_gate->invoke(null, $request, $capability);
};
$id = wp_insert_user(array(
    'user_login' => 'bound_fixture_' . bin2hex(random_bytes(8)),
    'user_pass' => bin2hex(random_bytes(24)),
    'role' => 'subscriber',
));
check_wordpress_schema(is_int($id) && $id > 0, 'create only a synthetic fan');
$uuid = wp_generate_uuid4();
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_UUID, $uuid);
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, 'fixture_douyin_123');
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_CREDENTIAL_EPOCH, 1);
$user = get_userdata($id);
check_wordpress_schema($user instanceof WP_User, 'actual WordPress user');
$user->add_role(Shuzijun_App_Content_API::ROLE);
$token = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
$install = wp_generate_uuid4();
$option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . hash('sha256', $token);
$session = array('userID' => $id, 'expires' => time() + 600,
    'installHash' => hash('sha256', $install), 'scope' => 'normal',
    'credentialEpoch' => 1, 'authMethod' => 'password', 'recentAuthUntil' => 0);
check_wordpress_schema(add_option($option, $session, '', false), 'synthetic session is stored in real options');
$request = new WP_REST_Request('GET');
$request->set_header('Authorization', 'Bearer ' . $token);
$request->set_header('X-Yishu-Install-ID', $install);
foreach (array(Shuzijun_App_Content_API::CAPABILITY, Shuzijun_App_Content_API::FAN_CAPABILITY,
    Shuzijun_App_Content_API::PUSH_CAPABILITY) as $capability) {
    wp_set_current_user(0);
    check_wordpress_schema($manages($request, $capability), 'actual session grants actual App capability');
    check_wordpress_schema(get_current_user_id() === $id, 'WP current actor is the authenticated fan');
}
check_wordpress_schema(!$manages($request, 'manage_options'), 'App admin is not a WordPress super administrator');
check_wordpress_schema(!user_can($id, 'manage_options'), 'role binding did not grant site-wide administration');
// The existing REST pre-dispatch hook authenticates the App bearer before the
// core media controller checks upload_files. Verify the actual integration,
// not an assumed need for an additional upload endpoint. No file is uploaded.
$media_request = new WP_REST_Request('POST', '/wp/v2/media');
$media_request->set_header('Authorization', 'Bearer ' . $token);
$media_request->set_header('X-Yishu-Install-ID', $install);
wp_set_current_user(0);
check_wordpress_schema(Shuzijun_App_Content_API::block_public_catalog_routes(null, null, $media_request) === null,
    'real media pre-dispatch accepts an approved bound administrator');
check_wordpress_schema(get_current_user_id() === $id, 'media controller receives actual bearer actor');
$media_controller = new WP_REST_Attachments_Controller('attachment');
check_wordpress_schema($media_controller->create_item_permissions_check($media_request) === true,
    'core media create permission accepts scoped upload_files without site editing rights');
check_wordpress_schema(!current_user_can('edit_others_posts'), 'media upload does not grant editing other posts');
check_wordpress_schema(Shuzijun_App_Content_API::can_access_app_content($request) === true, 'bound user still accesses fan content');
foreach (array('pending', 'rejected', 'suspended') as $status) {
    update_user_meta($id, Shuzijun_App_Content_API::FAN_META_STATUS, $status);
    check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'actual approval state prevents management');
    check_wordpress_schema(get_current_user_id() === 0, 'denial clears WP actor');
    check_wordpress_schema(is_wp_error(Shuzijun_App_Content_API::can_access_app_content($request)), 'role does not bypass approval for fan pages');
}
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_STATUS, 'active');
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, '');
check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'actual missing Douyin ID blocks management');
update_user_meta($id, Shuzijun_App_Content_API::FAN_META_DOUYIN_ID, 'fixture_douyin_123');
foreach (array(Shuzijun_App_Content_API::FAN_META_INVITATION,
    Shuzijun_App_Content_API::FAN_META_PASSWORD_RECOVERY, Shuzijun_App_Content_API::FAN_META_APPLE_SETUP) as $meta) {
    update_user_meta($id, $meta, array('incomplete' => true));
    check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'incomplete setup blocks actual bound user');
    delete_user_meta($id, $meta);
}
foreach (array('onboarding', 'password_recovery', 'apple_onboarding') as $scope) {
    update_option($option, array_merge($session, array('scope' => $scope,
        'authMethod' => $scope === 'apple_onboarding' ? 'apple' : 'password')), false);
    check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'restricted actual session cannot manage');
}
update_option($option, $session, false);
$user->remove_role(Shuzijun_App_Content_API::ROLE);
check_wordpress_schema(is_wp_error(Shuzijun_App_Content_API::block_public_catalog_routes(null, null, $media_request)),
    'revoked administrator cannot enter the media controller');
check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'role removal takes effect on the next request');
check_wordpress_schema(Shuzijun_App_Content_API::can_access_app_content($request) === true, 'revoking admin does not remove approved fan access');
check_wordpress_schema(get_user_meta($id, Shuzijun_App_Content_API::FAN_META_UUID, true) === $uuid, 'identity survives admin revocation');
$user->add_role(Shuzijun_App_Content_API::ROLE);
check_wordpress_schema($manages($request, Shuzijun_App_Content_API::CAPABILITY), 'explicit fixture regrant restores admin access');
wp_set_current_user($id);
check_wordpress_schema(!$manages(new WP_REST_Request('GET'), Shuzijun_App_Content_API::CAPABILITY), 'fan WP cookie cannot substitute for App session');
// Real Application Password verification, including the legacy non-fan path.
// REST normally supplies this API-request context; only the CLI fixture sets it.
$api_request = static function () { return true; };
add_filter('application_password_is_api_request', $api_request);
try {
    $credential = WP_Application_Passwords::create_new_application_password($id, array('name' => 'Synthetic bound account test'));
    check_wordpress_schema(is_array($credential), 'create a temporary bound-user application password');
    $verified = wp_authenticate_application_password(null, $user->user_login, $credential[0]);
    check_wordpress_schema($verified instanceof WP_User && $verified->ID === $id, 'bound Basic credential is genuinely valid before the App policy rejects it');
    $basic = new WP_REST_Request('GET');
    $basic->set_header('Authorization', 'Basic ' . base64_encode($user->user_login . ':' . $credential[0]));
    wp_set_current_user(0);
    check_wordpress_schema(!$manages($basic, Shuzijun_App_Content_API::CAPABILITY), 'valid fan Basic credential cannot bypass installation/session requirements');

    $legacy_id = wp_insert_user(array('user_login' => 'legacy_fixture_' . bin2hex(random_bytes(8)),
        'user_pass' => bin2hex(random_bytes(24)), 'role' => Shuzijun_App_Content_API::ROLE));
    check_wordpress_schema(is_int($legacy_id) && $legacy_id > 0, 'create a synthetic legacy non-fan manager');
    $legacy_user = get_userdata($legacy_id);
    $legacy_credential = WP_Application_Passwords::create_new_application_password($legacy_id, array('name' => 'Synthetic legacy test'));
    check_wordpress_schema(is_array($legacy_credential), 'create a temporary legacy application password');
    $basic->set_header('Authorization', 'Basic ' . base64_encode($legacy_user->user_login . ':' . $legacy_credential[0]));
    check_wordpress_schema($manages($basic, Shuzijun_App_Content_API::CAPABILITY), 'actual legacy Basic login still works');
    check_wordpress_schema(get_current_user_id() === $legacy_id, 'legacy request retains the authenticated actor');
    check_wordpress_schema($manages(new WP_REST_Request('GET'), Shuzijun_App_Content_API::CAPABILITY), 'actual legacy WP cookie still works');
} finally {
    remove_filter('application_password_is_api_request', $api_request);
    unset($credential, $legacy_credential, $basic, $verified);
}
$request->set_header('X-Yishu-Install-ID', 'invalid');
check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'invalid installation cannot use administrator role');
$request->set_header('X-Yishu-Install-ID', $install);
delete_option($option);
wp_set_current_user($id);
check_wordpress_schema(!$manages($request, Shuzijun_App_Content_API::CAPABILITY), 'revoked actual token cannot borrow current administrator');
check_wordpress_schema(get_current_user_id() === 0, 'revoked token clears WP actor');
check_wordpress_schema(!Shuzijun_App_Content_API::collaboration_phase1_enabled(), 'production collaboration fuse remains off');
fwrite(STDOUT, 'fan-bound-administrator-wordpress: ' . ($checks - $before_checks)
    . " assertions passed; real WP roles, options and session verifier; no live users\n");
