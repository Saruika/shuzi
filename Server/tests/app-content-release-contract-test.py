from pathlib import Path


DEPLOYER = Path("Server/operations/deploy-app-content-release")
OPERATIONS_README = Path("Server/operations/README.md")


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


def main() -> None:
    text = DEPLOYER.read_text(encoding="utf-8")
    lines = text.splitlines()
    readme = OPERATIONS_README.read_text(encoding="utf-8")

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
    ):
        assert fixed_path in lines
    assert "LOCK_FILE=" not in text
    assert 'exec 9<"$LOCK_PATH"' in lines
    assert 'exec 9<>"$LOCK_PATH"' not in lines

    root_check = line_number(lines, '[[ "$EUID" -eq 0 ]]')
    lock_validation = line_number(lines, "validate_staging_lock_path", root_check + 1)
    lock_open = line_number(lines, 'exec 9<"$LOCK_PATH"', lock_validation + 1)
    lock_take = line_number(lines, "flock -n 9", lock_open + 1)
    fixed_validation = line_number(lines, "validate_fixed_paths", lock_take + 1)
    assert root_check < lock_validation < lock_open < lock_take < fixed_validation

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

    composer_body = function_body(lines, "run_composer", "preflight_release")
    for operation in (
        "env -i",
        "COMPOSER_HOME=/dev/null",
        "COMPOSER_CACHE_DIR=/dev/null",
        "--no-cache",
        "--no-plugins",
        "--no-scripts",
    ):
        assert operation in composer_body

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
    assert 'require $root . "/vendor/autoload.php"' not in preflight_body

    installed_autoload = function_body(
        lines, "verify_installed_jwt_autoload", "validate_target_boundary"
    )
    assert "runuser -u www-data -- env -i" in installed_autoload
    assert 'open_basedir=$TARGET_DIR' in installed_autoload
    assert 'require $root . "/vendor/autoload.php"' in installed_autoload

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

    probe_body = function_body(lines, "probe_unauthorized_api", "verify_live_release_hashes")
    assert "?rest_route=%2Fshuzijun%2Fv1%2Fapp-content" in text
    for probe_guard in (
        "curl -q",
        "--resolve \"$HEALTH_HOST:443:127.0.0.1\"",
        '[[ "$status" == 401 ]]',
        "application/json",
        "x-robots-tag:",
        "vary:.*authorization.*x-yishu-install-id",
    ):
        assert probe_guard in probe_body
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
    assert "ROLLBACK_READY=1" in backup_body

    removal_body = function_body(lines, "remove_live_vendor", "remove_live_metadata")
    assert "wp-content/mu-plugins/vendor" in removal_body
    assert 'rm -rf --one-file-system -- "$live_vendor"' in removal_body
    assert "|| return 1" in removal_body
    metadata_removal = function_body(
        lines, "remove_live_metadata", "install_release_unit"
    )
    assert "wp-content/mu-plugins/*" in metadata_removal
    assert 'rm -f -- "$TARGET_DIR/shuzijun-app-content.php"' in metadata_removal
    assert "|| return 1" in metadata_removal
    assert 'rm -rf -- "$TARGET_DIR"' not in text

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
    assert vendor_install < composer_json_install < composer_lock_install < plugin_install
    assert plugin_install < install_end

    rollback_body = function_body(lines, "restore_code_backup", "handle_failure")
    assert 'systemctl stop "$FPM_SERVICE"' in rollback_body
    assert "sha256sum --strict --quiet --check" in rollback_body
    assert '[[ "$restore_status" -eq 0 && "$FPM_WAS_ACTIVE" -eq 1 ]]' in rollback_body
    assert 'systemctl start "$FPM_SERVICE"' in rollback_body
    assert "Never restart PHP-FPM with a partial or unverified rollback" in rollback_body
    assert 'rm -rf -- "$TARGET_DIR"' not in rollback_body
    handle_start = line_number(lines, "handle_failure() {")
    trap_start = line_number(lines, "trap 'handle_failure $?'", handle_start + 1)
    handle_body = "\n".join(lines[handle_start:trap_start])
    assert "trap '' INT TERM HUP" in handle_body
    assert 'systemctl stop "$FPM_SERVICE"' in handle_body
    assert "PHP-FPM left stopped" in handle_body
    assert "PHP-FPM could not be stopped" in handle_body
    assert 'systemctl is-active --quiet "$FPM_SERVICE"' in handle_body

    dry_run = line_number(lines, 'if [[ "$MODE" == dry-run ]]')
    first_apply_probe = line_number(lines, "probe_unauthorized_api", dry_run + 1)
    backup = line_number(lines, "create_code_backup", first_apply_probe + 1)
    fpm_stop = line_number(lines, 'systemctl stop "$FPM_SERVICE"', backup + 1)
    install = line_number(lines, "install_release_unit", fpm_stop + 1)
    live_hash = line_number(lines, "verify_live_release_hashes", install + 1)
    autoload = line_number(lines, "verify_installed_jwt_autoload", live_hash + 1)
    fpm_start = line_number(lines, 'systemctl start "$FPM_SERVICE"', autoload + 1)
    post_verify = line_number(lines, '"$VERIFY" "$SITE"', fpm_start + 1)
    nginx_check = line_number(lines, "nginx -t", post_verify + 1)
    final_probe = line_number(lines, "probe_unauthorized_api", nginx_check + 1)
    rollback_disarm = line_number(lines, "ROLLBACK_READY=0", final_probe + 1)
    assert dry_run < first_apply_probe < backup < fpm_stop < install < live_hash
    assert live_hash < autoload < fpm_start < post_verify < nginx_check
    assert nginx_check < final_probe < rollback_disarm

    # No main-path call that can create backups, stop services, install code or
    # issue HTTP is allowed before the early dry-run exit.
    main_pre_dry_run = "\n".join(lines[fixed_validation:dry_run])
    assert "create_code_backup\n" not in main_pre_dry_run
    assert 'systemctl stop "$FPM_SERVICE"\n' not in main_pre_dry_run
    assert "install_release_unit\n" not in main_pre_dry_run
    assert "probe_unauthorized_api\n" not in main_pre_dry_run

    for duplicate_guard in (
        "bundle option may be specified only once",
        "manifest SHA256 option may be specified only once",
        "release mode may be specified only once",
    ):
        assert duplicate_guard in text

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
    ):
        assert documented_prerequisite in readme

    print("app-content-release-contract-test: passed")


if __name__ == "__main__":
    main()
