#!/usr/bin/env python3
"""Fake-filesystem/command contract for the Build 34 Nginx installer."""

from __future__ import annotations

import copy
import contextlib
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
BACKUP = Path("/var/backups/shuzijun-nginx-build34/test-transaction")
WEBROOT_IMAGES = Path("/var/www/html/shuzijun.com.cn/images")


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
                resolved = self.resolve(entry)
                selected = self.entries[resolved]
            if selected.kind == "file":
                result[entry] = selected.data
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
        "    location = /favicon.ico { return 204; }\n"
        "    location = /robots.txt { return 204; }\n"
        "    location ~ ^/health/[0-9]{1,5}$ { return 204; }\n"
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


def old_location_hash(config: bytes) -> str:
    document = MODULE.parse(config.decode(), "fixture")
    img = MODULE.unique_tls_server(document, MODULE.IMG_HOST)
    location = MODULE.images_location(img)[0]
    return MODULE.sha256(config.decode()[location.start : location.end].encode())


def initial_entries(config: bytes | None = None) -> dict[Path, object]:
    current = config or active_config()
    return {
        ACTIVE: file_state(current),
        AVAILABLE: file_state(b"# stale sites-available copy\n"),
        SENSITIVE_SOURCE: file_state(b"# reviewed sensitive Build 34\n"),
        LEGACY_SOURCE: file_state(b"# reviewed legacy alias Build 34\n"),
        SENSITIVE_TARGET: file_state(b"# old sensitive snippet\n"),
        LEGACY_TARGET: file_state(b"# old legacy snippet\n"),
        WEBROOT_IMAGES: symlink_state("wp-content/uploads/hero-images"),
    }


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
    return {
        "active": ACTIVE,
        "available": AVAILABLE,
        "sensitive_source": SENSITIVE_SOURCE,
        "legacy_source": LEGACY_SOURCE,
        "sensitive_target": SENSITIVE_TARGET,
        "legacy_target": LEGACY_TARGET,
        "expected_active_sha256": MODULE.sha256(active_data),
        "expected_available_sha256": MODULE.sha256(available.data),
        "expected_sensitive_target": (
            MODULE.sha256(sensitive_target.data) if sensitive_target else "absent"
        ),
        "expected_legacy_target": (
            MODULE.sha256(legacy_target.data) if legacy_target else "absent"
        ),
        "sensitive_source_sha256": MODULE.sha256(sensitive_source.data),
        "legacy_source_sha256": MODULE.sha256(legacy_source.data),
        "expected_old_location_sha256": old_hash_override or old_location_hash(active_data),
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


def assert_dry_run_uses_only_active() -> None:
    entries = initial_entries()
    filesystem = FakeFilesystem(entries)
    runner = FakeRunner()
    result = make_installer(filesystem, runner).install(
        **install_arguments(entries, apply=False)
    )
    assert result.state == "rewrite-required"
    assert b"primary-shanghai" in result.content
    assert b"primary-upstream" in result.content
    assert b"node-specific-apex-route.conf" in result.content
    assert (
        b"shuzijun-sensitive-files-deny.conf; # keep-comment\n"
        b"    include /etc/nginx/snippets/shuzijun-legacy-images-alias.conf;\n"
        in result.content
    )
    assert b"stale sites-available" not in result.content
    assert result.content.count(MODULE.LEGACY_INCLUDE.encode()) == 2
    parsed = MODULE.parse(result.content.decode(), "dry-run candidate")
    assert not MODULE.images_location(MODULE.unique_tls_server(parsed, MODULE.IMG_HOST))
    assert filesystem.entries == entries
    assert not filesystem.operations and not runner.calls and not filesystem.backups

    inventory_arguments = install_arguments(entries, apply=False)
    inventory_arguments["expected_old_location_sha256"] = None
    inventory = make_installer(filesystem, runner).install(**inventory_arguments)
    assert inventory.old_location_sha256 == old_location_hash(entries[ACTIVE].data)


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
    assert filesystem.entries[ACTIVE].kind == "symlink"
    assert filesystem.entries[ACTIVE].target == "../sites-available/shuzijun-ssl.conf"
    assert filesystem.entries[AVAILABLE].data == result.content
    assert filesystem.entries[SENSITIVE_TARGET].data == entries[SENSITIVE_SOURCE].data
    assert filesystem.entries[LEGACY_TARGET].data == entries[LEGACY_SOURCE].data
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
            b"location ~ ^/health/[0-9]{1,5}$",
            b"location ^~ /wp-content/",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(protected_prefix_location, "bypasses security regex rules")

    def harmless_caret_prefix(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ ^/health/[0-9]{1,5}$",
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
                b"location ~ ^/health/[0-9]{1,5}$",
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
            b"location ~ ^/health/[0-9]{1,5}$",
            b"location ^~ /",
        )
        filesystem.entries[ACTIVE] = file_state(changed)
        arguments["expected_active_sha256"] = MODULE.sha256(changed)
        arguments["expected_old_location_sha256"] = old_location_hash(changed)

    assert_rejected(wide_protected_prefix, "bypasses security regex rules")

    def inline_images_regex(filesystem, arguments) -> None:
        changed = filesystem.entries[ACTIVE].data.replace(
            b"location ~ ^/health/[0-9]{1,5}$",
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


def assert_already_current_is_idempotent() -> None:
    original = active_config(node_marker="backup-singapore")
    old_hash = old_location_hash(original)
    candidate = MODULE.rewrite_active_config(original, old_hash).content
    entries = initial_entries(candidate)
    entries[AVAILABLE] = file_state(candidate)
    entries[ACTIVE] = symlink_state("../sites-available/shuzijun-ssl.conf")
    arguments = install_arguments(entries, apply=False, old_hash_override=old_hash)
    arguments["expected_active_sha256"] = MODULE.sha256(candidate)
    arguments["expected_old_location_sha256"] = old_hash
    filesystem = FakeFilesystem(entries)
    result = make_installer(filesystem, FakeRunner()).install(**arguments)
    assert result.state == "already-current"
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
    assert_baseline_failure_does_not_write(1)  # existing nginx -t
    assert_baseline_failure_does_not_write(2)  # existing service state
    assert_command_failure_rolls_back(3)  # candidate nginx -t
    assert_command_failure_rolls_back(4)  # reload
    assert_command_failure_rolls_back(5)  # is-active confirmation
    assert_atomic_filesystem_failures_roll_back()
    assert_drift_and_unsafe_inputs_rejected()
    assert_sensitive_exact_location_mirror()
    assert_already_current_is_idempotent()
    assert_cli_boundaries()
    assert_real_backup_directory_fsync_order()
    assert_real_atomic_failure_can_restore_exactly()
    print("install-build34-nginx-routing-contract-test: passed")


if __name__ == "__main__":
    main()
