<?php
declare(strict_types=1);

// Pure offline test adapter: stdin vectors only, no WordPress/database/network.
require dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-game-rules.php';
$rules = Shuzijun_Game_Rules::bundled();
$count = 0;
while (($line = fgets(STDIN, 8193)) !== false) {
    if (++$count > 10000 || strlen($line) > 8192) { throw new RuntimeException('fixture_limit'); }
    try {
        $value = json_decode($line, true, 16, JSON_THROW_ON_ERROR);
        $result = $rules->replay($value['origin'] ?? null, $value['choices'] ?? null);
        echo json_encode(array('ok' => true, 'result' => $result), JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
    } catch (InvalidArgumentException $error) {
        echo json_encode(array('ok' => false, 'error' => $error->getMessage()), JSON_THROW_ON_ERROR) . "\n";
    }
}
