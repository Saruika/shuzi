import importlib.util
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path


VERIFIER = Path("Server/operations/verify-account-authority-role.py")
CONFIGURATOR = Path("Server/operations/configure-account-authority.py")
DEPLOYER = Path("Server/operations/deploy-app-content-release")
PLUGIN = Path(
    "Server/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php"
)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if fragment in lines[index]:
            return index
    raise AssertionError(f"missing deployer operation: {fragment}")


def expect_payload_rejected(verifier, payload: bytes, role: str) -> None:
    try:
        verifier.verify_payload(payload, role)
    except verifier.VerificationError:
        return
    raise AssertionError(f"unsafe marker was accepted: role={role} payload={payload!r}")


def main() -> None:
    verifier = load_module("account_authority_verifier", VERIFIER)
    configurator = load_module("account_authority_configurator", CONFIGURATOR)
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    configurator_text = CONFIGURATOR.read_text(encoding="utf-8")
    deployer_text = DEPLOYER.read_text(encoding="utf-8")
    deployer_lines = deployer_text.splitlines()
    plugin_text = PLUGIN.read_text(encoding="utf-8")
    verifier_sha256 = hashlib.sha256(VERIFIER.read_bytes()).hexdigest()

    assert verifier_text.splitlines()[0] == "#!/usr/bin/python3 -I"
    assert configurator_text.splitlines()[0] == "#!/usr/bin/python3 -I"
    verifier.verify_payload(b"authority\n", "authority")
    verifier.verify_payload(b"standby\n", "standby")
    for payload, role in (
        (b"standby\n", "authority"),
        (b"authority\n", "standby"),
        (b"authority", "authority"),
        (b"authority\r\n", "authority"),
        (b"Authority\n", "authority"),
        (b"authority\nextra", "authority"),
        (b"", "standby"),
    ):
        expect_payload_rejected(verifier, payload, role)

    for guard in (
        'ROLE_PATH = Path("/etc/shuzijun/account-authority-role")',
        'PARENT_CHAIN = (Path("/etc"), Path("/etc/shuzijun"))',
        'getattr(os, "O_NOFOLLOW", 0)',
        "metadata.st_uid != 0 or metadata.st_gid != 0",
        "stat.S_IMODE(metadata.st_mode) != 0o755",
        "stat.S_IMODE(metadata.st_mode) != 0o644",
        "metadata.st_nlink != 1",
        'VALID_PAYLOADS = {"authority": b"authority\\n", "standby": b"standby\\n"}',
    ):
        assert guard in verifier_text
    for prohibited_inference in (
        "HTTP_HOST",
        "REMOTE_ADDR",
        "X-Forwarded",
        "socket.gethostname",
        "os.uname",
        "wp-config.php",
    ):
        assert prohibited_inference not in verifier_text
        assert prohibited_inference not in configurator_text

    assert "const ACCOUNT_AUTHORITY_ROLE_PATH = '/etc/shuzijun/account-authority-role';" in plugin_text
    assert '$payload === "authority\\n"' in plugin_text

    for transaction_guard in (
        'OPERATION_LOCK_ROOT = Path("/var/lib/shuzijun-sync")',
        'OPERATION_LOCK = OPERATION_LOCK_ROOT / "site-operation.lock"',
        "--confirm-single-writer",
        "--confirm-writers-drained",
        "--expected-current-sha256",
        "authority marker changed after preflight",
        "previous-state",
        "os.replace(temp_path, ROLE_PATH)",
        "_atomic_replace(current)",
        "_run_verifier(target_role)",
        "backup directory must be an immediate child of the fixed backup root",
        "fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)",
        "_fsync_directory(BACKUP_ROOT)",
        "authority marker rollback did not restore absence",
        "php8.3-fpm must be persistently masked and inactive/dead before role change",
        "_record_commit(backup_dir, target_role)",
        "fixed marker parent mode must be exactly 0755",
        "site-operation lock root mode must be exactly 0700",
        "site-operation lock file or opened inode is unsafe",
        "os.O_EXCL",
        'getattr(os, "O_NOFOLLOW", 0)',
        "metadata.st_nlink != 1",
        "metadata.st_size != 0",
        "os.fsync(root_descriptor)",
    ):
        assert transaction_guard in configurator_text
    assert f'VERIFIER_SHA256 = "{verifier_sha256}"' in configurator_text
    for verifier_fd_guard in (
        'getattr(os, "O_NOFOLLOW", 0)',
        "metadata = os.fstat(descriptor)",
        "stat.S_IMODE(metadata.st_mode) != 0o755",
        "metadata.st_nlink != 1",
        'f"/proc/self/fd/{descriptor}"',
        "pass_fds=(descriptor,)",
        "os.close(descriptor)",
    ):
        assert verifier_fd_guard in configurator_text
    configurator_lines = configurator_text.splitlines()
    configurator_main = line_number(configurator_lines, "def main(argv: list[str])")
    config_lock = line_number(
        configurator_lines,
        "root_lock_fd, lock_fd = _acquire_operation_lock(create=args.apply)",
        configurator_main,
    )
    locked_current = line_number(
        configurator_lines, "current, _ = _read_current()", config_lock
    )
    drain_gate = line_number(
        configurator_lines, "_require_writers_drained()", locked_current
    )
    apply_call = line_number(
        configurator_lines, "_apply(current, args.role, args.backup_dir, lock_fd)", drain_gate
    )
    assert config_lock < locked_current < drain_gate < apply_call
    apply_definition = configurator_text[
        configurator_text.index("def _apply("):configurator_text.index("def _arguments(")
    ]
    assert apply_definition.count("_require_writers_drained()") == 2
    assert "deferred_signals.append(signum)" in configurator_text

    original_run = configurator.subprocess.run
    try:
        configurator.subprocess.run = lambda *_args, **_kwargs: type(
            "Result",
            (),
            {
                "returncode": 0,
                "stdout": "LoadState=masked\nActiveState=inactive\nSubState=dead\n",
            },
        )()
        configurator._require_writers_drained()
        configurator.subprocess.run = lambda *_args, **_kwargs: type(
            "Result",
            (),
            {
                "returncode": 0,
                "stdout": "LoadState=loaded\nActiveState=active\nSubState=running\n",
            },
        )()
        try:
            configurator._require_writers_drained()
        except configurator.ConfigurationError:
            pass
        else:
            raise AssertionError("active PHP-FPM was accepted as drained")
    finally:
        configurator.subprocess.run = original_run

    with tempfile.TemporaryDirectory(prefix="yishu-authority-marker-") as temp_dir:
        root = Path(temp_dir).resolve()
        role_root = root / "etc" / "shuzijun"
        site = root / "site"
        backup_root = root / "backups"
        operation_root = root / "var" / "lib" / "shuzijun-sync"
        role_root.mkdir(parents=True)
        site.mkdir()
        backup_root.mkdir()
        operation_root.mkdir(parents=True, mode=0o700)
        operation_root.chmod(0o700)
        role_path = role_root / "account-authority-role"

        configurator.ROLE_ROOT = role_root
        configurator.ROLE_PATH = role_path
        configurator.OPERATION_LOCK_ROOT = operation_root
        configurator.OPERATION_LOCK = operation_root / "site-operation.lock"
        configurator.ROOT_UID = os.geteuid()
        configurator.ROOT_GID = os.getegid()
        configurator.BACKUP_ROOT = backup_root
        configurator.os.fchown = lambda *_args: None
        configurator._read_current = lambda: (
            (role_path.read_bytes(), role_path.stat()) if role_path.exists() else (None, None)
        )

        def local_verifier(role: str) -> None:
            verifier.verify_payload(role_path.read_bytes(), role)

        configurator._run_verifier = local_verifier
        configurator._require_writers_drained = lambda: None
        absent_root_lock, absent_lock = configurator._acquire_operation_lock(create=False)
        try:
            assert absent_lock is None
            assert not configurator.OPERATION_LOCK.exists()
        finally:
            configurator.os.close(absent_root_lock)

        success_backup = backup_root / "authority-success"
        success_root_lock, success_lock = configurator._acquire_operation_lock(create=True)
        assert success_lock is not None
        try:
            configurator._apply(None, "authority", success_backup, success_lock)
        finally:
            configurator.os.close(success_lock)
            configurator.os.close(success_root_lock)
        operation_metadata = configurator.OPERATION_LOCK.lstat()
        assert stat.S_IMODE(operation_metadata.st_mode) == 0o600
        assert operation_metadata.st_nlink == 1
        assert operation_metadata.st_size == 0
        assert role_path.read_bytes() == b"authority\n"
        assert (success_backup / "previous-state").read_bytes() == b"absent\n"
        assert (success_backup / "committed").read_bytes() == (
            b"role=authority\nsha256="
            + hashlib.sha256(b"authority\n").hexdigest().encode("ascii")
            + b"\n"
        )

        role_path.unlink()

        def rejecting_verifier(role: str) -> None:
            if role == "authority":
                raise configurator.ConfigurationError("simulated post-write rejection")
            local_verifier(role)

        configurator._run_verifier = rejecting_verifier
        rollback_backup = backup_root / "authority-rollback"
        operation_identity = (
            configurator.OPERATION_LOCK.stat().st_dev,
            configurator.OPERATION_LOCK.stat().st_ino,
        )
        rollback_root_lock, rollback_lock = configurator._acquire_operation_lock(create=True)
        assert rollback_lock is not None
        try:
            configurator._apply(None, "authority", rollback_backup, rollback_lock)
        except configurator.ConfigurationError:
            pass
        else:
            raise AssertionError("post-write verifier failure did not abort transaction")
        finally:
            configurator.os.close(rollback_lock)
            configurator.os.close(rollback_root_lock)
        assert not role_path.exists()
        assert (rollback_backup / "previous-state").read_bytes() == b"absent\n"
        assert not (rollback_backup / "committed").exists()
        assert (
            configurator.OPERATION_LOCK.stat().st_dev,
            configurator.OPERATION_LOCK.stat().st_ino,
        ) == operation_identity

        hardlink = operation_root / "site-operation-lock-hardlink"
        os.link(configurator.OPERATION_LOCK, hardlink)
        try:
            try:
                configurator._acquire_operation_lock(create=False)
            except configurator.ConfigurationError:
                pass
            else:
                raise AssertionError("hard-linked operation lock was accepted")
        finally:
            hardlink.unlink()

        saved_lock = operation_root / "saved-site-operation-lock"
        configurator.OPERATION_LOCK.rename(saved_lock)
        configurator.OPERATION_LOCK.symlink_to(saved_lock)
        try:
            try:
                configurator._acquire_operation_lock(create=False)
            except (configurator.ConfigurationError, OSError):
                pass
            else:
                raise AssertionError("symbolic-link operation lock was accepted")
        finally:
            configurator.OPERATION_LOCK.unlink()
            saved_lock.rename(configurator.OPERATION_LOCK)

        configurator.OPERATION_LOCK.write_bytes(b"not-empty\n")
        try:
            try:
                configurator._acquire_operation_lock(create=False)
            except configurator.ConfigurationError:
                pass
            else:
                raise AssertionError("nonempty operation lock was accepted")
        finally:
            configurator.OPERATION_LOCK.write_bytes(b"")
            configurator.OPERATION_LOCK.chmod(0o600)

    assert (
        "readonly AUTHORITY_VERIFY=/usr/local/sbin/verify-shuzijun-account-authority-role"
        in deployer_lines
    )
    assert f"readonly AUTHORITY_VERIFY_SHA256={verifier_sha256}" in deployer_lines
    assert 'verifier_sha256=$(sha256sum "$verifier_fd_path"' in deployer_text
    assert '[[ "$verifier_sha256" == "$AUTHORITY_VERIFY_SHA256" ]]' in deployer_text
    assert 'exec 7<"$AUTHORITY_VERIFY"' in deployer_text
    assert '/usr/bin/python3 -I /proc/self/fd/7 "$AUTHORITY_ROLE"' in deployer_text
    assert "stat -Lc '%u:%g:%h:%a'" in deployer_text
    assert "exec 7<&-" in deployer_text
    assert 'readonly AUTHORITY_LOCK_PATH="$SITE"' not in deployer_text
    assert 'exec 8<"$SITE"' not in deployer_text
    early_lock = line_number(deployer_lines, "acquire_authority_lock", 900)
    early_gate = line_number(deployer_lines, "verify_authority_role", early_lock + 1)
    staging_lock = line_number(deployer_lines, 'exec 9<"$LOCK_PATH"', early_gate + 1)
    verify_current = line_number(deployer_lines, "verify_current_webroot", staging_lock + 1)
    dry_gate = line_number(deployer_lines, "verify_authority_role", verify_current + 1)
    dry_run = line_number(deployer_lines, 'if [[ "$MODE" == dry-run ]]', dry_gate + 1)
    strict_probe = line_number(
        deployer_lines, 'probe_unauthorized_api "$AUTHORITY_ROLE"', dry_run + 1
    )
    write_gate = line_number(deployer_lines, "verify_authority_role", strict_probe + 1)
    backup = line_number(deployer_lines, "create_code_backup", write_gate + 1)
    assert early_lock < early_gate < staging_lock < verify_current < dry_gate < dry_run
    assert dry_run < strict_probe < write_gate < backup
    assert 'env -i PATH="$PATH" LC_ALL=C LANG=C' in deployer_text
    assert "python3 -I -" in deployer_text
    assert "HEALTH_INDEX_URL" in deployer_text
    assert 'for url in "$HEALTH_URL" "$HEALTH_INDEX_URL"' in deployer_text

    print("account-authority-role-contract-test: passed")


if __name__ == "__main__":
    main()
