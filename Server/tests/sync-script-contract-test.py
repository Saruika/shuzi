from pathlib import Path


SCRIPT = Path("Server/operations/apply-shuzijun-sync")


def line_number(lines: list[str], fragment: str) -> int:
    for index, line in enumerate(lines):
        if fragment in line:
            return index
    raise AssertionError(f"missing required operation: {fragment}")


def main() -> None:
    lines = SCRIPT.read_text(encoding="utf-8").splitlines()

    assert lines[:2] == ["#!/bin/bash", "set -euo pipefail"]
    assert 'SITE=/var/www/html/shuzijun.com.cn' in lines
    assert 'STAGE=/tmp/shuzijun-stage' in lines

    checksum = line_number(lines, 'sha256sum -c "$MANIFEST"')
    backup = line_number(lines, 'wp db export "$DEST/wordpress.sql"')
    file_sync = line_number(lines, "rsync -a --delete")
    database_import = line_number(lines, 'wp db import "$STAGE/shuzijun-sync.sql"')
    schema_update = line_number(lines, "wp core update-db")
    cache_flush = line_number(lines, "wp cache flush --allow-root")
    nginx_check = line_number(lines, "nginx -t")
    service_restart = line_number(lines, "systemctl restart php8.3-fpm")

    assert checksum < backup < file_sync < database_import
    assert database_import < schema_update < cache_flush
    assert cache_flush < nginx_check < service_restart
    assert "--allow-root" in lines[cache_flush]
    assert any("cache=flushed" in line for line in lines)

    print("sync-script-contract-test: passed")


if __name__ == "__main__":
    main()
