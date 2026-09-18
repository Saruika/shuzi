#!/usr/bin/env python3
"""Transformation and temporary-directory transaction tests; no production access."""
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'operations/protect-game-rules-json.py'
spec = importlib.util.spec_from_file_location('game_json_protection', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProtectionTests(unittest.TestCase):
    def test_only_two_exact_anchors_change(self):
        original = b'alpha\n' + module.ANCHOR + b'middle\n' + module.ANCHOR + b'omega\n'
        new = module.candidate(original)
        self.assertEqual(new.replace(module.RULE, b''), original)
        self.assertEqual(new.count(module.RULE), 2)
        self.assertIn(b'location = /wp-content/mu-plugins/vendor/shuzijun/app-content/game-rules-v1.json', new)
        self.assertEqual(new.count(b'return 404;'), 2)

    def test_missing_or_extra_anchors_rejected(self):
        for count in (0, 1, 3, 4):
            with self.subTest(count=count), self.assertRaises(RuntimeError):
                module.candidate(module.ANCHOR * count)

    def test_reapply_or_foreign_game_rules_rejected(self):
        for suffix in (module.RULE, b'# game-rules-v1.json already changed\n'):
            with self.subTest(suffix=suffix), self.assertRaises(RuntimeError):
                module.candidate(module.ANCHOR * 2 + suffix)

    def test_no_header_or_generic_routing_changes(self):
        self.assertNotIn(b'add_header', module.RULE)
        self.assertNotIn(b'proxy_pass', module.RULE)
        self.assertNotIn(b'fastcgi_pass', module.RULE)
        self.assertNotIn(b'location ~', module.RULE)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='game-json-transaction-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.site = root / 'sites' / 'site.conf'
        self.site.parent.mkdir()
        self.backups = root / 'backups'
        self.backups.mkdir()
        self.lock = root / 'lock'
        self.lock.write_bytes(b'')
        self.old = b'alpha\n' + module.ANCHOR + b'middle\n' + module.ANCHOR + b'omega\n'
        self.new = module.candidate(self.old)
        self.site.write_bytes(self.old)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in (('SITE', self.site), ('BACKUPS', self.backups), ('LOCK', self.lock)):
            self.stack.enter_context(mock.patch.object(module, name, value))
        self.stack.enter_context(mock.patch.object(module.os, 'geteuid', return_value=0))
        # Only root ownership/path validation is replaced for unprivileged local
        # fixtures. Real atomic rename, file fsync and directory fsync still run.
        self.stack.enter_context(mock.patch.object(module, 'secure'))
        self.stack.enter_context(mock.patch.object(sys, 'argv', ['protect', '--expected-sha256',
            hashlib.sha256(self.old).hexdigest(), '--apply']))
        self.commands = self.stack.enter_context(mock.patch.object(module, 'run'))

    def retained_original(self):
        originals = list(self.backups.glob('game-json-nginx-*/shuzijun-ssl.conf'))
        self.assertEqual(len(originals), 1)
        return originals[0]

    def test_success_still_validates_and_reloads(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            module.main()
        self.assertEqual(self.site.read_bytes(), self.new)
        self.assertEqual(self.retained_original().read_bytes(), self.old)
        self.assertIn('"state": "applied"', output.getvalue())
        self.assertEqual(len(self.commands.call_args_list), 4)

    def test_failure_before_replace_does_not_rewrite_or_reload(self):
        failure = OSError('synthetic pre-replace failure')
        with mock.patch.object(module, 'atomic', side_effect=failure) as atomic:
            with self.assertRaises(OSError) as raised:
                module.main()
        self.assertIs(raised.exception, failure)
        self.assertEqual(atomic.call_args_list, [mock.call(self.new)])
        self.assertEqual(self.site.read_bytes(), self.old)
        self.assertEqual(self.retained_original().read_bytes(), self.old)
        self.commands.assert_not_called()

    def test_real_replace_then_directory_fsync_failure_is_rolled_back(self):
        actual_fsync = os.fsync
        failure = OSError('synthetic directory fsync failure')
        failed = False
        def fsync(descriptor):
            nonlocal failed
            if not failed and stat.S_ISDIR(os.fstat(descriptor).st_mode) and self.site.read_bytes() == self.new:
                failed = True
                raise failure
            return actual_fsync(descriptor)
        with mock.patch.object(module.os, 'fsync', side_effect=fsync):
            with self.assertRaisesRegex(RuntimeError, 'original restored') as raised:
                module.main()
        self.assertTrue(failed)
        self.assertIs(raised.exception.__cause__, failure)
        self.assertEqual(self.site.read_bytes(), self.old)
        self.assertEqual(self.retained_original().read_bytes(), self.old)
        self.assertEqual(self.commands.call_args_list, [mock.call(['/usr/sbin/nginx', '-t']),
            mock.call(['/usr/bin/systemctl', 'reload', 'nginx']),
            mock.call(['/usr/bin/systemctl', 'is-active', '--quiet', 'nginx'])])

    def test_foreign_live_change_is_not_overwritten(self):
        actual_atomic = module.atomic
        failure = OSError('synthetic post-replace failure')
        def replace_then_change(value):
            actual_atomic(value)
            self.site.write_bytes(b'foreign live config')
            raise failure
        with mock.patch.object(module, 'atomic', side_effect=replace_then_change) as atomic:
            with self.assertRaisesRegex(RuntimeError, 'foreign change') as raised:
                module.main()
        self.assertIs(raised.exception.__cause__, failure)
        self.assertEqual(atomic.call_args_list, [mock.call(self.new)])
        self.assertEqual(self.site.read_bytes(), b'foreign live config')
        self.assertEqual(self.retained_original().read_bytes(), self.old)
        self.commands.assert_not_called()

    def test_foreign_backup_change_prevents_rollback(self):
        actual_atomic = module.atomic
        def replace_then_change_backup(value):
            actual_atomic(value)
            self.retained_original().write_bytes(b'foreign backup')
            raise OSError('synthetic post-replace failure')
        with mock.patch.object(module, 'atomic', side_effect=replace_then_change_backup) as atomic:
            with self.assertRaisesRegex(RuntimeError, 'foreign change'):
                module.main()
        self.assertEqual(atomic.call_args_list, [mock.call(self.new)])
        self.assertEqual(self.site.read_bytes(), self.new)
        self.assertEqual(self.retained_original().read_bytes(), b'foreign backup')
        self.commands.assert_not_called()

    def test_missing_backup_prevents_rollback_and_preserves_failure_chain(self):
        actual_atomic = module.atomic
        failure = OSError('synthetic post-replace failure')
        def replace_then_remove_backup(value):
            actual_atomic(value)
            self.retained_original().unlink()
            raise failure
        with mock.patch.object(module, 'atomic', side_effect=replace_then_remove_backup) as atomic:
            with self.assertRaisesRegex(RuntimeError, 'cannot be verified') as raised:
                module.main()
        self.assertIsInstance(raised.exception.__cause__, FileNotFoundError)
        self.assertIs(raised.exception.__cause__.__context__, failure)
        self.assertEqual(atomic.call_args_list, [mock.call(self.new)])
        self.assertEqual(self.site.read_bytes(), self.new)
        self.commands.assert_not_called()

    def test_rollback_failure_is_not_reported_as_restored(self):
        actual_atomic = module.atomic
        rollback_failure = OSError('synthetic rollback failure')
        def atomic(value):
            if value == self.old:
                raise rollback_failure
            actual_atomic(value)
            raise OSError('synthetic candidate failure')
        with mock.patch.object(module, 'atomic', side_effect=atomic):
            with self.assertRaisesRegex(RuntimeError, 'rollback failed or unverified') as raised:
                module.main()
        self.assertIs(raised.exception.__cause__, rollback_failure)
        self.assertEqual(self.site.read_bytes(), self.new)
        self.assertEqual(self.retained_original().read_bytes(), self.old)
        self.commands.assert_not_called()

    def test_validation_failure_still_rolls_back(self):
        failure = RuntimeError('synthetic nginx validation failure')
        self.commands.side_effect = [failure, None, None, None]
        with self.assertRaisesRegex(RuntimeError, 'original restored') as raised:
            module.main()
        self.assertIs(raised.exception.__cause__, failure)
        self.assertEqual(self.site.read_bytes(), self.old)
        self.assertEqual(self.retained_original().read_bytes(), self.old)

    def test_rollback_reload_failure_is_not_swallowed(self):
        apply_failure = RuntimeError('synthetic new validation failure')
        reload_failure = RuntimeError('synthetic rollback reload failure')
        self.commands.side_effect = [apply_failure, None, reload_failure]
        with self.assertRaisesRegex(RuntimeError, 'rollback failed or unverified') as raised:
            module.main()
        self.assertIs(raised.exception.__cause__, reload_failure)
        self.assertEqual(self.site.read_bytes(), self.old)
        self.assertEqual(self.retained_original().read_bytes(), self.old)


if __name__ == '__main__':
    unittest.main()
