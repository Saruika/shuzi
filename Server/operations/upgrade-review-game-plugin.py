#!/usr/bin/env python3
"""Pinned review-only game plugin transaction; default is read-only preflight.

No schema/account/content writes. --apply upgrades the exact predecessor.
--restore BACKUP restores a verified interrupted transaction, leaving both
review services stopped. Never restart automatically after a failed upgrade.
"""
import argparse
from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

spec = importlib.util.spec_from_file_location(
    'game_review_acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
b = a.bootstrap
a.HTTPS_EDGE = True
ROOT_UID = 0
LIVE = b.SITE / 'wp-content/mu-plugins'
BASELINE = '5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe'
TARGET = '3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576'
PREFIX = 'vendor/shuzijun/app-content/'
CHANGED = (PREFIX + 'trait-shuzijun-app-content-delivery.php',
           PREFIX + 'trait-shuzijun-app-collaboration.php',
           PREFIX + 'trait-shuzijun-app-push-notifications.php',
           PREFIX + 'trait-shuzijun-app-fan-identity.php',
           PREFIX + 'class-shuzijun-app-content-api.php', 'shuzijun-app-content.php')
ADDED = (PREFIX + 'class-shuzijun-game-rules.php', PREFIX + 'game-rules-v1.json',
         PREFIX + 'trait-shuzijun-app-game-leaderboard.php')
WRITE_ORDER = ADDED + CHANGED  # Thin entry is always committed last.
UNITS = ('shuzijun-review-php.service', 'shuzijun-review-web.service')
ASSET_HASHES = {
    '000-review-bootstrap.php': '29f8caf26aebc14a69ed9775df2e78ec2ddf885e73898b0b941012681bd6d8f9',
    'php-fpm.conf': '61be02be75fa5d307a86fad0ebb8d1746d540360b828c3bb6ca16ab60b7ebef9',
    'nginx.conf': '9eadeb26861e9ce199e89d0feddf62aa80ae300b9d1e77dc29cc4b9198ea6dd0',
    UNITS[0]: 'ed3256d3937e8597f98eae826ff4b2a1614d2c4171664e38d08d54209928d4b5',
    UNITS[1]: '4bc2a647bbc71788de6ac71ac8688a88178c08ab8b53f1ef351b22ace86d0132',
}


class ReviewGameError(RuntimeError):
    """Only fixed non-sensitive guard labels may cross the CLI boundary."""


def check(condition, message):
    if not condition:
        raise ReviewGameError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def directory(path, *, private=False):
    check(path.is_absolute() and path.resolve() == path, 'noncanonical directory')
    info = path.lstat()
    check(stat.S_ISDIR(info.st_mode) and info.st_uid == ROOT_UID
          and stat.S_IMODE(info.st_mode) & 0o022 == 0, 'unprotected directory')
    if private:
        check(stat.S_IMODE(info.st_mode) == 0o700, 'backup directory must be private')
    for parent in path.parents:
        metadata = parent.lstat()
        check(stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == ROOT_UID
              and (stat.S_IMODE(metadata.st_mode) & 0o022 == 0
                   or metadata.st_mode & stat.S_ISVTX), 'replaceable ancestor')


def protected_file(path):
    directory(path.parent)
    check(path.is_absolute() and path.resolve() == path, 'noncanonical file')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        info = os.fstat(handle.fileno())
        check(stat.S_ISREG(info.st_mode) and info.st_uid == ROOT_UID and info.st_nlink == 1
              and stat.S_IMODE(info.st_mode) in (0o600, 0o640, 0o644)
              and info.st_size <= 8 * 1024 * 1024, 'unprotected file')
        data = handle.read(8 * 1024 * 1024 + 1)
        check(len(data) == info.st_size, 'file changed while reading')
        current = path.lstat()
        for observed in (os.fstat(handle.fileno()), current):
            check((observed.st_dev, observed.st_ino, observed.st_size, observed.st_mtime_ns,
                   observed.st_ctime_ns) == (info.st_dev, info.st_ino, info.st_size,
                                             info.st_mtime_ns, info.st_ctime_ns),
                  'file replaced or changed while reading')
    return data, info


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def absent(path):
    check(not os.path.lexists(path), 'new target already exists')


def file_map(root):
    directory(root)
    if root == LIVE:
        check({path.name for path in root.iterdir()} == {
            '000-review-bootstrap.php', 'shuzijun-app-content.php',
            'composer.json', 'composer.lock', 'vendor',
        }, 'unexpected review mu-plugin root inventory')
    return {path.relative_to(root).as_posix(): protected_file(path)
            for path in b.plugin_files(root)}


def map_manifest(files):
    return digest(''.join(digest(data) + '  ' + relative + '\n'
                         for relative, (data, _) in sorted(files.items())).encode('ascii'))


def asset_paths():
    return {
        '000-review-bootstrap.php': LIVE / '000-review-bootstrap.php',
        'php-fpm.conf': b.CONFIG / 'php-fpm.conf',
        'nginx.conf': b.CONFIG / 'nginx.conf',
        **{unit: Path('/etc/systemd/system') / unit for unit in UNITS},
        'wp-config.php': b.SITE / 'wp-config.php',
    }


def invariants():
    values = {}
    for name, path in asset_paths().items():
        data, info = protected_file(path)
        values[name] = {'sha256': digest(data), **metadata_record(info)}
    for name, expected in ASSET_HASHES.items():
        check(values[name]['sha256'] == expected, 'review isolation asset differs')
    return values


def service_properties(unit):
    result = b.command(['/usr/bin/systemctl', 'show', unit,
                        '--property=ActiveState,SubState,MainPID,DropInPaths,FragmentPath'])
    properties = dict(line.split('=', 1) for line in result.splitlines() if '=' in line)
    check(properties.get('DropInPaths') == ''
          and properties.get('FragmentPath') == '/etc/systemd/system/' + unit,
          'unexpected review service override')
    return properties


def assert_services(stopped):
    for unit in UNITS:
        state = service_properties(unit)
        if stopped:
            check(state.get('ActiveState') == 'inactive' and state.get('SubState') == 'dead'
                  and state.get('MainPID') == '0', 'review service is not fully stopped')
        else:
            check(state.get('ActiveState') == 'active' and state.get('SubState') == 'running'
                  and state.get('MainPID', '').isdigit() and int(state['MainPID']) > 0,
                  'review service is not running')


def stop_services():
    b.command(['/usr/bin/systemctl', 'stop', *reversed(UNITS)])
    assert_services(True)


def exclusive_rename_api():
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'linux':
        name, directory_fd, flag = 'renameat2', -100, 1  # AT_FDCWD, RENAME_NOREPLACE
    elif sys.platform == 'darwin':
        # Public macOS SDK sys/stdio.h and sys/fcntl.h; used by local contracts.
        name, directory_fd, flag = 'renameatx_np', -2, 4  # AT_FDCWD, RENAME_EXCL
    else:
        raise ReviewGameError('atomic exclusive rename unavailable')
    function = getattr(library, name, None)
    check(function is not None, 'atomic exclusive rename unavailable')
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    return function, directory_fd, flag


def rename_new(source, target):
    function, directory_fd, flag = exclusive_rename_api()
    result = function(directory_fd, os.fsencode(source), directory_fd, os.fsencode(target), flag)
    if result != 0:
        raise OSError(ctypes.get_errno(), 'atomic exclusive rename failed')


def preflight(source):
    check(os.geteuid() == ROOT_UID, 'root required')
    directory(b.CONFIG)
    current, candidate = file_map(LIVE), file_map(source)
    check(map_manifest(current) == BASELINE, 'unexpected live release; do not replay')
    check(map_manifest(candidate) == TARGET, 'candidate differs from reviewed release')
    check(set(candidate) - set(current) == set(ADDED)
          and not set(current) - set(candidate), 'unexpected added or removed files')
    check({name for name in current if current[name][0] != candidate[name][0]} == set(CHANGED),
          'unexpected changed files')
    for name in ADDED:
        directory((LIVE / name).parent)
        absent(LIVE / name)
    exclusive_rename_api()
    check(all((LIVE / name).parent.stat().st_dev == b.CONFIG.stat().st_dev
              for name in WRITE_ORDER), 'private staging and live targets must share a filesystem')
    preserved = invariants()
    assert_services(False)
    check(a.wp_eval("echo DB_NAME;").strip() == b.DATABASE, 'unexpected review database')
    for name in WRITE_ORDER:
        if name.endswith('.php'):
            b.command(['/usr/bin/php', '-l', str(source / name)])
    # Validate actual same-directory rules resolution without booting WordPress
    # or creating tables; no request handler is invoked.
    result = b.command(['/usr/bin/php', '-n', '-d', 'allow_url_fopen=0', '-r',
               'require $argv[1]; Shuzijun_Game_Rules::bundled(); echo "rules-ready";',
               str(source / (PREFIX + 'class-shuzijun-game-rules.php'))])
    check(result.strip() == 'rules-ready', 'rules initialization not confirmed')
    return current, candidate, preserved


def metadata_record(info):
    return {'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)}


def write_new(path, data, metadata):
    directory(path.parent)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    created = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fchown(handle.fileno(), metadata['uid'], metadata['gid'])
            os.fchmod(handle.fileno(), metadata['mode'])
            os.fsync(handle.fileno())
    except BaseException:
        current = path.lstat()
        if (current.st_dev, current.st_ino, current.st_nlink) == (created.st_dev, created.st_ino, 1):
            path.unlink()  # Only our incomplete O_EXCL-created file.
            sync_directory(path.parent)
        raise
    sync_directory(path.parent)


def stage_payload(backup, relative, data, metadata, operation):
    check(relative in WRITE_ORDER and operation in ('add', 'replace', 'restore'), 'invalid stage operation')
    staging = backup / 'staging'
    directory(staging, private=True)
    check(staging.stat().st_dev == (LIVE / relative).parent.stat().st_dev,
          'private staging and target filesystem changed')
    token = uuid.uuid4().hex
    payload = staging / (token + '.payload')
    receipt = {'relative': relative, 'sha256': digest(data), 'operation': operation,
               'payload': payload.name, 'metadata': metadata, 'baseline': BASELINE, 'target': TARGET}
    # Persist the exact transaction receipt before creating any payload. A
    # killed process can leave only a private receipt/partial stage, never a
    # partially-written live file. Recovery retains these artifacts; no glob
    # cleanup or deletion of an unidentified temporary file is necessary.
    write_new(staging / (token + '.json'), json.dumps(receipt, sort_keys=True).encode(),
              {'uid': ROOT_UID, 'gid': os.getgid(), 'mode': 0o600})
    write_new(payload, data, metadata)
    actual, info = protected_file(payload)
    check(actual == data and metadata_record(info) == metadata, 'staged payload changed')
    return payload


def install_added(backup, relative, data, metadata):
    path = LIVE / relative
    absent(path)
    staging = stage_payload(backup, relative, data, metadata, 'add')
    rename_new(staging, path)  # Atomic NOREPLACE, never downgrade to overwrite.
    sync_directory(path.parent)
    sync_directory(staging.parent)


def replace_exact(path, data, metadata, expected, backup, operation='replace'):
    current, info = protected_file(path)
    check(current == expected and metadata_record(info) == metadata,
          'foreign file change before replacement')
    temporary = stage_payload(backup, path.relative_to(LIVE).as_posix(), data, metadata, operation)
    current, info = protected_file(path)
    check(current == expected and metadata_record(info) == metadata,
          'foreign file change during replacement')
    os.replace(temporary, path)
    sync_directory(path.parent)
    sync_directory(temporary.parent)


def record_outcome(backup, state):
    check(state in ('completed', 'restored-stopped'), 'invalid journal outcome')
    path = backup / (state + '.json')
    data = json.dumps({'state': state, 'baseline': BASELINE, 'target': TARGET}, sort_keys=True).encode()
    if os.path.lexists(path):
        check(protected_file(path)[0] == data, 'foreign outcome journal')
    else:
        write_new(path, data, {'uid': ROOT_UID, 'gid': os.getgid(), 'mode': 0o600})


def backup_transaction(current, candidate, preserved):
    backup = b.CONFIG / ('game-plugin-backup-' + uuid.uuid4().hex)
    backup.mkdir(mode=0o700)
    (backup / 'staging').mkdir(mode=0o700)
    private = {'uid': ROOT_UID, 'gid': os.getgid(), 'mode': 0o600}
    records = []
    for name, (data, info) in current.items():
        path = backup / 'original' / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_new(path, data, private)
        records.append({'path': name, 'sha256': digest(data), **metadata_record(info)})
    for name in WRITE_ORDER:
        path = backup / 'candidate' / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_new(path, candidate[name][0], private)
    journal = {'version': 1, 'baseline': BASELINE, 'target': TARGET,
               'files': records, 'invariants': preserved}
    write_new(backup / 'prepared.json', json.dumps(journal, sort_keys=True).encode(), private)
    for path in sorted((p for p in backup.rglob('*') if p.is_dir()),
                       key=lambda p: len(p.parts), reverse=True):
        sync_directory(path)
    sync_directory(backup)
    sync_directory(b.CONFIG)
    load_transaction(backup)  # Read back all backup bytes before stopping PHP.
    print('review-game: prepared backup=' + str(backup), flush=True)
    return backup


def load_transaction(backup):
    check(backup.parent == b.CONFIG
          and re.fullmatch(r'game-plugin-backup-[a-f0-9]{32}', backup.name), 'invalid backup target')
    directory(backup, private=True)
    directory(backup / 'staging', private=True)
    raw, _ = protected_file(backup / 'prepared.json')
    check(len(raw) <= 65536, 'oversized backup journal')
    journal = json.loads(raw)
    check(set(journal) == {'version', 'baseline', 'target', 'files', 'invariants'}
          and journal['version'] == 1 and journal['baseline'] == BASELINE
          and journal['target'] == TARGET, 'unreviewed backup transaction')
    original = file_map(backup / 'original')
    check(map_manifest(original) == BASELINE, 'backup baseline mismatch')
    records = journal['files']
    check(isinstance(records, list) and len(records) == len(original), 'invalid backup records')
    metadata = {}
    for record in records:
        check(isinstance(record, dict) and set(record) == {'path', 'sha256', 'uid', 'gid', 'mode'},
              'invalid metadata record')
        name = record['path']
        check(isinstance(name, str) and name in original and name not in metadata,
              'unknown or duplicate backup path')
        check(record['sha256'] == digest(original[name][0])
              and all(type(record[key]) is int for key in ('uid', 'gid', 'mode'))
              and record['uid'] == ROOT_UID and record['gid'] >= 0
              and record['mode'] in (0o600, 0o640, 0o644), 'invalid original metadata')
        metadata[name] = {key: record[key] for key in ('uid', 'gid', 'mode')}
    new_files = {p.relative_to(backup / 'candidate').as_posix(): protected_file(p)
                 for p in b.regular_tree(backup / 'candidate')}
    check(set(new_files) == set(WRITE_ORDER), 'backup candidate graph differs')
    candidate = dict(original)
    candidate.update(new_files)
    check(map_manifest(candidate) == TARGET, 'backup candidate manifest mismatch')
    check(set(journal['invariants']) == set(asset_paths()), 'invalid isolation snapshot')
    for value in journal['invariants'].values():
        check(isinstance(value, dict) and set(value) == {'sha256', 'uid', 'gid', 'mode'}
              and re.fullmatch('[a-f0-9]{64}', value['sha256'])
              and all(type(value[key]) is int for key in ('uid', 'gid', 'mode'))
              and value['uid'] == ROOT_UID and value['gid'] >= 0
              and value['mode'] in (0o600, 0o640, 0o644), 'invalid isolation metadata')
    return original, candidate, metadata, journal['invariants']


def assert_known_live(original, candidate, metadata):
    current = file_map(LIVE)
    check(set(original) <= set(current) <= set(candidate), 'foreign live file graph')
    for name, (data, info) in current.items():
        permitted = {candidate[name][0]}
        if name in original:
            permitted.add(original[name][0])
        check(data in permitted, 'foreign file change prevents rollback')
        expected_metadata = metadata[name] if name in original else metadata[CHANGED[0]]
        check(metadata_record(info) == expected_metadata, 'foreign metadata change prevents rollback')
    for name in ADDED:
        if name not in current:
            absent(LIVE / name)  # Also reject dangling symlinks.


def restore(backup, *, already_stopped=False):
    original, candidate, metadata, preserved = load_transaction(backup)
    if already_stopped:
        assert_services(True)
    else:
        stop_services()
    check(invariants() == preserved, 'configuration changed; leave review stopped')
    assert_known_live(original, candidate, metadata)  # Entire graph before any overwrite.
    for name in reversed(WRITE_ORDER):
        path = LIVE / name
        if name in ADDED:
            if os.path.lexists(path):
                data, info = protected_file(path)
                check(data == candidate[name][0] and metadata_record(info) == metadata[CHANGED[0]],
                      'foreign added file')
                path.unlink()  # Only exact reviewed new path with matching bytes/metadata.
                sync_directory(path.parent)
        else:
            current, _ = protected_file(path)
            if current != original[name][0]:
                replace_exact(path, original[name][0], metadata[name], current, backup, 'restore')
    check(map_manifest(file_map(LIVE)) == BASELINE, 'restored manifest mismatch')
    check(invariants() == preserved, 'configuration changed during rollback')
    assert_services(True)
    record_outcome(backup, 'restored-stopped')
    print('review-game: baseline restored; both review services remain stopped', flush=True)


def apply(source):
    current, candidate, preserved = preflight(source)
    backup = backup_transaction(current, candidate, preserved)
    original, saved_candidate, metadata, saved_invariants = load_transaction(backup)
    check(map_manifest(file_map(LIVE)) == BASELINE and invariants() == saved_invariants,
          'live changed after backup; no services changed')
    stop_attempted = False
    try:
        stop_attempted = True
        stop_services()
        check(map_manifest(file_map(LIVE)) == BASELINE and invariants() == preserved,
              'live changed after service stop')
        for name in WRITE_ORDER:
            if name in ADDED:
                install_added(backup, name, saved_candidate[name][0], metadata[CHANGED[0]])
            else:
                replace_exact(LIVE / name, saved_candidate[name][0], metadata[name], original[name][0], backup)
        check(map_manifest(file_map(LIVE)) == TARGET and invariants() == preserved,
              'installed candidate or isolation mismatch')
        assert_known_live(original, saved_candidate, metadata)
        b.command(['/usr/bin/systemctl', 'start', *UNITS])
        assert_services(False)
        b.wait_for_php()
        status, _ = a.request('app-admin/session')
        check(status in (401, 403), 'anonymous management not denied')
        status, _ = a.request('fan/game/leaderboard')
        check(status in (401, 403), 'anonymous leaderboard not denied')
        check(invariants() == preserved and map_manifest(file_map(LIVE)) == TARGET,
              'post-health candidate changed')
        record_outcome(backup, 'completed')
        print('review-game: candidate installed; schema and account acceptance still pending', flush=True)
    except BaseException:
        if stop_attempted:
            # If stop confirmation or foreign-change validation fails, do not
            # overwrite anything else and never attempt to start either unit.
            stop_services()  # Stop first, even if the backup itself became unreadable.
            restore(backup, already_stopped=True)
        raise


@contextmanager
def maintenance_lock():
    check(os.geteuid() == ROOT_UID, 'root required')
    directory(b.CONFIG)
    lock_path = b.CONFIG / 'plugin-maintenance.lock'  # Same lock as legacy tool.
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'rb') as handle:
        info = os.fstat(handle.fileno())
        check(stat.S_ISREG(info.st_mode) and info.st_uid == ROOT_UID and info.st_nlink == 1
              and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size == 0, 'unsafe maintenance lock')
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = lock_path.lstat()
        check((info.st_dev, info.st_ino) == (current.st_dev, current.st_ino), 'replaced maintenance lock')
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--apply', action='store_true')
    action.add_argument('--restore', type=Path, metavar='BACKUP')
    args = parser.parse_args()
    if args.restore:
        check(args.source is None, 'restore accepts only its verified backup')
        with maintenance_lock():
            restore(args.restore)
    else:
        check(args.source is not None, '--source required')
        if args.apply:
            with maintenance_lock():
                apply(args.source)
        else:
            preflight(args.source)
            print('review-game: read-only preflight passed; no writes or service changes')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        label = str(error) if isinstance(error, ReviewGameError) else type(error).__name__
        print('review-game: failed: ' + label
              + '; inspect backup; do not restart isolated services without verification')
        raise SystemExit(1) from None
