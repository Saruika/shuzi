#!/usr/bin/env python3
"""Replace the backup node's local account API handler with the proxy include."""

import os
import pathlib
import tempfile


TARGET = pathlib.Path("/etc/nginx/sites-enabled/shuzijun-ssl.conf")
OLD_BLOCK = """    location ^~ /wp-json/shuzijun/v1/ {
        limit_req zone=sj_analytics burst=100 nodelay;
        try_files $uri $uri/ /index.php?$args;
    }
"""
NEW_BLOCK = "    include /etc/nginx/snippets/shuzijun-account-api-backup-proxy.conf;\n"


source = TARGET.read_text(encoding="utf-8")
if NEW_BLOCK in source and OLD_BLOCK not in source:
    print("backup-account-api-proxy state=already-current")
    raise SystemExit(0)
if source.count(OLD_BLOCK) != 1 or NEW_BLOCK in source:
    raise SystemExit("unexpected Nginx account API block; refusing edit")

updated = source.replace(OLD_BLOCK, NEW_BLOCK, 1)
metadata = TARGET.stat()
with tempfile.NamedTemporaryFile(
    mode="w",
    encoding="utf-8",
    dir=TARGET.parent,
    prefix=f".{TARGET.name}.",
    delete=False,
) as handle:
    temporary = pathlib.Path(handle.name)
    handle.write(updated)
    handle.flush()
    os.fsync(handle.fileno())

try:
    os.chmod(temporary, metadata.st_mode)
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    os.replace(temporary, TARGET)
finally:
    temporary.unlink(missing_ok=True)

print("backup-account-api-proxy state=installed")
