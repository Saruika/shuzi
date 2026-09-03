#!/usr/bin/python3 -I
"""Atomic, reversible transaction for the fixed account-authority marker."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROLE_PATH = Path("/etc/shuzijun/account-authority-role")
ROLE_ROOT = ROLE_PATH.parent
OPERATION_LOCK_ROOT = Path("/var/lib/shuzijun-sync")
OPERATION_LOCK = OPERATION_LOCK_ROOT / "site-operation.lock"
VERIFIER = Path("/usr/local/sbin/verify-shuzijun-account-authority-role")
VERIFIER_SHA256 = "5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58"
BACKUP_ROOT = Path("/var/backups/shuzijun-account-authority")
PAYLOADS = {"authority": b"authority\n", "standby": b"standby\n"}
ROOT_UID = 0
ROOT_GID = 0


class ConfigurationError(RuntimeError):
    pass


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _safe_path(
    path: Path, *, directory: bool, require_root_group: bool = True
) -> os.stat_result:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ConfigurationError(f"unsafe fixed path {path}: {error.strerror}") from error
    correct_type = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not correct_type or path.is_symlink() or resolved != path:
        raise ConfigurationError(f"fixed path is not canonical: {path}")
    if (
        metadata.st_uid != ROOT_UID
        or (require_root_group and metadata.st_gid != ROOT_GID)
        or metadata.st_mode & 0o022
    ):
        raise ConfigurationError(
            f"fixed path must be root-owned with a trusted group and not writable "
            f"by non-root identities: {path}"
        )
    if not directory and metadata.st_nlink != 1:
        raise ConfigurationError(f"fixed file must not be hard-linked: {path}")
    return metadata


def _read_current() -> tuple[bytes | None, os.stat_result | None]:
    try:
        ROLE_PATH.lstat()
    except FileNotFoundError:
        return None, None
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(ROLE_PATH, flags)
    except OSError as error:
        raise ConfigurationError(f"cannot safely open authority marker: {error.strerror}") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or metadata.st_gid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o644
            or metadata.st_nlink != 1
        ):
            raise ConfigurationError("authority marker ownership, mode or link count is unsafe")
        payload = os.read(descriptor, 16)
        if os.read(descriptor, 1):
            raise ConfigurationError("authority marker exceeds the fixed size")
        if payload not in PAYLOADS.values():
            raise ConfigurationError("existing authority marker has an invalid payload")
        return payload, metadata
    finally:
        os.close(descriptor)


def _open_reviewed_verifier() -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(VERIFIER, flags)
    except OSError as error:
        raise ConfigurationError(f"cannot safely open fixed authority verifier: {error.strerror}") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or metadata.st_gid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o755
            or metadata.st_nlink != 1
        ):
            raise ConfigurationError("fixed authority verifier metadata is unsafe")
        payload = bytearray()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            payload.extend(chunk)
            if len(payload) > 1024 * 1024:
                raise ConfigurationError("fixed authority verifier exceeds the size limit")
        if _sha256(bytes(payload)) != VERIFIER_SHA256:
            raise ConfigurationError("fixed authority verifier SHA256 is not the reviewed version")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _run_verifier(role: str) -> None:
    descriptor = _open_reviewed_verifier()
    try:
        result = subprocess.run(
            ["/usr/bin/python3", "-I", f"/proc/self/fd/{descriptor}", role],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "LANG": "C"},
            pass_fds=(descriptor,),
        )
    except OSError as error:
        raise ConfigurationError(f"cannot execute fixed authority verifier: {error.strerror}") from error
    finally:
        os.close(descriptor)
    if result.returncode != 0:
        raise ConfigurationError(result.stderr.strip() or "authority verifier rejected marker")


def _require_writers_drained() -> None:
    try:
        result = subprocess.run(
            [
                "/usr/bin/systemctl",
                "show",
                "php8.3-fpm",
                "--property=LoadState",
                "--property=ActiveState",
                "--property=SubState",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "LANG": "C"},
        )
    except OSError as error:
        raise ConfigurationError(f"cannot verify PHP-FPM drain state: {error.strerror}") from error
    states = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in states:
            raise ConfigurationError("cannot prove the exact PHP-FPM drain state")
        states[key] = value
    if result.returncode != 0 or states != {
        "LoadState": "masked",
        "ActiveState": "inactive",
        "SubState": "dead",
    }:
        raise ConfigurationError(
            "php8.3-fpm must be persistently masked and inactive/dead before role change"
        )


def _write_all(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise ConfigurationError("short marker write")
        view = view[written:]


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_replace(payload: bytes) -> None:
    descriptor, temp_name = tempfile.mkstemp(prefix=".account-authority-role.", dir=ROLE_ROOT)
    temp_path = Path(temp_name)
    try:
        os.fchmod(descriptor, 0o644)
        os.fchown(descriptor, 0, 0)
        _write_all(descriptor, payload)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temp_path, ROLE_PATH)
        _fsync_directory(ROLE_ROOT)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _validate_expected(current: bytes | None, expected: str) -> None:
    if expected == "absent":
        if current is not None:
            raise ConfigurationError("authority marker exists but absent was expected")
        return
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ConfigurationError("expected current SHA256 must be absent or 64 lowercase hex")
    if current is None or _sha256(current) != expected:
        raise ConfigurationError("authority marker SHA256 does not match the reviewed value")


def _validate_backup_dir(path: Path) -> None:
    if not path.is_absolute() or path.parent != BACKUP_ROOT:
        raise ConfigurationError("backup directory must be an immediate child of the fixed backup root")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", path.name):
        raise ConfigurationError("backup directory name is unsafe")
    if path.exists() or path.is_symlink():
        raise ConfigurationError("backup directory already exists")


def _create_backup(path: Path, current: bytes | None) -> None:
    path.mkdir(mode=0o700)
    state = b"absent\n" if current is None else b"present " + _sha256(current).encode() + b"\n"
    for name, payload in (("previous-state", state), ("account-authority-role", current)):
        if payload is None:
            continue
        descriptor = os.open(
            path / name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        try:
            _write_all(descriptor, payload)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    _fsync_directory(path)
    _fsync_directory(BACKUP_ROOT)


def _record_commit(path: Path, target_role: str) -> None:
    payload = b"role=" + target_role.encode("ascii") + b"\nsha256=" \
        + _sha256(PAYLOADS[target_role]).encode("ascii") + b"\n"
    descriptor = os.open(
        path / "committed",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path)
    _fsync_directory(BACKUP_ROOT)


def _validate_operation_lock_root() -> os.stat_result:
    metadata = _safe_path(OPERATION_LOCK_ROOT, directory=True)
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ConfigurationError("site-operation lock root mode must be exactly 0700")
    return metadata


def _validate_operation_lock_fd(
    descriptor: int, root_metadata: os.stat_result
) -> os.stat_result:
    try:
        metadata = os.fstat(descriptor)
        named = OPERATION_LOCK.lstat()
        resolved = OPERATION_LOCK.resolve(strict=True)
    except OSError as error:
        raise ConfigurationError(
            f"cannot validate site-operation lock inode: {error.strerror}"
        ) from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != ROOT_UID
        or metadata.st_gid != ROOT_GID
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size != 0
        or metadata.st_dev != root_metadata.st_dev
        or not stat.S_ISREG(named.st_mode)
        or (named.st_dev, named.st_ino) != (metadata.st_dev, metadata.st_ino)
        or OPERATION_LOCK.is_symlink()
        or resolved != OPERATION_LOCK
    ):
        raise ConfigurationError("site-operation lock file or opened inode is unsafe")
    return metadata


def _create_operation_lock(root_descriptor: int, root_metadata: os.stat_result) -> None:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(
            OPERATION_LOCK.name, flags, 0o600, dir_fd=root_descriptor
        )
    except FileExistsError:
        return
    except OSError as error:
        raise ConfigurationError(
            f"cannot create site-operation lock: {error.strerror}"
        ) from error
    try:
        os.fchown(descriptor, ROOT_UID, ROOT_GID)
        os.fchmod(descriptor, 0o600)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != ROOT_UID
            or metadata.st_gid != ROOT_GID
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_size != 0
            or metadata.st_dev != root_metadata.st_dev
        ):
            raise ConfigurationError("new site-operation lock metadata is unsafe")
        os.fsync(descriptor)
        os.fsync(root_descriptor)
    finally:
        os.close(descriptor)


def _acquire_operation_lock(*, create: bool) -> tuple[int, int | None]:
    root_metadata = _validate_operation_lock_root()
    root_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        root_descriptor = os.open(OPERATION_LOCK_ROOT, root_flags)
    except OSError as error:
        raise ConfigurationError(
            f"cannot open site-operation lock root: {error.strerror}"
        ) from error
    lock_descriptor: int | None = None
    try:
        opened_root = os.fstat(root_descriptor)
        named_root = OPERATION_LOCK_ROOT.lstat()
        if (
            not stat.S_ISDIR(opened_root.st_mode)
            or (opened_root.st_dev, opened_root.st_ino)
            != (named_root.st_dev, named_root.st_ino)
            or opened_root.st_uid != ROOT_UID
            or opened_root.st_gid != ROOT_GID
            or stat.S_IMODE(opened_root.st_mode) != 0o700
        ):
            raise ConfigurationError("opened site-operation lock root changed")
        fcntl.flock(root_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            OPERATION_LOCK.lstat()
        except FileNotFoundError:
            if create:
                _create_operation_lock(root_descriptor, root_metadata)
            else:
                return root_descriptor, None
        lock_flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            lock_descriptor = os.open(
                OPERATION_LOCK.name, lock_flags, dir_fd=root_descriptor
            )
        except OSError as error:
            raise ConfigurationError(
                f"cannot safely open site-operation lock: {error.strerror}"
            ) from error
        _validate_operation_lock_fd(lock_descriptor, root_metadata)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _validate_operation_lock_fd(lock_descriptor, root_metadata)
        return root_descriptor, lock_descriptor
    except BaseException:
        if lock_descriptor is not None:
            os.close(lock_descriptor)
        os.close(root_descriptor)
        raise


def _apply(
    current: bytes | None,
    target_role: str,
    backup_dir: Path,
    lock_fd: int,
) -> None:
    root_metadata = _validate_operation_lock_root()
    _validate_operation_lock_fd(lock_fd, root_metadata)
    latest, _ = _read_current()
    if latest != current:
        raise ConfigurationError("authority marker changed after preflight")
    _require_writers_drained()
    _create_backup(backup_dir, current)
    try:
        _atomic_replace(PAYLOADS[target_role])
        _run_verifier(target_role)
        _require_writers_drained()
        _record_commit(backup_dir, target_role)
    except BaseException:
        try:
            (backup_dir / "committed").unlink()
        except FileNotFoundError:
            pass
        _fsync_directory(backup_dir)
        _fsync_directory(BACKUP_ROOT)
        if current is None:
            try:
                ROLE_PATH.unlink()
            except FileNotFoundError:
                pass
            _fsync_directory(ROLE_ROOT)
            if ROLE_PATH.exists() or ROLE_PATH.is_symlink():
                raise ConfigurationError("authority marker rollback did not restore absence")
        else:
            _atomic_replace(current)
            previous_role = "authority" if current == PAYLOADS["authority"] else "standby"
            _run_verifier(previous_role)
        raise


def _arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", required=True, choices=sorted(PAYLOADS))
    parser.add_argument("--expected-current-sha256", required=True)
    parser.add_argument("--backup-dir", required=True, type=Path)
    parser.add_argument("--confirm-single-writer", action="store_true")
    parser.add_argument("--confirm-writers-drained", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", dest="apply", action="store_false")
    mode.add_argument("--apply", dest="apply", action="store_true")
    parser.set_defaults(apply=False)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = _arguments(argv)
    try:
        if os.geteuid() != 0:
            raise ConfigurationError("must run as root")
        if not args.confirm_writers_drained:
            raise ConfigurationError("--confirm-writers-drained is mandatory")
        if args.role == "authority" and not args.confirm_single_writer:
            raise ConfigurationError("--confirm-single-writer is mandatory for authority")
        for directory in (
            Path("/etc"),
            ROLE_ROOT,
            Path("/var"),
            Path("/var/lib"),
            OPERATION_LOCK_ROOT,
            Path("/usr"),
            Path("/usr/local"),
            Path("/usr/local/sbin"),
            Path("/var/backups"),
            BACKUP_ROOT,
        ):
            _safe_path(directory, directory=True)
        for marker_parent in (Path("/etc"), ROLE_ROOT):
            if stat.S_IMODE(marker_parent.stat().st_mode) != 0o755:
                raise ConfigurationError(
                    f"fixed marker parent mode must be exactly 0755: {marker_parent}"
                )
        if stat.S_IMODE(OPERATION_LOCK_ROOT.stat().st_mode) != 0o700:
            raise ConfigurationError("site-operation lock root mode must be exactly 0700")
        _safe_path(VERIFIER, directory=False)
        if not os.access(VERIFIER, os.X_OK):
            raise ConfigurationError("fixed authority verifier is not executable")
        descriptor = _open_reviewed_verifier()
        os.close(descriptor)
        _validate_backup_dir(args.backup_dir)
        root_lock_fd, lock_fd = _acquire_operation_lock(create=args.apply)
        try:
            current, _ = _read_current()
            _validate_expected(current, args.expected_current_sha256)
            if current == PAYLOADS[args.role]:
                raise ConfigurationError("authority marker already has the requested role")
            _require_writers_drained()
            deferred_signals: list[int] = []
            if args.apply:
                if lock_fd is None:
                    raise ConfigurationError("apply requires the persistent site-operation lock")
                handled_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
                previous_handlers = {item: signal.getsignal(item) for item in handled_signals}

                def defer_signal(signum, _frame):
                    deferred_signals.append(signum)

                try:
                    for item in handled_signals:
                        signal.signal(item, defer_signal)
                    _apply(current, args.role, args.backup_dir, lock_fd)
                finally:
                    for item, handler in previous_handlers.items():
                        signal.signal(item, handler)
        finally:
            if lock_fd is not None:
                os.close(lock_fd)
            os.close(root_lock_fd)
        print(
            f"account-authority-config: {'applied' if args.apply else 'dry-run passed'} "
            f"role={args.role} candidate-sha256={_sha256(PAYLOADS[args.role])}" \
            + (" deferred-signal-handled=true" if deferred_signals else "")
        )
        return 0
    except (ConfigurationError, BlockingIOError) as error:
        print(f"account-authority-config: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
