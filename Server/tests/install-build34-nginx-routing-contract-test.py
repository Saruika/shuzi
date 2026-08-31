#!/usr/bin/env python3
"""Fake-filesystem/command contract for the Build 34 Nginx installer."""

from __future__ import annotations

import copy
import contextlib
import fnmatch
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
INSTALLER_PATH = ROOT / "operations" / "install-build34-nginx-routing"
LOADER = importlib.machinery.SourceFileLoader("build34_nginx_installer", str(INSTALLER_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = MODULE
LOADER.exec_module(MODULE)


ACTIVE = Path("/etc/nginx/sites-enabled/shuzijun-ssl.conf")
AVAILABLE = Path("/etc/nginx/sites-available/shuzijun-ssl.conf")
SENSITIVE_SOURCE = Path("/root/stage/shuzijun-sensitive-files-deny.conf")
LEGACY_SOURCE = Path("/root/stage/shuzijun-legacy-images-alias.conf")
SENSITIVE_TARGET = Path("/etc/nginx/snippets/shuzijun-sensitive-files-deny.conf")
LEGACY_TARGET = Path("/etc/nginx/snippets/shuzijun-legacy-images-alias.conf")
ACCOUNT_API_TARGET = Path(
    "/etc/nginx/snippets/shuzijun-account-api-backup-proxy.conf"
)
SECURITY_INCLUDE = Path("/etc/nginx/snippets/shuzijun-security.conf")
FASTCGI_PHP_INCLUDE = Path("/etc/nginx/snippets/fastcgi-php.conf")
FASTCGI_BASE_INCLUDE = Path("/etc/nginx/fastcgi.conf")
BACKUP = Path("/var/backups/shuzijun-nginx-build34/test-transaction")
WEBROOT_IMAGES = Path("/var/www/html/shuzijun.com.cn/images")
REVIEWED_SENSITIVE = (ROOT / "nginx" / "shuzijun-sensitive-files-deny.conf").read_bytes()
REVIEWED_LEGACY = (ROOT / "nginx" / "shuzijun-legacy-images-alias.conf").read_bytes()
REVIEWED_SECURITY_INCLUDE = b"".join(
    f'add_header X-Build34-{index} "reviewed-{index}" always;\n'.encode()
    for index in range(1, 8)
)
REVIEWED_FASTCGI_PHP_INCLUDE = (
    b'fastcgi_split_path_info "^(.+?\\.php)(/.*)$";\n'
    b"try_files $fastcgi_script_name =404;\n"
    b"set $path_info $fastcgi_path_info;\n"
    b"fastcgi_param PATH_INFO $path_info;\n"
    b"fastcgi_index index.php;\n"
    b"include fastcgi.conf;\n"
)
REVIEWED_FASTCGI_BASE_INCLUDE = (
    b"fastcgi_param QUERY_STRING $query_string;\n"
    b"fastcgi_param REQUEST_METHOD $request_method;\n"
    b"fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n"
    b"fastcgi_param DOCUMENT_ROOT $document_root;\n"
    b"fastcgi_param SCRIPT_NAME $fastcgi_script_name;\n"
    b"fastcgi_param REQUEST_URI $request_uri;\n"
    b"fastcgi_param SERVER_NAME $server_name;\n"
    b"fastcgi_param REDIRECT_STATUS 200;\n"
)


def file_state(
    data: bytes,
    *,
    mode: int = 0o644,
    uid: int = 0,
    gid: int = 0,
    nlink: int = 1,
):
    return MODULE.FileState("file", data, mode, uid, gid, nlink=nlink)


def symlink_state(target: str, *, uid: int = 0, gid: int = 0):
    return MODULE.FileState("symlink", mode=0o777, uid=uid, gid=gid, target=target)


class FakeFilesystem:
    """Deterministic in-memory filesystem with atomic-operation tracing."""

    def __init__(self, entries: dict[Path, object]) -> None:
        self.entries = copy.deepcopy(entries)
        self.directories = {
            ACTIVE.parent,
            AVAILABLE.parent,
            SENSITIVE_TARGET.parent,
            SENSITIVE_SOURCE.parent,
            BACKUP.parent,
        }
        self.operations: list[tuple[str, str]] = []
        self.backups: dict[Path, dict[str, object]] = {}
        self.on_snapshot = None
        self.snapshot_count = 0
        self.fail_after_atomic: int | None = None
        self.atomic_count = 0

    def require_secure_directory(self, path: Path, owner_uid: int, label: str) -> None:
        if path not in self.directories:
            raise MODULE.InstallError(f"{label} is missing: {path}")

    def snapshot(self, path: Path, allow_absent: bool = False):
        self.snapshot_count += 1
        if self.on_snapshot is not None:
            self.on_snapshot(self, path, self.snapshot_count)
        state = self.entries.get(path)
        if state is None:
            if allow_absent:
                return MODULE.FileState("absent")
            raise MODULE.InstallError(f"required path is missing: {path}")
        return copy.deepcopy(state)

    def atomic_write(self, path: Path, data: bytes, mode: int, uid: int, gid: int) -> None:
        self.operations.append(("write", str(path)))
        self.entries[path] = file_state(data, mode=mode, uid=uid, gid=gid)
        self.atomic_count += 1
        if self.fail_after_atomic == self.atomic_count:
            raise MODULE.InstallError(
                f"injected post-replace atomic failure {self.atomic_count}"
            )

    def atomic_symlink(self, path: Path, target: str, uid: int, gid: int) -> None:
        self.operations.append(("symlink", str(path)))
        self.entries[path] = symlink_state(target, uid=uid, gid=gid)
        self.atomic_count += 1
        if self.fail_after_atomic == self.atomic_count:
            raise MODULE.InstallError(
                f"injected post-replace atomic failure {self.atomic_count}"
            )

    def restore(self, path: Path, state) -> None:
        self.operations.append(("restore", str(path)))
        if state.kind == "absent":
            self.entries.pop(path, None)
        else:
            self.entries[path] = copy.deepcopy(state)

    def create_backup(self, path: Path, states: dict[str, object]) -> None:
        if path in self.backups:
            raise MODULE.InstallError("backup transaction already exists")
        self.operations.append(("backup", str(path)))
        self.backups[path] = copy.deepcopy(states)

    def resolve(self, path: Path) -> Path:
        state = self.entries.get(path)
        if state is None:
            raise FileNotFoundError(path)
        if state.kind != "symlink":
            return Path(os.path.normpath(str(path)))
        target = Path(state.target)
        if not target.is_absolute():
            target = path.parent / target
        return Path(os.path.normpath(str(target)))

    @contextlib.contextmanager
    def lock(self, path: Path):
        self.operations.append(("lock", str(path)))
        yield

    def enabled_documents(self, path: Path) -> dict[Path, bytes]:
        result: dict[Path, bytes] = {}
        for entry, state in sorted(self.entries.items(), key=lambda item: str(item[0])):
            if entry.parent != path:
                continue
            selected = state
            if selected.kind == "symlink":
                if selected.uid != 0 or selected.gid != 0 or selected.nlink != 1:
                    raise MODULE.InstallError(
                        f"enabled Nginx symlink must be root:root with one link: {entry}"
                    )
                direct_target = MODULE.lexical_symlink_target(entry, selected)
                if direct_target.parent != AVAILABLE.parent:
                    raise MODULE.InstallError(
                        f"enabled Nginx symlink target is outside sites-available: {entry}"
                    )
                selected = self.snapshot(direct_target)
                MODULE.require_root_config(
                    selected, direct_target, "enabled Nginx symlink target"
                )
            else:
                MODULE.require_root_config(selected, entry, "enabled Nginx config")
            result[entry] = selected.data
        return result

    def secure_include_matches(self, raw_path: str, nginx_root: Path):
        if "$" in raw_path or "\x00" in raw_path or "\\" in raw_path:
            raise MODULE.InstallError("dynamic or escaped Nginx include path is not allowed")
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            candidate = nginx_root / candidate
        candidate = Path(os.path.normpath(str(candidate)))
        if candidate != nginx_root and nginx_root not in candidate.parents:
            raise MODULE.InstallError("Nginx include escapes the reviewed root")
        matches = [
            path
            for path in self.entries
            if fnmatch.fnmatchcase(str(path), str(candidate))
        ]
        if not matches:
            raise MODULE.InstallError(f"Nginx include matched no files: {raw_path}")
        result = {}
        for path in sorted(matches):
            state = self.snapshot(path)
            MODULE.require_root_config(state, path, "included Nginx file")
            result[path] = copy.deepcopy(state)
        return result


class FakeRunner:
    def __init__(self, fail_call: int | None = None) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.fail_call = fail_call

    def run(self, command) -> None:
        self.calls.append(tuple(command))
        if self.fail_call == len(self.calls):
            raise MODULE.InstallError(f"injected command failure {self.fail_call}")


def active_config(node_marker: str = "primary-shanghai") -> bytes:
    return (
        "# misleading: server { server_name img.shuzijun.com.cn; }\n"
        "server {\n"
        "    listen 443 ssl http2;\n"
        "    server_name www.shuzijun.com.cn;\n"
        "    root /var/www/html/shuzijun.com.cn;\n"
        f"    set $node_marker \"{node_marker}\";\n"
        "    set $quoted \"# location ^~ /images/ { fake; }\";\n"
        "    include /etc/nginx/snippets/shuzijun-sensitive-files-deny.conf; # keep-comment\n"
        "    proxy_set_header X-Node primary-upstream;\n"
        "    location ^~ /wp-json/shuzijun/v1/ {\n"
        "        limit_req zone=sj_analytics burst=100 nodelay;\n"
        "        try_files $uri $uri/ /index.php?$args;\n"
        "        add_header X-Node-Account primary-direct-preserved;\n"
        "    }\n"
        "    location = /favicon.ico { return 204; }\n"
        "    location = /robots.txt { return 204; }\n"
        "    location ~ \"^/health/[0-9]{1,5}$\" { return 204; }\n"
        "}\n"
        "server {\n"
        "    listen [::]:443 ssl;\n"
        "    server_name img.shuzijun.com.cn _;\n"
        "    root /var/www/html/shuzijun.com.cn;\n"
        "    include /etc/nginx/snippets/shuzijun-sensitive-files-deny.conf;\n"
        "    location ^~ /images/ {\n"
        "        alias /var/www/html/shuzijun.com.cn/wp-content/uploads/hero-images/;\n"
        "        expires 365d;\n"
        "        add_header X-Origin-Node preserved-node-specific;\n"
        "    }\n"
        "    location / { try_files $uri =404; }\n"
        "}\n"
        "server {\n"
        "    listen 443 ssl;\n"
        "    server_name shuzijun.com.cn;\n"
        "    include /etc/nginx/snippets/node-specific-apex-route.conf;\n"
        "}\n"
    ).encode()


def php_include_active_config() -> bytes:
    config = active_config()
    config = config.replace(
        b"    include /etc/nginx/snippets/shuzijun-sensitive-files-deny.conf; # keep-comment\n",
        (
            b"    include /etc/nginx/snippets/shuzijun-security.conf;\n"
            b"    include /etc/nginx/snippets/shuzijun-sensitive-files-deny.conf; # keep-comment\n"
        ),
        1,
    )
    return config.replace(
        b'    location ~ "^/health/[0-9]{1,5}$" { return 204; }\n',
        (
            b'    location ~ "\\.php$" {\n'
            b"        include snippets/fastcgi-php.conf;\n"
            b"        fastcgi_pass unix:/run/php/php8.3-fpm.sock;\n"
            b"    }\n"
        ),
        1,
    )


def add_reviewed_include_entries(entries: dict[Path, object]) -> None:
    entries[SECURITY_INCLUDE] = file_state(REVIEWED_SECURITY_INCLUDE)
    entries[FASTCGI_PHP_INCLUDE] = file_state(REVIEWED_FASTCGI_PHP_INCLUDE)
    entries[FASTCGI_BASE_INCLUDE] = file_state(REVIEWED_FASTCGI_BASE_INCLUDE)


def backup_account_api_snippet() -> bytes:
    return (
        "# backup proxy route; comments and body bytes must survive\n"
        "location ^~ /wp-json/shuzijun/v1/ {\n"
        "    limit_req zone=sj_account_api burst=30 nodelay;\n"
        "    set $yishu_client_ip $remote_addr;\n"
        "    if ($remote_addr ~ ^(?:127\\.0\\.0\\.1|::1)$) {\n"
        "        set $yishu_client_ip $http_x_yishu_client_ip;\n"
        "    }\n"
        "    proxy_pass http://127.0.0.1:9080;\n"
        "    proxy_set_header X-Account-Node backup-singapore-preserved;\n"
        "}\n"
    ).encode()


def backup_active_config(node_marker: str = "backup-singapore") -> bytes:
    direct_block = (
        b"    location ^~ /wp-json/shuzijun/v1/ {\n"
        b"        limit_req zone=sj_analytics burst=100 nodelay;\n"
        b"        try_files $uri $uri/ /index.php?$args;\n"
        b"        add_header X-Node-Account primary-direct-preserved;\n"
        b"    }\n"
    )
    replacement = (
        b"    include /etc/nginx/snippets/"
        b"shuzijun-account-api-backup-proxy.conf;\n"
    )
    return active_config(node_marker).replace(direct_block, replacement, 1).replace(
        b"proxy_set_header X-Node primary-upstream;",
        b"proxy_set_header X-Node backup-upstream;",
        1,
    )


def old_location_hash(config: bytes) -> str:
    document = MODULE.parse(config.decode(), "fixture")
    img = MODULE.unique_tls_server(document, MODULE.IMG_HOST)
    location = MODULE.images_location(img)[0]
    return MODULE.sha256(config.decode()[location.start : location.end].encode())


def account_old_hashes(
    config: bytes, account_snippet: bytes | None
) -> tuple[str | None, str | None]:
    state = (
        file_state(account_snippet)
        if account_snippet is not None
        else MODULE.FileState("absent")
    )
    rewrite = MODULE.rewrite_account_api_routes(
        config,
        state,
        None,
        None,
        apply=False,
        source="fixture",
    )
    return rewrite.old_direct_sha256, rewrite.old_snippet_sha256


def initial_entries(
    config: bytes | None = None,
    *,
    account_snippet: bytes | None = None,
) -> dict[Path, object]:
    current = config or active_config()
    entries = {
        ACTIVE: file_state(current),
        AVAILABLE: file_state(b"# stale sites-available copy\n"),
        SENSITIVE_SOURCE: file_state(REVIEWED_SENSITIVE),
        LEGACY_SOURCE: file_state(REVIEWED_LEGACY),
        SENSITIVE_TARGET: file_state(b"# old sensitive snippet\n"),
        LEGACY_TARGET: file_state(b"# old legacy snippet\n"),
        WEBROOT_IMAGES: symlink_state("wp-content/uploads/hero-images"),
    }
    if account_snippet is not None:
        entries[ACCOUNT_API_TARGET] = file_state(account_snippet)
    return entries


def install_arguments(
    entries: dict[Path, object],
    *,
    apply: bool,
    old_hash_override: str | None = None,
) -> dict[str, object]:
    active = entries[ACTIVE]
    available = entries[AVAILABLE]
    active_data = active.data if active.kind == "file" else available.data
    sensitive_source = entries[SENSITIVE_SOURCE]
    legacy_source = entries[LEGACY_SOURCE]
    sensitive_target = entries.get(SENSITIVE_TARGET)
    legacy_target = entries.get(LEGACY_TARGET)
    account_api_target = entries.get(ACCOUNT_API_TARGET)
    direct_old_hash, snippet_old_hash = account_old_hashes(
        active_data,
        account_api_target.data if account_api_target is not None else None,
    )
    return {
        "active": ACTIVE,
        "available": AVAILABLE,
        "sensitive_source": SENSITIVE_SOURCE,
        "legacy_source": LEGACY_SOURCE,
        "sensitive_target": SENSITIVE_TARGET,
        "legacy_target": LEGACY_TARGET,
        "account_api_target": ACCOUNT_API_TARGET,
        "expected_active_sha256": MODULE.sha256(active_data),
        "expected_available_sha256": MODULE.sha256(available.data),
        "expected_sensitive_target": (
            MODULE.sha256(sensitive_target.data) if sensitive_target else "absent"
        ),
        "expected_legacy_target": (
            MODULE.sha256(legacy_target.data) if legacy_target else "absent"
        ),
        "expected_account_api_snippet": (
            MODULE.sha256(account_api_target.data) if account_api_target else "absent"
        ),
        "sensitive_source_sha256": MODULE.sha256(sensitive_source.data),
        "legacy_source_sha256": MODULE.sha256(legacy_source.data),
        "expected_old_location_sha256": old_hash_override or old_location_hash(active_data),
        "expected_old_direct_account_api_sha256": direct_old_hash or "absent",
        "expected_old_snippet_account_api_sha256": snippet_old_hash or "absent",
        "backup_dir": BACKUP,
        "apply": apply,
    }


def make_installer(filesystem: FakeFilesystem, runner: FakeRunner):
    return MODULE.Installer(
        filesystem,
        runner,
        nginx_test=("fake-nginx", "-t"),
        nginx_reload=("fake-systemctl", "reload", "nginx"),
        nginx_active=("fake-systemctl", "is-active", "--quiet", "nginx"),
    )


def fully_migrated(
    config: bytes, account_snippet: bytes | None
) -> tuple[bytes, bytes | None, str]:
    direct_old_hash, snippet_old_hash = account_old_hashes(config, account_snippet)
    account_state = (
        file_state(account_snippet)
        if account_snippet is not None
        else MODULE.FileState("absent")
    )
    account_rewrite = MODULE.rewrite_account_api_routes(
        config,
        account_state,
        direct_old_hash or "absent",
        snippet_old_hash or "absent",
        apply=True,
        source="fixture",
    )
    image_hash = old_location_hash(account_rewrite.active_content)
    migrated_config = MODULE.rewrite_active_config(
        account_rewrite.active_content, image_hash, "fixture"
    ).content
    return migrated_config, account_rewrite.snippet_content, image_hash


def assert_dry_run_uses_only_active() -> None:
    entries = initial_entries()
    filesystem = FakeFilesystem(entries)
    runner = FakeRunner()
    result = make_installer(filesystem, runner).install(
        **install_arguments(entries, apply=False)
    )
    assert result.state == "rewrite-required"
    assert result.account_api_state == "direct-rewrite-required"
    assert result.old_direct_account_api_sha256 is not None
    assert result.old_snippet_account_api_sha256 is None
    assert result.account_api_content is None
    assert b"primary-shanghai" in result.content
    assert b"primary-upstream" in result.content
    assert b"node-specific-apex-route.conf" in result.content
    assert (
        b"shuzijun-sensitive-files-deny.conf; # keep-comment\n"
        b"    include /etc/nginx/snippets/shuzijun-legacy-images-alias.conf;\n"
        in result.content
    )
    assert b"stale sites-available" not in result.content
    assert b"location /wp-json/shuzijun/v1/ {" in result.content
    assert b"location ^~ /wp-json/shuzijun/v1/ {" not in result.content
    assert b"primary-direct-preserved" in result.content
    assert result.content.count(MODULE.LEGACY_INCLUDE.encode()) == 2
    parsed = MODULE.parse(result.content.decode(), "dry-run candidate")
    assert not MODULE.images_location(MODULE.unique_tls_server(parsed, MODULE.IMG_HOST))
    assert filesystem.entries == entries
    assert not filesystem.operations and not runner.calls and not filesystem.backups

    inventory_arguments = install_arguments(entries, apply=False)
    inventory_arguments["expected_old_location_sha256"] = None
    inventory_arguments["expected_old_direct_account_api_sha256"] = None
    inventory = make_installer(filesystem, runner).install(**inventory_arguments)
    assert inventory.old_location_sha256 == old_location_hash(entries[ACTIVE].data)
    assert inventory.old_direct_account_api_sha256 == account_old_hashes(
        entries[ACTIVE].data, None
    )[0]


def assert_apply_requires_reviewed_location_hash() -> None:
    entries = initial_entries()
    filesystem = FakeFilesystem(entries)
    arguments = install_arguments(entries, apply=True)
    arguments["expected_old_location_sha256"] = None
    try:
        make_installer(filesystem, FakeRunner()).install(**arguments)
    except MODULE.InstallError as error:
        assert "mandatory with --apply" in str(error), error
    else:
        raise AssertionError("apply accepted an unreviewed old location")
    assert not filesystem.operations and not filesystem.backups


def assert_successful_transaction() -> None:
    entries = initial_entries()
    originals = copy.deepcopy(entries)
    filesystem = FakeFilesystem(entries)
    runner = FakeRunner()
    result = make_installer(filesystem, runner).install(
        **install_arguments(entries, apply=True)
    )
    assert result.state == "rewrite-required"
    assert result.account_api_state == "direct-rewrite-required"
    assert filesystem.entries[ACTIVE].kind == "symlink"
    assert filesystem.entries[ACTIVE].target == "../sites-available/shuzijun-ssl.conf"
    assert filesystem.entries[AVAILABLE].data == result.content
    assert filesystem.entries[SENSITIVE_TARGET].data == entries[SENSITIVE_SOURCE].data
    assert filesystem.entries[LEGACY_TARGET].data == entries[LEGACY_SOURCE].data
    assert ACCOUNT_API_TARGET not in filesystem.entries
    assert filesystem.entries[WEBROOT_IMAGES] == originals[WEBROOT_IMAGES]
    assert filesystem.operations[:6] == [
        ("lock", str(ACTIVE.parent)),
        ("backup", str(BACKUP)),
        ("write", str(SENSITIVE_TARGET)),
        ("write", str(LEGACY_TARGET)),
        ("write", str(AVAILABLE)),
        ("symlink", str(ACTIVE)),
    ]
    assert runner.calls == [
        ("fake-nginx", "-t"),
        ("fake-systemctl", "is-active", "--quiet", "nginx"),
        ("fake-nginx", "-t"),
        ("fake-systemctl", "reload", "nginx"),
        ("fake-systemctl", "is-active", "--quiet", "nginx"),
    ]
    backed_up = filesystem.backups[BACKUP]
    assert backed_up["active"] == originals[ACTIVE]
    assert backed_up["available"] == originals[AVAILABLE]
    assert backed_up["sensitive-snippet"] == originals[SENSITIVE_TARGET]
    assert backed_up["legacy-snippet"] == originals[LEGACY_TARGET]
    assert backed_up["account-api-snippet"] == MODULE.FileState("absent")


def assert_backup_account_api_transaction() -> None:
    account_snippet = backup_account_api_snippet()
    entries = initial_entries(
        backup_active_config(), account_snippet=account_snippet
    )
    originals = copy.deepcopy(entries)

    dry_filesystem = FakeFilesystem(entries)
    dry_result = make_installer(dry_filesystem, FakeRunner()).install(
        **install_arguments(entries, apply=False)
    )
    expected_snippet = account_snippet.replace(
        b"location ^~ /wp-json/shuzijun/v1/ {",
        b"location /wp-json/shuzijun/v1/ {",
        1,
    )
    assert dry_result.state == "rewrite-required"
    assert dry_result.account_api_state == "snippet-rewrite-required"
    assert dry_result.account_api_content == expected_snippet
    assert dry_result.old_direct_account_api_sha256 is None
    assert dry_result.old_snippet_account_api_sha256 == account_old_hashes(
        entries[ACTIVE].data, account_snippet
    )[1]
    assert b"backup-singapore" in dry_result.content
    assert b"backup-upstream" in dry_result.content
    assert MODULE.ACCOUNT_API_INCLUDE.encode() in dry_result.content
    assert b"backup-singapore-preserved" in expected_snippet
    assert dry_filesystem.entries == originals
    assert not dry_filesystem.operations and not dry_filesystem.backups

    filesystem = FakeFilesystem(entries)
    runner = FakeRunner()
    result = make_installer(filesystem, runner).install(
        **install_arguments(entries, apply=True)
    )
    assert result.content == dry_result.content
    assert result.account_api_content == expected_snippet
    assert filesystem.entries[ACCOUNT_API_TARGET].data == expected_snippet
    assert filesystem.entries[WEBROOT_IMAGES] == originals[WEBROOT_IMAGES]
    assert filesystem.operations[:7] == [
        ("lock", str(ACTIVE.parent)),
        ("backup", str(BACKUP)),
        ("write", str(SENSITIVE_TARGET)),
        ("write", str(LEGACY_TARGET)),
        ("write", str(ACCOUNT_API_TARGET)),
        ("write", str(AVAILABLE)),
        ("symlink", str(ACTIVE)),
    ]
    assert runner.calls == [
        ("fake-nginx", "-t"),
        ("fake-systemctl", "is-active", "--quiet", "nginx"),
        ("fake-nginx", "-t"),
        ("fake-systemctl", "reload", "nginx"),
        ("fake-systemctl", "is-active", "--quiet", "nginx"),
    ]
    assert filesystem.backups[BACKUP] == {
        "active": originals[ACTIVE],
        "available": originals[AVAILABLE],
        "sensitive-snippet": originals[SENSITIVE_TARGET],
        "legacy-snippet": originals[LEGACY_TARGET],
        "account-api-snippet": originals[ACCOUNT_API_TARGET],
    }


def assert_backup_account_api_failures_roll_back() -> None:
    for fail_call in (3, 4, 5):
        entries = initial_entries(
            backup_active_config(), account_snippet=backup_account_api_snippet()
        )
        originals = copy.deepcopy(entries)
        filesystem = FakeFilesystem(entries)
        try:
            make_installer(filesystem, FakeRunner(fail_call=fail_call)).install(
                **install_arguments(entries, apply=True)
            )
        except MODULE.InstallError as error:
            assert "exact rollback completed" in str(error), (fail_call, error)
        else:
            raise AssertionError(
                f"backup command failure {fail_call} unexpectedly succeeded"
            )
        assert filesystem.entries == originals, fail_call
        assert filesystem.backups[BACKUP]["account-api-snippet"] == originals[
            ACCOUNT_API_TARGET
        ]

    for atomic_point in range(1, 6):
        entries = initial_entries(
            backup_active_config(), account_snippet=backup_account_api_snippet()
        )
        originals = copy.deepcopy(entries)
        filesystem = FakeFilesystem(entries)
        filesystem.fail_after_atomic = atomic_point
        try:
            make_installer(filesystem, FakeRunner()).install(
                **install_arguments(entries, apply=True)
            )
        except MODULE.InstallError as error:
            assert "exact rollback completed" in str(error), (atomic_point, error)
            assert "post-replace atomic failure" in str(error), (atomic_point, error)
        else:
            raise AssertionError(
                f"backup atomic failure {atomic_point} unexpectedly succeeded"
            )
        assert filesystem.entries == originals, atomic_point


def assert_account_api_gates_and_topology() -> None:
    def expect_failure(
        entries: dict[Path, object],
        arguments: dict[str, object],
        message: str,
    ) -> None:
        filesystem = FakeFilesystem(entries)
        try:
            make_installer(filesystem, FakeRunner()).install(**arguments)
        except MODULE.InstallError as error:
            assert message in str(error), error
        else:
            raise AssertionError(f"expected account API rejection containing {message!r}")
        assert not filesystem.backups

    entries = initial_entries()
    arguments = install_arguments(entries, apply=True)
    arguments["expected_old_direct_account_api_sha256"] = "0" * 64
    expect_failure(entries, arguments, "direct account API old block drifted")

    arguments = install_arguments(entries, apply=True)
    arguments["expected_old_direct_account_api_sha256"] = None
    expect_failure(entries, arguments, "direct account API old block SHA-256 is mandatory")

    arguments = install_arguments(entries, apply=True)
    arguments["expected_old_snippet_account_api_sha256"] = None
    expect_failure(entries, arguments, "snippet account API old block=absent is mandatory")

    unexpected_target_entries = initial_entries()
    unexpected_target_arguments = install_arguments(
        unexpected_target_entries, apply=True
    )
    unexpected_target_entries[ACCOUNT_API_TARGET] = file_state(b"# unexpected\n")
    expect_failure(
        unexpected_target_entries,
        unexpected_target_arguments,
        "account API snippet target drifted: expected absent",
    )

    backup_entries = initial_entries(
        backup_active_config(), account_snippet=backup_account_api_snippet()
    )
    backup_arguments = install_arguments(backup_entries, apply=True)
    backup_arguments["expected_account_api_snippet"] = "0" * 64
    expect_failure(
        backup_entries, backup_arguments, "account API snippet target drifted"
    )

    backup_arguments = install_arguments(backup_entries, apply=True)
    backup_arguments["expected_old_snippet_account_api_sha256"] = "0" * 64
    expect_failure(
        backup_entries, backup_arguments, "snippet account API old block drifted"
    )

    backup_arguments = install_arguments(backup_entries, apply=True)
    backup_arguments["expected_old_direct_account_api_sha256"] = None
    expect_failure(
        backup_entries,
        backup_arguments,
        "direct account API old block=absent is mandatory",
    )

    both_entries = initial_entries()
    both_arguments = install_arguments(both_entries, apply=True)
    both_config = both_entries[ACTIVE].data.replace(
        b"    proxy_set_header X-Node primary-upstream;\n",
        (
            b"    proxy_set_header X-Node primary-upstream;\n"
            b"    include /etc/nginx/snippets/"
            b"shuzijun-account-api-backup-proxy.conf;\n"
        ),
        1,
    )
    both_entries[ACTIVE] = file_state(both_config)
    both_entries[ACCOUNT_API_TARGET] = file_state(backup_account_api_snippet())
    both_arguments["expected_active_sha256"] = MODULE.sha256(both_config)
    both_arguments["expected_account_api_snippet"] = MODULE.sha256(
        backup_account_api_snippet()
    )
    expect_failure(both_entries, both_arguments, "exactly one direct block or one reviewed")

    duplicate_entries = initial_entries()
    duplicate_arguments = install_arguments(duplicate_entries, apply=True)
    block_start = duplicate_entries[ACTIVE].data.index(
        b"    location ^~ /wp-json/shuzijun/v1/ {"
    )
    block_end = duplicate_entries[ACTIVE].data.index(
        b"    location = /favicon.ico", block_start
    )
    block = duplicate_entries[ACTIVE].data[block_start:block_end]
    duplicate_config = (
        duplicate_entries[ACTIVE].data[:block_end]
        + block
        + duplicate_entries[ACTIVE].data[block_end:]
    )
    duplicate_entries[ACTIVE] = file_state(duplicate_config)
    duplicate_arguments["expected_active_sha256"] = MODULE.sha256(duplicate_config)
    expect_failure(
        duplicate_entries, duplicate_arguments, "exactly one direct block or one reviewed"
    )

    malformed_entries = initial_entries()
    malformed_arguments = install_arguments(malformed_entries, apply=True)
    malformed_config = malformed_entries[ACTIVE].data.replace(
        b"location ^~ /wp-json/shuzijun/v1/ {",
        b"location ^~ /wp-json/shuzijun/v1/extra {",
        1,
    )
    malformed_entries[ACTIVE] = file_state(malformed_config)
    malformed_arguments["expected_active_sha256"] = MODULE.sha256(malformed_config)
    expect_failure(malformed_entries, malformed_arguments, "location is malformed")

    extra_arg_entries = initial_entries()
    extra_arg_arguments = install_arguments(extra_arg_entries, apply=True)
    extra_arg_config = extra_arg_entries[ACTIVE].data.replace(
        b"location ^~ /wp-json/shuzijun/v1/ {",
        b"location ^~ /wp-json/shuzijun/v1/ unexpected {",
        1,
    )
    extra_arg_entries[ACTIVE] = file_state(extra_arg_config)
    extra_arg_arguments["expected_active_sha256"] = MODULE.sha256(extra_arg_config)
    expect_failure(extra_arg_entries, extra_arg_arguments, "location is malformed")

    nested_entries = initial_entries()
    nested_arguments = install_arguments(nested_entries, apply=True)
    nested_config = nested_entries[ACTIVE].data.replace(
        b"    location ^~ /wp-json/shuzijun/v1/ {",
        b"    location /wrapper {\n        location ^~ /wp-json/shuzijun/v1/ {",
        1,
    ).replace(
        b"    location = /favicon.ico",
        b"    }\n    location = /favicon.ico",
        1,
    )
    nested_entries[ACTIVE] = file_state(nested_config)
    nested_arguments["expected_active_sha256"] = MODULE.sha256(nested_config)
    expect_failure(nested_entries, nested_arguments, "must be a direct child")

    missing_entries = initial_entries(
        backup_active_config(), account_snippet=backup_account_api_snippet()
    )
    missing_arguments = install_arguments(missing_entries, apply=True)
    missing_entries.pop(ACCOUNT_API_TARGET)
    missing_arguments["expected_account_api_snippet"] = "absent"
    expect_failure(missing_entries, missing_arguments, "must be a regular file")

    malformed_snippet_entries = initial_entries(
        backup_active_config(), account_snippet=backup_account_api_snippet()
    )
    malformed_snippet_arguments = install_arguments(
        malformed_snippet_entries, apply=True
    )
    malformed_snippet = malformed_snippet_entries[ACCOUNT_API_TARGET].data.replace(
        b"location ^~ /wp-json/shuzijun/v1/ {",
        b"location ^~ /wp-json/shuzijun/v1/ unexpected {",
        1,
    )
    malformed_snippet_entries[ACCOUNT_API_TARGET] = file_state(malformed_snippet)
    malformed_snippet_arguments["expected_account_api_snippet"] = MODULE.sha256(
        malformed_snippet
    )
    expect_failure(
        malformed_snippet_entries,
        malformed_snippet_arguments,
        "snippet location is malformed",
    )

    extra_entries = initial_entries(
        backup_active_config(), account_snippet=backup_account_api_snippet()
    )
    extra_arguments = install_arguments(extra_entries, apply=True)
    extra_snippet = extra_entries[ACCOUNT_API_TARGET].data + (
        b"location ^~ /assets/ { return 204; }\n"
    )
    extra_entries[ACCOUNT_API_TARGET] = file_state(extra_snippet)
    extra_arguments["expected_account_api_snippet"] = MODULE.sha256(extra_snippet)
    expect_failure(extra_entries, extra_arguments, "exactly one top-level API location")

    hidden_entries = initial_entries(
        backup_active_config(), account_snippet=backup_account_api_snippet()
    )
    hidden_arguments = install_arguments(hidden_entries, apply=True)
    hidden_snippet = hidden_entries[ACCOUNT_API_TARGET].data.replace(
        b"location ^~ /wp-json/shuzijun/v1/ {",
        b"location /wp-json/shuzijun/v1/ {",
        1,
    ).replace(
        b"    proxy_set_header X-Account-Node backup-singapore-preserved;\n",
        (
            b"    proxy_set_header X-Account-Node backup-singapore-preserved;\n"
            b"    location ^~ /assets/ { return 204; }\n"
        ),
        1,
    )
    hidden_entries[ACCOUNT_API_TARGET] = file_state(hidden_snippet)
    hidden_arguments["expected_account_api_snippet"] = MODULE.sha256(hidden_snippet)
    hidden_arguments["expected_old_snippet_account_api_sha256"] = "absent"
    expect_failure(hidden_entries, hidden_arguments, "contains a nested location")

    def reject_account_snippet_mutation(
        mutate,
        message: str,
    ) -> None:
        current_entries = initial_entries(
            backup_active_config(), account_snippet=backup_account_api_snippet()
        )
        current_arguments = install_arguments(current_entries, apply=True)
        changed = mutate(current_entries[ACCOUNT_API_TARGET].data)
        current_entries[ACCOUNT_API_TARGET] = file_state(changed)
        current_arguments["expected_account_api_snippet"] = MODULE.sha256(changed)
        expect_failure(current_entries, current_arguments, message)

    reject_account_snippet_mutation(
        lambda content: content.replace(
            b"set $yishu_client_ip $remote_addr;",
            b"set $yishu_client_ip $http_x_yishu_client_ip;",
            1,
        ),
        "client IP assignment topology drifted",
    )
    reject_account_snippet_mutation(
        lambda content: content.replace(
            b"    set $yishu_client_ip $remote_addr;\n",
            (
                b"    set $yishu_client_ip $remote_addr;\n"
                b"    set $yishu_client_ip $remote_addr;\n"
            ),
            1,
        ),
        "client IP assignment topology drifted",
    )
    reject_account_snippet_mutation(
        lambda content: content.replace(
            (
                b"    if ($remote_addr ~ ^(?:127\\.0\\.0\\.1|::1)$) {\n"
                b"        set $yishu_client_ip $http_x_yishu_client_ip;\n"
                b"    }\n"
            ),
            b"",
            1,
        ),
        "unreviewed if block",
    )

    for old, new in (
        (
            b"^(?:127\\.0\\.0\\.1|::1)$)",
            b"^(?:127\\.0\\.0\\.1|::1|10\\.0\\.0\\.1)$)",
        ),
        (
            b"set $yishu_client_ip $http_x_yishu_client_ip;",
            b"set $yishu_client_ip $http_x_forwarded_for;",
        ),
        (
            b"set $yishu_client_ip $http_x_yishu_client_ip;",
            (
                b"set $yishu_client_ip $http_x_yishu_client_ip;\n"
                b"        set $extra_assignment on;"
            ),
        ),
        (
            b"    proxy_pass http://127.0.0.1:9080;",
            (
                b"    if ($request_method = OPTIONS) {\n"
                b"        set $yishu_client_ip invalid;\n"
                b"    }\n"
                b"    proxy_pass http://127.0.0.1:9080;"
            ),
        ),
    ):
        reject_account_snippet_mutation(
            lambda content, source=old, replacement=new: content.replace(
                source, replacement, 1
            ),
            "unreviewed if block",
        )

    for injected, expected in (
        (b"    return 204;\n", "unreviewed control-flow directive"),
        (
            b"    try_files $uri /index.php?$args;\n",
            "unreviewed control-flow directive",
        ),
        (b"    rewrite ^ /index.php last;\n", "internal redirect mechanism"),
        (b"    error_page 404 = @account_bypass;\n", "internal redirect mechanism"),
        (
            b"    location @account_bypass { return 204; }\n",
            "contains a nested location",
        ),
    ):
        reject_account_snippet_mutation(
            lambda content, line=injected: content.replace(
                b"    proxy_pass http://127.0.0.1:9080;\n",
                line + b"    proxy_pass http://127.0.0.1:9080;\n",
                1,
            ),
            expected,
        )


def assert_account_api_toctou_and_unused_target() -> None:
    dormant = b"# unused node-specific account snippet\n"
    entries = initial_entries(account_snippet=dormant)
    originals = copy.deepcopy(entries)
    filesystem = FakeFilesystem(entries)
    make_installer(filesystem, FakeRunner()).install(
        **install_arguments(entries, apply=True)
    )
    assert filesystem.entries[ACCOUNT_API_TARGET] == originals[ACCOUNT_API_TARGET]
    assert ("write", str(ACCOUNT_API_TARGET)) not in filesystem.operations

    race_entries = initial_entries()
    race_arguments = install_arguments(race_entries, apply=True)
    race_filesystem = FakeFilesystem(race_entries)
    reads = 0

    def hook(fs, path, count) -> None:
        nonlocal reads
        if path == ACCOUNT_API_TARGET:
            reads += 1
            if reads == 2:
                fs.entries[ACCOUNT_API_TARGET] = file_state(b"# concurrent drift\n")

    race_filesystem.on_snapshot = hook
    try:
        make_installer(race_filesystem, FakeRunner()).install(**race_arguments)
    except MODULE.InstallError as error:
        assert "account API snippet target changed after validation" in str(error), error
    else:
        raise AssertionError("account API target TOCTOU drift unexpectedly succeeded")
    assert not race_filesystem.backups


def assert_account_api_already_migrated_parameter_gates() -> None:
    original = active_config()
    candidate, _, image_hash = fully_migrated(original, None)
    primary_entries = initial_entries(candidate)
    primary_entries[AVAILABLE] = file_state(candidate)
    primary_entries[ACTIVE] = symlink_state("../sites-available/shuzijun-ssl.conf")
    primary_arguments = install_arguments(
        primary_entries, apply=False, old_hash_override=image_hash
    )
    primary_result = make_installer(
        FakeFilesystem(primary_entries), FakeRunner()
    ).install(**primary_arguments)
    assert primary_result.state == "already-current"
    assert primary_result.account_api_state == "direct-already-current"

    bad_primary_arguments = install_arguments(
        primary_entries, apply=True, old_hash_override=image_hash
    )
    bad_primary_arguments["expected_old_direct_account_api_sha256"] = MODULE.sha256(
        b"old direct"
    )
    try:
        make_installer(FakeFilesystem(primary_entries), FakeRunner()).install(
            **bad_primary_arguments
        )
    except MODULE.InstallError as error:
        assert "expected no old block" in str(error), error
    else:
        raise AssertionError("migrated direct route accepted an old-block hash")

    missing_primary_gate = install_arguments(
        primary_entries, apply=True, old_hash_override=image_hash
    )
    missing_primary_gate["expected_old_direct_account_api_sha256"] = None
    try:
        make_installer(FakeFilesystem(primary_entries), FakeRunner()).install(
            **missing_primary_gate
        )
    except MODULE.InstallError as error:
        assert "old block=absent is mandatory" in str(error), error
    else:
        raise AssertionError("migrated direct route accepted a missing absent gate")

    backup_original = backup_active_config()
    backup_snippet = backup_account_api_snippet()
    backup_candidate, migrated_snippet, backup_image_hash = fully_migrated(
        backup_original, backup_snippet
    )
    assert migrated_snippet is not None
    backup_entries = initial_entries(
        backup_candidate, account_snippet=migrated_snippet
    )
    backup_entries[AVAILABLE] = file_state(backup_candidate)
    backup_entries[ACTIVE] = symlink_state("../sites-available/shuzijun-ssl.conf")
    backup_arguments = install_arguments(
        backup_entries, apply=False, old_hash_override=backup_image_hash
    )
    backup_result = make_installer(
        FakeFilesystem(backup_entries), FakeRunner()
    ).install(**backup_arguments)
    assert backup_result.state == "already-current"
    assert backup_result.account_api_state == "snippet-already-current"
    assert backup_result.account_api_content == migrated_snippet

    bad_backup_arguments = install_arguments(
        backup_entries, apply=True, old_hash_override=backup_image_hash
    )
    bad_backup_arguments["expected_old_snippet_account_api_sha256"] = MODULE.sha256(
        b"old snippet"
    )
    try:
        make_installer(FakeFilesystem(backup_entries), FakeRunner()).install(
            **bad_backup_arguments
        )
    except MODULE.InstallError as error:
        assert "expected no old block" in str(error), error
    else:
        raise AssertionError("migrated snippet route accepted an old-block hash")

    missing_backup_gate = install_arguments(
        backup_entries, apply=True, old_hash_override=backup_image_hash
    )
    missing_backup_gate["expected_old_snippet_account_api_sha256"] = None
    try:
        make_installer(FakeFilesystem(backup_entries), FakeRunner()).install(
            **missing_backup_gate
        )
    except MODULE.InstallError as error:
        assert "old block=absent is mandatory" in str(error), error
    else:
        raise AssertionError("migrated snippet route accepted a missing absent gate")


def assert_command_failure_rolls_back(fail_call: int) -> None:
    entries = initial_entries()
    originals = copy.deepcopy(entries)
    filesystem = FakeFilesystem(entries)
    runner = FakeRunner(fail_call=fail_call)
    try:
        make_installer(filesystem, runner).install(
            **install_arguments(entries, apply=True)
        )
    except MODULE.InstallError as error:
        assert "exact rollback completed" in str(error), error
    else:
        raise AssertionError("injected command failure unexpectedly succeeded")
    assert filesystem.entries == originals
    assert filesystem.backups[BACKUP]["active"] == originals[ACTIVE]
    assert runner.calls[-3:] == [
        ("fake-nginx", "-t"),
        ("fake-systemctl", "reload", "nginx"),
        ("fake-systemctl", "is-active", "--quiet", "nginx"),
    ]


def assert_atomic_filesystem_failures_roll_back() -> None:
    for atomic_point in range(1, 5):
        entries = initial_entries()
        originals = copy.deepcopy(entries)
        filesystem = FakeFilesystem(entries)
        filesystem.fail_after_atomic = atomic_point
        try:
            make_installer(filesystem, FakeRunner()).install(
                **install_arguments(entries, apply=True)
            )
        except MODULE.InstallError as error:
            assert "exact rollback completed" in str(error), (atomic_point, error)
            assert "post-replace atomic failure" in str(error), (atomic_point, error)
        else:
            raise AssertionError(f"atomic failure {atomic_point} unexpectedly succeeded")
        assert filesystem.entries == originals, atomic_point
        assert filesystem.backups[BACKUP] == {
            "active": originals[ACTIVE],
            "available": originals[AVAILABLE],
            "sensitive-snippet": originals[SENSITIVE_TARGET],
            "legacy-snippet": originals[LEGACY_TARGET],
            "account-api-snippet": MODULE.FileState("absent"),
        }

    # An absent pre-deployment target is an exact state too.  A later failure
    # must remove the newly installed file rather than leaving a partial base.
    entries = initial_entries()
    entries.pop(LEGACY_TARGET)
    originals = copy.deepcopy(entries)
    filesystem = FakeFilesystem(entries)
    filesystem.fail_after_atomic = 3
    try:
        make_installer(filesystem, FakeRunner()).install(
            **install_arguments(entries, apply=True)
        )
    except MODULE.InstallError as error:
        assert "exact rollback completed" in str(error), error
    else:
        raise AssertionError("absent-target rollback case unexpectedly succeeded")
    assert filesystem.entries == originals
    assert LEGACY_TARGET not in filesystem.entries


def assert_baseline_failure_does_not_write(fail_call: int) -> None:
    entries = initial_entries()
    originals = copy.deepcopy(entries)
    filesystem = FakeFilesystem(entries)
    runner = FakeRunner(fail_call=fail_call)
    try:
        make_installer(filesystem, runner).install(
            **install_arguments(entries, apply=True)
        )
    except MODULE.InstallError as error:
        assert "injected command failure" in str(error), error
    else:
        raise AssertionError("invalid baseline unexpectedly proceeded")
    assert filesystem.entries == originals
    assert filesystem.operations == [("lock", str(ACTIVE.parent))]
    assert not filesystem.backups


def assert_rejected(mutator, expected_message: str) -> None:
    entries = initial_entries()
    arguments = install_arguments(entries, apply=True)
    filesystem = FakeFilesystem(entries)
    mutator(filesystem, arguments)
    try:
        make_installer(filesystem, FakeRunner()).install(**arguments)
    except MODULE.InstallError as error:
        assert expected_message in str(error), error
    else:
        raise AssertionError(f"expected rejection containing {expected_message!r}")
    assert all(operation == "lock" for operation, _ in filesystem.operations)
    assert not filesystem.backups


def assert_drift_and_unsafe_inputs_rejected() -> None:
    assert_rejected(
        lambda filesystem, arguments: arguments.update(
            expected_active_sha256="0" * 64
        ),
        "active config drifted",
    )

    def drift_old_location(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(b"expires 365d", b"expires 30d")
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)

    assert_rejected(drift_old_location, "old /images/ location drifted")

    def partial_state(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"    proxy_set_header X-Node primary-upstream;",
            (
                b"    include /etc/nginx/snippets/"
                b"shuzijun-legacy-images-alias.conf;\n"
                b"    proxy_set_header X-Node primary-upstream;"
            ),
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)

    assert_rejected(partial_state, "partial Build 34 routing state")

    def duplicate_www(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data + (
            b"server { listen 443 ssl; server_name www.shuzijun.com.cn; }\n"
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)

    assert_rejected(duplicate_www, "exactly one TLS block")

    def duplicate_enabled_file(filesystem, arguments) -> None:
        duplicate = Path("/etc/nginx/sites-enabled/duplicate-www.conf")
        filesystem.entries[duplicate] = file_state(
            b"server { listen 443 ssl; server_name www.shuzijun.com.cn; }\n"
        )

    assert_rejected(duplicate_enabled_file, "exactly one enabled TLS block")

    def hidden_duplicate_include(filesystem, arguments) -> None:
        wrapper = Path("/etc/nginx/sites-enabled/hidden-duplicate.conf")
        filesystem.entries[wrapper] = file_state(
            b"include /etc/nginx/conf.d/hidden-www-duplicate.conf;\n"
        )

    assert_rejected(hidden_duplicate_include, "must not contain a top-level include")

    def canonical_top_level_include(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data + (
            b"include /etc/nginx/conf.d/hidden-canonical-hosts.conf;\n"
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)

    assert_rejected(canonical_top_level_include, "must not contain a top-level include")

    def ipv6_port_4430(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"listen [::]:443 ssl;",
            b"listen [::]:4430 ssl;",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)

    assert_rejected(ipv6_port_4430, "exactly one TLS block")

    def non_root_source(filesystem, arguments) -> None:
        state = filesystem.entries[SENSITIVE_SOURCE]
        filesystem.entries[SENSITIVE_SOURCE] = file_state(state.data, uid=33)

    assert_rejected(non_root_source, "must be root-owned")

    def hardlinked_source(filesystem, arguments) -> None:
        state = filesystem.entries[LEGACY_SOURCE]
        filesystem.entries[LEGACY_SOURCE] = file_state(state.data, nlink=2)

    assert_rejected(hardlinked_source, "must be root-owned")

    def hardlinked_target(filesystem, arguments) -> None:
        state = filesystem.entries[SENSITIVE_TARGET]
        filesystem.entries[SENSITIVE_TARGET] = file_state(state.data, nlink=2)

    assert_rejected(hardlinked_target, "must be root-owned")

    def wrong_root(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"root /var/www/html/shuzijun.com.cn;",
            b"root /var/www/html/unreviewed;",
            1,
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(wrong_root, "must have exactly one fixed root")

    def protected_prefix_location(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ \"^/health/[0-9]{1,5}$\"",
            b"location ^~ /wp-content/",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(protected_prefix_location, "bypasses security regex rules")

    def harmless_caret_prefix(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ \"^/health/[0-9]{1,5}$\"",
            b"location ^~ /assets/",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(harmless_caret_prefix, "bypasses security regex rules")

    for exact_path in (
        b"/wp-content/mu-plugins/x.php",
        b"/wp-config.php",
        b"/wp-config.php.before-build34",
        b"/.env.production",
        b"/COMPOSER.JSON",
        b"/exports/database.sql",
        b"/private/credentials.json",
        b"/cache/file.php.bak",
        b"/.svn",
    ):
        def exact_protected_location(filesystem, arguments, path=exact_path) -> None:
            changed = filesystem.entries[ACTIVE].data.replace(
                b"location ~ \"^/health/[0-9]{1,5}$\"",
                b"location = " + path,
            )
            filesystem.entries[ACTIVE] = file_state(changed)
            arguments["expected_active_sha256"] = MODULE.sha256(changed)
            arguments["expected_old_location_sha256"] = old_location_hash(changed)

        assert_rejected(
            exact_protected_location,
            "bypasses sensitive-file rules",
        )

    def wide_protected_prefix(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ \"^/health/[0-9]{1,5}$\"",
            b"location ^~ /",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(wide_protected_prefix, "bypasses security regex rules")

    def inline_images_regex(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ \"^/health/[0-9]{1,5}$\"",
            b"location ~* ^\\/images\\/.*$",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(inline_images_regex, "inline /images location")

    def drift_after_validation(filesystem, arguments) -> None:
        mutated = False

        def hook(fs, path, count) -> None:
            nonlocal mutated
            # The second read of the active path begins the pre-write race
            # check.  Change an independently monitored target just before it.
            if path == ACTIVE and count > 6 and not mutated:
                mutated = True
                fs.entries[SENSITIVE_TARGET] = file_state(b"# concurrent drift\n")

        filesystem.on_snapshot = hook

    assert_rejected(drift_after_validation, "sensitive snippet target changed")


def assert_sensitive_exact_location_mirror() -> None:
    sensitive_paths = (
        "/wp-content/mu-plugins/x.php",
        "/WP-CONTENT/cache/X.PHP/path-info",
        "/images/payload.php",
        "/wp-config.php",
        "/nested/wp-config.php.before-review",
        "/cache/file.php.bak",
        "/cache/file.backup",
        "/cache/file.old.1",
        "/cache/file.before-build34",
        "/cache/file~",
        "/.env",
        "/private/.ENV.production",
        "/.git/config",
        "/assets/.svn",
        "/archive/.hg/store",
        "/composer.json",
        "/COMPOSER.LOCK",
        "/auth.json",
        "/package.json",
        "/package-lock.json",
        "/yarn.lock",
        "/pnpm-lock.yaml",
        "/exports/database.sql",
        "/exports/database.sql.gz",
        "/exports/database.dump",
        "/private/certificate.pem",
        "/private/signing.key",
        "/private/apple.p8",
        "/private/signing.p12",
        "/private/signing.pfx",
        "/private/trust.jks",
        "/logs/error.log",
        "/archives/site.zip",
        "/archives/site.tar",
        "/archives/site.tar.gz",
        "/archives/site.tgz",
        "/archives/site.7z",
        "/archives/site.rar",
        "/private/credentials.json",
        "/private/credentials-prod.json",
        "/private/service-account-app.json",
    )
    for path in sensitive_paths:
        assert MODULE.exact_location_is_sensitive(path), path

    for safe_path in (
        "/favicon.ico",
        "/robots.txt",
        "/wp-content/themes/site.css",
        "/images/portrait.jpg",
        "/health",
        "/ordinary/file.php",
        "/ordinary/file.oldish",
    ):
        assert not MODULE.exact_location_is_sensitive(safe_path), safe_path


def assert_nginx_tokenizer_semantics() -> None:
    document = MODULE.parse(
        'location ~ "\\.php$" { include "snippets/foo\\q.conf"; }',
        "quoted-escape-contract",
    )
    assert document[0].args == ("~", r"\.php$")
    assert document[0].children[0].args == (r"snippets/foo\q.conf",)
    unquoted = MODULE.parse(r"set $pattern foo\q;", "unquoted-escape-contract")
    assert unquoted[0].args == ("$pattern", r"foo\q")
    try:
        MODULE.parse(
            r"location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "unquoted-regex-quantifier",
        )
    except MODULE.InstallError:
        pass
    else:
        raise AssertionError("unquoted regex quantifier was parsed ambiguously")


def assert_candidate_semantic_bypass_gates() -> None:
    health = b'location ~ "^/health/[0-9]{1,5}$"'

    def reject_location(replacement: bytes, expected: str) -> None:
        def mutate(filesystem, arguments) -> None:
            changed = filesystem.entries[ACTIVE].data.replace(health, replacement, 1)
            filesystem.entries[ACTIVE] = file_state(changed)
            arguments["expected_active_sha256"] = MODULE.sha256(changed)
            arguments["expected_old_location_sha256"] = old_location_hash(changed)

        assert_rejected(mutate, expected)

    reject_location(
        b"location /outer { location /inner { return 204; } } location /after",
        "nested location",
    )
    for pattern in (
        rb"^/(?:images)/.*$",
        rb"^/[i]mages/.*$",
        rb"^/\x69mages/.*$",
        rb"^/im\141ges/.*$",
        rb"^/.*\.jpg$",
    ):
        reject_location(
            b'location ~* "' + pattern + b'"',
            "regex location that may bypass legacy /images routing",
        )
    reject_location(b"location @deny_bypass", "named location")

    def reject_server_line(line: bytes, expected: str) -> None:
        def mutate(filesystem, arguments) -> None:
            changed = filesystem.entries[ACTIVE].data.replace(
                b"    proxy_set_header X-Node primary-upstream;\n",
                b"    " + line + b"\n    proxy_set_header X-Node primary-upstream;\n",
                1,
            )
            filesystem.entries[ACTIVE] = file_state(changed)
            arguments["expected_active_sha256"] = MODULE.sha256(changed)
            arguments["expected_old_location_sha256"] = old_location_hash(changed)

        assert_rejected(mutate, expected)

    for line in (
        b"rewrite ^ /index.php last;",
        b"error_page 404 = @deny_bypass;",
        b"internal_redirect @deny_bypass;",
    ):
        reject_server_line(line, "redirect mechanism")

    def escaped_fixed_include(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"/etc/nginx/snippets/shuzijun-sensitive-files-deny.conf; # keep-comment",
            b'"/etc/nginx/snippets/shuzijun-sensitive-files-deny\\.conf"; # keep-comment',
            1,
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(escaped_fixed_include, "must contain exactly one direct")


def assert_fixed_snippet_semantic_gates() -> None:
    def reject_sensitive(
        replacement: bytes,
        expected: str = "sensitive snippet candidate semantic content drifted",
    ) -> None:
        def mutate(filesystem, arguments) -> None:
            filesystem.entries[SENSITIVE_SOURCE] = file_state(replacement)
            arguments["sensitive_source_sha256"] = MODULE.sha256(replacement)

        assert_rejected(mutate, expected)

    reject_sensitive(REVIEWED_SENSITIVE.replace(b"location ~*", b"location ~", 1))
    reject_sensitive(REVIEWED_SENSITIVE.replace(b"return 404;", b"return 200;", 1))
    reject_sensitive(b"# no deny rules\n")
    reject_sensitive(
        REVIEWED_SENSITIVE + b"include /etc/nginx/evil.conf;\n",
        "must not contain another include",
    )

    def reject_legacy(replacement: bytes) -> None:
        def mutate(filesystem, arguments) -> None:
            filesystem.entries[LEGACY_SOURCE] = file_state(replacement)
            arguments["legacy_source_sha256"] = MODULE.sha256(replacement)

        assert_rejected(mutate, "legacy images snippet candidate semantic content drifted")

    reject_legacy(REVIEWED_LEGACY.replace(b"ico|svg", b"ico|svg|txt", 1))
    reject_legacy(REVIEWED_LEGACY.replace(b"expires 365d;", b"expires 30d;", 1))
    reject_legacy(REVIEWED_LEGACY + b"location /extra { return 200; }\n")

    cases = []
    direct_entries = initial_entries()
    direct_arguments = install_arguments(direct_entries, apply=True)
    direct_changed = direct_entries[ACTIVE].data.replace(
        b"        try_files $uri $uri/ /index.php?$args;\n",
        b"        rewrite ^ /index.php last;\n",
        1,
    )
    direct_entries[ACTIVE] = file_state(direct_changed)
    direct_arguments["expected_active_sha256"] = MODULE.sha256(direct_changed)
    direct_arguments["expected_old_location_sha256"] = old_location_hash(direct_changed)
    cases.append((direct_entries, direct_arguments))

    snippet = backup_account_api_snippet()
    backup_entries = initial_entries(
        backup_active_config(), account_snippet=snippet
    )
    backup_arguments = install_arguments(backup_entries, apply=True)
    changed_snippet = snippet.replace(
        b"    proxy_pass http://127.0.0.1:9080;\n",
        b"    error_page 404 = @account_bypass;\n",
        1,
    )
    backup_entries[ACCOUNT_API_TARGET] = file_state(changed_snippet)
    backup_arguments["expected_account_api_snippet"] = MODULE.sha256(changed_snippet)
    cases.append((backup_entries, backup_arguments))

    for entries, arguments in cases:
        filesystem = FakeFilesystem(entries)
        try:
            make_installer(filesystem, FakeRunner()).install(**arguments)
        except MODULE.InstallError as error:
            assert "internal redirect mechanism" in str(error), error
        else:
            raise AssertionError("account API redirect bypass was accepted")
        assert not filesystem.backups


def assert_recursive_include_contract() -> None:
    config = php_include_active_config()
    entries = initial_entries(config)
    add_reviewed_include_entries(entries)
    arguments = install_arguments(entries, apply=False)
    filesystem = FakeFilesystem(entries)
    result = make_installer(filesystem, FakeRunner()).install(**arguments)
    assert result.state == "rewrite-required"
    assert SECURITY_INCLUDE in filesystem.entries
    assert not filesystem.operations

    def reject_include(mutator, expected: str) -> None:
        current = initial_entries(config)
        add_reviewed_include_entries(current)
        args = install_arguments(current, apply=True)
        fs = FakeFilesystem(current)
        mutator(fs, args)
        try:
            make_installer(fs, FakeRunner()).install(**args)
        except MODULE.InstallError as error:
            assert expected in str(error), error
        else:
            raise AssertionError(f"included attack unexpectedly accepted: {expected}")
        assert not fs.backups

    reject_include(
        lambda fs, args: fs.entries.__setitem__(
            SECURITY_INCLUDE,
            file_state(REVIEWED_SECURITY_INCLUDE + b"rewrite ^ /index.php last;\n"),
        ),
        "security header include",
    )
    reject_include(
        lambda fs, args: fs.entries.__setitem__(
            FASTCGI_PHP_INCLUDE,
            file_state(
                REVIEWED_FASTCGI_PHP_INCLUDE.replace(
                    b"include fastcgi.conf;",
                    b"location /nested { return 204; }\ninclude fastcgi.conf;",
                )
            ),
        ),
        "FastCGI PHP include contains a block",
    )
    reject_include(
        lambda fs, args: fs.entries.__setitem__(
            FASTCGI_BASE_INCLUDE,
            file_state(
                REVIEWED_FASTCGI_BASE_INCLUDE
                + b"fastcgi_param SCRIPT_FILENAME /var/www/html/wp-config.php;\n"
            ),
        ),
        "duplicate FastCGI parameters",
    )
    reject_include(
        lambda fs, args: fs.entries.__setitem__(
            FASTCGI_BASE_INCLUDE,
            file_state(
                REVIEWED_FASTCGI_BASE_INCLUDE.replace(
                    b"$document_root$fastcgi_script_name",
                    b"/var/www/html/shuzijun.com.cn/wp-config.php",
                )
            ),
        ),
        "SCRIPT_FILENAME is not the reviewed execution target",
    )
    reject_include(
        lambda fs, args: fs.entries.__setitem__(
            FASTCGI_BASE_INCLUDE,
            file_state(REVIEWED_FASTCGI_BASE_INCLUDE, mode=0o666),
        ),
        "must be root-owned",
    )

    def unknown_server_include(fs, args) -> None:
        unknown = Path("/etc/nginx/snippets/unreviewed.conf")
        fs.entries[unknown] = file_state(b"add_header X-Unknown yes always;\n")
        changed = fs.entries[ACTIVE].data.replace(
            b"    include /etc/nginx/snippets/shuzijun-security.conf;\n",
            b"    include /etc/nginx/snippets/unreviewed.conf;\n",
            1,
        )
        fs.entries[ACTIVE] = file_state(changed)
        args["expected_active_sha256"] = MODULE.sha256(changed)
        args["expected_old_location_sha256"] = old_location_hash(changed)

    reject_include(unknown_server_include, "includes an unreviewed file")

    race_entries = initial_entries(config)
    add_reviewed_include_entries(race_entries)
    race_arguments = install_arguments(race_entries, apply=True)
    race_filesystem = FakeFilesystem(race_entries)
    security_reads = 0

    def race_hook(fs, path, count) -> None:
        nonlocal security_reads
        if path != SECURITY_INCLUDE:
            return
        security_reads += 1
        if security_reads == 2:
            fs.entries[SECURITY_INCLUDE] = file_state(
                REVIEWED_SECURITY_INCLUDE.replace(b"reviewed-1", b"reviewed-race")
            )

    race_filesystem.on_snapshot = race_hook
    try:
        make_installer(race_filesystem, FakeRunner()).install(**race_arguments)
    except MODULE.InstallError as error:
        assert "included Nginx files changed after validation" in str(error), error
    else:
        raise AssertionError("included-file TOCTOU drift was accepted")
    assert race_filesystem.operations == [("lock", str(ACTIVE.parent))]
    assert not race_filesystem.backups


def assert_enabled_and_target_identity_gates() -> None:
    def hardlinked_active(filesystem, arguments) -> None:
        state = filesystem.entries[ACTIVE]
        filesystem.entries[ACTIVE] = file_state(state.data, nlink=2)

    assert_rejected(hardlinked_active, "must be root-owned")

    def unsafe_enabled_mode(filesystem, arguments) -> None:
        filesystem.entries[Path("/etc/nginx/sites-enabled/extra.conf")] = file_state(
            b"server { listen 80; server_name example.invalid; }\n", mode=0o666
        )

    assert_rejected(unsafe_enabled_mode, "must be root-owned")

    def escaped_enabled_target(filesystem, arguments) -> None:
        link = Path("/etc/nginx/sites-enabled/extra.conf")
        target = Path("/untrusted/extra.conf")
        filesystem.entries[link] = symlink_state(str(target))
        filesystem.entries[target] = file_state(
            b"server { listen 80; server_name example.invalid; }\n"
        )

    assert_rejected(escaped_enabled_target, "outside sites-available")

    def secondary_symlink_target(filesystem, arguments) -> None:
        link = Path("/etc/nginx/sites-enabled/extra.conf")
        relay = Path("/etc/nginx/sites-available/relay.conf")
        final = Path("/etc/nginx/sites-available/final.conf")
        filesystem.entries[link] = symlink_state(str(relay))
        filesystem.entries[relay] = symlink_state(str(final))
        filesystem.entries[final] = file_state(
            b"server { listen 80; server_name example.invalid; }\n"
        )

    assert_rejected(secondary_symlink_target, "must be a regular non-symlink file")

    active_config_bytes = active_config()
    relay = Path("/untrusted/relay.conf")
    relayed_entries = initial_entries(active_config_bytes)
    relayed_entries[AVAILABLE] = file_state(active_config_bytes)
    relayed_entries[ACTIVE] = symlink_state(str(relay))
    relayed_entries[relay] = symlink_state(str(AVAILABLE))
    relayed_arguments = install_arguments(relayed_entries, apply=True)
    try:
        make_installer(FakeFilesystem(relayed_entries), FakeRunner()).install(
            **relayed_arguments
        )
    except MODULE.InstallError as error:
        assert "does not directly target sites-available" in str(error), error
    else:
        raise AssertionError("active symlink relay was accepted")

    for target, attribute, value in (
        (SENSITIVE_TARGET, "gid", 33),
        (LEGACY_TARGET, "mode", 0o640),
        (ACCOUNT_API_TARGET, "nlink", 2),
    ):
        def unsafe_target(filesystem, arguments, path=target, field=attribute, bad=value):
            if path not in filesystem.entries:
                filesystem.entries[path] = file_state(b"reviewed placeholder\n")
                arguments["expected_account_api_snippet"] = MODULE.sha256(
                    filesystem.entries[path].data
                )
            state = filesystem.entries[path]
            values = {
                "mode": state.mode,
                "uid": state.uid,
                "gid": state.gid,
                "nlink": state.nlink,
            }
            values[field] = bad
            filesystem.entries[path] = file_state(state.data, **values)

        assert_rejected(unsafe_target, "must be root")


def assert_already_current_is_idempotent() -> None:
    original = active_config(node_marker="backup-singapore")
    candidate, _, old_hash = fully_migrated(original, None)
    entries = initial_entries(candidate)
    entries[AVAILABLE] = file_state(candidate)
    entries[ACTIVE] = symlink_state("../sites-available/shuzijun-ssl.conf")
    arguments = install_arguments(entries, apply=False, old_hash_override=old_hash)
    arguments["expected_active_sha256"] = MODULE.sha256(candidate)
    arguments["expected_old_location_sha256"] = old_hash
    filesystem = FakeFilesystem(entries)
    result = make_installer(filesystem, FakeRunner()).install(**arguments)
    assert result.state == "already-current"
    assert result.account_api_state == "direct-already-current"
    assert result.content == candidate
    assert b"backup-singapore" in candidate


def assert_cli_boundaries() -> None:
    MODULE.require_backup_transaction_path(
        Path("/var/backups/shuzijun-nginx-build34/reviewed-transaction")
    )
    for unsafe in (
        Path("relative-backup"),
        Path("/var/www/html/shuzijun.com.cn/backup"),
        Path("/var/backups/shuzijun-nginx-build34/nested/transaction"),
        Path("/var/backups/shuzijun-nginx-build34/bad name"),
        Path("/var/backups/shuzijun-nginx-build34/.hidden"),
    ):
        try:
            MODULE.require_backup_transaction_path(unsafe)
        except MODULE.InstallError:
            pass
        else:
            raise AssertionError(f"unsafe backup path accepted: {unsafe}")
    parser_destinations = {action.dest for action in MODULE.parser()._actions}
    assert "active" not in parser_destinations
    assert "available" not in parser_destinations
    assert "sensitive_target" not in parser_destinations
    assert "legacy_target" not in parser_destinations
    assert "account_api_target" not in parser_destinations
    assert "expected_account_api_snippet" in parser_destinations
    assert "expected_old_direct_account_api_location_sha256" in parser_destinations
    assert "expected_old_snippet_account_api_location_sha256" in parser_destinations


def assert_real_backup_directory_fsync_order() -> None:
    class BackupTraceFilesystem(MODULE.RealFilesystem):
        def __init__(self) -> None:
            self.events: list[tuple[str, str]] = []

        def require_root_only_directory(self, path: Path, label: str) -> None:
            assert path.is_dir(), (path, label)

        def atomic_write(
            self, path: Path, data: bytes, mode: int, uid: int, gid: int
        ) -> None:
            self.events.append(("write", str(path)))

        def _sync_directory(self, path: Path) -> None:
            self.events.append(("fsync", str(path)))

    with tempfile.TemporaryDirectory(prefix="yishu-nginx-backup-trace-") as temporary:
        root = Path(temporary) / "backup-root"
        root.mkdir(mode=0o700)
        transaction = root / "transaction"
        filesystem = BackupTraceFilesystem()
        original_chown = MODULE.os.chown
        MODULE.os.chown = lambda path, uid, gid: None
        try:
            filesystem.create_backup(
                transaction,
                {
                    "active": file_state(b"active\n"),
                    "legacy-snippet": MODULE.FileState("absent"),
                },
            )
        finally:
            MODULE.os.chown = original_chown
        first_write = next(
            index for index, event in enumerate(filesystem.events) if event[0] == "write"
        )
        assert ("fsync", str(root)) in filesystem.events[:first_write]
        assert filesystem.events[-2:] == [
            ("fsync", str(transaction)),
            ("fsync", str(root)),
        ]


def assert_real_atomic_failure_can_restore_exactly() -> None:
    filesystem = MODULE.RealFilesystem()
    current_uid = os.getuid()
    current_gid = os.getgid()

    def fail_once_after_replace(action) -> None:
        original_replace = MODULE.os.replace
        calls = 0

        def replace_then_fail(source, target) -> None:
            nonlocal calls
            calls += 1
            original_replace(source, target)
            if calls == 1:
                raise OSError("injected failure after atomic replace")

        MODULE.os.replace = replace_then_fail
        try:
            action()
        finally:
            MODULE.os.replace = original_replace
        assert calls >= 2  # failed replacement followed by rollback replacement

    with tempfile.TemporaryDirectory(prefix="yishu-nginx-atomic-trace-") as temporary:
        root = Path(temporary)
        regular = root / "regular.conf"
        regular.write_bytes(b"original bytes\n")
        regular.chmod(0o640)
        original_regular = filesystem.snapshot(regular)

        def write_then_restore() -> None:
            try:
                filesystem.atomic_write(
                    regular,
                    b"candidate bytes\n",
                    0o644,
                    current_uid,
                    current_gid,
                )
            except OSError as error:
                assert "after atomic replace" in str(error)
            else:
                raise AssertionError("post-replace write fault did not propagate")
            filesystem.restore(regular, original_regular)

        fail_once_after_replace(write_then_restore)
        assert filesystem.snapshot(regular) == original_regular

        link = root / "enabled.conf"
        link.symlink_to("original-target.conf")
        original_link = filesystem.snapshot(link)

        def symlink_then_restore() -> None:
            try:
                filesystem.atomic_symlink(
                    link,
                    "candidate-target.conf",
                    current_uid,
                    current_gid,
                )
            except OSError as error:
                assert "after atomic replace" in str(error)
            else:
                raise AssertionError("post-replace symlink fault did not propagate")
            filesystem.restore(link, original_link)

        fail_once_after_replace(symlink_then_restore)
        assert filesystem.snapshot(link) == original_link


def main() -> None:
    assert_dry_run_uses_only_active()
    assert_apply_requires_reviewed_location_hash()
    assert_successful_transaction()
    assert_backup_account_api_transaction()
    assert_backup_account_api_failures_roll_back()
    assert_account_api_gates_and_topology()
    assert_account_api_toctou_and_unused_target()
    assert_account_api_already_migrated_parameter_gates()
    assert_baseline_failure_does_not_write(1)  # existing nginx -t
    assert_baseline_failure_does_not_write(2)  # existing service state
    assert_command_failure_rolls_back(3)  # candidate nginx -t
    assert_command_failure_rolls_back(4)  # reload
    assert_command_failure_rolls_back(5)  # is-active confirmation
    assert_atomic_filesystem_failures_roll_back()
    assert_drift_and_unsafe_inputs_rejected()
    assert_sensitive_exact_location_mirror()
    assert_nginx_tokenizer_semantics()
    assert_candidate_semantic_bypass_gates()
    assert_fixed_snippet_semantic_gates()
    assert_recursive_include_contract()
    assert_enabled_and_target_identity_gates()
    assert_already_current_is_idempotent()
    assert_cli_boundaries()
    assert_real_backup_directory_fsync_order()
    assert_real_atomic_failure_can_restore_exactly()
    print("install-build34-nginx-routing-contract-test: passed")


if __name__ == "__main__":
    main()
