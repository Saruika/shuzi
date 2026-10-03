<?php
/**
 * Authorized one-off CLI publication; dry-run by default, additive and backed up.
 * Applied to authority and standby on 2026-10-03 after both dry-runs passed.
 * Read-back: six dramas, new work first, other config sections unchanged.
 * Public cover: HTTP 200 image/webp, 48204 bytes, SHA256
 * 2eb398eb2034e4a0818b3f954a5f3843a3afdadda77cdcdd9ba6b0c544a35f92.
 * Source: actor 易姝, series 7688692316625718296, official share page.
 * Backups are retained on each node in shuzijun_drama_backup_20261003.
 * No push, account mutation, website-theme change or App release is included.
 */
if (!defined('WP_CLI') || !WP_CLI || !current_user_can('manage_options')) {
    throw new RuntimeException('Administrator WP-CLI required.');
}
$role = trim(file_get_contents(Shuzijun_App_Content_API::ACCOUNT_AUTHORITY_ROLE_PATH));
if (!in_array($role, array('authority', 'standby'), true) || $role !== ($args[1] ?? '')) {
    throw new RuntimeException('Node role mismatch.');
}
$acquire = new ReflectionMethod('Shuzijun_App_Content_API', 'acquire_editorial_publication_lock');
$acquire->setAccessible(true);
$lock = $acquire->invoke(null);
if (is_wp_error($lock)) { throw new RuntimeException($lock->get_error_code()); }
try {
    $key = Shuzijun_App_Content_API::OPTION_CONFIG;
    $before = get_option($key);
    $entry = array('id' => 'tuihun-jijia', 'title' => '退婚当天，我嫁季家掌权人',
        'imageURL' => 'https://img.shuzijun.com.cn/images/drama-tuihun-jijia-20261003.webp',
        'destinationURL' => 'https://novelquickapp.com/s/qcN1w-iokyY/');
    $expected = array('jingchunye', 'wangshengjiudian', 'nianxiadidi', 'xinhunye', 'ouyangxiu');
    if (!is_array($before) || !isset($before['dramas'])) { throw new RuntimeException('Missing config.'); }
    $old = $before['dramas'];
    $already = count($old) === 6 && $old[0] === $entry;
    if ($already) { array_shift($old); }
    if (array_column($old, 'id') !== $expected) { throw new RuntimeException('Catalog changed.'); }
    foreach ($old as $item) {
        if ($item['destinationURL'] !== $entry['destinationURL']) { throw new RuntimeException('Link changed.'); }
    }
    $cover = '/var/www/html/shuzijun.com.cn/wp-content/uploads/hero-images/drama-tuihun-jijia-20261003.webp';
    $size = is_file($cover) ? getimagesize($cover) : false;
    if (!$size || $size[0] < 300 || $size[1] < 400 || $size['mime'] !== 'image/webp') {
        throw new RuntimeException('Verified cover required before publication.');
    }
    $after = $before;
    $after['dramas'] = array_merge(array($entry), $old);
    $backup = 'shuzijun_drama_backup_20261003';
    $apply = ($args[0] ?? '') === 'apply';
    if ($apply && !$already) {
        if (!add_option($backup, array('config' => $before,
            'updated' => get_option(Shuzijun_App_Content_API::OPTION_UPDATED)), '', false)) {
            throw new RuntimeException('Backup exists; inspect before retry.');
        }
        if (get_option($key) !== $before) { throw new RuntimeException('Concurrent change.'); }
        if (!update_option($key, $after, false) || get_option($key) !== $after) {
            throw new RuntimeException('Write verification failed; inspect backup.');
        }
        update_option(Shuzijun_App_Content_API::OPTION_UPDATED, time(), false);
    }
    $other_before = $before; $other_after = $after;
    unset($other_before['dramas'], $other_after['dramas']);
    echo wp_json_encode(array('mode' => $apply ? 'apply' : 'dry-run', 'role' => $role,
        'alreadyApplied' => $already, 'titles' => array_column($after['dramas'], 'title'),
        'otherSectionsUnchanged' => $other_before === $other_after,
        'backupOption' => $backup, 'coverSHA256' => hash_file('sha256', $cover))) . PHP_EOL;
} finally {
    $release = new ReflectionMethod('Shuzijun_App_Content_API', 'release_named_fan_lock');
    $release->setAccessible(true);
    $release->invoke(null, $lock);
}
