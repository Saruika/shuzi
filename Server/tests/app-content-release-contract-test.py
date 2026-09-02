import hashlib
from pathlib import Path


DEPLOYER = Path("Server/operations/deploy-app-content-release")
STANDBY_SEEDER = Path("Server/operations/seed-standby-app-content-release")
OPERATIONS_README = Path("Server/operations/README.md")
AUTHORITY_VERIFIER = Path("Server/operations/verify-account-authority-role.py")
WEBROOT_VERIFIER = Path("Server/operations/verify-webroot-security")
LEGACY_MANIFEST_SHA256 = "64aee00b4bb78903577ae9de737eb1cfdd3aae687c7633483fa410b8b09d4134"
TARGET_MANIFEST_SHA256 = "76f1591503d2bb11005d50f0429171b638caac40246be10ab260c500a63cabe9"


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if fragment in lines[index]:
            return index
    raise AssertionError(f"missing required release operation: {fragment}")


def function_range(lines: list[str], name: str, next_name: str) -> tuple[int, int]:
    start = line_number(lines, f"{name}() {{")
    end = line_number(lines, f"{next_name}() {{", start + 1)
    return start, end


def function_body(lines: list[str], name: str, next_name: str) -> str:
    start, end = function_range(lines, name, next_name)
    return "\n".join(lines[start:end])


def assert_manifest_lifecycle_regressions(text: str, lines: list[str]) -> None:
    """Bind the three supported manifest transitions to executable state checks."""

    seed_text = STANDBY_SEEDER.read_text(encoding="utf-8")
    assert (
        "for relative in vendor composer.lock composer.json "
        "shuzijun-app-content.php release.sha256; do"
    ) in seed_text

    install_body = function_body(lines, "install_release_unit", "verify_restored_release_matches_backup")
    assert install_body.rindex("install_live_manifest_atomic") > install_body.rindex(
        '"$BUNDLE/shuzijun-app-content.php" "$TARGET_DIR/shuzijun-app-content.php"'
    )
    assert 'mv -T -- "$LIVE_MANIFEST_STAGE" "$LIVE_MANIFEST"' in text

    release_entries = (
        "vendor",
        "composer.lock",
        "composer.json",
        "shuzijun-app-content.php",
        "release.sha256",
    )

    # A complete 1.5.8 standby seed is a valid ordinary-deploy baseline. The
    # subsequent ordinary publication changes all payload bytes before the
    # final manifest commit, leaving one complete 1.5.10 release.
    live: dict[str, str] = {}
    for entry in release_entries:
        live[entry] = LEGACY_MANIFEST_SHA256
    assert live["release.sha256"] == LEGACY_MANIFEST_SHA256
    publish_order: list[str] = []
    for entry in release_entries:
        live[entry] = TARGET_MANIFEST_SHA256
        publish_order.append(entry)
    assert publish_order[-1] == "release.sha256"
    assert set(live.values()) == {TARGET_MANIFEST_SHA256}

    # Rollback is presence-sensitive: a manifested baseline restores the exact
    # prior bytes, while the sole legacy transition restores manifest absence.
    for previous_manifest in (LEGACY_MANIFEST_SHA256, None):
        before = {entry: "old" for entry in release_entries[:-1]}
        if previous_manifest is not None:
            before["release.sha256"] = previous_manifest
        backup_state = "present" if "release.sha256" in before else "absent"
        backup_manifest = before.get("release.sha256")

        failed_live = {entry: "partial" for entry in release_entries}
        for entry in release_entries[:-1]:
            failed_live[entry] = before[entry]
        if backup_state == "present":
            failed_live["release.sha256"] = backup_manifest  # type: ignore[assignment]
        else:
            failed_live.pop("release.sha256", None)
        assert failed_live == before

    backup_integrity = function_body(
        lines, "write_backup_integrity_manifest", "validate_code_backup"
    )
    assert 'BACKUP_MANIFEST="$BACKUP_DIR/$BACKUP_INTEGRITY_NAME"' in backup_integrity
    assert 'BACKUP_MANIFEST="$BACKUP_DIR/$MANIFEST_NAME"' not in text
    assert 'backup_paths+=("$MANIFEST_NAME")' in backup_integrity

    backup_validation = function_body(lines, "validate_code_backup", "create_code_backup")
    for guard in (
        "code backup integrity manifest has an invalid record",
        "code backup integrity manifest is not bytewise sorted and unique",
        "code backup integrity manifest does not cover every backup file",
        "code backup integrity manifest has a missing or extra file",
        'sha256sum --strict --quiet --check "$BACKUP_MANIFEST"',
        "present:8)",
        "absent:7)",
    ):
        assert guard in backup_validation

    backup_body = function_body(lines, "create_code_backup", "remove_live_vendor")
    rollback_body = function_body(lines, "restore_code_backup", "isolate_failed_fpm")
    assert "BACKUP_LIVE_MANIFEST_STATE=present" in backup_body
    assert "BACKUP_LIVE_MANIFEST_STATE=absent" in backup_body
    assert '"$BACKUP_LIVE_MANIFEST_STATE" == present' in rollback_body
    assert 'rm -f -- "$TARGET_DIR/shuzijun-app-content.php"' in text


