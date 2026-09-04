import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / "shuzijun-app-content.php"
CORE = ROOT / "vendor/shuzijun/app-content/class-shuzijun-app-content-api.php"
FAN = ROOT / "vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php"
PUSH = ROOT / "vendor/shuzijun/app-content/trait-shuzijun-app-push-notifications.php"
IDENTITY = ROOT / "vendor/shuzijun/app-content/trait-shuzijun-app-fan-identity.php"
DELIVERY = ROOT / "vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php"
RELEASE = ROOT / "releases/v1.3.33-build45.1.md"
IOS_PUSH = ROOT.parent / "Yishu/Services/PushNotificationService.swift"


def section(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin + len(start))
    return source[begin:finish]


def main() -> None:
    entry = ENTRY.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")
    fan = FAN.read_text(encoding="utf-8")
    push = PUSH.read_text(encoding="utf-8")
    identity = IDENTITY.read_text(encoding="utf-8")
    delivery = DELIVERY.read_text(encoding="utf-8")
    release = RELEASE.read_text(encoding="utf-8")
    ios_push = IOS_PUSH.read_text(encoding="utf-8")
    combined = "\n".join((core, fan, push, identity, delivery))

    assert "Version: 1.5.12.1" in entry
    assert "v1.3.33-build45" in release
    assert "推送 Worker 尚未启用" in release
    for variable in (
        "YISHU_APNS_KEY_ID",
        "YISHU_APNS_TEAM_ID",
        "YISHU_APNS_PRIVATE_KEY_PATH",
        "YISHU_APNS_DATA_KEY_PATH",
    ):
        assert variable in release

    # Server 1.5.12.1 is an explicit source-level bridge: Build 42 submits v3,
    # Build 45 submits v4, and no option/filter can broaden the exact pair.
    assert "FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS" in core
    bridge_versions = section(
        core,
        "const FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS",
        "const FAN_ACCEPTED_LEGACY_CONSENT_VERSIONS",
    )
    assert bridge_versions.count("'2026-09-02-approval-v3'") == 1
    assert bridge_versions.count("'2026-09-04-approval-v4'") == 1
    assert "approval-v2" not in bridge_versions
    consent_bridge = section(
        core,
        "public static function fan_new_consent_version_is_accepted",
        "public static function fan_stored_consent_is_accepted",
    )
    assert "FAN_ACCEPTED_TRANSITIONAL_NEW_CONSENT_VERSIONS" in consent_bridge
    assert "in_array(" in consent_bridge and "true" in consent_bridge
    assert "get_option(" not in consent_bridge
    assert "apply_filters(" not in consent_bridge
    assert "defined(" not in consent_bridge
    assert "server 1.5.13" in core

    # The reviewed release bundle has five traits plus its core class. Push
    # delivery is isolated from the fan-account endpoints without changing
    # runtime behavior.
    assert core.count("require_once __DIR__ . '/trait-") == 5
    assert core.count("    use Shuzijun_App_") == 5
    assert "trait-shuzijun-app-push-notifications.php" in core
    assert "trait Shuzijun_App_Push_Notifications" in push

    # Both surfaces have explicit, independent authentication boundaries.
    assert "'/fan/push-device'" in core
    assert "'callback' => array(__CLASS__, 'register_fan_push_device')" in core
    assert "'callback' => array(__CLASS__, 'unregister_fan_push_device')" in core
    assert core.count(
        "'permission_callback' => array(__CLASS__, 'can_access_normal_fan_session')"
    ) >= 5
    assert "'/app-admin/push-notifications'" in core
    assert "'permission_callback' => array(__CLASS__, 'can_manage_push')" in core
    assert "const PUSH_CAPABILITY = 'manage_yishu_push_notifications';" in core
    assert "const PUSH_SCHEMA_VERSION = 3;" in core
    assert "is_sensitive tinyint(1) unsigned NOT NULL DEFAULT 1" in push
    assert re.search(r"(?m)^\s*sensitive\s+tinyint", push) is None
    assert core.count("$role->add_cap(self::PUSH_CAPABILITY, true)") == 1
    assert core.count("$administrator->add_cap(self::PUSH_CAPABILITY, true)") == 1
    assert "user_can($user, self::PUSH_CAPABILITY)" in core
    assert "'push_capability_required'" in core
    assert "'pushNotificationsEnabled'" in core
    assert "'canSendPushNotifications'" in core

    # Schema v3 makes installation ownership and binding order durable across
    # PHP workers, hosts and cache loss. Both device and outbox rows carry the
    # exact generation they were created for, while the notification stores one
    # immutable absolute APNs deadline.
    storage = section(
        push,
        "public static function ensure_push_storage",
        "private static function push_table_names",
    )
    assert "'version-3'" in storage
    assert "migrate_push_notification_sensitivity_column" in storage
    assert "schema_migration_failed" in storage
    assert "schema_delta_failed" in storage
    assert "SHOW TABLE STATUS LIKE %s" in push
    assert "'InnoDB'" in push
    assert "['Sub_part']" in push
    devices_schema = section(storage, '$devices_sql = "CREATE TABLE', '$notifications_sql =')
    notifications_schema = section(
        storage,
        '$notifications_sql = "CREATE TABLE',
        '$outbox_sql = "CREATE TABLE',
    )
    outbox_schema = section(storage, '$outbox_sql = "CREATE TABLE', '$recipients_sql =')
    install_states_schema = section(
        storage,
        '$install_states_sql = "CREATE TABLE',
        "foreach (array(",
    )
    assert "'push_schema', 'version-3'" in storage
    assert "session_option_id bigint(20) unsigned NOT NULL" in devices_schema
    assert "binding_generation bigint(20) unsigned NOT NULL" in devices_schema
    assert "deliver_before bigint(20) unsigned NOT NULL" in notifications_schema
    assert "install_hash char(64) NOT NULL" in outbox_schema
    assert "binding_generation bigint(20) unsigned NOT NULL" in outbox_schema
    for column in (
        "install_hash char(64) NOT NULL",
        "fan_user_id bigint(20) unsigned NOT NULL",
        "session_option_id bigint(20) unsigned NOT NULL",
        "binding_generation bigint(20) unsigned NOT NULL DEFAULT 0",
        "desired_state varchar(12) NOT NULL DEFAULT 'unbound'",
        "session_expires_at datetime NOT NULL",
        "PRIMARY KEY  (install_hash)",
    ):
        assert column in install_states_schema
    delta_order = section(storage, "foreach (array(", ") as $schema_sql")
    assert delta_order.index("$install_states_sql") < delta_order.index("$devices_sql")
    table_names = section(push, "private static function push_table_names", "private static function push_tables_exist")
    assert "'install_states' => $wpdb->prefix . 'yishu_push_install_states'" in table_names
    schema_match = section(push, "private static function push_schema_matches", "private static function push_storage_ready")
    assert "'install_states' => array(" in schema_match
    assert "'binding_generation', 'desired_state', 'session_expires_at'" in schema_match
    assert "'deliver_before'" in schema_match
    assert "'outbox' => array(" in schema_match
    assert "'fan_user_id', 'install_hash', 'token_hash'" in schema_match
    assert "'binding_generation'" in schema_match
    assert "'PRIMARY' => array('install_hash')" in schema_match

    # Apple says the binary token is opaque and its size must not be assumed.
    validator = section(
        push,
        "private static function valid_push_device_token",
        "public static function register_fan_push_device",
    )
    assert "strlen($device_token) >= 2" in validator
    assert "strlen($device_token) <= 512" in validator
    assert "strlen($device_token) % 2 === 0" in validator
    assert "preg_match('/^[a-f0-9]+$/D'" in validator
    assert "{64}" not in validator

    # A global installation/token binding prevents account-switch residue.
    assert "UNIQUE KEY token_hash (token_hash)" in push
    assert "UNIQUE KEY install_hash (install_hash)" in push
    register = section(
        push,
        "public static function register_fan_push_device",
        "public static function unregister_fan_push_device",
    )
    assert "START TRANSACTION" in register and "COMMIT" in register and "ROLLBACK" in register
    assert "WHERE token_hash = %s OR install_hash = %s" in register
    assert "token_ciphertext" in register and "deviceToken'" in register
    assert "do_action(" not in register

    # Per-user locks do not serialize account A and account B on the same App
    # installation. Both register and unbind therefore take the same global
    # install lock before the fan lock, then lock the persistent owner row.
    assert "acquire_named_fan_lock_with_timeout(" in register
    assert "'push_install'" in register
    assert register.index("'push_install'") < register.index("acquire_fan_lock($user_id)")
    assert "fan_session_context_is_current_from_database($context, 'normal', true)" in register
    assert "FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE" in register
    assert "(int) ($state['fan_user_id'] ?? 0) !== $user_id" in register
    assert "(int) ($state['session_option_id'] ?? 0) !== $option_id" in register
    assert "strtotime((string) ($state['session_expires_at'] ?? '') . ' UTC') <= time()" in register
    assert "push_install_session_superseded" in register
    assert "normalize_push_binding_generation(" in register
    assert "$request->get_param('bindingGeneration')" in register
    assert "push_binding_transition(" in register
    assert "if ($transition === 'stale')" in register
    assert "push_binding_superseded" in register
    assert "$transition === 'conflict' || $transition === 'invalid'" in register
    idempotent_register = section(
        register,
        "if ($transition === 'idempotent')",
        "$cancelled = $wpdb->query",
    )
    assert "session_option_id = %d AND binding_generation = %d" in idempotent_register
    assert "AND token_hash = %s" in idempotent_register
    assert "push_binding_conflict" in idempotent_register
    register_apply = register[register.index("$cancelled = $wpdb->query") :]
    assert "last_error_code = 'binding_replaced'" in register_apply
    assert "WHERE install_hash = %s AND status IN ('pending', 'processing')" in register_apply
    assert "'binding_generation' => $generation" in register_apply
    assert "SET binding_generation = %d, desired_state = 'bound'" in register_apply
    assert "release_named_fan_lock($install_lock)" in register

    # Existing normal sessions predate the schema-v2 install-state row. Their
    # first bind is migrated under the same install->fan lock and transaction,
    # rather than being rejected simply because the new authority row is absent.
    assert register.index(
        "fan_session_context_is_current_from_database($context, 'normal', true)"
    ) < register.index("initialize_legacy_push_install_state(")
    assert register.index("initialize_legacy_push_install_state(") < register.rindex(
        "FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE"
    )

    # Unregister applies a mutation only for a newer generation. A lower request
    # is a successful no-op, while reusing the current generation for the
    # opposite action is a conflict.
    unregister = section(
        push,
        "public static function unregister_fan_push_device",
        "private static function remove_push_device_for_install_hash",
    )
    assert "($context['scope'] ?? '') !== 'normal'" in unregister
    assert "matching_request_install_id($request)" in unregister
    assert "fan_session_context_is_current_from_database($context, 'normal', true)" in unregister
    assert "array('ok' => true)" in unregister
    assert "acquire_named_fan_lock_with_timeout(" in unregister
    assert "'push_install'" in unregister
    assert unregister.index("'push_install'") < unregister.index("acquire_fan_lock($user_id)")
    assert "FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE" in unregister
    assert "push_binding_transition(" in unregister
    assert "$transition === 'conflict' || $transition === 'invalid'" in unregister
    unregister_apply = section(
        unregister,
        "if ($transition === 'apply')",
        "// A lower generation",
    )
    assert "last_error_code = 'binding_revoked'" in unregister_apply
    assert "WHERE install_hash = %s AND status IN ('pending', 'processing')" in unregister_apply
    assert "DELETE FROM {$tables['devices']}" in unregister_apply
    assert "SET binding_generation = %d, desired_state = 'unbound'" in unregister_apply
    assert "if ($transition === 'stale')" not in unregister
    assert "remove_push_device_for_install_hash" not in unregister
    assert "release_named_fan_lock($install_lock)" in unregister
    assert unregister.index(
        "fan_session_context_is_current_from_database($context, 'normal', true)"
    ) < unregister.index("initialize_legacy_push_install_state(")
    assert "get_error_code() !== 'push_install_session_superseded'" in unregister

    # Lazy migration trusts a freshly locked, exact wp_options row and scans
    # every later session by monotonic option_id. It never pattern-matches a
    # serialized value. Any incomplete scan/DB ambiguity fails closed, and a
    # higher current same-install session (including another account) wins.
    legacy_decoder = section(
        push,
        "private static function legacy_push_session_option_context",
        "private static function legacy_push_session_candidate_context",
    )
    legacy_migration = section(
        push,
        "private static function initialize_legacy_push_install_state",
        "private static function advance_push_install_ownership_for_session",
    )
    assert "@unserialize($serialized, array('allowed_classes' => false))" in legacy_decoder
    assert "(!is_scalar($value) && $value !== null)" in legacy_decoder
    assert "strlen($serialized) > 8192" in legacy_decoder
    assert "maybe_unserialize(" not in legacy_decoder
    for required in (
        "WHERE option_id = %d AND option_name = %s LIMIT 1 FOR UPDATE",
        "legacy_push_session_option_context(",
        "fan_session_context_is_current_from_database(",
        "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE",
        "WHERE option_id > %d AND option_name LIKE %s",
        "ORDER BY option_id ASC LIMIT %d FOR UPDATE",
        "PUSH_LEGACY_SESSION_PAGE_SIZE",
        "PUSH_LEGACY_SESSION_SCAN_LIMIT",
        "legacy_push_session_candidate_context(",
        "FAN_META_CREDENTIAL_EPOCH",
        "INSERT IGNORE INTO {$tables['install_states']}",
        "FROM {$tables['install_states']}",
        "WHERE install_hash = %s FOR UPDATE",
        "gmdate('Y-m-d H:i:s', (int) $fresh_context['expires'])",
        "if ($owner_option_id > $option_id)",
        "if ($owner_option_id === $option_id && $owner_user_id !== $user_id)",
        "return self::push_storage_error();",
    ):
        assert required in legacy_migration
    assert "option_value LIKE" not in legacy_migration
    assert "ORDER BY option_id DESC" not in legacy_migration
    assert "maybe_unserialize(" not in legacy_migration
    assert legacy_migration.count("return self::push_storage_error();") >= 10

    transition = section(
        push,
        "private static function push_binding_transition",
        "private static function advance_push_install_ownership_for_session",
    )
    assert "if ($generation < $current_generation) { return 'stale'; }" in transition
    assert "hash_equals($current_state, $action) ? 'idempotent' : 'conflict'" in transition
    assert "return 'apply';" in transition

    # Session creation advances persistent installation ownership before the
    # credential is returned. A newer wp_options row cancels the old generation,
    # removes its device, and leaves an unbound tombstone for the new session.
    session_creation = section(
        identity,
        "private static function issue_fan_session",
        "private static function authenticate_fan_session",
    )
    assert session_creation.index("add_option(") < session_creation.index(
        "advance_push_install_ownership_for_session($context)"
    )
    assert session_creation.index("advance_push_install_ownership_for_session($context)") < session_creation.index(
        "$context['token'] = $token"
    )
    assert "self::revoke_fan_session((int) $user_id, $token_hash)" in session_creation
    ownership = section(
        push,
        "private static function advance_push_install_ownership_for_session",
        "private static function tombstone_push_install_session",
    )
    assert "self::ensure_push_storage()" in ownership
    assert "INSERT IGNORE INTO {$tables['install_states']}" in ownership
    assert "VALUES (%s, %d, %d, 0, 'unbound'" in ownership
    assert "FROM {$tables['install_states']} WHERE install_hash = %s FOR UPDATE" in ownership
    assert "if ($current_option_id > $option_id) { return false; }" in ownership
    assert "if ($current_option_id < $option_id || $created === 1)" in ownership
    assert "last_error_code = 'binding_superseded'" in ownership
    assert "WHERE install_hash = %s AND status IN ('pending', 'processing')" in ownership
    assert "DELETE FROM {$tables['devices']} WHERE install_hash = %s" in ownership
    assert "SET fan_user_id = %d, session_option_id = %d" in ownership
    assert "desired_state = 'unbound', session_expires_at = %s" in ownership
    assert "START TRANSACTION" in ownership and "COMMIT" in ownership and "ROLLBACK" in ownership
    tombstone = section(
        push,
        "private static function tombstone_push_install_session",
        "private static function remove_all_fan_push_devices",
    )
    assert "FROM {$tables['install_states']}" in tombstone and "FOR UPDATE" in tombstone
    assert "WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d" in tombstone
    assert "DELETE FROM {$tables['devices']}" in tombstone
    assert "AND binding_generation = %d" in tombstone
    assert "SET desired_state = 'unbound'" in tombstone

    # The local half of the same boundary stops APNs registration immediately
    # on account transitions/opt-out, while an explicit re-enable can register
    # again after the account-scoped preference has been restored.
    account_transition = section(
        ios_push,
        "func accountContextDidChange",
        "func forgetSessionBinding",
    )
    preference_change = section(
        ios_push,
        "func setNotificationsEnabled",
        "private func bindIfPossible",
    )
    synchronization = section(
        ios_push,
        "func synchronize",
        "func requestAuthorizationAfterRationale",
    )
    assert "UIApplication.shared.unregisterForRemoteNotifications()" in account_transition
    assert "await stopDeliveryLocally(unbindingFrom: account)" in preference_change
    assert "if enabled" in preference_change and "await synchronize(with: account)" in preference_change
    assert "UIApplication.shared.registerForRemoteNotifications()" in synchronization

    # Plain tokens cannot be persisted: authenticated ciphertext and a keyed
    # index are independently derived from an out-of-webroot server data key.
    crypto = section(
        push,
        "private static function push_read_secure_file",
        "public static function register_fan_push_device",
    )
    for required in (
        "YISHU_APNS_DATA_KEY_PATH",
        "sodium_crypto_secretbox(",
        "sodium_crypto_secretbox_open(",
        "hash_hmac('sha256', $device_token, $keys['index'])",
        "hash_equals($expected_hash, $actual_hash)",
        "strpos($path, $root . DIRECTORY_SEPARATOR) === 0",
        "($opened['mode'] & 077) !== 0",
    ):
        assert required in crypto
    fingerprint = section(
        push,
        "private static function push_device_key_fingerprint",
        "private static function encrypt_push_device_token",
    )
    encryption = section(
        push,
        "private static function encrypt_push_device_token",
        "private static function decrypt_push_device_token",
    )
    decryption = section(
        push,
        "private static function decrypt_push_device_token",
        "private static function valid_push_device_token",
    )
    assert "yishu/apns-device-key-fingerprint/v1" in fingerprint
    assert "'keyFingerprint' => $key_fingerprint" in encryption
    assert "strlen($result['ciphertext']) > 1024" in encryption
    assert decryption.index("self::push_device_keys()") < decryption.index(
        "!is_string($encoded)"
    )
    assert "is_wp_error($keys)) { return self::push_device_crypto_error(); }" in decryption
    assert "$record['keyFingerprint'] ?? null" in decryption
    assert "hash_equals($stored_fingerprint, $active_fingerprint)" in decryption
    assert decryption.count("return self::push_device_crypto_error();") >= 4
    assert "sodium_memzero($keys['encryption'])" in decryption
    assert "sodium_memzero($keys['index'])" in decryption
    assert "return '';" in decryption
    devices_schema = section(push, '$devices_sql = "CREATE TABLE', '$notifications_sql =')
    assert "device_token" not in devices_schema
    assert "token_ciphertext text NOT NULL" in devices_schema

    # Provider authentication is production-only, topic-bound and sourced only
    # from environment/private files. The reusable JWT is encrypted at rest.
    provider = section(
        delivery,
        "private static function apns_provider_configuration",
        "private static function base64url_encode",
    )
    for required in (
        "getenv('YISHU_APNS_KEY_ID')",
        "getenv('YISHU_APNS_TEAM_ID')",
        "YISHU_APNS_PRIVATE_KEY_PATH",
        "openssl_pkey_get_private($private_key)",
        "openssl_pkey_get_details($handle)",
        "OPENSSL_KEYTYPE_EC",
        "($details['bits'] ?? 0) !== 256",
        "$details['ec']['curve_name']",
        "array('prime256v1', 'secp256r1')",
        "'alg' => 'ES256'",
        "OPENSSL_ALGO_SHA256",
        "get_transient(",
        "set_transient(",
        "encrypt_apns_provider_token_cache",
        "SODIUM_CRYPTO_SECRETBOX_KEYBYTES",
        "time() + 3000",
    ):
        assert required in provider
    assert "api.sandbox.push.apple.com" not in combined
    assert "const PUSH_PRODUCTION_HOST = 'https://api.push.apple.com';" in core
    assert "const PUSH_TOPIC = 'cn.com.shuzijun.yishu';" in core
    assert "const PUSH_APNS_EXPIRATION_SECONDS = 86400;" in core
    creator = section(
        push,
        "public static function create_targeted_push_notification",
        "private static function targeted_push_response",
    )
    assert "$created_at = time();" in creator
    assert "$deliver_before = $created_at + self::PUSH_APNS_EXPIRATION_SECONDS;" in creator
    assert "'deliver_before' => $deliver_before" in creator
    assert "get_param('expiration')" not in creator
    sender = section(
        delivery,
        "private static function send_push_to_apns",
        "private static function clear_apns_provider_token_cache",
    )
    assert "$notification['deliver_before']" in sender
    assert "preg_match('/^[1-9][0-9]{0,9}$/D', $deliver_before)" in sender
    assert "$apns_expiration = (int) $deliver_before;" in sender
    assert "$apns_expiration <= time()" in sender
    assert "time() + self::PUSH_APNS_EXPIRATION_SECONDS" not in sender
    assert "'apns-topic: ' . self::PUSH_TOPIC" in sender
    assert "'apns-expiration: ' . (string) $apns_expiration" in sender
    assert "'apns-expiration: 0'" not in sender
    assert "CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2TLS" in sender

    # Recipient IDs are canonicalized numerically before deterministic fan-lock
    # acquisition. Eligibility is then read again from locked database rows
    # before any notification, recipient or outbox record is inserted.
    target_sanitizer = section(
        push,
        "private static function sanitize_targeted_push_request",
        "private static function normalize_push_text",
    )
    assert "sort($user_ids, SORT_NUMERIC);" in target_sanitizer
    # The selector map must survive normalization and reach the locked
    # revalidation phase; seeing it only in the canonical hash is insufficient.
    target_return = target_sanitizer[target_sanitizer.rindex("return array(") :]
    assert "'userIDs' => $user_ids" in target_return
    assert "'selectors' => $selectors" in target_return
    first_target_loop = creator.index("foreach ($input['userIDs'] as $target_user_id)")
    transaction_start = creator.index("$wpdb->query('START TRANSACTION')")
    install_state_lock = creator.index(
        "SELECT install_hash FROM {$tables['install_states']}", transaction_start
    )
    locked_user_read = creator.index("SELECT ID FROM {$wpdb->users}", transaction_start)
    idempotency_read = creator.index("FROM {$tables['notifications']}", locked_user_read)
    assert first_target_loop < transaction_start < install_state_lock < locked_user_read < idempotency_read
    assert "ORDER BY install_hash ASC FOR UPDATE" in creator[install_state_lock:locked_user_read]
    assert "acquire_fan_lock($target_user_id)" in creator[first_target_loop:transaction_start]
    assert "LIMIT 1 FOR UPDATE" in creator[locked_user_read:idempotency_read]
    locked_revalidation = creator[locked_user_read:idempotency_read]
    assert locked_revalidation.count("fan_meta_from_database(") >= 2
    assert locked_revalidation.count("true") >= 2
    assert "$selector_matches" in locked_revalidation
    assert "array_reverse($fan_locks, true)" in creator
    device_snapshot = section(
        creator,
        "$devices = $wpdb->get_results",
        "if (!is_array($devices)",
    )
    assert "INNER JOIN {$tables['install_states']} s" in device_snapshot
    assert "s.binding_generation = d.binding_generation" in device_snapshot
    assert "s.desired_state = 'bound'" in device_snapshot
    assert "s.session_expires_at > %s" in device_snapshot
    assert "FOR UPDATE" in device_snapshot
    assert "'binding_generation' => $binding_generation" in creator

    # Durable, idempotent outbox with bounded retries. Generation joins keep an
    # old job from following a replaced token/installation binding.
    assert "UNIQUE KEY actor_idempotency (created_by, idempotency_key)" in push
    assert "UNIQUE KEY dedupe_key (dedupe_key)" in push
    assert "status = 'processing', attempts = attempts + 1" in push
    assert "PUSH_OUTBOX_MAX_ATTEMPTS" in combined
    assert "array(408, 429, 500, 503)" in delivery
    assert "$status === 410" in delivery
    assert "baddevicetoken" in delivery and "devicetokennotfortopic" in delivery
    worker = section(
        push,
        "public static function process_push_outbox",
        "private static function defer_push_outbox_without_attempt",
    )
    assert "SELECT o.fan_user_id, o.install_hash" in worker
    routing_read = section(
        worker,
        "$routing = $wpdb->get_row",
        "$user_id = is_array($routing)",
    )
    assert "!empty($wpdb->last_error)" in routing_read
    assert "defer_push_outbox_without_attempt(" in routing_read
    assert "'storage_unavailable'" in routing_read
    assert "o.install_hash AS outbox_install_hash" in worker
    assert "d.binding_generation = o.binding_generation" in worker
    assert worker.index("'push_install'") < worker.index("acquire_fan_lock($user_id)")
    locked_delivery = worker[worker.index("$transaction = false;") :]
    assert locked_delivery.count("$wpdb->query('ROLLBACK')") == 1
    assert "$rollback_transaction();" in locked_delivery
    owner_lock = locked_delivery.index("SELECT install_hash FROM {$tables['install_states']}")
    joined_job = locked_delivery.index("o.install_hash AS outbox_install_hash")
    assert locked_delivery.index("START TRANSACTION") < owner_lock < joined_job
    assert "LIMIT 1 FOR UPDATE" in locked_delivery[owner_lock:joined_job]
    assert locked_delivery.count("'storage_unavailable'") >= 3
    assert "if (is_wp_error($session_state))" in locked_delivery
    for ownership_check in (
        "binding_generation AS device_generation",
        "binding_generation AS owner_generation",
        "owner_session_option_id",
        "s.desired_state",
        "s.session_expires_at",
        "!== (int) ($job['device_generation'] ?? 0)",
        "!== (int) ($job['owner_generation'] ?? 0)",
        "!== (int) ($job['owner_session_option_id'] ?? 0)",
        "!hash_equals($install_hash, (string) ($job['outbox_install_hash'] ?? ''))",
        "!hash_equals('bound', (string) ($job['desired_state'] ?? ''))",
        "strtotime((string) ($job['session_expires_at'] ?? '') . ' UTC') <= time()",
        "push_delivery_session_is_current($job)",
    ):
        assert ownership_check in locked_delivery
    deadline_check = locked_delivery.index("(int) ($job['deliver_before'] ?? 0) <= time()")
    decrypt = locked_delivery.index("self::decrypt_push_device_token(")
    send = locked_delivery.index("self::send_push_to_apns($device_token, $job)")
    release_fan = locked_delivery.rindex("self::release_fan_lock($user_id, $fan_lock)")
    release_install = locked_delivery.rindex("self::release_named_fan_lock($install_lock)")
    assert deadline_check < decrypt < send < release_fan < release_install
    crypto_defer = section(
        worker,
        "if (is_wp_error($device_token))",
        "if ($device_token === '')",
    )
    invalid_ciphertext = section(
        worker,
        "if ($device_token === '')",
        "$result = self::send_push_to_apns",
    )
    assert "defer_push_outbox_without_attempt(" in crypto_defer
    assert "'device_crypto_unavailable'" in crypto_defer
    assert "invalidate_push_binding_for_job" not in crypto_defer
    assert "invalidate_push_binding_for_job($job, 'device_ciphertext_invalid')" in invalid_ciphertext
    assert "device_ciphertext_invalid" in invalid_ciphertext
    defer = section(
        push,
        "private static function defer_push_outbox_without_attempt",
        "private static function push_delivery_session_is_current",
    )
    assert "attempts = CASE WHEN attempts > 0 THEN attempts - 1 ELSE 0 END" in defer
    assert "status = 'pending'" in defer
    assert "last_error_code = %s" in defer
    assert "sanitize_key((string) $reason)" in defer
    assert "lease_token = %s AND status = 'processing'" in defer
    assert "time() + 60" in defer
    assert "invalidate_push_binding_for_job" not in defer
    sweep = section(
        push,
        "public static function sweep_push_outbox",
        "public static function process_push_outbox",
    )
    assert "WHERE n.deliver_before <= %d AND o.status IN ('pending', 'processing')" in sweep
    assert "last_error_code = 'attempts_exhausted'" in sweep
    assert "status = 'processing' AND lease_until <= %s AND attempts >= %d" in sweep
    assert "last_error_code = 'lease_recovered'" in sweep
    assert "status = 'processing' AND lease_until <= %s AND attempts < %d" in sweep
    assert "status = 'pending' OR (status = 'processing' AND lease_until <= %s)" in sweep
    key_preflight = section(sweep, "$device_keys = self::push_device_keys();", "$ids =")
    assert "is_wp_error($device_keys)" in key_preflight
    assert "schedule_push_sweep(time() + 60)" in key_preflight
    assert "sodium_memzero($device_keys['encryption'])" in key_preflight
    assert "sodium_memzero($device_keys['index'])" in key_preflight
    assert "attempts" not in key_preflight
    delivery_session = section(
        push,
        "private static function push_delivery_session_is_current",
        "private static function invalidate_push_binding_for_job",
    )
    assert "WHERE option_id = %d LIMIT 1 FOR UPDATE" in delivery_session
    assert "SELECT ID FROM {$wpdb->users} WHERE ID = %d LIMIT 1 FOR UPDATE" in delivery_session
    assert "array('pending', 'active')" in delivery_session
    assert "fan_meta_from_database(" in delivery_session
    assert "fan_session_context_is_current_from_database(" in delivery_session
    assert "'normal'," in delivery_session
    assert delivery_session.count("return self::push_storage_error();") >= 4
    invalidation = section(
        push,
        "private static function invalidate_push_binding_for_job",
        "private static function complete_push_outbox_job",
    )
    assert "WHERE install_hash = %s AND fan_user_id = %d AND binding_generation = %d" in invalidation
    assert "AND fan_user_id = %d AND session_option_id = %d AND binding_generation = %d" in invalidation
    assert "WHERE install_hash = %s AND fan_user_id = %d" in invalidation
    assert "AND session_option_id = %d AND binding_generation = %d" in invalidation
    assert "SET desired_state = 'unbound'" in invalidation
    for method in (
        "ensure_push_outbox_schedule",
        "sweep_push_outbox",
        "process_push_outbox",
    ):
        body = section(push, f"function {method}", "\n    }")
        assert "account_authority_enabled()" in body
    init = section(core, "public static function init()", "public static function ensure_roles()")
    assert "if (self::account_authority_enabled())" in init
    assert "self::PUSH_OUTBOX_HOOK" in init and "self::PUSH_SWEEP_HOOK" in init

    # Sensitive content defaults to a generic alert, and all records have a
    # bounded retention/deletion path including zero-device recipients.
    sanitizer = section(
        push,
        "private static function sanitize_targeted_push_request",
        "private static function normalize_push_text",
    )
    assert "$raw_sensitive === null ? true" in sanitizer
    assert "$title = 'Hi，梳子';" in sanitizer
    assert "$body = '有新消息，请登录查看';" in sanitizer
    assert "yishu_push_recipients" in push
    assert push.count("expires_at datetime NOT NULL") >= 2
    assert "PUSH_RETENTION_SECONDS" in combined and "PUSH_DEVICE_TTL" in combined
    purge = section(push, "public static function purge_push_data_for_fan_user", "\n}")
    assert "DELETE FROM {$tables['outbox']} WHERE fan_user_id = %d" in purge
    assert "DELETE FROM {$tables['devices']} WHERE fan_user_id = %d" in purge
    assert "UPDATE {$tables['install_states']}" in purge
    assert "SET fan_user_id = 0, desired_state = 'unbound'" in purge
    assert purge.index("UPDATE {$tables['install_states']}") < purge.index(
        "DELETE FROM {$tables['outbox']}"
    ) < purge.index("DELETE FROM {$tables['devices']}")
    assert "DELETE FROM {$tables['recipients']} WHERE fan_user_id = %d" in purge
    assert "WHERE r.id IS NULL" in purge

    # Every session invalidation path reaches server-side device cleanup; the
    # client DELETE is only an additional best-effort privacy control.
    revoke_one = section(identity, "private static function revoke_fan_session(", "private static function revoke_fan_session_by_public_id")
    revoke_all = section(identity, "private static function revoke_all_fan_sessions", "public static function cleanup_fan_session")
    assert "tombstone_push_install_session($revoked_context)" in revoke_one
    assert revoke_one.index("tombstone_push_install_session($revoked_context)") < revoke_one.index(
        "delete_option(self::FAN_SESSION_OPTION_PREFIX . $token_hash)"
    )
    assert "remove_fan_push_device_for_install_hash" in revoke_one
    assert "remove_all_fan_push_devices" in revoke_all
    logout = section(fan, "public static function logout_fan", "public static function delete_fan_account")
    assert "revoke_fan_session" in logout
    assert "remove_fan_push_device_for_install_hash" not in logout
    assert identity.count("purge_push_data_for_fan_user") >= 2

    # Admin browsing is paginated so an older fan remains selectable.
    list_fans = section(fan, "public static function list_fans", "public static function update_fan_access")
    assert "get_param('page')" in list_fans
    assert "get_param('perPage')" in list_fans
    assert "'offset' => ($page - 1) * $per_page" in list_fans
    assert "fan_search_invalid" in list_fans
    assert "SELECT u.ID FROM " in list_fans
    assert "LIMIT %d OFFSET %d" in list_fans
    assert "EXISTS (" in list_fans
    assert "$query['number'] = 201" not in list_fans
    assert "'hasMore' => $has_more" in list_fans

    print("push-notification-contract-test: passed")


if __name__ == "__main__":
    main()
