#!/usr/bin/env python3
"""Narrow, reversible JSON protection for the two reviewed production nodes."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

SITE = Path('/etc/nginx/sites-available/shuzijun-ssl.conf')
BACKUPS = Path('/var/backups/shuzijun-app-content')
LOCK = Path('/var/lib/shuzijun-sync/site-operation.lock')
ANCHOR = b'    include /etc/nginx/snippets/shuzijun-legacy-images-alias.conf;\n'
RULE = (b'    # Server-side game rules are not a public media resource.\n'
        b'    location = /wp-content/mu-plugins/vendor/shuzijun/app-content/game-rules-v1.json {\n'
        b'        access_log off;\n        log_not_found off;\n        return 404;\n    }\n')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def candidate(old):
    if old.count(ANCHOR) != 2 or b'game-rules-v1.json' in old:
        raise RuntimeError('unreviewed config shape')
    return old.replace(ANCHOR, ANCHOR + RULE)


def secure(path, directory=False, mode=None):
    info = path.lstat()
    if (path.resolve() != path or info.st_uid != 0 or info.st_gid != 0
            or (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) is False
            or info.st_mode & 0o022 or (not directory and info.st_nlink != 1)
            or (mode is not None and stat.S_IMODE(info.st_mode) != mode)):
        raise RuntimeError('unsafe fixed boundary')


def atomic(value):
    fd, name = tempfile.mkstemp(prefix='.game-json-', dir=SITE.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(value)
        stream.flush()
        os.fchmod(stream.fileno(), 0o644)
        os.fsync(stream.fileno())
    os.replace(name, SITE)
    fd = os.open(SITE.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def run(args):
    result = subprocess.run(args, capture_output=True, timeout=90, check=False)
    if result.returncode:
        raise RuntimeError('configuration validation or reload failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('root required')
    for path in (Path('/etc/nginx'), SITE.parent, BACKUPS, LOCK.parent):
        secure(path, directory=True)
    secure(SITE, mode=0o644)
    secure(LOCK, mode=0o600)
    fd = os.open(LOCK, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old = SITE.read_bytes()
        if digest(old) != args.expected_sha256:
            raise RuntimeError('live config hash changed')
        new = candidate(old)
        report = {'oldSHA256': digest(old), 'newSHA256': digest(new), 'locations': 2}
        if not args.apply:
            print(json.dumps({**report, 'state': 'preflight', 'changed': False}))
            return
        backup = Path(tempfile.mkdtemp(prefix='game-json-nginx-', dir=BACKUPS))
        original = backup / 'shuzijun-ssl.conf'
        with original.open('xb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(old)
            stream.flush()
            os.fsync(stream.fileno())
        for directory in (backup, BACKUPS):
            parent_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
        if SITE.read_bytes() != old:
            raise RuntimeError('live config changed before replacement')
        try:
            # os.replace can succeed before atomic()'s directory fsync fails.
            # The replacement therefore belongs inside the recovery boundary.
            atomic(new)
            run(['/usr/sbin/nginx', '-t'])
            run(['/usr/local/sbin/verify-shuzijun-webroot-security'])
            run(['/usr/bin/systemctl', 'reload', 'nginx'])
            run(['/usr/bin/systemctl', 'is-active', '--quiet', 'nginx'])
        except BaseException as failure:
            # Never replace a foreign file or use a changed/missing backup.
            # A pre-replace failure leaves the old config untouched and must
            # not trigger a redundant replacement/reload or hide its cause.
            try:
                secure(SITE, mode=0o644)
                secure(original, mode=0o600)
                live = SITE.read_bytes()
                saved = original.read_bytes()
            except (OSError, RuntimeError) as inspection:
                raise RuntimeError('rollback refused; live or backup cannot be verified') from inspection
            if saved != old or live not in (old, new):
                raise RuntimeError('rollback refused after foreign change') from failure
            if live == old:
                raise
            try:
                # Only the exact candidate may be rolled back to the retained
                # exact original. A failed rollback remains an explicit error.
                atomic(old)
                run(['/usr/sbin/nginx', '-t'])
                run(['/usr/bin/systemctl', 'reload', 'nginx'])
                run(['/usr/bin/systemctl', 'is-active', '--quiet', 'nginx'])
            except BaseException as rollback_failure:
                raise RuntimeError('rollback failed or unverified; backup retained') from rollback_failure
            raise RuntimeError('new config rejected; original restored') from failure
        print(json.dumps({**report, 'state': 'applied', 'backup': str(original)}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit('game-json-protection: ' + str(error)) from None
