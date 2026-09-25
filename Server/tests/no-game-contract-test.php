<?php
declare(strict_types=1);
// The main plugin contract independently executes route/hook registration.
// This release check prevents retired code/data from remaining distributable.
$root = dirname(__DIR__);
$checks = 0;
function no_game_check(bool $ok, string $label): void {
    if (!$ok) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
foreach (array('trait-shuzijun-app-game-leaderboard.php', 'class-shuzijun-game-rules.php', 'game-rules-v1.json') as $name) {
    no_game_check(!file_exists($root . '/vendor/shuzijun/app-content/' . $name), 'retired runtime asset: ' . $name);
}
foreach (glob($root . '/vendor/shuzijun/app-content/*.php') as $path) {
    $source = file_get_contents($path);
    no_game_check(!preg_match('/Shuzijun_(?:App_Game|Game_Rules)|\/fan\/game\/|GAME_SCHEMA|purge_game_leaderboard|yishu_install_game/', $source), 'no game runtime in ' . basename($path));
}
foreach (array('install-game-leaderboard-schema.php', 'test-review-game-leaderboard.php',
    'protect-game-rules-json.py', 'upgrade-review-game-plugin.py', 'update-game-privacy-policy.php') as $name) {
    no_game_check(!file_exists($root . '/operations/' . $name), 'retired installer: ' . $name);
}
$cleanup = file_get_contents($root . '/operations/decommission-game.php');
no_game_check(str_contains($cleanup, "'when' => 'before_wp_load'") && !str_contains($cleanup, "require 'wp-load.php'"), 'cleanup runs before WP bootstrap');
no_game_check(str_contains($cleanup, "retire_require(\$meta === '0'"), 'unknown meta fails closed');
no_game_check(!preg_match('/DELETE\s+FROM\s+.*(?:users|usermeta)|TRUNCATE|wp_delete_user|flush_cache|wp_cache_flush/i', $cleanup), 'no account or broad cache deletion');
no_game_check(str_contains($cleanup, 'retire_backup') && str_contains($cleanup, 'fsync('), 'durable backup boundary');
echo 'no-game-contract-test: ' . $checks . " checks passed\n";
