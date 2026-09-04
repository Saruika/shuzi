import hashlib
from pathlib import Path


SEED = Path("Server/operations/seed-standby-app-content-release")
DEPLOYER = Path("Server/operations/deploy-app-content-release")
AUTHORITY_VERIFIER = Path("Server/operations/verify-account-authority-role.py")
WEBROOT_VERIFIER = Path("Server/operations/verify-webroot-security")
README = Path("Server/operations/README.md")


def body(text: str, name: str, next_name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index(f"{next_name}() {{", start + 1)
    return text[start:end]


def main() -> None:
    text = SEED.read_text(encoding="utf-8")
    readme = README.read_text(encoding="utf-8")
    deployer = DEPLOYER.read_text(encoding="utf-8")
    deployer_sha = hashlib.sha256(DEPLOYER.read_bytes()).hexdigest()
    verifier_sha = hashlib.sha256(AUTHORITY_VERIFIER.read_bytes()).hexdigest()
    webroot_verifier_sha = hashlib.sha256(WEBROOT_VERIFIER.read_bytes()).hexdigest()

    assert text.startswith("#!/bin/bash\nset -Eeuo pipefail\numask 077\n")
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in text
    assert "unset CDPATH ENV http_proxy" in text
    assert f"readonly DEPLOYER_SHA256={deployer_sha}" in text
    assert f"readonly AUTHORITY_VERIFY_SHA256={verifier_sha}" in text
    assert f"readonly VERIFY_SHA256={webroot_verifier_sha}" in text
    assert 'exec 6<"$VERIFY"' in text
    assert "stat -Lc '%u:%g:%h:%a'" in text
    assert 'sha256sum "$verifier_fd_path"' in text
    assert '/bin/bash /proc/self/fd/6 "$SITE"' in text
    assert '"$VERIFY" "$SITE"' not in text
    assert "readonly AUTHORITY_LOCK_ROOT=/var/lib/shuzijun-sync" in text
    assert 'readonly AUTHORITY_LOCK_PATH="$AUTHORITY_LOCK_ROOT/site-operation.lock"' in text
    assert "readonly LOCK_PATH=\"$STAGING_ROOT\"" in text
    assert 'exec 8<"$AUTHORITY_LOCK_PATH"' in text
    assert 'exec 9<"$LOCK_PATH"' in text
    assert 'exec 8<>"$AUTHORITY_LOCK_PATH"' not in text
    assert 'exec 9<>"$LOCK_PATH"' not in text
    assert 'exec 10<"$AUTHORITY_LOCK_ROOT"' in text
    assert 'readonly AUTHORITY_LOCK_PATH="$SITE"' not in text
    assert 'exec 8<"$SITE"' not in text

    lock_root = body(text, "validate_authority_lock_root", "validate_authority_lock_path")
    assert "/var/lib/shuzijun-sync" in lock_root
    assert "0:0:700" in lock_root
    lock_path = body(text, "validate_authority_lock_path", "create_authority_lock_if_requested")
    assert "0:0:1:600:0" in lock_path
    assert "crosses a filesystem boundary" in lock_path
    lock_create = body(text, "create_authority_lock_if_requested", "acquire_authority_lock")
    for guard in (
        "os.O_EXCL",
        "os.O_NOFOLLOW",
        "metadata.st_nlink != 1",
        "metadata.st_size != 0",
        "os.fsync(descriptor)",
        "os.fsync(root_fd)",
    ):
        assert guard in lock_create
    lock_acquire = body(text, "acquire_authority_lock", "validate_digest")
    assert 'flock -n 10' in lock_acquire
    assert 'flock -n 8' in lock_acquire
    assert lock_acquire.count("validate_authority_lock_path") == 2
    assert "site-operation lock inode changed after acquisition" in lock_acquire
    assert 'rm ' not in lock_acquire and 'unlink' not in lock_acquire

    parser = text[text.index("while [[ $# -gt 0 ]]"):]
    for option in (
        "--bundle",
        "--manifest-sha256",
        "--legacy-php-sha256",
        "--approved-plan-sha256",
        "--confirm-writers-drained",
        "--dry-run",
        "--apply",
    ):
        assert option in parser
    assert "--authority-role" not in parser
    assert "fixed account-authority role is not exact standby" in text
    assert "/usr/bin/python3 -I /proc/self/fd/7 standby" in text

    fpm = body(text, "verify_fpm_isolated", "resolve_php")
    assert '"$enabled" == masked' in fpm
    assert '"$active" == inactive' in fpm
    assert '"$sub" == dead' in fpm
    assert "systemctl unmask" not in text
    assert "systemctl start" not in text
    assert "systemctl restart" not in text
    assert "systemctl enable" not in text

    preflight = text.index('"$DEPLOYER" --bundle "$BUNDLE_INPUT"')
    authority = text.index("verify_standby_role", text.index("acquire_authority_lock\n"))
    fpm_first = text.index("verify_fpm_isolated", text.index("validate_tool \"$DEPLOYER\""))
    write_first = text.index("create_backup\nprepare_stage")
    plan_check = text.index('[[ "$APPROVED_PLAN_SHA256" == "$PLAN_SHA256" ]]')
    assert fpm_first < authority < preflight < plan_check < write_first
    assert "--bundle-preflight" in text
    candidate_probe = body(
        deployer, "probe_candidate_collaboration_release_fuse", "preflight_release"
    )
    deployer_preflight = body(
        deployer, "preflight_release", "verify_installed_jwt_autoload"
    )
    assert 'define("YISHU_ENABLE_COLLABORATION_PHASE1", true);' in candidate_probe
    assert 'if (!$has_gate && !$has_fuse) {' in candidate_probe
    assert '$sourceMode === "legacy"' in candidate_probe
    assert 'source_hashes=("$LEGACY_BRIDGE_PHP_SHA256")' in candidate_probe
    assert 'hash_equals($sourceHashes[$index], hash("sha256", $source))' in candidate_probe
    assert 'if ($sourceMode !== "legacy") { exit(24); }' in candidate_probe
    assert 'candidate plugin exited before the isolated fuse probe completed' in candidate_probe
    assert 'if (constant($fuse) !== false) { exit(22); }' in candidate_probe
    assert 'if ($class::$gate() !== false) { exit(23); }' in candidate_probe
    assert 'fwrite(STDOUT, $sentinel . "\\n");' in candidate_probe
    assert "probe_candidate_collaboration_release_fuse" in deployer_preflight
    assert deployer_preflight.index(
        "probe_candidate_collaboration_release_fuse"
    ) < deployer_preflight.index('run_composer --working-dir="$BUNDLE" validate')
    assert "plan-sha256=%s" in text
    assert "approved plan SHA256 does not match" in text

    manifest = body(text, "validate_bundle_locked", "validate_legacy_state")
    for artifact in (
        "shuzijun-app-content.php",
        "composer.json",
        "composer.lock",
        "vendor/autoload.php",
        "vendor/composer/installed.php",
        "release.sha256",
    ):
        assert artifact in manifest
    assert "sha256sum --strict --quiet --check" in manifest
    assert "Version: 1.5.8" in manifest

    legacy = body(text, "validate_legacy_state", "compute_plan")
    assert "Version: 1.5.7" in legacy
    assert "expected single-file state" in legacy
    assert "EXPECTED_LEGACY_PHP_SHA256" in legacy

    publish = body(text, "publish_release", "validate_complete_release")
    assert "verify_fpm_isolated" in publish
    assert "vendor composer.lock composer.json shuzijun-app-content.php release.sha256" in publish
    assert 'mv -T -- "$STAGE_DIR/$relative" "$TARGET_DIR/$relative"' in publish
    stage = body(text, "prepare_stage", "create_backup")
    assert '-exec chmod a-s,a-t,u=rwx,g=rx,o=rx {} +' in stage
    assert '-exec chmod a-s,u=rwx,g=rx,o=rx {} +' not in stage
    assert '-exec chmod u=rwx,g=rx,o=rx {} +' not in stage
    assert '-exec chmod 0755 {} +' not in stage
    complete = body(text, "validate_complete_release", "verify_jwt_as_worker")
    assert "sha256sum --strict --quiet --check release.sha256" in complete
    assert "installed vendor contains a symbolic link" in complete

    offline = body(text, "probe_offline_query_forms", "rollback")
    assert "/?rest_route=%2Fshuzijun%2Fv1%2Fapp-content" in offline
    assert "/index.php?rest_route=%2Fshuzijun%2Fv1%2Fapp-content" in offline
    assert "yishu_account_authority_unavailable" in offline
    assert "array(503" in offline
    assert 'runuser -u www-data -- env -i' in offline

    rollback = body(text, "rollback", "handle_failure")
    assert "verify_fpm_isolated" in rollback
    assert "remove_release_entries" in rollback
    assert "validate_legacy_state" in rollback
    failure = text[text.index("handle_failure() {"):text.index("trap 'handle_failure")]
    assert "rollback" in failure
    assert "clear_stage" in failure
    assert "verify_fpm_isolated" in failure

    forbidden_invocation = "bootstrap-legacy-app-content-release"
    executable_lines = [
        line for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    assert all(forbidden_invocation not in line for line in executable_lines)
    assert "sync-to-backup" not in text
    assert 'cp -a -- "$SITE"' not in text
    assert 'cp -R -- "$SITE"' not in text
    assert "database" in text

    for phrase in (
        "seed-standby-app-content-release",
        "--approved-plan-sha256",
        "--confirm-writers-drained",
        "masked`、`inactive`、`dead",
        "`bootstrap-legacy-app-content-release`",
    ):
        assert phrase in readme

    print("standby-seed-contract-test: passed")


if __name__ == "__main__":
    main()
