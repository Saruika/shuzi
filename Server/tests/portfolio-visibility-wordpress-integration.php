<?php
declare(strict_types=1);

// Run only inside the existing network-isolated disposable WordPress fixture.
if (!isset($database, $fixture_portfolio_id, $dispatch_media_fixture, $publisher)
    || !defined('DB_NAME') || DB_NAME !== $database
    || !str_starts_with(DB_NAME, 'yishu_wp_schema_test_')) {
    throw new RuntimeException('Requires isolated album fixture');
}
$visibility_route = '/shuzijun/v1/app-content/portfolio/' . $fixture_portfolio_id . '/visibility';
$set_visibility = static fn($visible, $expected, ?array $caller = null) =>
    $dispatch_media_fixture($caller ?? $publisher, 'POST', $visibility_route,
        array('isVisible' => $visible, 'expectedIsVisible' => $expected));
$manifest_method = new ReflectionMethod(Shuzijun_App_Content_API::class, 'manifest');
$visible_ids = static fn($audience) => array_column(
    $manifest_method->invoke(null, $audience, array('gallery_full', 'video_view'))['portfolios'], 'id');
check_wordpress_schema($albums[0]['isVisible'] === true, 'unconfigured existing album defaults visible');
foreach (array(null, 'false', 0, 1, array()) as $bad) {
    check_wordpress_schema($set_visibility($bad, true)->get_status() === 400, 'invalid visibility type rejected');
    check_wordpress_schema($set_visibility(false, $bad)->get_status() === 400, 'invalid expected visibility type rejected');
}
check_wordpress_schema($set_visibility(false, true, array())->get_status() >= 400, 'anonymous cannot hide album');
$ordinary_viewer = $make_fan();
check_wordpress_schema($set_visibility(false, true, $ordinary_viewer)->get_status() >= 400, 'ordinary fan cannot hide album');
check_wordpress_schema($set_visibility(true, true)->get_status() === 200, 'no-op visibility save is safe');
$hidden = $set_visibility(false, true);
check_wordpress_schema($hidden->get_status() === 200 && $hidden->get_data()['isVisible'] === false, 'admin hides actual album');
check_wordpress_schema($hidden->get_headers()['Cache-Control'] === 'private, no-store', 'visibility response not cacheable');
foreach (array('public', 'app', 'premium') as $audience) {
    check_wordpress_schema(!in_array($fixture_portfolio_id, $visible_ids($audience), true), 'hidden album omitted for ' . $audience);
}
check_wordpress_schema(in_array($fixture_portfolio_id, $visible_ids('admin'), true), 'admin retains hidden album');
$empty_content = $manifest_method->invoke(null, 'app', array('gallery_full'));
check_wordpress_schema($empty_content['portfolios'] === array(), 'hiding the last album yields an authoritative empty list');
check_wordpress_schema($set_visibility(true, true)->get_status() === 409, 'stale administrator cannot overwrite changed state');
check_wordpress_schema($set_visibility(false, false)->get_status() === 200, 'idempotent hidden save succeeds');
check_wordpress_schema(get_post_meta($fixture_portfolio_id, '_portfolio_gallery', true) === $saved_gallery
    && get_option(Shuzijun_App_Content_API::OPTION_CONFIG) === $saved_configuration
    && scandir($upload_root) === $saved_files && is_file($uploaded_file), 'hiding preserves gallery, shared config and photo bytes');
// Updating a hidden gallery must not silently make it visible again.
check_wordpress_schema($dispatch_media_fixture($publisher, 'POST', $gallery_route,
    array('mediaIDs' => array($media_id)))->get_status() === 200, 'hidden album remains editable');
check_wordpress_schema(!in_array($fixture_portfolio_id, $visible_ids('app'), true), 'editing does not unhide');
check_wordpress_schema($set_visibility(true, false)->get_status() === 200, 'admin restores visibility');
check_wordpress_schema(in_array($fixture_portfolio_id, $visible_ids('app'), true), 'restored album returns to viewer list');
check_wordpress_schema(get_post_meta($fixture_portfolio_id, '_portfolio_gallery', true) === $saved_gallery,
    'restoring preserves exact image ordering');
