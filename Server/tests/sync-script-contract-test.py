from pathlib import Path


RECEIVER = Path("Server/operations/apply-shuzijun-sync")
SENDER = Path("Server/operations/sync-to-backup")
VERIFIER = Path("Server/operations/verify-webroot-security")


def line_number(lines: list[str], fragment: str) -> int:
    for index, line in enumerate(lines):
        if fragment in line:
            return index
    raise AssertionError(f"missing required operation: {fragment}")


def verify_filters(text: str) -> None:
    for required in (
        "--exclude='*.php?*'",
        "--exclude='*.php.*'",
        "--exclude='*.bak*'",
        "--exclude='*.before-*'",
        "--exclude='.env*'",
        "--exclude='*.sql*'",
        "--exclude='*.key'",
        "--exclude='*.p8'",
        "--exclude='*.P8'",
        "--exclude='*.zip'",
    ):
        assert required in text, f"missing sync exclusion: {required}"


def main() -> None:
    receiver_text = RECEIVER.read_text(encoding="utf-8")
    sender_text = SENDER.read_text(encoding="utf-8")
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    lines = receiver_text.splitlines()

    assert lines[:2] == ["#!/bin/bash", "set -euo pipefail"]
    assert 'SITE=/var/www/html/shuzijun.com.cn' in lines
    assert 'STAGE=/tmp/shuzijun-stage' in lines

    checksum = line_number(lines, 'sha256sum -c "$MANIFEST"')
    preflight = line_number(lines, '"$VERIFY" "$SITE"')
    backup = line_number(lines, 'wp db export "$DEST/wordpress.sql"')
    file_sync = line_number(lines, "rsync -a --delete")
    database_import = line_number(lines, 'wp db import "$STAGE/shuzijun-sync.sql"')
    schema_update = line_number(lines, "wp core update-db")
    cache_flush = line_number(lines, "wp cache flush --allow-root")
    immutable_root = line_number(lines, 'install -d -o root -g www-data -m 755 "$wp_content"')
    ownership_safe_sync = line_number(lines, "rsync -a --delete --no-owner --no-group --chmod=D755,F644")
    code_hardening = line_number(lines, '! -name uploads ! -name cache')
    runtime_ownership = line_number(lines, 'chown -R www-data:www-data "$runtime_path"')
    nginx_check = line_number(lines, "nginx -t")
    service_restart = line_number(lines, "systemctl restart php8.3-fpm")

    assert preflight < checksum < backup < immutable_root < file_sync
    assert file_sync == ownership_safe_sync < code_hardening < runtime_ownership
    assert runtime_ownership < database_import
    assert database_import < schema_update < cache_flush
    assert cache_flush < nginx_check < service_restart
    assert "--allow-root" in lines[cache_flush]
    assert any("cache=flushed" in line for line in lines)
    assert receiver_text.count('"$VERIFY" "$SITE"') >= 2
    assert 'chown www-data:www-data "$wp_content"' not in receiver_text
    assert "--delete-excluded" in sender_text
    verify_filters(receiver_text)
    verify_filters(sender_text)
    assert "stat -c '%a %U:%G' \"$wp_content\"" in verifier_text
    assert "'755 root:www-data'" in verifier_text
    assert '-path "$wp_content/uploads"' in verifier_text
    assert '-path "$wp_content/cache"' in verifier_text
    assert "-type l -print -quit" in verifier_text
    assert "-iname '*.php' ! -name '*.php'" in verifier_text

    print("sync-script-contract-test: passed")


if __name__ == "__main__":
    main()
