#!/usr/bin/env python3
"""Install the direct, non-CDN account API route into the apex TLS server."""

import os
import pathlib
import tempfile


TARGET = pathlib.Path("/etc/nginx/sites-enabled/shuzijun-ssl.conf")
SERVER_NAME = "server_name shuzijun.com.cn;"
REDIRECT = "return 301 https://www.shuzijun.com.cn$request_uri;"
INCLUDE = "include /etc/nginx/snippets/shuzijun-account-api-apex-route.conf;"


lines = TARGET.read_text(encoding="utf-8").splitlines(keepends=True)
name_indexes = [index for index, line in enumerate(lines) if line.strip() == SERVER_NAME]
if len(name_indexes) != 1:
    raise SystemExit("unexpected apex TLS server count")

name_index = name_indexes[0]
start = next(
    (index for index in range(name_index, -1, -1) if lines[index].strip() == "server {"),
    None,
)
if start is None:
    raise SystemExit("apex TLS server start not found")

depth = 0
end = None
for index in range(start, len(lines)):
    depth += lines[index].count("{") - lines[index].count("}")
    if depth == 0:
        end = index
        break
if end is None or not any("listen 443 ssl" in line for line in lines[start : end + 1]):
    raise SystemExit("unexpected apex TLS server block")

block = lines[start : end + 1]
if any(line.strip() == INCLUDE for line in block):
    if not any(REDIRECT in line for line in block):
        raise SystemExit("apex redirect missing from configured block")
    print("apex-account-api-route state=already-current")
    raise SystemExit(0)

redirect_indexes = [
    index for index in range(start, end + 1) if lines[index].strip() == REDIRECT
]
if len(redirect_indexes) != 1:
    raise SystemExit("unexpected apex redirect count")

redirect_index = redirect_indexes[0]
indent = lines[redirect_index][ : len(lines[redirect_index]) - len(lines[redirect_index].lstrip())]
lines[redirect_index : redirect_index + 1] = [
    f"{indent}{INCLUDE}\n",
    f"{indent}location / {{ {REDIRECT} }}\n",
]

metadata = TARGET.stat()
with tempfile.NamedTemporaryFile(
    mode="w",
    encoding="utf-8",
    dir=TARGET.parent,
    prefix=f".{TARGET.name}.",
    delete=False,
) as handle:
    temporary = pathlib.Path(handle.name)
    handle.writelines(lines)
    handle.flush()
    os.fsync(handle.fileno())

try:
    os.chmod(temporary, metadata.st_mode)
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    os.replace(temporary, TARGET)
finally:
    temporary.unlink(missing_ok=True)

print("apex-account-api-route state=installed")
