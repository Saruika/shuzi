<?php
declare(strict_types=1);

// Included only inside the real WordPress fixture's temporary authority scope.
// Exercise core upload bytes and actual plugin routes; never use real photos,
// the production uploads tree, HTTP downloads, live accounts, or live options.
if (!defined('DB_NAME') || !isset($database, $wpdb, $server, $make_fan, $call)
    || DB_NAME !== $database || !str_starts_with(DB_NAME, 'yishu_wp_schema_test_')
    || $wpdb->get_var('SELECT DATABASE()') !== $database
    || !Shuzijun_App_Content_API::account_authority_enabled()
    || !function_exists('imagecreatetruecolor')) {
    throw new RuntimeException('Requires isolated database, authority marker and GD');
}
$media_before_checks = $checks;
$upload_root = sys_get_temp_dir() . '/yishu-media-fixture-' . bin2hex(random_bytes(10));
if (!mkdir($upload_root, 0700)) { throw new RuntimeException('Private upload fixture unavailable'); }
$fixture_media_ids = array();
$fixture_portfolio_id = 0;
$upload_location = static function ($location) use ($upload_root) {
    return array('path' => $upload_root, 'basedir' => $upload_root, 'subdir' => '',
        'url' => 'https://example.invalid/synthetic-uploads',
        'baseurl' => 'https://example.invalid/synthetic-uploads', 'error' => false);
};
$media_gate = array(Shuzijun_App_Content_API::class, 'block_public_catalog_routes');
$force_gd = static fn() => array('WP_Image_Editor_GD');
$dispatch_media_fixture = static function (array $caller, string $method, string $route,
    array $payload = array(), ?string $bytes = null) use ($server): WP_REST_Response {
    wp_set_current_user(0);
    $request = new WP_REST_Request($method, $route);
    if ($caller) {
        $request->set_header('Authorization', 'Bearer ' . $caller['token']);
        $request->set_header('X-Yishu-Install-ID', $caller['install']);
    }
    if ($bytes !== null) {
        $request->set_header('Content-Type', 'image/png');
        $request->set_header('Content-Disposition', 'attachment; filename="synthetic-portrait.png"');
        $request->set_body($bytes);
    } elseif ($payload) {
        $request->set_header('Content-Type', 'application/json');
        $request->set_body(wp_json_encode($payload));
    }
    return $server->dispatch($request);
};
$attachment_count = static fn(): int => (int) $wpdb->get_var(
    "SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type = 'attachment'");
