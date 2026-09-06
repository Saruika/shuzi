#!/usr/bin/python3 -I
"""Primary-only, hash-pinned hotfix for transient shared-lock contention.

Default: read-only plan. --apply changes only the installed sender. It neither
runs a synchronization nor changes the receiver, PHP, nginx, or user data.
The already-deployed v5 source is deliberately pinned independently of pending
working-tree changes. --rollback restores the exact saved pre-hotfix bytes.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

TARGET = Path('/usr/local/sbin/sync-to-backup')
STATE = Path('/var/lib/shuzijun-sync')
OUTER_LOCK = Path('/run/shuzijun-sync/sync.lock')
OPERATION_LOCK = STATE / 'site-operation.lock'
BACKUP_DIR = Path('/var/backups/shuzijun-sync-lock-wait-20260906')
BACKUP = BACKUP_DIR / 'sender-before.sh'
ROLE_VERIFIER = Path('/usr/local/sbin/verify-shuzijun-account-authority-role')
ROLE_SHA256 = '5fe67111642c53895e16afd0a9d6a341af881c3711736f9fe40a34b830e20a58'
OLD_SHA256 = '8496e3e7b859d46ad3aff6e379f44b84ffb8fd33ce041bce6b7622a5c4e2c65e'
NEW_SHA256 = 'dae9f1508c0051cdff097ab0d4c194c80ce4ef0b61ef8c98070bd40ef5963be9'
SERVICE = 'shuzijun-sync.service'
TIMER = 'shuzijun-sync.timer'
ENV = {'PATH':'/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL':'C', 'LANG':'C'}
OLD_LOCK = b'    flock -n 8 || return 1\n'
NEW_LOCK = b'''    # A push sweep holds this same inode in shared mode for a bounded time.
    # Preserve exclusion, but do not discard a daily sync for that brief overlap.
    local site_lock_status
    if /usr/bin/flock -n -E 75 8; then
        :
    else
        site_lock_status=$?
        if (( site_lock_status != 75 )); then
            printf 'sync sender: operation lock error (status=%s)\\n' "$site_lock_status" >&2
            return "$site_lock_status"
        fi
        printf 'sync sender: operation lock busy; waiting at most 60 seconds\\n' >&2
        if /usr/bin/flock -w 60 -E 75 8; then
            printf 'sync sender: operation lock acquired after waiting\\n' >&2
        else
            site_lock_status=$?
            printf 'sync sender: operation lock wait failed (status=%s)\\n' "$site_lock_status" >&2
            return "$site_lock_status"
        fi
    fi
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def transform(data: bytes) -> bytes:
    if digest(data) != OLD_SHA256 or data.count(OLD_LOCK) != 1:
        raise ValueError('unreviewed sender or non-unique lock boundary')
    result = data.replace(OLD_LOCK, NEW_LOCK, 1)
    if digest(result) != NEW_SHA256:
        raise ValueError('candidate digest mismatch')
    return result


def command(args: list[str], timeout: float = 15) -> str:
    result = subprocess.run(args, cwd='/', env=ENV, capture_output=True,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed with status {result.returncode}')
    return result.stdout.strip()


def directory(path: Path, private: bool = False) -> None:
    current = path
    while True:
        meta = current.lstat()
        if (not stat.S_ISDIR(meta.st_mode) or current.resolve(strict=True) != current
                or meta.st_uid != 0 or meta.st_gid != 0
                or stat.S_IMODE(meta.st_mode) & 0o022):
            raise ValueError('untrusted directory chain')
        if current == path and private and stat.S_IMODE(meta.st_mode) != 0o700:
            raise ValueError('private directory mode mismatch')
        if current == current.parent:
            break
        current = current.parent


def read_regular(path: Path, mode: int) -> bytes:
    directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_gid != 0
                or meta.st_nlink != 1 or stat.S_IMODE(meta.st_mode) != mode
                or meta.st_size > 512 * 1024):
            raise ValueError('untrusted regular file')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read(512 * 1024 + 1)
        named = path.lstat()
        if ((meta.st_dev, meta.st_ino, meta.st_size, meta.st_mtime_ns)
                != (named.st_dev, named.st_ino, named.st_size, named.st_mtime_ns)
                or len(data) != meta.st_size):
            raise ValueError('file changed during read')
        return data
    finally:
        os.close(fd)


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish(data: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix='.sync-lock-wait-', dir=TARGET.parent)
    pending = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            # main verifies root ownership, trusted parents and the full source
            # digest. This non-secret executable must retain the installed 0755
            # contract; group/other receive no write permission. See regression.
            os.fchmod(stream.fileno(), 0o755)  # nosec B103
            os.fsync(stream.fileno())
        command(['/bin/bash', '-n', str(pending)])
        os.replace(pending, TARGET)
        fsync_directory(TARGET.parent)
    finally:
        if pending.exists():
            pending.unlink()


def properties(unit: str) -> dict[str, str]:
    text = command(['/usr/bin/systemctl', 'show', unit,
                    '--property=LoadState,ActiveState,SubState,Job'])
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def ensure_idle() -> None:
    values = properties(SERVICE)
    if (values.get('LoadState') != 'loaded' or values.get('Job')
            or values.get('ActiveState') not in {'inactive', 'failed'}):
        raise ValueError('sender is not safely idle')


def lock_file(path: Path, timeout: float) -> int:
    directory(path.parent, private=True)
    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_gid != 0
                or meta.st_nlink != 1 or stat.S_IMODE(meta.st_mode) != 0o600):
            raise ValueError('untrusted operation lock')
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('operation lock still busy')
                time.sleep(0.1)
        named = path.lstat()
        if (meta.st_dev, meta.st_ino) != (named.st_dev, named.st_ino):
            raise ValueError('operation lock identity changed')
        return fd
    except BaseException:
        os.close(fd)
        raise


def main(argv: list[str]) -> int:
    if argv not in [[], ['--dry-run'], ['--apply'], ['--rollback']]:
        raise ValueError('usage: repair-shuzijun-sync-lock-wait.py [--dry-run|--apply|--rollback]')
    if os.geteuid() != 0:
        raise ValueError('run as root on the primary node')
    if digest(read_regular(ROLE_VERIFIER, 0o755)) != ROLE_SHA256:
        raise ValueError('authority verifier digest mismatch')
    command(['/usr/bin/python3', '-I', str(ROLE_VERIFIER), 'authority'])
    current = read_regular(TARGET, 0o755)
    current_hash = digest(current)
    rollback = argv == ['--rollback']
    desired_hash = OLD_SHA256 if rollback else NEW_SHA256
    if current_hash == desired_hash:
        print(json.dumps({'changed':False, 'sha256':current_hash, 'already_applied':True}))
        return 0
    if rollback:
        if current_hash != NEW_SHA256:
            raise ValueError('refusing rollback of an unknown sender')
        directory(BACKUP_DIR, private=True)
        candidate = read_regular(BACKUP, 0o600)
        if digest(candidate) != OLD_SHA256:
            raise ValueError('backup digest mismatch')
    else:
        candidate = transform(current)
    ensure_idle()
    if argv in [[], ['--dry-run']]:
        print(json.dumps({'changed':False, 'dry_run':True, 'old_sha256':current_hash,
                          'candidate_sha256':digest(candidate), 'lock_wait_seconds':60}))
        return 0
    timer = properties(TIMER)
    if timer.get('LoadState') != 'loaded' or timer.get('Job') or timer.get('ActiveState') not in {'active','inactive'}:
        raise ValueError('unexpected sync timer state')
    was_active = timer['ActiveState'] == 'active'
    held: list[int] = []
    try:
        if was_active:
            command(['/usr/bin/systemctl', 'stop', TIMER])
        if properties(TIMER).get('ActiveState') != 'inactive':
            raise ValueError('timer did not stop')
        ensure_idle()
        held.append(lock_file(OUTER_LOCK, 0))
        held.append(lock_file(OPERATION_LOCK, 60))
        ensure_idle()
        if read_regular(TARGET, 0o755) != current:
            raise ValueError('sender changed before publication')
        if not rollback:
            directory(BACKUP_DIR.parent)
            try:
                BACKUP_DIR.mkdir(mode=0o700)
                fsync_directory(BACKUP_DIR.parent)
            except FileExistsError:
                pass
            directory(BACKUP_DIR, private=True)
            try:
                fd = os.open(BACKUP, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError:
                if read_regular(BACKUP, 0o600) != current:
                    raise ValueError('existing backup differs')
            else:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(current)
                    stream.flush()
                    os.fsync(stream.fileno())
                fsync_directory(BACKUP_DIR)
        publish(candidate)
        if digest(read_regular(TARGET, 0o755)) != desired_hash:
            raise ValueError('installed sender digest mismatch')
    except BaseException:
        # os.replace may have succeeded even if the following fsync failed.
        # Restore only our exact candidate, never overwrite an unknown writer.
        if digest(read_regular(TARGET, 0o755)) == digest(candidate):
            publish(current)
        raise
    finally:
        for fd in reversed(held):
            os.close(fd)
        if was_active:
            command(['/usr/bin/systemctl', 'start', TIMER])
            if properties(TIMER).get('ActiveState') != 'active':
                raise ValueError('sync timer not restored')
    print(json.dumps({'changed':True, 'sha256':desired_hash, 'backup':str(BACKUP),
                      'timer_restored':was_active, 'synchronization_started':False}))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:
        print(f'sync-lock-repair: {error}', file=sys.stderr)
        raise SystemExit(1)
