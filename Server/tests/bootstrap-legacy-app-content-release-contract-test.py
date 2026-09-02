import hashlib
from pathlib import Path
import re
import subprocess


BOOTSTRAP = Path("Server/operations/bootstrap-legacy-app-content-release")
DEPLOYER = Path("Server/operations/deploy-app-content-release")
AUTHORITY_VERIFIER = Path("Server/operations/verify-account-authority-role.py")
WEBROOT_VERIFIER = Path("Server/operations/verify-webroot-security")
OPERATIONS_README = Path("Server/operations/README.md")


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if fragment in lines[index]:
            return index
    raise AssertionError(f"missing required bootstrap operation: {fragment}")


def function_range(lines: list[str], name: str, next_name: str) -> tuple[int, int]:
    start = line_number(lines, f"{name}() {{")
    end = line_number(lines, f"{next_name}() {{", start + 1)
    return start, end


def function_body(lines: list[str], name: str, next_name: str) -> str:
    start, end = function_range(lines, name, next_name)
    return "\n".join(lines[start:end])


def assert_fault_resume_model(publication_order: list[str]) -> None:
    """Model every SIGKILL boundary between the three atomic renames."""
    expected = set(publication_order)
    assert publication_order == ["vendor", "composer.lock", "composer.json"]
    assert len(expected) == 3

    for crash_after in range(len(publication_order) + 1):
        # Atomic rename makes each visible entry absent or wholly verified. A
        # rerun skips exact entries and fills only the remaining suffix.
        visible = set(publication_order[:crash_after])
        assert visible <= expected
        for entry in publication_order:
            if entry not in visible:
                visible.add(entry)
        assert visible == expected

    # A visible byte mismatch is rejected rather than overwritten as a resume.
    for bad_entry in publication_order:
        exact = {entry: True for entry in publication_order}
        exact[bad_entry] = False
        try:
            if not all(exact.values()):
                raise ValueError("inconsistent live subset")
        except ValueError:
            pass
        else:
            raise AssertionError("an inconsistent support subset was accepted")