add_filter('upload_dir', $upload_location);
add_filter('wp_image_editors', $force_gd);
add_filter('rest_pre_dispatch', $media_gate, 10, 3);
try {
    // The theme normally registers this post type; the isolated fixture loads
    // no theme. Keep the native attachment controller and every API callback.
    check_wordpress_schema(!post_type_exists('portfolio'), 'fixture has no live theme portfolio registration');
    register_post_type('portfolio', array('public' => false, 'supports' => array('title', 'thumbnail')));
    $publisher = $make_fan();
    $granting_manager = $make_fan(true);
    check_wordpress_schema($call($granting_manager, $publisher, true, false) instanceof WP_REST_Response,
        'publisher obtains role through actual assignment API');
    $image = imagecreatetruecolor(1200, 1800);
    imagefilledrectangle($image, 0, 0, 1199, 1799, imagecolorallocate($image, 25, 85, 135));
    imagefilledellipse($image, 600, 550, 400, 600, imagecolorallocate($image, 210, 180, 120));
    ob_start();
    try { imagepng($image); $png_bytes = (string) ob_get_contents(); }
    finally { ob_end_clean(); imagedestroy($image); }
    check_wordpress_schema(strlen($png_bytes) > 100, 'synthetic portrait bytes were generated, not downloaded');
    $before_upload = $attachment_count();
    $upload = $dispatch_media_fixture($publisher, 'POST', '/wp/v2/media', array(), $png_bytes);
    check_wordpress_schema($upload->get_status() === 201, 'actual core raw-body upload returns created');
    $uploaded = $upload->get_data();
    $media_id = (int) ($uploaded['id'] ?? 0);
    if ($media_id > 0) { $fixture_media_ids[] = $media_id; }
    check_wordpress_schema($media_id > 0 && $attachment_count() === $before_upload + 1, 'upload creates one real attachment');
    check_wordpress_schema((int) get_post($media_id)->post_author === $publisher['id'], 'uploaded image belongs to bearer publisher');
    $uploaded_file = get_attached_file($media_id);
    check_wordpress_schema(is_string($uploaded_file) && dirname($uploaded_file) === $upload_root
        && is_file($uploaded_file), 'actual file is confined to private upload fixture');
    check_wordpress_schema(hash_file('sha256', $uploaded_file) === hash('sha256', $png_bytes), 'stored original matches uploaded bytes');
    check_wordpress_schema($uploaded['mime_type'] === 'image/png'
        && $uploaded['source_url'] === 'https://example.invalid/synthetic-uploads/' . basename($uploaded_file),
        'native upload response supplies the expected source URL and MIME');
    $metadata = wp_get_attachment_metadata($media_id);
    check_wordpress_schema($metadata['width'] === 1200 && $metadata['height'] === 1800,
        'core metadata preserves portrait dimensions');
    check_wordpress_schema(isset($metadata['sizes']['large'])
        && $metadata['sizes']['large']['width'] < $metadata['sizes']['large']['height'],
        'core creates portrait display derivative without landscape cropping');
    check_wordpress_schema(is_file($upload_root . '/' . $metadata['sizes']['large']['file']), 'display derivative actually exists');
    check_wordpress_schema(!user_can($publisher['id'], 'edit_others_posts')
        && !user_can($publisher['id'], 'manage_options'), 'successful upload does not require whole-site privileges');

    $created = $dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/app-content/portfolio',
        array('title' => 'Synthetic portrait album', 'subtitle' => 'Only a disposable test', 'eyebrow' => 'FIXTURE'));
    check_wordpress_schema($created->get_status() === 201, 'bound publisher creates album through real REST route');
    $fixture_portfolio_id = (int) ($created->get_data()['portfolioID'] ?? 0);
    check_wordpress_schema($fixture_portfolio_id > 0 && get_post_status($fixture_portfolio_id) === 'publish', 'synthetic album is published in disposable DB');
    $gallery_route = '/shuzijun/v1/app-content/portfolio/' . $fixture_portfolio_id . '/gallery';
    $gallery = $dispatch_media_fixture($publisher, 'POST', $gallery_route, array('mediaIDs' => array($media_id)));
    check_wordpress_schema($gallery->get_status() === 200 && $gallery->get_data()['mediaIDs'] === array($media_id),
        'native uploaded image can be assigned to the new album');
    check_wordpress_schema((int) wp_get_post_parent_id($media_id) === $fixture_portfolio_id,
        'gallery assignment updates actual attachment parent');
    $read = $dispatch_media_fixture($publisher, 'GET', '/shuzijun/v1/app-content');
    check_wordpress_schema($read->get_data()['contentAudience'] === 'administrator',
        'actual bound administrator receives explicit editorial audience');
    $albums = array_values(array_filter($read->get_data()['portfolios'],
        static fn($album) => $album['id'] === $fixture_portfolio_id));
    check_wordpress_schema($read->get_status() === 200 && count($albums) === 1
        && count($albums[0]['images']) === 1, 'published feed contains actual uploaded album and image');
    check_wordpress_schema($albums[0]['images'][0]['fullSizeURL'] === $uploaded['source_url']
        && str_ends_with($albums[0]['images'][0]['url'], $metadata['sizes']['large']['file']),
        'manifest connects original and lighter display derivative');
    $updated = $dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/app-content',
        array('aboutPortraitURL' => $uploaded['source_url']));
    check_wordpress_schema($updated->get_status() === 200
        && $updated->get_data()['aboutPortraitURL'] === $uploaded['source_url'], 'bound publisher updates portrait configuration');
    $saved_configuration = get_option(Shuzijun_App_Content_API::OPTION_CONFIG);
    $saved_gallery = get_post_meta($fixture_portfolio_id, '_portfolio_gallery', true);
    $saved_files = scandir($upload_root);
    $count_before_denials = $attachment_count();
    // Installation mismatch intentionally revokes that token. Use a different
    // account so it cannot make the subsequent role-revocation test pass merely
    // because the publisher's session was already invalidated.
    $installation_subject = $make_fan(true);
    $wrong_install = array_merge($installation_subject, array('install' => wp_generate_uuid4()));
    $denied_install = $dispatch_media_fixture($wrong_install, 'POST', '/wp/v2/media', array(), $png_bytes);
    check_wordpress_schema($denied_install->get_status() === 404, 'wrong installation cannot upload with a valid token');
    check_wordpress_schema($dispatch_media_fixture($publisher, 'GET', '/shuzijun/v1/app-content')->get_status() === 200,
        'publisher token is valid immediately before role revocation');
    check_wordpress_schema($call($granting_manager, $publisher, false, true) instanceof WP_REST_Response,
        'real allocation API revokes publisher while keeping same token');
    $denied_upload = $dispatch_media_fixture($publisher, 'POST', '/wp/v2/media', array(), $png_bytes);
    check_wordpress_schema($denied_upload->get_status() === 404, 'same session cannot upload after role revocation');
    check_wordpress_schema($dispatch_media_fixture(array(), 'POST', '/wp/v2/media', array(), $png_bytes)->get_status() === 404,
        'anonymous upload is denied by actual pre-dispatch policy');
    check_wordpress_schema($dispatch_media_fixture($publisher, 'POST', $gallery_route, array('mediaIDs' => array()))->get_status() >= 400,
        'same revoked session cannot empty an album');
    check_wordpress_schema($dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/app-content',
        array('aboutPortraitURL' => null))->get_status() >= 400, 'same revoked session cannot replace portrait configuration');
    check_wordpress_schema($dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/app-content/portfolio',
        array('title' => 'Should not exist'))->get_status() >= 400, 'same revoked session cannot publish another album');
    check_wordpress_schema($attachment_count() === $count_before_denials && scandir($upload_root) === $saved_files,
        'rejected requests create no attachments or upload files');
    check_wordpress_schema(get_option(Shuzijun_App_Content_API::OPTION_CONFIG) === $saved_configuration
        && get_post_meta($fixture_portfolio_id, '_portfolio_gallery', true) === $saved_gallery,
        'rejected writes leave configuration and album unchanged');
    $revoked_read = $dispatch_media_fixture($publisher, 'GET', '/shuzijun/v1/app-content');
    check_wordpress_schema($revoked_read->get_status() === 200,
        'revoked administrator remains an approved ordinary fan');
    check_wordpress_schema($revoked_read->get_data()['contentAudience'] === 'viewer',
        'the same bearer after revocation cannot receive an editorial content marker');
    $forged_scope = $dispatch_media_fixture($publisher, 'GET', '/shuzijun/v1/app-content',
        array('audience' => 'admin', 'contentAudience' => 'administrator'));
    check_wordpress_schema($forged_scope->get_status() === 200
        && $forged_scope->get_data()['contentAudience'] === 'viewer',
        'client-supplied audience cannot override actual server-side role checks');

    $deletion = $dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/fan/delete', array(
        'installID' => $publisher['install'], 'currentPassword' => $publisher['password'],
        'confirmation' => 'DELETE_ACCOUNT'));
    check_wordpress_schema($deletion->get_status() === 200, 'revoked publisher can delete own account normally');
    check_wordpress_schema(!get_userdata($publisher['id']), 'publisher personal account is actually deleted');
    check_wordpress_schema(get_post($media_id) instanceof WP_Post && is_file($uploaded_file),
        'published original survives publisher account deletion');
    check_wordpress_schema((int) get_post($media_id)->post_author === 0
        && (int) get_post($fixture_portfolio_id)->post_author === 0,
        'published image and album no longer reference deleted uploader');
    check_wordpress_schema(hash_file('sha256', $uploaded_file) === hash('sha256', $png_bytes)
        && is_file($upload_root . '/' . $metadata['sizes']['large']['file']),
        'retained original and display derivative remain unchanged');
    $retained = $dispatch_media_fixture($granting_manager, 'GET', '/shuzijun/v1/app-content');
    $retained_albums = array_values(array_filter($retained->get_data()['portfolios'],
        static fn($album) => $album['id'] === $fixture_portfolio_id));
    check_wordpress_schema(count($retained_albums) === 1 && count($retained_albums[0]['images']) === 1,
        'administrator still receives published gallery after uploader deletion');
} finally {
    remove_filter('rest_pre_dispatch', $media_gate, 10);
    remove_filter('wp_image_editors', $force_gd);
    // Keep upload mapping installed while WordPress removes original/subsizes.
    foreach ($fixture_media_ids as $fixture_media_id) { wp_delete_attachment($fixture_media_id, true); }
    if ($fixture_portfolio_id > 0) { wp_delete_post($fixture_portfolio_id, true); }
    remove_filter('upload_dir', $upload_location);
    unregister_post_type('portfolio');
    // Only direct files in the directory created by this fixture. Never follow
    // symlinks or recursively delete a WP content directory on failure.
    foreach (new DirectoryIterator($upload_root) as $entry) {
        if ($entry->isDot()) { continue; }
        if ($entry->isLink() || !$entry->isFile()) { throw new RuntimeException('Unexpected upload fixture entry'); }
        unlink($entry->getPathname());
    }
    rmdir($upload_root);
    wp_set_current_user(0);
}
check_wordpress_schema(!file_exists($upload_root), 'private synthetic upload directory removed');
fwrite(STDOUT, 'fan-administrator-media-wordpress: ' . ($checks - $media_before_checks)
    . " assertions passed; real core upload, metadata, publish and revoke; synthetic bytes only\n");
