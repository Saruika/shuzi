#!/usr/bin/env python3
"""Exercise real file replacement/rollback with fake services and temp code only."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('upgrade', SERVER / 'operations/upgrade-review-plugin.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
original_preflight = u.preflight
original_protected_file = u.protected_file


class ReviewUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        self.site = root / 'site'
        self.live = self.site / 'wp-content/mu-plugins'
        self.config = root / 'config'
        self.config.mkdir()
        self.snapshots = {}
        for relative in u.CHANGED:
            path = self.live / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'original plugin')
            path.chmod(0o640)
            self.snapshots[relative] = ((path.read_bytes(), path.stat()), b'candidate plugin')
        (self.live / '000-review-bootstrap.php').write_bytes(b'isolation stays enabled')
        (self.site / 'wp-config.php').write_bytes(b'not a real configuration')

        def fake_manifest(path):
            values = [(path / relative).read_bytes() for relative in u.CHANGED]
            if values == [b'original plugin'] * len(u.CHANGED):
                return u.BASELINE
            if values == [b'candidate plugin'] * len(u.CHANGED):
                return u.TARGET
            return 'unrecognized'

        def write_new(path, text, mode):
            with path.open('x') as handle:
                handle.write(text)
            path.chmod(mode)

        self.patches = [patch.object(u, 'LIVE', self.live), patch.object(u.b, 'SITE', self.site),
            patch.object(u.b, 'CONFIG', self.config), patch.object(u, 'preflight', return_value=self.snapshots),
            patch.object(u, 'protected_file', side_effect=lambda p: (p.read_bytes(), p.stat())),
            patch.object(u.b, 'manifest', side_effect=fake_manifest),
            patch.object(u.b, 'write_new', side_effect=write_new)]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.command = patch.object(u.b, 'command', return_value='')
        self.commands = self.command.start()
        self.addCleanup(self.command.stop)
        for owner, name, result in [(u.b, 'wait_for_php', None), (u.a, 'request', (401, {})),
                                     (u.a, 'wp_eval', 'administrator')]:
            item = patch.object(owner, name, return_value=result)
            item.start()
            self.addCleanup(item.stop)

    def test_success_changes_only_pinned_files_and_keeps_protection(self):
        u.apply(Path('/unused-fixture-source'))
        for relative in u.CHANGED:
            self.assertEqual((self.live / relative).read_bytes(), b'candidate plugin')
            self.assertEqual((self.live / relative).stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.site / 'wp-config.php').read_bytes(), b'not a real configuration')
        self.assertEqual((self.live / '000-review-bootstrap.php').read_bytes(), b'isolation stays enabled')
        self.assertEqual(len(list(self.config.glob('plugin-backup-*/completed.json'))), 1)
        self.assertEqual([c.args[0] for c in self.commands.call_args_list],
            [['/usr/bin/systemctl', 'stop', *reversed(u.UNITS)], ['/usr/bin/systemctl', 'start', *u.UNITS]])

    def test_restart_includes_web_dependency_after_php_shutdown(self):
        states = dict.fromkeys(u.UNITS, True)
        def service_command(arguments):
            verb, *units = arguments[1:]
            if verb == 'stop':
                for unit in units:
                    states[unit] = False
                if u.PHP_UNIT in units:
                    states[u.UNITS[1]] = False
            elif verb == 'start':
                for unit in units:
                    states[unit] = True
            return ''
        def actual_readiness():
            if not all(states.values()):
                raise RuntimeError('dependent web service is still stopped')
        self.commands.side_effect = service_command
        u.b.wait_for_php.side_effect = actual_readiness
        u.apply(Path('/unused-fixture-source'))
        self.assertTrue(all(states.values()))
        self.assertEqual(len(list(self.config.glob('plugin-backup-*/completed.json'))), 1)

    def test_failed_health_restores_all_original_bytes_and_service(self):
        u.b.wait_for_php.side_effect = [RuntimeError('fixture health failure'), None]
        with self.assertRaises(RuntimeError):
            u.apply(Path('/unused-fixture-source'))
        for relative in u.CHANGED:
            self.assertEqual((self.live / relative).read_bytes(), b'original plugin')
        self.assertEqual(len(list(self.config.glob('plugin-backup-*/rollback.json'))), 1)
        self.assertEqual(len(list(self.config.glob('plugin-backup-*/completed.json'))), 0)
        self.assertEqual([c.args[0][1] for c in self.commands.call_args_list], ['stop', 'start', 'stop', 'start'])

    def test_failed_backup_never_stops_a_service(self):
        u.b.write_new.side_effect = OSError('fixture storage failure')
        with self.assertRaises(OSError):
            u.apply(Path('/unused-fixture-source'))
        self.commands.assert_not_called()
        self.assertEqual(u.b.manifest(self.live), u.BASELINE)

    def test_rollback_refuses_to_overwrite_foreign_change(self):
        def health_failure():
            (self.live / u.CHANGED[1]).write_bytes(b'foreign edit')
            raise RuntimeError('fixture failed')
        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaises(RuntimeError):
            u.apply(Path('/unused-fixture-source'))
        self.assertEqual((self.live / u.CHANGED[1]).read_bytes(), b'foreign edit')
        self.assertEqual((self.live / u.CHANGED[0]).read_bytes(), b'candidate plugin')
        self.assertEqual([c.args[0][1] for c in self.commands.call_args_list], ['stop', 'start', 'stop'])
        self.assertFalse(list(self.config.glob('plugin-backup-*/completed.json')))

    def test_explicit_api_failure_rolls_back_even_after_php_start(self):
        u.a.request.return_value = (200, {})
        with self.assertRaises(RuntimeError):
            u.apply(Path('/unused-fixture-source'))
        self.assertEqual(u.b.manifest(self.live), u.BASELINE)
        self.assertFalse(list(self.config.glob('plugin-backup-*/completed.json')))

    def test_preflight_rejects_non_root_before_any_command(self):
        with patch.object(u.os, 'geteuid', return_value=501), self.assertRaises(RuntimeError):
            original_preflight(self.live)
        self.commands.assert_not_called()

    def test_protected_file_rejects_a_symlink(self):
        link = self.live / 'alias.php'
        link.symlink_to(self.live / u.CHANGED[0])
        with self.assertRaises(RuntimeError):
            original_protected_file(link)


if __name__ == '__main__':
    unittest.main()