def main() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    lines = text.splitlines()
    deployer = DEPLOYER.read_text(encoding="utf-8")
    deployer_lines = deployer.splitlines()
    authority_verifier_sha256 = hashlib.sha256(AUTHORITY_VERIFIER.read_bytes()).hexdigest()
    webroot_verifier_sha256 = hashlib.sha256(WEBROOT_VERIFIER.read_bytes()).hexdigest()
    operations_readme = OPERATIONS_README.read_text(encoding="utf-8")

    assert lines[:3] == ["#!/bin/bash", "set -Eeuo pipefail", "umask 077"]
    assert BOOTSTRAP.stat().st_mode & 0o111
    assert "MODE=dry-run" in lines
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in lines
    assert "COMPOSER_AUTH GITHUB_TOKEN GITLAB_TOKEN" in text
    for fixed_path in (
        "readonly SITE=/var/www/html/shuzijun.com.cn",
        'readonly TARGET_DIR="$SITE/wp-content/mu-plugins"',
        'readonly LIVE_PHP="$TARGET_DIR/shuzijun-app-content.php"',
        "readonly STAGING_ROOT=/var/lib/shuzijun-app-content/releases",
        "readonly BACKUP_ROOT=/var/backups/shuzijun-app-content",
        'readonly LOCK_PATH="$STAGING_ROOT"',
        'readonly AUTHORITY_LOCK_PATH="$SITE"',
        "readonly DEPLOYER=/usr/local/sbin/deploy-app-content-release",
        "readonly VERIFY=/usr/local/sbin/verify-shuzijun-webroot-security",
        "readonly AUTHORITY_VERIFY=/usr/local/sbin/verify-shuzijun-account-authority-role",
        f"readonly AUTHORITY_VERIFY_SHA256={authority_verifier_sha256}",
        "readonly VERIFY=/usr/local/sbin/verify-shuzijun-webroot-security",
        f"readonly VERIFY_SHA256={webroot_verifier_sha256}",
    ):
        assert fixed_path in lines

    find_guard = function_body(lines, "reject_find_match", "is_outside_site")
    assert "filesystem safety scan did not complete" in find_guard
    assert 'if [[ "$scan_complete" -ne 1 ]]' in find_guard
    assert 'if [[ "$found" -ne 0 ]]' in find_guard
    assert find_guard.count("return 1") >= 2

    # Delegate the full package/runtime audit before taking the shared staging
    # lock and revalidating all bundle bytes under that lock.
    assert "--bundle-preflight" in deployer
    deploy_preflight = line_number(deployer_lines, "preflight_release", 700)
    bundle_preflight_exit = line_number(
        deployer_lines, 'if [[ "$MODE" == bundle-preflight ]]', deploy_preflight
    )
    live_webroot_check = line_number(
        deployer_lines, "verify_current_webroot", bundle_preflight_exit
    )
    assert deploy_preflight < bundle_preflight_exit < live_webroot_check
    candidate_probe = function_body(
        deployer_lines,
        "probe_candidate_collaboration_release_fuse",
        "preflight_release",
    )
    deployer_preflight_body = function_body(
        deployer_lines, "preflight_release", "verify_installed_jwt_autoload"
    )
    assert 'define("YISHU_ENABLE_COLLABORATION_PHASE1", true);' in candidate_probe
    assert 'if (!$has_gate && !$has_fuse) {' in candidate_probe
    assert 'if (!hash_equals($legacyHash, $sourceHash)) { exit(24); }' in candidate_probe
    assert 'candidate plugin exited before the isolated fuse probe completed' in candidate_probe
    assert 'if (constant($fuse) !== false) { exit(22); }' in candidate_probe
    assert 'if ($class::$gate() !== false) { exit(23); }' in candidate_probe
    assert 'fwrite(STDOUT, $sentinel . "\\n");' in candidate_probe
    assert "probe_candidate_collaboration_release_fuse" in deployer_preflight_body
    assert deployer_preflight_body.index(
        "probe_candidate_collaboration_release_fuse"
    ) < deployer_preflight_body.index(
        'run_composer --working-dir="$BUNDLE" validate'
    )

    root_check = line_number(lines, '[[ "$EUID" -eq 0 ]]')
    authority_only = line_number(
        lines,
        '[[ "$AUTHORITY_ROLE" == authority ]]',
        root_check,
    )
    authority_lock_open = line_number(
        lines, 'exec 8<"$AUTHORITY_LOCK_PATH"', root_check
    )
    authority_lock_take = line_number(lines, "flock -n 8", authority_lock_open)
    early_role_gate = line_number(lines, "verify_authority_role", authority_lock_take)
    delegated_preflight = line_number(
        lines,
        '--manifest-sha256 "$EXPECTED_MANIFEST_SHA256" --bundle-preflight',
        root_check,
    )
    lock_open = line_number(lines, 'exec 9<"$LOCK_PATH"', delegated_preflight)
    lock_take = line_number(lines, "flock -n 9", lock_open)
    locked_validation = line_number(lines, "validate_locked_bundle", lock_take)
    assert root_check < authority_only < authority_lock_open < authority_lock_take < early_role_gate
    assert early_role_gate < delegated_preflight < lock_open < lock_take < locked_validation
    assert 'exec 9<>"$LOCK_PATH"' not in text
    assert 'exec 8<>"$AUTHORITY_LOCK_PATH"' not in text

    locked_bundle = function_body(lines, "validate_locked_bundle", "resolve_php")
    for boundary in (
        'BUNDLE=$(realpath -e -- "$BUNDLE_INPUT")',
        '[[ "$BUNDLE" == "$BUNDLE_INPUT"',
        '"$BUNDLE" == "$STAGING_ROOT/"*',
        "bundle contains a symbolic link",
        "bundle contains a non-regular entry",
        "bundle contains a hard-linked file",
        "bundle contains an unsafe or cross-filesystem entry",
        "release manifest paths must be unique and bytewise sorted",
        "release manifest contains a duplicate path",
        "release manifest does not allow every bundle file",
        "sha256sum --strict --quiet --check",
        " * Version: 1.5.8",
    ):
        assert boundary in locked_bundle, f"missing locked bundle boundary: {boundary}"

    legacy_validation = function_body(
        lines, "validate_legacy_php", "validate_support_file_at"
    )
    for guard in (
        '"$(realpath -e -- "$LIVE_PHP")" == "$LIVE_PHP"',
        '"$(stat -c \'%u\' "$LIVE_PHP")" == 0',
        '"$(stat -c \'%h\' "$LIVE_PHP")" == 1',
        "legacy PHP is writable by a non-root identity",
        "legacy PHP crosses a filesystem boundary",
        '"$actual_sha" != "$EXPECTED_LEGACY_PHP_SHA256"',
        " * Version: 1.5.7",
        "trusted legacy PHP unexpectedly references release support files",
        '"$PHP_BIN" -n -l "$LIVE_PHP"',
    ):
        assert guard in legacy_validation, f"missing legacy PHP guard: {guard}"
    assert "vendor[/\\\\]+autoload\\.php" in legacy_validation

    # Optional live support entries must be exact safe bundle entries.
    support_file = function_body(
        lines, "validate_support_file_at", "validate_vendor_tree_at"
    )
    for guard in (
        '"$(realpath -e -- "$path")" == "$path"',
        '"$(stat -c \'%u\' "$path")" == 0',
        '"$(stat -c \'%a\' "$path")" == 644',
        '"$(stat -c \'%h\' "$path")" == 1',
        '"$(stat -c \'%d\' "$path")" == "$target_device"',
        '"$actual" != "$expected"',
        "differs from the trusted bundle",
    ):
        assert guard in support_file

    vendor_validation = function_body(
        lines, "validate_vendor_tree_at", "validate_complete_support_at"
    )
    for guard in (
        "release support vendor contains a symbolic link",
        "release support vendor contains a non-regular entry",
        "release support vendor contains a hard-linked file",
        "release support vendor has unsafe ownership or write access",
        "release support vendor omits a trusted directory",
        "release support vendor omits a trusted file",
        "sha256sum --strict --quiet --check -",
        "release support vendor hash verification failed",
    ):
        assert guard in vendor_validation

    resumable = function_body(
        lines, "validate_resumable_support_state", "validate_legacy_state"
    )
    assert 'for path in composer.json composer.lock' in resumable
    assert 'if [[ -e "$TARGET_DIR/$path" || -L "$TARGET_DIR/$path" ]]' in resumable
    assert 'if [[ -e "$TARGET_DIR/vendor" || -L "$TARGET_DIR/vendor" ]]' in resumable
    assert resumable.count("SUPPORT_PRESENT_COUNT=$((SUPPORT_PRESENT_COUNT + 1))") == 2
    assert "validate_staging_boundary" in resumable

    # Only the deterministic, same-manifest hidden stage is recoverable.
    staging_boundary = function_body(
        lines, "validate_staging_boundary", "validate_resumable_support_state"
    )
    for guard in (
        '.shuzijun-bootstrap-stage-$EXPECTED_MANIFEST_SHA256',
        "an unknown legacy bootstrap staging entry exists",
        '"$(stat -c \'%d\' "$STAGE_DIR")" == "$target_device"',
        '[[ "$stage_mode" != 700 && "$stage_mode" != 2700 ]]',
        "legacy bootstrap staging is not root-only",
        "legacy bootstrap staging contains a symbolic link",
        "legacy bootstrap staging contains an unknown entry",
        "legacy bootstrap staging type is inconsistent",
        "legacy bootstrap staging crosses a filesystem boundary",
    ):
        assert guard in staging_boundary

    stage_cleanup = function_body(lines, "clear_atomic_stage", "prepare_atomic_stage")
    assert "validate_staging_boundary" in stage_cleanup
    assert 'rm -rf --one-file-system -- "$STAGE_DIR"' in stage_cleanup
    assert "shuzijun-app-content.php" not in stage_cleanup
    stage_prepare = function_body(
        lines, "prepare_atomic_stage", "publish_one_support_entry"
    )
    assert 'mkdir -m 0700 "$STAGE_DIR"' in stage_prepare
    assert 'chown root:www-data "$STAGE_DIR"' in stage_prepare
    assert 'chmod 2700 "$STAGE_DIR"' in stage_prepare
    assert "all three intermediate states" in stage_prepare
    assert "every in-progress child inherit www-data" in stage_prepare
    assert '"$BUNDLE/vendor/." "$STAGE_DIR/vendor/"' in stage_prepare
    assert '"$BUNDLE/composer.json" "$STAGE_DIR/composer.json"' in stage_prepare
    assert '"$BUNDLE/composer.lock" "$STAGE_DIR/composer.lock"' in stage_prepare
    assert "validate_complete_support_at" in stage_prepare
    assert 'sync -f "$STAGE_DIR"' in stage_prepare

    publication = function_body(
        lines, "publish_one_support_entry", "install_support_unit"
    )
    assert 'if [[ -e "$destination" || -L "$destination" ]]' in publication
    assert 'mv -T -- "$source" "$destination"' in publication
    assert 'sync -f "$TARGET_DIR"' in publication
    assert "validate_support_file_at" in publication
    assert "validate_vendor_tree_at" in publication

    install_body = function_body(
        lines, "install_support_unit", "validate_completed_unit"
    )
    assert 'if [[ "$SUPPORT_PRESENT_COUNT" -eq 3 ]]' in install_body
    order = re.findall(r"publish_one_support_entry ([A-Za-z0-9.]+)", install_body)
    assert_fault_resume_model(order)
    assert "clear_atomic_stage" in install_body
    assert '[[ "$SUPPORT_PRESENT_COUNT" -eq 3 ]]' in install_body
    assert '"$BUNDLE/shuzijun-app-content.php"' not in install_body

    support_verification = function_body(
        lines, "verify_support_hashes", "verify_installed_jwt_autoload"
    )
    assert "validate_completed_unit" in support_verification
    assert "grep -v '  shuzijun-app-content.php$'" in support_verification
    assert "sha256sum --strict --quiet --check -" in support_verification
    autoload_body = function_body(
        lines, "verify_installed_jwt_autoload", "handle_failure"
    )
    assert "runuser -u www-data -- env -i" in autoload_body
    assert 'require $root . "/vendor/autoload.php"' in autoload_body

    # Failure cleans only unpublished staging; it neither rolls back exact live
    # support nor changes FPM state.
    handle_start = line_number(lines, "handle_failure() {")
    trap_start = line_number(lines, "trap 'handle_failure $?'", handle_start + 1)
    handler = "\n".join(lines[handle_start:trap_start])
    assert "clear_atomic_stage" in handler
    assert "validate_resumable_support_state" in handler
    assert 'systemctl is-active --quiet "$FPM_SERVICE"' in handler
    assert "healthy legacy PHP remained online" in handler
    assert "audit-backup=" in handler
    assert "systemctl stop" not in handler
    assert "systemctl start" not in handler
    assert "remove_added_support" not in text
    assert "restore_legacy_state" not in text

    # Apply probes old health, writes/verifies a root-only audit backup, then
    # publishes support online and runs every final check. Dry-run exits first.
    dry_run = line_number(lines, 'if [[ "$MODE" == dry-run ]]', locked_validation)
    first_direct_probe = line_number(lines, "probe_direct_plugin_blocked", dry_run + 1)
    first_api_probe = line_number(lines, "probe_unauthorized_api", first_direct_probe + 1)
    active_precondition = line_number(
        lines, 'systemctl is-active --quiet "$FPM_SERVICE" || fail', first_api_probe
    )
    apply_role_gate = line_number(lines, "verify_authority_role", active_precondition + 1)
    backup = line_number(lines, "create_legacy_backup", apply_role_gate + 1)
    backup_verify = line_number(lines, "verify_legacy_backup", backup + 1)
    install_support = line_number(lines, "install_support_unit", backup_verify + 1)
    support_hash = line_number(lines, "verify_support_hashes", install_support + 1)
    autoload = line_number(lines, "verify_installed_jwt_autoload", support_hash + 1)
    active_postcondition = line_number(
        lines, 'systemctl is-active --quiet "$FPM_SERVICE"', autoload + 1
    )
    post_verify = line_number(lines, "run_webroot_verifier", active_postcondition + 1)
    post_role_gate = line_number(lines, "verify_authority_role", post_verify + 1)
    post_direct_probe = line_number(lines, "probe_direct_plugin_blocked", post_role_gate + 1)
    post_api_probe = line_number(lines, "probe_unauthorized_api", post_direct_probe + 1)
    assert dry_run < first_direct_probe < first_api_probe < active_precondition
    assert active_precondition < apply_role_gate < backup < backup_verify < install_support
    assert install_support < support_hash < autoload < active_postcondition
    assert active_postcondition < post_verify < post_role_gate < post_direct_probe < post_api_probe

    main_pre_dry_run = "\n".join(lines[locked_validation:dry_run])
    early_resume_validation = line_number(
        lines, "validate_resumable_support_state", locked_validation
    )
    apply_stage_cleanup_guard = line_number(
        lines, 'if [[ "$MODE" == apply ]]', early_resume_validation
    )
    apply_stage_cleanup = line_number(
        lines, "clear_atomic_stage", apply_stage_cleanup_guard
    )
    baseline = line_number(lines, "verify_baseline_no_http", apply_stage_cleanup)
    dry_role_gate = line_number(lines, "verify_authority_role", baseline + 1)
    assert (
        locked_validation
        < early_resume_validation
        < apply_stage_cleanup_guard
        < apply_stage_cleanup
        < baseline
        < dry_role_gate
        < dry_run
    )
    for prohibited in (
        "create_legacy_backup\n",
        "install_support_unit\n",
        "probe_direct_plugin_blocked\n",
        "probe_unauthorized_api\n",
    ):
        assert prohibited not in main_pre_dry_run

    direct_probe = function_body(
        lines, "probe_direct_plugin_blocked", "probe_unauthorized_api"
    )
    assert '--resolve "$HEALTH_HOST:443:127.0.0.1"' in direct_probe
    assert '[[ "$status" == 404 ]]' in direct_probe
    assert "return 1" in direct_probe
    api_probe = function_body(lines, "probe_unauthorized_api", "create_legacy_backup")
    for guard in (
        '[[ "$status" == 401 ]]',
        "application/json",
        "x-robots-tag:",
        "vary:.*authorization.*x-yishu-install-id",
    ):
        assert guard in api_probe

    backup_body = function_body(lines, "create_legacy_backup", "verify_legacy_backup")
    assert 'mkdir -m 0700 "$BACKUP_DIR"' in backup_body
    assert 'install -o root -g root -m 0600 "$LIVE_PHP"' in backup_body
    assert "sha256sum --strict --quiet --check" in backup_body
    assert "BACKUP_READY=1" in backup_body
    backup_validation = function_body(
        lines, "verify_legacy_backup", "clear_atomic_stage"
    )
    assert "legacy backup is accessible or writable outside root" in backup_validation
    assert "! -uid 0 -o -perm /077" in backup_validation
    assert "BACKUP_VERIFIED=1" in backup_validation
    assert "audit-backup-unverified" in handler

    for duplicate_guard in (
        "bundle option may be specified only once",
        "manifest SHA256 option may be specified only once",
        "legacy PHP SHA256 option may be specified only once",
        "authority role option may be specified only once",
        "bootstrap mode may be specified only once",
    ):
        assert duplicate_guard in text

    # The bridge never replaces/removes PHP or controls FPM state.
    assert 'systemctl stop "$FPM_SERVICE"' not in text
    assert 'systemctl start "$FPM_SERVICE"' not in text
    assert 'systemctl mask "$FPM_SERVICE"' not in text
    assert 'systemctl unmask "$FPM_SERVICE"' not in text
    for prohibited in (
        "wp db ",
        "wp-config.php",
        "wp-content/uploads",
        "mysql ",
        "rsync ",
        "YISHU_APPLE_PRIVATE_KEY_PATH",
        "YISHU_APPLE_DATA_KEY_PATH",
    ):
        assert prohibited not in text, f"bootstrap crossed forbidden boundary: {prohibited}"
    assert 'rm -rf -- "$TARGET_DIR"' not in text
    assert '"$BUNDLE/shuzijun-app-content.php" "$LIVE_PHP"' not in text

    subprocess.run(["bash", "-n", str(BOOTSTRAP)], check=True)
    subprocess.run(["bash", "-n", str(DEPLOYER)], check=True)
    help_result = subprocess.run(
        [str(BOOTSTRAP), "--help"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert "--legacy-php-sha256" in help_result.stdout
    assert "--authority-role authority" in help_result.stdout
    assert "standby legacy bootstrap is prohibited" in text
    assert 'env -i PATH="$PATH" LC_ALL=C LANG=C' in text
    assert 'verifier_sha256=$(sha256sum "$verifier_fd_path"' in text
    assert '[[ "$verifier_sha256" == "$AUTHORITY_VERIFY_SHA256" ]]' in text
    assert 'exec 7<"$AUTHORITY_VERIFY"' in text
    assert '/usr/bin/python3 -I /proc/self/fd/7 "$AUTHORITY_ROLE"' in text
    assert "stat -Lc '%u:%g:%h:%a'" in text
    assert "exec 7<&-" in text
    assert "for verifier_parent in /usr /usr/local /usr/local/sbin" in text
    assert "account-authority verifier parent is writable" in text
    assert 'exec 6<"$VERIFY"' in text
    assert 'sha256sum "$verifier_fd_path"' in text
    assert '[[ "$verifier_sha256" == "$VERIFY_SHA256" ]]' in text
    assert '/bin/bash /proc/self/fd/6 "$SITE"' in text
    assert '"$VERIFY" "$SITE"' not in text
    assert "default mode is --dry-run" in help_result.stdout
    assert "never replaces PHP or stops" in help_result.stdout
    assert "byte-exact subset" in help_result.stdout
    assert "--authority-role <authority|standby>" not in operations_readme
    assert "--authority-role <与本机实际配置一致的-authority或standby>" not in operations_readme
    assert "只允许在 authority 节点使用" in operations_readme

    print("bootstrap-legacy-app-content-release-contract-test: passed")


if __name__ == "__main__":
    main()
