#!/usr/bin/env python3
"""Execute production upgrade/rollback functions with local OS-boundary doubles.

No SSH, root privileges, real systemd units, credentials, APNs or WP database.
The timing model below is not a substitute for a Linux systemd smoke test.
"""
from __future__ import annotations

import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

OPS = Path('Server/operations').resolve()
deployer = (OPS / 'deploy-shuzijun-push-worker').read_text()
timer = (OPS / 'shuzijun-push-outbox.timer').read_text()
previous = timer.replace(
    'five seconds after completion', 'every minute'
).replace('OnUnitInactiveSec=5s', 'OnUnitActiveSec=60s').replace('AccuracySec=1s', 'AccuracySec=5s')
pins = dict(re.findall(r'^readonly ([A-Z_]+_SHA)=([a-f0-9]{64})$', deployer, re.M))
assert hashlib.sha256(previous.encode()).hexdigest() == pins['PREVIOUS_TIMER_SHA']

def body(name: str) -> str:
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', deployer, re.M | re.S)
    assert match, name
    return match.group()

# Parse the actual timer and model a fast run, a run longer than the polling
# interval, and timeout/recovery. Every next deadline is based on completion.
configuration = configparser.ConfigParser(interpolation=None)
configuration.optionxform = str
configuration.read_string(timer)
values = configuration['Timer']
assert values['OnUnitInactiveSec'] == '5s'
assert 'OnUnitActiveSec' not in values
assert values['AccuracySec'] == '1s' and values['Persistent'] == 'false'
for durations in ((0.2, 0.3, 0.2), (9, 16, 41), (40, 0.2, 43, 0.2)):
    start = 75.0
    windows = []
    for duration in durations:
        finish = start + duration
        windows.append((start, finish))
        start = finish + 5
    assert all(later[0] - earlier[1] == 5 for earlier, later in zip(windows, windows[1:]))
    assert all(later[0] > earlier[1] for earlier, later in zip(windows, windows[1:]))

names = ('fail', 'require_dir', 'require_file', 'require_absent_or_reviewed',
         'require_absent_or_reviewed_timer', 'validate_installed_state', 'installed_state',
         'install_asset', 'require_all_installed', 'timer_state_matches_role',
         'upgrade_reviewed_timer', 'rollback_reviewed_timer', 'cleanup')
functions = '\n'.join(body(name) for name in names)
current_branch = deployer.split('elif [[ "$INSTALLED_STATE" == reviewed ]]; then', 1)[1].split('\n        else', 1)[0]
assert '"$SYSTEMD" restart' not in current_branch and 'install_asset' not in current_branch

