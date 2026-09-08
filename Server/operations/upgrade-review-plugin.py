#!/usr/bin/env python3
"""Upgrade only the pinned review plugin; default is read-only preflight.

Keeps accounts, content, configuration and outbound isolation unchanged. A
failed apply restores original plugin bytes before restarting review PHP.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import uuid

spec = importlib.util.spec_from_file_location('review_acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
b = a.bootstrap
a.HTTPS_EDGE = True
LIVE = b.SITE / 'wp-content/mu-plugins'
BASELINE = '5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe'
TARGET = '942a95ee1174707716282998229ada7ea3759328fd3b425a55c8a383e910b4b6'
CHANGED = (
    'vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php',
    'vendor/shuzijun/app-content/class-shuzijun-app-content-api.php',
    'shuzijun-app-content.php',  # Commit entry/version last while PHP is stopped.
)
PHP_UNIT = 'shuzijun-review-php.service'
UNITS = (PHP_UNIT, 'shuzijun-review-web.service')


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def protected_file(path):
    check(path.is_absolute() and path.resolve() == path, 'noncanonical file')
    metadata = path.lstat()
    check(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == 0
          and stat.S_IMODE(metadata.st_mode) & 0o022 == 0, 'unprotected file')
    return path.read_bytes(), metadata


def preflight(source):
    check(os.geteuid() == 0, 'root required')
    for directory in (source, LIVE, b.CONFIG):
        check(directory.is_absolute() and directory.resolve() == directory and directory.is_dir(),
              'noncanonical directory')
        metadata = directory.stat()
        check(metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) & 0o022 == 0, 'unprotected directory')
    for parent in source.parents:
        metadata = parent.stat()
        protected = metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) & 0o022 == 0
        # A root-owned sticky parent protects the already-verified root-owned
        # child from replacement, without trusting a particular temp pathname.
        sticky_parent = metadata.st_uid == 0 and metadata.st_mode & stat.S_ISVTX
        check(protected or sticky_parent, 'replaceable candidate ancestor')
    check(b.manifest(source) == TARGET, 'candidate differs from reviewed release')
    check(b.manifest(LIVE) == BASELINE, 'unexpected live release; do not replay')
    for path in [*b.plugin_files(source), *b.plugin_files(LIVE)]:
        protected_file(path)
    different = {p.relative_to(source).as_posix() for p in b.plugin_files(source)
                 if p.read_bytes() != (LIVE / p.relative_to(source)).read_bytes()}
    check(different == set(CHANGED), 'unexpected plugin changes')
    isolation = LIVE / '000-review-bootstrap.php'
    check(protected_file(isolation)[0] == protected_file(source / 'operations/review/000-review-bootstrap.php')[0],
          'outbound isolation differs')
    check(a.wp_eval("echo DB_NAME;").strip() == b.DATABASE, 'unexpected review database')
    for unit in UNITS:
        check(protected_file(Path('/etc/systemd/system') / unit)[0]
              == protected_file(source / 'operations/review' / unit)[0], 'review service definition differs')
        check(not b.command(['/usr/bin/systemctl', 'show', unit, '--property=DropInPaths', '--value']).strip(),
              'unexpected review service override')
    b.command(['/usr/bin/systemctl', 'is-active', *UNITS])
    for relative in CHANGED:
        b.command(['/usr/bin/php', '-l', str(source / relative)])
    return {relative: (protected_file(LIVE / relative), (source / relative).read_bytes()) for relative in CHANGED}


def atomic_replace(path, data, metadata):
    temporary = path.with_name('.review-upgrade-' + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fchown(handle.fileno(), metadata.st_uid, metadata.st_gid)
            os.fchmod(handle.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()  # Only the exact file created by this invocation.


def restore_originals(snapshots):
    # Validate all targets before overwriting any: never clobber foreign changes.
    for relative, ((old, _), new) in snapshots.items():
        current, _ = protected_file(LIVE / relative)
        check(digest(current) in (digest(old), digest(new)), 'foreign change prevents automatic rollback')
    for relative, ((old, metadata), _) in snapshots.items():
        atomic_replace(LIVE / relative, old, metadata)
    check(b.manifest(LIVE) == BASELINE, 'rollback manifest mismatch')


def apply(source):
    snapshots = preflight(source)
    protected_paths = (LIVE / '000-review-bootstrap.php', b.SITE / 'wp-config.php')
    unchanged = {p: protected_file(p)[0] for p in protected_paths}
    backup = b.CONFIG / ('plugin-backup-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700)
    records = []
    for relative, ((old, metadata), new) in snapshots.items():
        destination = backup / relative
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        b.write_new(destination, old.decode('utf-8'), 0o600)
        check(destination.read_bytes() == old, 'backup differs')
        records.append({'path': relative, 'before': digest(old), 'after': digest(new),
                        'mode': stat.S_IMODE(metadata.st_mode), 'uid': metadata.st_uid, 'gid': metadata.st_gid})
    journal = {'baseline': BASELINE, 'target': TARGET, 'files': records, 'state': 'prepared'}
    b.write_new(backup / 'prepared.json', json.dumps(journal), 0o600)
    for directory in sorted((p for p in backup.rglob('*') if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        sync_directory(directory)
    sync_directory(backup)
    sync_directory(b.CONFIG)
    stop_attempted = False
    try:
        check(b.manifest(LIVE) == BASELINE, 'live changed after preflight')
        stop_attempted = True
        # Web Requires PHP: stopping PHP also stops web. Restart both, in the
        # declared dependency order, on success and rollback alike.
        b.command(['/usr/bin/systemctl', 'stop', *reversed(UNITS)])
        for relative, ((_, metadata), new) in snapshots.items():
            atomic_replace(LIVE / relative, new, metadata)
        check(b.manifest(LIVE) == TARGET, 'installed manifest mismatch')
        check(all(protected_file(p)[0] == data for p, data in unchanged.items()), 'configuration changed')
        b.command(['/usr/bin/systemctl', 'start', *UNITS])
        b.wait_for_php()
        status, _ = a.request('app-admin/session')
        check(status in (401, 403), 'anonymous management not denied')
        scope = a.wp_eval("$r = new ReflectionMethod('Shuzijun_App_Content_API', 'manifest'); "
                          "$m = $r->invoke(null, 'admin'); echo $m['contentAudience'];").strip()
        check(scope == 'administrator', 'new content protocol unavailable')
        journal['state'] = 'installed-and-health-checked'
        b.write_new(backup / 'completed.json', json.dumps(journal), 0o600)
        sync_directory(backup)
        print('review-plugin: installed pinned release; PHP/API checks passed; backup=' + str(backup))
    except Exception:
        if stop_attempted:
            b.command(['/usr/bin/systemctl', 'stop', *reversed(UNITS)])
            restore_originals(snapshots)
            b.command(['/usr/bin/systemctl', 'start', *UNITS])
            b.wait_for_php()
            journal['state'] = 'rolled-back'
            b.write_new(backup / 'rollback.json', json.dumps(journal), 0o600)
            sync_directory(backup)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not args.apply:
        preflight(args.source)
        print('review-plugin: read-only preflight passed; no services or plugin files changed')
        return
    # Validate the fixed private lock directory before creating anything.
    check(os.geteuid() == 0 and b.CONFIG.resolve() == b.CONFIG, 'invalid private configuration root')
    metadata = b.CONFIG.stat()
    check(metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) & 0o022 == 0, 'unsafe lock directory')
    descriptor = os.open(b.CONFIG / 'plugin-maintenance.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        apply(args.source)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('review-plugin: failed: ' + type(error).__name__ + '; inspect private backup journal')
        raise SystemExit(1) from None
