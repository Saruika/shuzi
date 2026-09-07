<?php
declare(strict_types=1);

// Deterministic contention using two real MySQL connections. This is included
// only by the private random-DB/synthetic-upload fixture, never a live route.
if (!isset($database, $socket, $publisher, $dispatch_media_fixture, $png_bytes)
    || !defined('DB_NAME') || DB_NAME !== $database
    || !str_starts_with($database, 'yishu_wp_schema_test_')
    || $wpdb->get_var('SELECT DATABASE()') !== $database) {
    throw new RuntimeException('Isolated editorial fixture required');
}
$concurrency_before = $checks;
$concurrent_connection = new PDO('mysql:unix_socket=' . $socket . ';dbname=' . $database, 'root', '',
    array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
$publication_lock_name = 'yishu_editorial_' . substr(hash('sha256', home_url('/') . '|publication-and-account-deletion-v1'), 0, 44);
$publisher_lock_name = 'yishu_fan_' . substr(hash('sha256', home_url('/') . '|' . $publisher['id']), 0, 48);
$external_lock = static function (string $name, string $operation) use ($concurrent_connection): int {
    if (!in_array($operation, array('GET_LOCK', 'RELEASE_LOCK', 'IS_FREE_LOCK'), true)) {
        throw new RuntimeException('Unknown fixture lock operation');
    }
    return (int) $concurrent_connection->query('SELECT ' . $operation . '(' . $concurrent_connection->quote($name)
        . ($operation === 'GET_LOCK' ? ', 0' : '') . ')')->fetchColumn();
};
$before_concurrent_uploads = $attachment_count();
$before_concurrent_posts = (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts}");
$before_concurrent_files = scandir($upload_root);
$before_concurrent_config = get_option(Shuzijun_App_Content_API::OPTION_CONFIG, array());
check_wordpress_schema($external_lock($publication_lock_name, 'GET_LOCK') === 1, 'second MySQL connection owns publication lock');
try {
    foreach (array(
        array('/wp/v2/media', array(), $png_bytes),
        array('/shuzijun/v1/app-content/portfolio', array('title' => 'Must wait for deletion'), null),
        array('/shuzijun/v1/app-content/portfolio/1/gallery', array('mediaIDs' => array()), null),
        array('/shuzijun/v1/app-content', array('heroImages' => array()), null),
    ) as [$route, $payload, $bytes]) {
        $blocked_write = $dispatch_media_fixture($publisher, 'POST', $route, $payload, $bytes);
        check_wordpress_schema($blocked_write->get_status() === 409, 'contending editorial REST mutation is retriable: ' . $route);
    }
    $blocked_delete = $dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/fan/delete', array(
        'installID' => $publisher['install'], 'currentPassword' => $publisher['password'], 'confirmation' => 'DELETE_ACCOUNT'));
    check_wordpress_schema($blocked_delete->get_status() === 503 && get_userdata($publisher['id']) instanceof WP_User,
        'delete cannot run while another writer owns publication lock');
    check_wordpress_schema($dispatch_media_fixture($publisher, 'GET', '/shuzijun/v1/app-content')->get_status() === 200,
        'ordinary reading continues while publication is locked');
} finally {
    $external_lock($publication_lock_name, 'RELEASE_LOCK');
}
check_wordpress_schema($attachment_count() === $before_concurrent_uploads
    && (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts}") === $before_concurrent_posts
    && scandir($upload_root) === $before_concurrent_files
    && get_option(Shuzijun_App_Content_API::OPTION_CONFIG, array()) === $before_concurrent_config,
    'contending requests create no files, posts or configuration changes');
check_wordpress_schema($external_lock($publisher_lock_name, 'GET_LOCK') === 1, 'second connection owns actor lock');
try {
    check_wordpress_schema($dispatch_media_fixture($publisher, 'POST', '/wp/v2/media', array(), $png_bytes)->get_status() === 409,
        'actor revoke/delete lock also excludes uploader');
    check_wordpress_schema($external_lock($publication_lock_name, 'IS_FREE_LOCK') === 1,
        'failed actor-lock acquisition releases publication lock');
} finally {
    $external_lock($publisher_lock_name, 'RELEASE_LOCK');
}

// Change role through the second SQL connection after initial authentication,
// deliberately leaving the first connection's WP caches stale. The write guard
// must reload roles after locking, not trust the earlier successful check.
$capability_key = $wpdb->prefix . 'capabilities';
$capability_rows = $wpdb->get_results($wpdb->prepare(
    "SELECT umeta_id, meta_value FROM {$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s",
    $publisher['id'], $capability_key));
