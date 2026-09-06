<?php

require dirname(__DIR__) . '/collaboration-private-payload.php';

$assertions = 0;
function check_private_payload($condition, $label) {
    global $assertions;
    $assertions++;
    if (!$condition) { throw new RuntimeException($label); }
}
function refuses_private_payload($callback, $label) {
    try { $callback(); } catch (Throwable $error) { check_private_payload(true, $label); return; }
    check_private_payload(false, $label);
}

$key = random_bytes(32);
$cipher = new Shuzijun_Collaboration_Private_Payload($key, 'fixture-key');
$id = '11111111-2222-4333-8444-555555555555';
$other_id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
$canary = 'SYNTHETIC-' . bin2hex(random_bytes(12));
$payload = array(
    'contactName' => '合成联系人' . $canary,
    'contactMethod' => $canary . '@example.invalid',
    'organization' => '测试组织', 'projectType' => 'drama', 'city' => '合成城市',
    'preferredDate' => null, 'budget' => '测试预算', 'details' => "测试说明\n" . $canary,
);
$envelope = $cipher->seal($payload, 101, $id);
check_private_payload($cipher->open($envelope, 101, $id) === $payload, 'unicode multiline round trip');
check_private_payload(strpos($envelope, $canary) === false, 'no contact canary in envelope');
check_private_payload(strpos($envelope, $payload['contactName']) === false, 'no plaintext contact');
check_private_payload($cipher->open($envelope, 102, $id) === null, 'other owner rejected');
check_private_payload($cipher->open($envelope, 101, $other_id) === null, 'other request rejected');
check_private_payload($cipher->open($envelope, '101', $id) === null, 'ambiguous owner type rejected');
check_private_payload($cipher->open($envelope, 0, $id) === null, 'invalid owner rejected');
check_private_payload($cipher->open($envelope, 101, strtoupper($id . 'a')) === null, 'invalid request rejected');
$other_key = new Shuzijun_Collaboration_Private_Payload(random_bytes(32), 'fixture-key');
check_private_payload($other_key->open($envelope, 101, $id) === null, 'wrong key rejected');
$other_key_id = new Shuzijun_Collaboration_Private_Payload($key, 'different-key');
check_private_payload($other_key_id->open($envelope, 101, $id) === null, 'unknown key version rejected');
check_private_payload($other_key_id->open(str_replace('.fixture-key.', '.different-key.', $envelope), 101, $id) === null,
    'key identifier authenticated even when the same bytes were misconfigured');
check_private_payload($cipher->seal($payload, 101, $id) !== $envelope, 'fresh nonce for repeated content');
// Every byte of the ASCII envelope participates in parsing or authentication.
for ($i = 0; $i < strlen($envelope); $i++) {
    $modified = $envelope;
    $modified[$i] = $modified[$i] === 'A' ? 'B' : 'A';
    check_private_payload($cipher->open($modified, 101, $id) === null, 'modified envelope rejected');
}
foreach (array('', 'plaintext contact', json_encode($payload), str_repeat('A', 44001),
    $envelope . '.', substr($envelope, 0, -1), 'v2' . substr($envelope, 2)) as $invalid) {
    check_private_payload($cipher->open($invalid, 101, $id) === null, 'malformed or legacy data rejected');
}
foreach (array(array(), array_merge($payload, array('unknown' => 'value')),
    array_merge($payload, array('details' => str_repeat('x', 32769))),
    array_merge($payload, array('details' => array())),
    array_merge($payload, array('contactName' => null)),
    array_merge($payload, array('details' => "\xff"))) as $invalid) {
    refuses_private_payload(static fn() => $cipher->seal($invalid, 101, $id), 'invalid input rejected');
}
refuses_private_payload(static fn() => $cipher->seal($payload, -1, $id), 'invalid seal owner rejected');
refuses_private_payload(static fn() => new Shuzijun_Collaboration_Private_Payload(random_bytes(31), 'fixture'), 'short key rejected');
refuses_private_payload(static fn() => new Shuzijun_Collaboration_Private_Payload($key, 'bad.key'), 'key ID delimiter rejected');
refuses_private_payload(static fn() => serialize($cipher), 'key serialization rejected');
refuses_private_payload(static fn() => clone $cipher, 'key cloning rejected');
refuses_private_payload(static fn() => $cipher->__unserialize(array()), 'key unserialization rejected');
ob_start();
var_dump($cipher);
$debug = ob_get_clean();
check_private_payload(strpos($debug, $key) === false && strpos($debug, '[redacted]') !== false, 'ordinary debug rendering redacts key');
sodium_memzero($key);
echo 'collaboration-private-payload: ' . $assertions . " assertions passed; no real contacts or keys used\n";
