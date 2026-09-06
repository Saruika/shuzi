#!/usr/bin/env python3
"""Isolated shared-reader/exclusive-sync regression; no production data used.

Pass --full-timeout on Linux to verify the actual 60-second production bound.
Only temp-directory lock files are ever opened by these tests.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPAIR = Path(__file__).resolve().parent.parent / 'operations/repair-shuzijun-sync-lock-wait.py'
SPEC = runpy.run_path(str(REPAIR))
NEW = SPEC['NEW_LOCK'].decode()
FULL_TIMEOUT = '--full-timeout' in sys.argv
if FULL_TIMEOUT:
    sys.argv.remove('--full-timeout')
LINUX = sys.platform.startswith('linux') and Path('/usr/bin/flock').is_file()
if '--require-linux' in sys.argv:
    sys.argv.remove('--require-linux')
    if not LINUX:
        raise SystemExit('Linux util-linux flock is required for this job')


class SourceContract(unittest.TestCase):
    def test_published_executable_is_not_group_or_world_writable(self):
        with tempfile.TemporaryDirectory(prefix='sync-publish-mode-') as temporary:
            target = Path(temporary) / 'fixture-sender'
            payload = b'#!/bin/bash\ntrue\n'
            with mock.patch.dict(SPEC['publish'].__globals__, {'TARGET': target}):
                SPEC['publish'](payload)
            mode = stat.S_IMODE(target.stat().st_mode)
            self.assertEqual(mode, 0o755)
            self.assertEqual(mode & 0o022, 0)
            self.assertEqual(target.read_bytes(), payload)
            self.assertEqual(list(Path(temporary).glob('.sync-lock-wait-*')), [])

    def test_only_the_single_reviewed_boundary_changes(self):
        raw=b'prefix\n'+SPEC['OLD_LOCK']+b'suffix\n'
        expected=b'prefix\n'+SPEC['NEW_LOCK']+b'suffix\n'
        pins={'OLD_SHA256':hashlib.sha256(raw).hexdigest(),
              'NEW_SHA256':hashlib.sha256(expected).hexdigest()}
        with mock.patch.dict(SPEC['transform'].__globals__,pins):
            self.assertEqual(SPEC['transform'](raw),expected)
            with self.assertRaises(ValueError):
                SPEC['transform'](raw+b'changed')
        duplicate=SPEC['OLD_LOCK']*2
        with mock.patch.dict(SPEC['transform'].__globals__,{'OLD_SHA256':hashlib.sha256(duplicate).hexdigest()}):
            with self.assertRaises(ValueError):
                SPEC['transform'](duplicate)

    def test_hash_pins_and_unique_known_boundary(self):
        self.assertEqual(len(SPEC['OLD_SHA256']),64)
        self.assertEqual(len(SPEC['NEW_SHA256']),64)
        self.assertNotEqual(SPEC['OLD_SHA256'],SPEC['NEW_SHA256'])
        self.assertEqual(SPEC['OLD_LOCK'],b'    flock -n 8 || return 1\n')
        with self.assertRaises(ValueError):
            SPEC['transform'](SPEC['OLD_LOCK'])

    def test_actual_workspace_candidate_when_pinned_v5_is_available(self):
        raw=(REPAIR.parent/'sync-to-backup').read_bytes()
        if hashlib.sha256(raw).hexdigest()!=SPEC['OLD_SHA256']:
            self.skipTest('full v5 deployment source is not this checkout revision')
        candidate=SPEC['transform'](raw)
        self.assertEqual(hashlib.sha256(candidate).hexdigest(),SPEC['NEW_SHA256'])
        self.assertEqual(candidate.replace(SPEC['NEW_LOCK'],SPEC['OLD_LOCK'],1),raw)
        self.assertEqual(candidate.count(SPEC['NEW_LOCK']),1)
        self.assertEqual(subprocess.run(['/bin/bash','-n'],input=candidate,capture_output=True).returncode,0)

    def test_only_contention_waits_and_bound_is_not_overridable(self):
        self.assertIn('/usr/bin/flock -n -E 75 8',NEW)
        self.assertIn('if (( site_lock_status != 75 )); then',NEW)
        self.assertIn('/usr/bin/flock -w 60 -E 75 8',NEW)
        self.assertEqual(NEW.count('return "$site_lock_status"'),2)
        self.assertNotIn(' -s ',NEW)
        self.assertNotIn('systemctl',NEW)
        self.assertNotIn('eval',NEW)
        self.assertNotIn('source ',NEW)


@unittest.skipUnless(LINUX,'Linux util-linux flock required; no emulated runtime pass')
class LockContention(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(prefix='sync-lock-regression-')
        self.path=Path(self.directory.name)/'fixture.lock'
        self.fd=os.open(self.path,os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
        self.children=[]

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
        os.close(self.fd)
        self.directory.cleanup()

    def child(self,block=NEW,open_fd=True):
        script='set -euo pipefail\nlock_test() {\n'+block+'}\n'
        script+=('exec 8<>"$1"\n' if open_fd else 'exec 8>&-\n')
        script+='lock_test\nprintf "FIXTURE_LOCK_ACQUIRED\\n"\n'
        child=subprocess.Popen(['/bin/bash','--noprofile','--norc','-c',script,'fixture',str(self.path)],
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.children.append(child)
        return child

    def test_reproduces_old_immediate_failure_while_push_holds_shared_lock(self):
        fcntl.flock(self.fd,fcntl.LOCK_SH)
        before=time.monotonic()
        child=self.child(SPEC['OLD_LOCK'].decode())
        out,_=child.communicate(timeout=3)
        self.assertEqual(child.returncode,1)
        self.assertLess(time.monotonic()-before,2)
        self.assertNotIn('FIXTURE_LOCK_ACQUIRED',out)

    def test_no_contention_returns_immediately(self):
        before=time.monotonic()
        child=self.child()
        out,err=child.communicate(timeout=3)
        self.assertEqual(child.returncode,0,err)
        self.assertIn('FIXTURE_LOCK_ACQUIRED',out)
        self.assertNotIn('waiting',err)
        self.assertLess(time.monotonic()-before,2)

    def test_waits_for_shared_push_sweep_then_succeeds(self):
        fcntl.flock(self.fd,fcntl.LOCK_SH)
        child=self.child()
        time.sleep(0.5)
        self.assertIsNone(child.poll(),'sync must wait, not fail or enter while reader is active')
        fcntl.flock(self.fd,fcntl.LOCK_UN)
        out,err=child.communicate(timeout=4)
        self.assertEqual(child.returncode,0,err)
        self.assertIn('FIXTURE_LOCK_ACQUIRED',out)
        self.assertIn('acquired after waiting',err)

    def test_waits_until_all_shared_readers_release(self):
        another=os.open(self.path,os.O_RDONLY)
        try:
            fcntl.flock(self.fd,fcntl.LOCK_SH)
            fcntl.flock(another,fcntl.LOCK_SH)
            child=self.child()
            time.sleep(0.25)
            fcntl.flock(self.fd,fcntl.LOCK_UN)
            time.sleep(0.25)
            self.assertIsNone(child.poll())
            fcntl.flock(another,fcntl.LOCK_UN)
            out,err=child.communicate(timeout=4)
            self.assertEqual(child.returncode,0,err)
            self.assertIn('FIXTURE_LOCK_ACQUIRED',out)
        finally:
            os.close(another)

    def test_busy_deadline_fails_closed(self):
        fcntl.flock(self.fd,fcntl.LOCK_EX)
        bound=60 if FULL_TIMEOUT else 0.25
        block=NEW if FULL_TIMEOUT else NEW.replace('-w 60 ','-w 0.25 ')
        child=self.child(block)
        before=time.monotonic()
        out,err=child.communicate(timeout=bound+5)
        elapsed=time.monotonic()-before
        self.assertEqual(child.returncode,75,err)
        self.assertGreaterEqual(elapsed,bound-0.05)
        self.assertLess(elapsed,bound+4)
        self.assertNotIn('FIXTURE_LOCK_ACQUIRED',out)
        self.assertIn('wait failed (status=75)',err)

    def test_invalid_descriptor_is_not_retried_as_contention(self):
        before=time.monotonic()
        child=self.child(open_fd=False)
        out,err=child.communicate(timeout=3)
        self.assertNotEqual(child.returncode,0)
        self.assertNotEqual(child.returncode,75)
        self.assertLess(time.monotonic()-before,2)
        self.assertNotIn('FIXTURE_LOCK_ACQUIRED',out)
        self.assertNotIn('waiting',err)
        self.assertIn('operation lock error',err)


if __name__=='__main__':
    unittest.main(verbosity=2)