check_wordpress_schema(count($capability_rows) === 1, 'exact synthetic publisher capability row');
$capability_row = $capability_rows[0];
$revoke_at_lock = false;
$revoke_after_auth = static function ($query) use (&$revoke_at_lock, $publication_lock_name, $concurrent_connection, $capability_row, $wpdb) {
    if (!$revoke_at_lock && str_contains($query, 'GET_LOCK') && str_contains($query, $publication_lock_name)) {
        $revoke_at_lock = true;
        $update = $concurrent_connection->prepare("UPDATE {$wpdb->usermeta} SET meta_value = ? WHERE umeta_id = ?");
        $update->execute(array(serialize(array('subscriber' => true)), (int) $capability_row->umeta_id));
    }
    return $query;
};
add_filter('query', $revoke_after_auth);
try {
    $stale_upload = $dispatch_media_fixture($publisher, 'POST', '/wp/v2/media', array(), $png_bytes);
    check_wordpress_schema($revoke_at_lock && $stale_upload->get_status() === 403,
        'role removed after first authentication cannot use stale permission to upload');
} finally {
    remove_filter('query', $revoke_after_auth);
    $restore = $concurrent_connection->prepare("UPDATE {$wpdb->usermeta} SET meta_value = ? WHERE umeta_id = ?");
    $restore->execute(array($capability_row->meta_value, (int) $capability_row->umeta_id));
    clean_user_cache($publisher['id']);
    wp_set_current_user(0);
}
check_wordpress_schema($external_lock($publication_lock_name, 'IS_FREE_LOCK') === 1
    && $external_lock($publisher_lock_name, 'IS_FREE_LOCK') === 1, 'permission failure releases both locks');
check_wordpress_schema($attachment_count() === $before_concurrent_uploads && scandir($upload_root) === $before_concurrent_files,
    'stale-authorized upload creates no original or attachment');

// Session options have a separate cache from WP_User. Remove the token through
// another SQL connection between authentication and locking to prove that
// clearing only the static context/user cache is not enough.
$session_option = Shuzijun_App_Content_API::FAN_SESSION_OPTION_PREFIX . hash('sha256', $publisher['token']);
$session_row = $wpdb->get_row($wpdb->prepare("SELECT * FROM {$wpdb->options} WHERE option_name = %s", $session_option), ARRAY_A);
check_wordpress_schema(is_array($session_row), 'exact disposable bearer option exists');
$removed_at_lock = false;
$remove_session_after_auth = static function ($query) use (&$removed_at_lock, $publication_lock_name, $session_option, $concurrent_connection, $wpdb) {
    if (!$removed_at_lock && str_contains($query, 'GET_LOCK') && str_contains($query, $publication_lock_name)) {
        $removed_at_lock = true;
        $delete = $concurrent_connection->prepare("DELETE FROM {$wpdb->options} WHERE option_name = ?");
        $delete->execute(array($session_option));
    }
    return $query;
};
add_filter('query', $remove_session_after_auth);
try {
    $stale_session_upload = $dispatch_media_fixture($publisher, 'POST', '/wp/v2/media', array(), $png_bytes);
    check_wordpress_schema($removed_at_lock && $stale_session_upload->get_status() === 403 && get_current_user_id() === 0,
        'token removed after first authentication cannot upload through stale options cache');
} finally {
    remove_filter('query', $remove_session_after_auth);
    $restore_session = $concurrent_connection->prepare("INSERT INTO {$wpdb->options} (option_id, option_name, option_value, autoload) VALUES (?, ?, ?, ?)");
    $restore_session->execute(array($session_row['option_id'], $session_row['option_name'], $session_row['option_value'], $session_row['autoload']));
    wp_cache_delete($session_option, 'options');
}
check_wordpress_schema($external_lock($publication_lock_name, 'IS_FREE_LOCK') === 1
    && $external_lock($publisher_lock_name, 'IS_FREE_LOCK') === 1
    && $attachment_count() === $before_concurrent_uploads, 'stale token rejection leaves no upload or lock');
$invalid_write = $dispatch_media_fixture($publisher, 'POST', '/shuzijun/v1/app-content/portfolio', array('title' => ''));
check_wordpress_schema($invalid_write->get_status() === 400
    && $external_lock($publication_lock_name, 'IS_FREE_LOCK') === 1, 'invalid payload releases write lock for retry');

// Observe the following real core upload inside its insert callback, before
// the REST completion filter is allowed to release either lock.
$observed_upload_lock = 0;
$observe_actual_upload = static function ($id) use (&$observed_upload_lock, $external_lock, $publication_lock_name, $publisher_lock_name) {
    check_wordpress_schema($external_lock($publication_lock_name, 'GET_LOCK') === 0
        && $external_lock($publisher_lock_name, 'GET_LOCK') === 0,
        'independent connection cannot acquire either lock inside real upload');
    $observed_upload_lock++;
};
add_action('add_attachment', $observe_actual_upload);
fwrite(STDOUT, 'editorial-concurrency-wordpress: ' . ($checks - $concurrency_before)
    . " assertions passed; separate MySQL connections; real REST denial/retry; no live data\n");