DOUBLE = r'''import hashlib, json, os, pathlib, shutil, stat, sys
root = pathlib.Path(os.environ['FIXTURE'])
operation, *args = sys.argv[1:]
log = root / 'calls.jsonl'
def record(value):
    with log.open('a') as stream: stream.write(json.dumps(value) + '\n')
def contained(raw):
    p = pathlib.Path(raw)
    assert p.resolve().is_relative_to(root.resolve()), raw
    return p
if operation == 'sha':
    print(hashlib.sha256(contained(args[0]).read_bytes()).hexdigest())
elif operation == 'realpath':
    print(contained(args[-1]).resolve(strict=True))
elif operation == 'stat':
    fmt, raw = args[1], args[-1]
    st = contained(raw).stat()
    owner = 'nobody' if os.environ.get('BAD_OWNER') and raw == os.environ['TIMER_TARGET'] else 'root'
    mode = oct(stat.S_IMODE(st.st_mode))[2:]
    print(fmt.replace('%U', owner).replace('%G', 'root').replace('%a', mode).replace('%h', str(st.st_nlink)))
elif operation == 'install':
    source, target = map(contained, args[-2:])
    mode = int(args[args.index('-m') + 1], 8)
    record(['install', str(source), str(target)])
    shutil.copyfile(source, target)
    target.chmod(mode)
elif operation == 'mv':
    source, target = map(contained, args[-2:])
    record(['mv', str(source), str(target)])
    os.replace(source, target)
elif operation == 'systemd':
    record(['systemd'] + args)
    statefile = root / 'systemd.json'
    state = json.loads(statefile.read_text())
    fault = os.environ.get('FAIL_ONCE', '')
    if fault and args[0] == fault and not state.get('failed_once'):
        state['failed_once'] = True
        statefile.write_text(json.dumps(state))
        raise SystemExit(1)
    op = args[0]
    if op == 'stop':
        assert args[1] == 'shuzijun-push-outbox.timer'
        state['active'] = 'inactive'
    elif op == 'enable':
        state.update(active='active', enabled='enabled')
    elif op == 'disable':
        state.update(active='inactive', enabled='disabled')
    elif op == 'is-enabled':
        print(state['enabled'])
    elif op == 'is-active':
        if args[-1] == 'php8.3-fpm.service':
            assert '--quiet' in args
        else: print(state['active'])
    else: assert op == 'daemon-reload', args
    statefile.write_text(json.dumps(state))
elif operation == 'fpm':
    record(['fpm'] + args)
    assert args == ['-t']
else: raise AssertionError(operation)
'''