def main() -> None:
    text = DEPLOYER.read_text(encoding="utf-8")
    lines = text.splitlines()
    readme = OPERATIONS_README.read_text(encoding="utf-8")
    authority_verifier_sha256 = hashlib.sha256(AUTHORITY_VERIFIER.read_bytes()).hexdigest()
    webroot_verifier_sha256 = hashlib.sha256(WEBROOT_VERIFIER.read_bytes()).hexdigest()

    assert lines[:3] == ["#!/bin/bash", "set -Eeuo pipefail", "umask 077"]
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in lines
    assert "unset CDPATH ENV http_proxy" in text
    assert "COMPOSER_AUTH GITHUB_TOKEN GITLAB_TOKEN" in text
    for fixed_path in (
        "readonly SITE=/var/www/html/shuzijun.com.cn",
        'readonly TARGET_DIR="$SITE/wp-content/mu-plugins"',
        "readonly STAGING_ROOT=/var/lib/shuzijun-app-content/releases",
        "readonly BACKUP_ROOT=/var/backups/shuzijun-app-content",
        'readonly LOCK_PATH="$STAGING_ROOT"',
        'readonly AUTHORITY_LOCK_PATH="$SITE"',
        "readonly AUTHORITY_VERIFY=/usr/local/sbin/verify-shuzijun-account-authority-role",
        f"readonly AUTHORITY_VERIFY_SHA256={authority_verifier_sha256}",
        "readonly VERIFY=/usr/local/sbin/verify-shuzijun-webroot-security",
        f"readonly VERIFY_SHA256={webroot_verifier_sha256}",
        'readonly LIVE_MANIFEST="$TARGET_DIR/$MANIFEST_NAME"',
        "readonly BACKUP_INTEGRITY_NAME=backup-integrity.sha256",
        "readonly BACKUP_MANIFEST_STATE_NAME=live-release-manifest.state",
        "readonly LEGACY_BRIDGE_MANIFEST_SHA256=64aee00b4bb78903577ae9de737eb1cfdd3aae687c7633483fa410b8b09d4134",
        "readonly TARGET_RELEASE_MANIFEST_SHA256=76f1591503d2bb11005d50f0429171b638caac40246be10ab260c500a63cabe9",
        "readonly LEGACY_PRE_MANIFEST_PHP_SHA256=36c0d27d1dd4ded7497017a41473ede7fdf0dcf234f95c6e697de8cd29a91f4a",
        "readonly LEGACY_BRIDGE_PHP_SHA256=c109713a02e469bd716767dfd14894c055aeaa68faed473481c119251789d7c0",
        "readonly TARGET_RELEASE_PHP_SHA256=90d50b197ad39e2efb45d2e394f6926c0c1f01d501ef95e4a21de18bd8581fa3",
        "readonly COLLABORATION_FUSE_PROBE_SENTINEL=shuzijun-collaboration-fuse-probe-complete-v1",
    ):
        assert fixed_path in lines
    assert "不得从 bootstrap 混合态\n直接跳到 1.5.10" in readme
    assert (
        "--manifest-sha256 "
        "64aee00b4bb78903577ae9de737eb1cfdd3aae687c7633483fa410b8b09d4134"
    ) in readme
    assert "LOCK_FILE=" not in text
    assert 'exec 9<"$LOCK_PATH"' in lines
    assert 'exec 9<>"$LOCK_PATH"' not in lines
    assert any(line.strip() == 'exec 8<"$AUTHORITY_LOCK_PATH"' for line in lines)
    assert not any(line.strip() == 'exec 8<>"$AUTHORITY_LOCK_PATH"' for line in lines)

    root_check = line_number(lines, '[[ "$EUID" -eq 0 ]]')
    authority_lock_validation = line_number(
        lines, "validate_authority_lock_path", root_check + 1
    )
    authority_lock_open = line_number(
        lines, 'exec 8<"$AUTHORITY_LOCK_PATH"', authority_lock_validation + 1
    )
    authority_lock_take = line_number(lines, "flock -n 8", authority_lock_open + 1)
    early_authority_check = line_number(
        lines, "verify_authority_role", authority_lock_take + 1
    )
    lock_validation = line_number(lines, "validate_staging_lock_path", early_authority_check + 1)
    lock_open = line_number(lines, 'exec 9<"$LOCK_PATH"', lock_validation + 1)
    lock_take = line_number(lines, "flock -n 9", lock_open + 1)
    fixed_validation = line_number(lines, "validate_fixed_paths", lock_take + 1)
    assert root_check < authority_lock_validation < authority_lock_open
    assert authority_lock_open < authority_lock_take < early_authority_check
    assert early_authority_check < lock_validation < lock_open < lock_take < fixed_validation

    find_guard = function_body(lines, "reject_find_match", "is_outside_site")
    assert "find \"$@\" -print0 -quit && printf '\\0'" in find_guard
    assert "filesystem safety scan did not complete" in find_guard
    assert 'if [[ "$found" -ne 0 ]]' in find_guard

    for required in (
        'BUNDLE=$(realpath -e -- "$BUNDLE_INPUT")',
        '[[ "$BUNDLE" == "$BUNDLE_INPUT" ]]',
        '[[ "$BUNDLE" == "$STAGING_ROOT/"* ]]',
        "bundle must be an immediate child of the staging root",
        "bundle directory name is unsafe",
        "bundle contains a symbolic link",
        "bundle contains a hard-linked file",
        "bundle contains a non-regular entry",
        "bundle crosses a filesystem boundary",
        "bundle is writable by a non-root identity",
        "manifest contains path traversal",
        "manifest contains an entry outside the fixed release unit",
        "bundle contains a forbidden secret or database filename",
        "bundle contains content resembling a long-lived credential",
        "bundle contains a binary or unreadable release file",
    ):
        assert required in text, f"missing package boundary: {required}"

    manifest_body = function_body(lines, "validate_manifest", "validate_secret_content")
    assert "tail -c 1" in manifest_body
    assert r'^([a-f0-9]{64})\ \ ([A-Za-z0-9._/-]+)$' in manifest_body
    assert "[[:space:]][[:space:]]" not in manifest_body
    assert "paths must be unique and bytewise sorted" in manifest_body
    assert "sha256sum --strict --quiet --check" in manifest_body
    assert "find \"$BUNDLE\" -type f -print0 && printf '\\0'" in manifest_body
    for required_path in (
        "shuzijun-app-content.php",
        "composer.json",
        "composer.lock",
        "vendor/autoload.php",
    ):
        assert required_path in manifest_body

    runtime_body = function_body(lines, "resolve_runtime_tools", "run_composer")
    for fixed_candidate in (
        "/usr/bin/php8.3",
        "/usr/local/bin/php8.3",
        "/usr/bin/composer",
        "/usr/local/bin/composer",
    ):
        assert fixed_candidate in runtime_body
    assert "binary directory is writable by a non-root identity" in runtime_body
    assert "runtime tools must be owned by root" in runtime_body
    assert "command -v composer" not in runtime_body

    composer_body = function_body(
        lines, "run_composer", "probe_candidate_collaboration_release_fuse"
    )
    for operation in (
        "env -i",
        "COMPOSER_HOME=/dev/null",
        "COMPOSER_CACHE_DIR=/dev/null",
        "--no-cache",
        "--no-plugins",
        "--no-scripts",
    ):
        assert operation in composer_body

    collaboration_probe = function_body(
        lines, "probe_candidate_collaboration_release_fuse", "preflight_release"
    )
    for probe_guard in (
        'cat -- "$BUNDLE/shuzijun-app-content.php" |',
        "timeout --signal=KILL 20s runuser -u www-data -- env -i",
        '"$PHP_BIN" -n -d display_errors=0 -d log_errors=0',
        "allow_url_fopen=0 -d open_basedir=/nonexistent",
        "disable_functions=exec,passthru,shell_exec,system",
        '$source = stream_get_contents(STDIN);',
        '$sourceHash = hash("sha256", $source);',
        '$legacyHash = $argv[1];',
        '$targetHash = $argv[2];',
        '$sentinel = $argv[3];',
        '&& !hash_equals($targetHash, $sourceHash)',
        'exit(25);',
        'define("ABSPATH", "/nonexistent/");',
        'define("YISHU_ENABLE_COLLABORATION_PHASE1", true);',
        'eval("?>" . $source);',
        'if (!class_exists($class, false)) { exit(19); }',
        'method_exists($class, $gate)',
        '$class . "::COLLABORATION_PHASE1_RELEASE_FUSE"',
        'constant("YISHU_ENABLE_COLLABORATION_PHASE1") !== true',
        'if (!$has_gate && !$has_fuse) {',
        'if (!hash_equals($legacyHash, $sourceHash)) { exit(24); }',
        'if (!$has_gate || !$has_fuse) { exit(21); }',
        'if (constant($fuse) !== false) { exit(22); }',
        'if ($class::$gate() !== false) { exit(23); }',
        'fwrite(STDOUT, $sentinel . "\\n");',
        'python3 -I -c',
        'sys.stdin.buffer.read(len(expected) + 1)',
        '"$COLLABORATION_FUSE_PROBE_SENTINEL" 8<&- 9<&- |',
        "candidate collaboration Phase 1 release fuse is not hard-disabled",
        "candidate plugin source could not be read from the reviewed bundle",
        "candidate plugin could not be evaluated by the isolated PHP probe",
        "gate-free collaboration candidate is not the reviewed 1.5.8 bridge",
        "candidate plugin exited before the isolated fuse probe completed",
        "candidate plugin PHP is not in the reviewed release allowlist",
    ):
        assert probe_guard in collaboration_probe, (
            f"missing candidate collaboration fuse probe: {probe_guard}"
        )
    for forbidden_probe_effect in (
        "$SITE",
        "$TARGET_DIR",
        "curl ",
        "systemctl ",
        "create_code_backup",
        "install_release_unit",
        'require $root . "/shuzijun-app-content.php";',
    ):
        assert forbidden_probe_effect not in collaboration_probe

    preflight_body = function_body(
        lines, "preflight_release", "verify_installed_jwt_autoload"
    )
    for operation in (
        '"$PHP_BIN" -n -l',
        "validate \\",
        "audit \\",
        "--locked --no-dev --format=summary",
        "check-platform-reqs \\",
        '!== "firebase/php-jwt"',
        "str_contains($psr4",
        "validate_manifest",
    ):
        assert operation in preflight_body, f"missing runtime preflight: {operation}"
    candidate_probe_call = preflight_body.index(
        "probe_candidate_collaboration_release_fuse"
    )
    composer_validate_call = preflight_body.index(
        'run_composer --working-dir="$BUNDLE" validate'
    )
    composer_audit_call = preflight_body.index(
        'run_composer --working-dir="$BUNDLE" audit'
    )
    assert candidate_probe_call < composer_validate_call < composer_audit_call
    assert "--strict --no-check-all --no-check-publish" in preflight_body
    assert "every other validation warning remains fatal" in preflight_body
    assert '($packages[0]["version"] ?? "") !== "v7.1.0"' in preflight_body
    assert 'require $root . "/vendor/autoload.php"' not in preflight_body

    installed_autoload = function_body(
        lines, "verify_installed_jwt_autoload", "probe_offline_wordpress_api"
    )
    assert "runuser -u www-data -- env -i" in installed_autoload
    assert 'open_basedir=$TARGET_DIR' in installed_autoload
    assert 'require $root . "/vendor/autoload.php"' in installed_autoload

    offline_probe = function_body(
        lines, "probe_offline_wordpress_api", "validate_target_boundary"
    )
    for offline_guard in (
        "runuser -u www-data -- env -i",
        'require $site . "/wp-load.php"',
        'new WP_REST_Request("GET", "/shuzijun/v1/app-content")',
        "rest_do_request($request)",
        'array(401, "fan_session_required")',
        'array(503, "yishu_account_authority_unavailable")',
    ):
        assert offline_guard in offline_probe

    current_unit = function_body(
        lines, "validate_current_release_unit", "verify_current_webroot"
    )
    for boundary in (
        "current release unit contains a symbolic link",
        "current release unit contains a non-regular entry",
        "current release unit contains a hard-linked file",
        "current release unit has unsafe ownership or write access",
        "current release unit crosses a filesystem boundary",
    ):
        assert boundary in current_unit
    assert "|| return 1" in current_unit
    assert "validate_live_manifested_release" in current_unit
    assert "validate_unmanifested_legacy_bridge" in current_unit
    assert "a stale live manifest staging entry requires manual inspection" in current_unit

    live_manifested = function_body(
        lines, "validate_live_manifested_release", "validate_unmanifested_legacy_bridge"
    )
    for guard in (
        "live release manifest metadata is unsafe",
        'stat -c \'%u:%g:%h:%a\'',
        "validate_allowed_release_manifest_sha256",
        "live release manifest paths must be unique and bytewise sorted",
        "live release manifest does not allow every release file",
        "live release manifest contains a missing or extra file",
        'sha256sum --strict --quiet --check "$LIVE_MANIFEST"',
    ):
        assert guard in live_manifested

    unmanifested_bridge = function_body(
        lines, "validate_unmanifested_legacy_bridge", "validate_current_release_unit"
    )
    for guard in (
        '"$AUTHORITY_ROLE" == authority',
        "a missing live manifest is allowed only on the authority bootstrap transition",
        '"$EXPECTED_MANIFEST_SHA256" == "$LEGACY_BRIDGE_MANIFEST_SHA256"',
        '"$actual_php_sha" == "$LEGACY_PRE_MANIFEST_PHP_SHA256"',
        "unmanifested live PHP does not declare version 1.5.7",
        "unmanifested release support differs from the reviewed 1.5.8 unit",
        'done < "$MANIFEST" | sha256sum --strict --quiet --check -',
    ):
        assert guard in unmanifested_bridge

    direct_probe_body = function_body(
        lines, "probe_direct_php_blocked", "probe_unauthorized_api"
    )
    assert "wp-content/mu-plugins/shuzijun-app-content.php" in text
    assert "wp-content/mu-plugins/vendor/autoload.php" in text
    for direct_guard in (
        '--resolve "$HEALTH_HOST:443:127.0.0.1"',
        '[[ "$status" == 404 ]]',
    ):
        assert direct_guard in direct_probe_body

    probe_body = function_body(lines, "probe_unauthorized_api", "verify_live_release_hashes")
    assert "?rest_route=%2Fshuzijun%2Fv1%2Fapp-content" in text
    for probe_guard in (
        "curl -q",
        "--resolve \"$HEALTH_HOST:443:127.0.0.1\"",
        '"$status" == 401',
        '"$status" == 503',
        "authority|standby)",
        "fan_session_required",
        "yishu_account_authority_unavailable",
        "json.loads",
        '--max-filesize 65536',
        "application/json",
        "x-robots-tag:",
        "vary:.*authorization.*x-yishu-install-id",
        "endpoint_role=authority",
        "endpoint_role=standby",
    ):
        assert probe_guard in probe_body
    assert "safe" not in probe_body
    assert "/wp-json/shuzijun/v1/app-content" not in probe_body

    backup_body = function_body(lines, "create_code_backup", "remove_live_vendor")
    assert "validate_current_release_unit" in backup_body
    assert 'mkdir -m 0700 "$BACKUP_DIR"' in backup_body
    assert 'install -d -o root -g root -m 0700 "$BACKUP_ROOT"' not in text
    for release_entry in (
        "shuzijun-app-content.php",
        "composer.json",
        "composer.lock",
        "vendor",
    ):
        assert f'$TARGET_DIR/{release_entry}' in backup_body
    assert 'cp -a -- "$LIVE_MANIFEST" "$BACKUP_DIR/$MANIFEST_NAME"' in backup_body
    assert "BACKUP_LIVE_MANIFEST_STATE=present" in backup_body
    assert "BACKUP_LIVE_MANIFEST_STATE=absent" in backup_body
    assert "write_backup_integrity_manifest" in backup_body
    assert "validate_code_backup" in backup_body
    assert 'sync -f "$BACKUP_DIR"' in backup_body
    assert 'sync -f "$BACKUP_ROOT"' in backup_body
    assert backup_body.index('sync -f "$BACKUP_ROOT"') < backup_body.index("ROLLBACK_READY=1")
    assert "ROLLBACK_READY=1" in backup_body

    removal_body = function_body(lines, "remove_live_vendor", "remove_live_metadata")
    assert "wp-content/mu-plugins/vendor" in removal_body
    assert 'rm -rf --one-file-system -- "$live_vendor"' in removal_body
    assert "|| return 1" in removal_body
    metadata_removal = function_body(
        lines, "remove_live_metadata", "install_live_manifest_atomic"
    )
    assert "wp-content/mu-plugins/*" in metadata_removal
    assert 'rm -f -- "$TARGET_DIR/shuzijun-app-content.php"' in metadata_removal
    assert '"$TARGET_DIR/composer.lock" "$LIVE_MANIFEST"' in metadata_removal
    assert "LIVE_MANIFEST_STAGE" in metadata_removal
    assert "|| return 1" in metadata_removal
    assert 'rm -rf -- "$TARGET_DIR"' not in text

    manifest_install = function_body(
        lines, "install_live_manifest_atomic", "install_release_unit"
    )
    for guard in (
        '.shuzijun-release-manifest-$EXPECTED_MANIFEST_SHA256',
        'install -o root -g www-data -m 0644 "$MANIFEST" "$LIVE_MANIFEST_STAGE"',
        'sync -f "$LIVE_MANIFEST_STAGE"',
        'mv -T -- "$LIVE_MANIFEST_STAGE" "$LIVE_MANIFEST"',
        'sync -f "$TARGET_DIR"',
        '"$actual_manifest_sha" == "$EXPECTED_MANIFEST_SHA256"',
    ):
        assert guard in manifest_install
    assert manifest_install.index('sync -f "$LIVE_MANIFEST_STAGE"') < manifest_install.index(
        'mv -T -- "$LIVE_MANIFEST_STAGE" "$LIVE_MANIFEST"'
    )

    install_start, install_end = function_range(
        lines, "install_release_unit", "restore_code_backup"
    )
    vendor_install = line_number(lines, 'cp -R -- "$BUNDLE/vendor/."', install_start)
    composer_json_install = line_number(
        lines, '"$BUNDLE/composer.json" "$TARGET_DIR/composer.json"', install_start
    )
    composer_lock_install = line_number(
        lines, '"$BUNDLE/composer.lock" "$TARGET_DIR/composer.lock"', install_start
    )
    plugin_install = line_number(
        lines,
        '"$BUNDLE/shuzijun-app-content.php" "$TARGET_DIR/shuzijun-app-content.php"',
        install_start,
    )
    manifest_install_call = line_number(
        lines, "install_live_manifest_atomic", plugin_install + 1
    )
    assert vendor_install < composer_json_install < composer_lock_install < plugin_install
    assert plugin_install < manifest_install_call < install_end

    rollback_body = function_body(lines, "restore_code_backup", "isolate_failed_fpm")
    assert "protect_fpm_from_incomplete_boot" in rollback_body
    assert "is_fpm_persistently_masked" in rollback_body
    assert "release_fpm_boot_guard" in rollback_body
    assert 'systemctl stop "$FPM_SERVICE"' in rollback_body
    assert "validate_code_backup" in rollback_body
    assert '"$BACKUP_LIVE_MANIFEST_STATE" == present' in rollback_body
    assert 'cp -a -- "$BACKUP_DIR/$MANIFEST_NAME" "$LIVE_MANIFEST"' in rollback_body
    assert "verify_restored_release_matches_backup" in rollback_body
    assert '[[ "$restore_status" -eq 0 && "$FPM_WAS_ACTIVE" -eq 1 ]]' in rollback_body
    assert 'systemctl start "$FPM_SERVICE"' in rollback_body
    offline_rollback_role = line_number(
        lines,
        "verify_authority_role >/dev/null 2>&1",
        lines.index("restore_code_backup() {") + 1,
    )
    offline_rollback_probe = line_number(
        lines,
        'probe_offline_wordpress_api "$AUTHORITY_ROLE"',
        offline_rollback_role + 1,
    )
    rollback_unmask = line_number(
        lines, "release_fpm_boot_guard", offline_rollback_probe + 1
    )
    assert offline_rollback_role < offline_rollback_probe < rollback_unmask
    assert rollback_body.count("protect_fpm_from_incomplete_boot") >= 2
    assert "Never restart PHP-FPM with a partial or unverified rollback" in rollback_body
    assert 'rm -rf -- "$TARGET_DIR"' not in rollback_body
    handle_start = line_number(lines, "handle_failure() {")
    trap_start = line_number(lines, "trap 'handle_failure $?'", handle_start + 1)
    handle_body = "\n".join(lines[handle_start:trap_start])
    assert "trap '' INT TERM HUP" in handle_body
    assert "probe_direct_php_blocked" in handle_body
    assert "isolate_failed_fpm" in handle_body
    assert "release_fpm_boot_guard" in handle_body
    assert "PHP-FPM left stopped and persistently masked" in handle_body
    assert "PHP-FPM isolation could not be confirmed" in handle_body
    assert 'systemctl is-active --quiet "$FPM_SERVICE"' in handle_body

    isolation_body = function_body(lines, "isolate_failed_fpm", "handle_failure")
    assert "is_fpm_persistently_masked" in isolation_body
    assert "protect_fpm_from_incomplete_boot" in isolation_body
    assert 'systemctl stop "$FPM_SERVICE"' in isolation_body
    assert isolation_body.count("is_fpm_persistently_masked") >= 2

    release_preflight = line_number(lines, "preflight_release", fixed_validation + 1)
    bundle_preflight_exit = line_number(
        lines, 'if [[ "$MODE" == bundle-preflight ]]', release_preflight + 1
    )
    current_webroot = line_number(
        lines, "verify_current_webroot", bundle_preflight_exit + 1
    )
    dry_run = line_number(lines, 'if [[ "$MODE" == dry-run ]]', current_webroot + 1)
    first_authority_check = line_number(lines, "verify_authority_role", fixed_validation + 1)
    assert release_preflight < bundle_preflight_exit < current_webroot < dry_run
    assert fixed_validation < first_authority_check < dry_run
    enabled_policy = line_number(lines, "require_fpm_enabled_policy", dry_run + 1)
    first_direct_probe = line_number(lines, "probe_direct_php_blocked", enabled_policy + 1)
    first_apply_probe = line_number(
        lines, 'probe_unauthorized_api "$AUTHORITY_ROLE"', first_direct_probe + 1
    )
    second_authority_check = line_number(
        lines, "verify_authority_role", first_apply_probe + 1
    )
    backup = line_number(lines, "create_code_backup", second_authority_check + 1)
    boot_guard = line_number(lines, "protect_fpm_from_incomplete_boot", backup + 1)
    fpm_stop = line_number(lines, 'systemctl stop "$FPM_SERVICE"', boot_guard + 1)
    install = line_number(lines, "install_release_unit", fpm_stop + 1)
    live_hash = line_number(lines, "verify_live_release_hashes", install + 1)
    autoload = line_number(lines, "verify_installed_jwt_autoload", live_hash + 1)
    offline_role = line_number(lines, "verify_authority_role", autoload + 1)
    offline_api = line_number(
        lines, 'probe_offline_wordpress_api "$AUTHORITY_ROLE"', offline_role + 1
    )
    guard_release = line_number(lines, "release_fpm_boot_guard", offline_api + 1)
    fpm_start = line_number(lines, 'systemctl start "$FPM_SERVICE"', guard_release + 1)
    online_guard = line_number(lines, "protect_fpm_from_incomplete_boot", fpm_start + 1)
    post_verify = line_number(lines, "run_webroot_verifier", online_guard + 1)
    final_authority_check = line_number(lines, "verify_authority_role", post_verify + 1)
    nginx_check = line_number(lines, "nginx -t", final_authority_check + 1)
    final_direct_probe = line_number(lines, "probe_direct_php_blocked", nginx_check + 1)
    final_probe = line_number(
        lines, 'probe_unauthorized_api "$AUTHORITY_ROLE"', final_direct_probe + 1
    )
    final_guard_release = line_number(lines, "release_fpm_boot_guard", final_probe + 1)
    rollback_disarm = line_number(lines, "ROLLBACK_READY=0", final_guard_release + 1)
    assert release_preflight < enabled_policy < first_direct_probe < first_apply_probe
    assert release_preflight < backup < fpm_stop < install
    assert dry_run < enabled_policy < first_direct_probe < first_apply_probe
    assert first_apply_probe < second_authority_check < backup
    assert backup < boot_guard < fpm_stop < install < live_hash
    assert live_hash < autoload < offline_role < offline_api < guard_release
    assert guard_release < fpm_start < online_guard < post_verify
    assert post_verify < final_authority_check < nginx_check < final_direct_probe < final_probe
    assert final_probe < final_guard_release < rollback_disarm

    # No main-path call that can create backups, stop services, install code or
    # issue HTTP is allowed before the early dry-run exit.
    main_pre_dry_run = "\n".join(lines[fixed_validation:dry_run])
    assert "create_code_backup\n" not in main_pre_dry_run
    assert "protect_fpm_from_incomplete_boot\n" not in main_pre_dry_run
    assert "release_fpm_boot_guard\n" not in main_pre_dry_run
    assert 'systemctl stop "$FPM_SERVICE"\n' not in main_pre_dry_run
    assert "install_release_unit\n" not in main_pre_dry_run
    assert "probe_direct_php_blocked\n" not in main_pre_dry_run
    assert "probe_unauthorized_api\n" not in main_pre_dry_run
    assert "mktemp" in text
    assert "python3" in text

    for duplicate_guard in (
        "bundle option may be specified only once",
        "manifest SHA256 option may be specified only once",
        "authority role option may be specified only once",
        "release mode may be specified only once",
    ):
        assert duplicate_guard in text

    assert "--authority-role authority|standby" in text
    assert "--authority-role is not accepted with --bundle-preflight" in text
    assert "--authority-role authority|standby is mandatory outside bundle preflight" in text
    assert 'probe_unauthorized_api "$AUTHORITY_ROLE"' in handle_body

    authority_verifier = function_body(
        lines, "validate_authority_verifier", "verify_authority_role"
    )
    for authority_guard in (
        "/usr/local/sbin/verify-shuzijun-account-authority-role",
        "realpath -e",
        "stat -c '%u'",
        "stat -c '%h'",
        "writable by a non-root identity",
        "AUTHORITY_VERIFY_SHA256",
        "sha256sum",
        "/proc/self/fd/7",
    ):
        assert authority_guard in authority_verifier
    assert 'sha256sum "$verifier_fd_path"' in authority_verifier
    assert '/usr/bin/python3 -I /proc/self/fd/7 "$AUTHORITY_ROLE"' in text

    webroot_verifier = function_body(
        lines, "validate_webroot_verifier", "run_webroot_verifier"
    )
    for webroot_guard in (
        "/usr/local/sbin/verify-shuzijun-webroot-security",
        "realpath -e",
        "stat -c '%u:%g:%h:%a'",
        "0:0:1:755",
        "for verifier_parent in /usr /usr/local /usr/local/sbin",
        "writable by a non-root identity",
        'exec 6<"$VERIFY"',
        "/proc/self/fd/6",
        "stat -Lc '%u:%g:%h:%a'",
        'sha256sum "$verifier_fd_path"',
        "VERIFY_SHA256",
    ):
        assert webroot_guard in webroot_verifier
    run_webroot = function_body(lines, "run_webroot_verifier", "validate_authority_lock_path")
    assert '/bin/bash /proc/self/fd/6 "$SITE"' in run_webroot
    assert '"$VERIFY" "$SITE"' not in text

    for prohibited in (
        "wp db ",
        "wp-config.php",
        "wp-content/uploads",
        "mysql ",
        "rsync ",
        "YISHU_APPLE_PRIVATE_KEY_PATH",
        "YISHU_APPLE_DATA_KEY_PATH",
    ):
        assert prohibited not in text, f"release deployer crossed forbidden boundary: {prohibited}"

    assert "--dry-run" in text and "--apply" in text
    for documented_prerequisite in (
        "/var/lib/shuzijun-app-content/releases",
        "/var/backups/shuzijun-app-content",
        "/usr/bin/composer",
        "缺少 Composer 时 dry-run 会按设计失败",
        "`root:www-data`",
        "不会发出可能",
        "/etc/shuzijun/account-authority-role",
        "--authority-role authority",
        "--authority-role standby",
        "wp-load.php",
        "不再存在接受任意 401/503",
        "--confirm-writers-drained",
    ):
        assert documented_prerequisite in readme

    assert_manifest_lifecycle_regressions(text, lines)
    print("app-content-release-contract-test: passed")


if __name__ == "__main__":
    main()
