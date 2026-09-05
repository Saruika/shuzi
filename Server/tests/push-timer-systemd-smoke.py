#!/usr/bin/env python3
"""Opt-in real systemd timing test using an isolated sleeping fixture only.

Run on Linux with a user manager, or explicitly use --system as root. No real
push unit, PHP, WordPress, APNs, account, key or network request is involved.
"""
from __future__ import annotations

import argparse
import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--system', action='store_true', help='explicitly use the root system manager')
args = parser.parse_args()
if sys.platform != 'linux' or not shutil.which('systemd-run') or not shutil.which('systemctl'):
    raise SystemExit('SKIP: requires Linux with systemd; no timing proof claimed')
if args.system and os.geteuid() != 0:
    raise SystemExit('--system requires root; this script never invokes sudo')
scope = [] if args.system else ['--user']
timer = Path(__file__).resolve().parents[1] / 'operations/shuzijun-push-outbox.timer'
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
config.read(timer)
settings = config['Timer']
assert settings['OnUnitInactiveSec'] == '5s' and 'OnUnitActiveSec' not in settings
assert settings['AccuracySec'] == '1s' and settings['RandomizedDelaySec'] == '0'
name = 'yishu-push-timer-contract-' + uuid.uuid4().hex

with tempfile.TemporaryDirectory(prefix='yishu-systemd-timer-contract-') as temporary:
    work = Path(temporary)
    events = work / 'events.jsonl'
    fixture = work / 'fixture.py'
    fixture.write_text('''import json, pathlib, sys, time
events = pathlib.Path(sys.argv[1])
def record(kind):
    with events.open('a') as output:
        output.write(json.dumps({'kind': kind, 'time': time.monotonic()}) + '\\n')
record('start')
time.sleep(7)  # Longer than the five-second timer interval.
record('finish')
''')
    created = False
    try:
        # Only the first activation is accelerated in this fixture. The
        # completion-relative recurring directive is copied from production.
        command = ['systemd-run', *scope, '--quiet', '--unit=' + name, '--collect',
                   '--on-active=100ms',
                   '--timer-property=OnUnitInactiveSec=' + settings['OnUnitInactiveSec'],
                   '--timer-property=AccuracySec=' + settings['AccuracySec'],
                   '--timer-property=RandomizedDelaySec=0',
                   '--timer-property=Persistent=false',
                   '--property=Type=oneshot', '--property=TimeoutStartSec=15s',
                   '--', sys.executable, '-I', str(fixture), str(events)]
        subprocess.run(command, check=True, timeout=10)
        created = True
        deadline = time.monotonic() + 50
        while time.monotonic() < deadline:
            rows = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
            if sum(row['kind'] == 'finish' for row in rows) >= 3:
                break
            time.sleep(0.2)
        else:
            raise AssertionError('timer did not complete three slow fixture runs within 50 seconds')
        subprocess.run(['systemctl', *scope, 'stop', name + '.timer'], check=True, timeout=10)
        assert [row['kind'] for row in rows[:6]] == ['start', 'finish'] * 3, rows
        gaps = [rows[index + 1]['time'] - rows[index]['time'] for index in (1, 3)]
        durations = [rows[index + 1]['time'] - rows[index]['time'] for index in (0, 2, 4)]
        assert all(value >= 7 for value in durations), durations
        assert all(4.8 <= value <= 8 for value in gaps), gaps
        print(json.dumps({'realSystemd': 'passed', 'runs': 3,
                          'completionToNextStartSeconds': gaps,
                          'slowRunSeconds': durations, 'realPushInvoked': False}))
    finally:
        if created:
            # Only these random, test-owned transient units are stopped.
            subprocess.run(['systemctl', *scope, 'stop', name + '.timer', name + '.service'],
                           check=False, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # --collect may already have unloaded an inactive unit; that is
            # successful cleanup, not a failed timing test.
            for suffix in ('.timer', '.service'):
                state = subprocess.run(['systemctl', *scope, 'is-active', '--quiet', name + suffix],
                                       check=False, timeout=10)
                assert state.returncode != 0, 'test-owned unit remained active after cleanup'
