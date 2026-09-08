<?php
/**
 * One-off, authenticated WP-CLI repair. Dry-run by default.
 * Run on the authority node with an existing content administrator --user.
 * Set SHUZI_APPLY_DRAMA_LINK=1 only after checking dry-run output.
 * On the fixed-host-key standby only, SHUZI_MIRROR_DRAMA_LINK=1 permits
 * this exact content repair under the same publication lock. It requires
 * a WordPress administrator and the root-owned standby role marker.
 * Does not install the pending plugin candidate or modify website content.
 */
if (!defined('WP_CLI') || !WP_CLI || !class_exists('Shuzijun_App_Content_API')) {
    throw new RuntimeException('Requires the loaded production plugin and WP-CLI.');
}
$request = new WP_REST_Request('POST', '/shuzijun/v1/app-content');
$mirror_lock = null;
if (getenv('SHUZI_MIRROR_DRAMA_LINK') === '1') {
    $role_path = Shuzijun_App_Content_API::ACCOUNT_AUTHORITY_ROLE_PATH;
    $stat = lstat($role_path);
    if (!current_user_can('manage_options') || !is_array($stat)
        || ($stat['mode'] & 0170000) !== 0100000 || $stat['uid'] !== 0
        || ($stat['mode'] & 0022) !== 0 || trim(file_get_contents($role_path)) !== 'standby') {
        throw new RuntimeException('Requires administrator CLI access on the standby node.');
    }
    $acquire = new ReflectionMethod('Shuzijun_App_Content_API', 'acquire_editorial_publication_lock');
    $acquire->setAccessible(true);
    $mirror_lock = $acquire->invoke(null);
    if (is_wp_error($mirror_lock)) { throw new RuntimeException($mirror_lock->get_error_code()); }
} else {
    $guard = Shuzijun_App_Content_API::guard_editorial_rest_write(null, array(), $request);
    if (is_wp_error($guard)) { throw new RuntimeException($guard->get_error_code()); }
}
try {
    $key = Shuzijun_App_Content_API::OPTION_CONFIG;
    $before = get_option($key, null);
    $old = 'https://novelquickapp.com/s/wHlfrwqog1g/';
    $new = 'https://novelquickapp.com/s/qcN1w-iokyY/';
    $expected = array('jingchunye', 'wangshengjiudian', 'nianxiadidi', 'xinhunye', 'ouyangxiu');
    if (!is_array($before) || !isset($before['dramas']) || count($before['dramas']) !== 5) {
        throw new RuntimeException('Unexpected current drama configuration.');
    }
    $after = $before;
    $seen = array();
    $changed = array();
    foreach ($after['dramas'] as &$drama) {
        $id = $drama['id'] ?? '';
        $url = $drama['destinationURL'] ?? '';
        if (!in_array($id, $expected, true) || isset($seen[$id]) || !in_array($url, array($old, $new), true)) {
            throw new RuntimeException('Unexpected drama ID or URL; refusing to overwrite editorial changes.');
        }
        $seen[$id] = true;
        if ($url === $old) {
            $drama['destinationURL'] = $new;
            $changed[] = $id;
        }
    }
    unset($drama);
    $apply = getenv('SHUZI_APPLY_DRAMA_LINK') === '1';
    $backup = 'shuzijun_drama_link_backup_20260908';
    if ($apply && $changed) {
        if (!add_option($backup, $before, '', false)) {
            throw new RuntimeException('Backup already exists; inspect before retrying.');
        }
        if (get_option($key) !== $before) {
            throw new RuntimeException('Configuration changed before write.');
        }
        if (!update_option($key, $after, false) || get_option($key) !== $after) {
            throw new RuntimeException('Write verification failed; inspect saved backup.');
        }
        update_option(Shuzijun_App_Content_API::OPTION_UPDATED, time(), false);
    }
    $other_before = $before;
    $other_after = $after;
    unset($other_before['dramas'], $other_after['dramas']);
    echo wp_json_encode(array(
        'mode' => $apply ? 'apply' : 'dry-run',
        'changedIDs' => $changed,
        'dramaCount' => count($seen),
        'destinationURL' => $new,
        'otherSectionsUnchanged' => $other_before === $other_after,
        'backupOption' => $apply && $changed ? $backup : null,
    ), JSON_UNESCAPED_SLASHES) . PHP_EOL;
} finally {
    if ($mirror_lock !== null) {
        $release = new ReflectionMethod('Shuzijun_App_Content_API', 'release_named_fan_lock');
        $release->setAccessible(true);
        $release->invoke(null, $mirror_lock);
    } else {
        Shuzijun_App_Content_API::release_editorial_rest_write(null, array(), $request);
    }
}