def run_case(kind: str, role: str = 'authority', fault: str = '') -> None:
    with tempfile.TemporaryDirectory(prefix='yishu-timer-contract-') as directory:
        root = Path(directory).resolve()
        helper = root / 'double.py'
        helper.write_text(DOUBLE)
        (root / 'backups').mkdir()
        assets = {
            'WORKER': ('shuzijun-push-outbox-worker', 0o755),
            'SERVICE': ('shuzijun-push-outbox.service', 0o644),
            'TIMER': ('shuzijun-push-outbox.timer', 0o644),
            'FPM_SYSTEMD': ('shuzijun-push-fpm-systemd.conf', 0o644),
            'FPM_POOL': ('shuzijun-push-fpm-pool.conf', 0o644),
        }
        env = dict(os.environ, FIXTURE=str(root), FAIL_ONCE=fault)
        declarations = []
        for name, (source, mode) in assets.items():
            path = root / source
            path.write_bytes((OPS / source).read_bytes())
            if name == 'TIMER' and kind != 'current':
                path.write_text(previous if kind != 'unknown' else previous + '# unreviewed\n')
            path.chmod(mode)
            env[name + '_TARGET'] = str(path)
            declarations.append(f'{name}_TARGET={shlex.quote(str(path))}')
            declarations.append(f'{name}_SHA={pins[name + "_SHA"]}')
        target = Path(env['TIMER_TARGET'])
        if kind == 'bad_owner': env['BAD_OWNER'] = '1'
        if kind == 'writable': target.chmod(0o666)
        if kind == 'hardlink': os.link(target, root / 'extra-link')
        if kind == 'partial': Path(env['FPM_POOL_TARGET']).unlink()
        if kind == 'symlink':
            target.rename(root / 'timer-real')
            target.symlink_to(root / 'timer-real')
        candidate = root / 'candidate.timer'
        candidate.write_text(timer)
        candidate.chmod(0o600)
        initial = {'active': 'active' if role == 'authority' else 'inactive',
                   'enabled': 'enabled' if role == 'authority' else 'disabled'}
        (root / 'systemd.json').write_text(json.dumps(initial))
        for operation in ('systemd', 'fpm'):
            wrapper = root / operation
            wrapper.write_text(f'#!{sys.executable}\n' +
                               f'import runpy, sys\nsys.argv.insert(1, {operation!r})\nrunpy.run_path({str(helper)!r}, run_name="__main__")\n')
            wrapper.chmod(0o700)
        preamble = f'''set -Eeuo pipefail
{chr(10).join(declarations)}
PREVIOUS_TIMER_SHA={pins['PREVIOUS_TIMER_SHA']}
TIMER_SOURCE={shlex.quote(str(candidate))}
ROLE={role}
NODE={'primary' if role == 'authority' else 'backup'}
SYSTEMD={shlex.quote(str(root / 'systemd'))}
PHP_FPM_BIN={shlex.quote(str(root / 'fpm'))}
PHP_FPM_SERVICE=php8.3-fpm.service
double() {{ {shlex.quote(sys.executable)} {shlex.quote(str(helper))} "$@"; }}
sha() {{ double sha "$@"; }}
stat() {{ double stat "$@"; }}
realpath() {{ double realpath "$@"; }}
install() {{ double install "$@"; }}
mv() {{ double mv "$@"; }}
mktemp() {{ [[ "$*" == '-d /var/backups/shuzijun-push-timer-upgrade.XXXXXX' ]] || return 1; command mktemp -d "$FIXTURE/backups/timer.XXXXXX"; }}
{functions}
'''
        # Only the fixed /var parent checks are substituted; all actual release
        # file hashes, mode/link guards and production shell branches execute.
        preamble += '''eval "$(declare -f require_dir | sed '1s/require_dir/fixture_require_dir/')"
require_dir() {
    if [[ "$1" == /var || "$1" == /var/backups ]]; then
        [[ "$2:$3:$4" == root:root:755 ]] || return 1
    else fixture_require_dir "$@"; fi
}
validate_installed_state
INSTALLED_STATE=$(installed_state)
declare -a TEMP_FILES=("$FIXTURE/nonexistent-placeholder")
ROLLBACK_NEW_INSTALL=0
ROLLBACK_TIMER_UPGRADE=0
TIMER_UPGRADE_BACKUP=
UNINSTALL_BACKUP=
trap cleanup EXIT
'''
        preamble += current_branch if kind == 'current' else 'upgrade_reviewed_timer\n'
        result = subprocess.run(['/bin/bash', '-c', preamble], env=env, text=True, capture_output=True)
        rejected = kind in ('unknown', 'bad_owner', 'writable', 'hardlink', 'partial', 'symlink')
        assert (result.returncode != 0) == bool(rejected or fault), (kind, role, fault, result.stdout, result.stderr)
        calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()] if (root / 'calls.jsonl').exists() else []
        assert not any(call[:2] == ['systemd', 'restart'] for call in calls)
        assert not any(call[:2] == ['systemd', 'stop'] and call[-1] != 'shuzijun-push-outbox.timer' for call in calls)
        if rejected:
            assert calls == [], (kind, calls)
            return
        actual = json.loads((root / 'systemd.json').read_text())
        assert {key: actual[key] for key in initial} == initial
        assert hashlib.sha256(target.read_bytes()).hexdigest() == pins['PREVIOUS_TIMER_SHA' if fault else 'TIMER_SHA']
        backups = list((root / 'backups').glob('*/timer'))
        if kind == 'current':
            assert not backups
            assert all(call[0] == 'fpm' or call[:2] in (['systemd', 'is-active'], ['systemd', 'is-enabled']) for call in calls)
        else:
            assert len(backups) == 1
            assert hashlib.sha256(backups[0].read_bytes()).hexdigest() == pins['PREVIOUS_TIMER_SHA']
            assert 'rolled back' in result.stderr if fault else 'timer upgraded' in result.stdout

for role in ('authority', 'standby'):
    run_case('previous', role)
    run_case('current', role)
    for fault in ('stop', 'daemon-reload', 'enable' if role == 'authority' else 'disable'):
        run_case('previous', role, fault)
for rejected in ('unknown', 'bad_owner', 'writable', 'hardlink', 'partial', 'symlink'):
    run_case(rejected)
print('push timer upgrade contract passed: timing model, old/new hashes, idempotency, rollback and fail-closed boundaries')
