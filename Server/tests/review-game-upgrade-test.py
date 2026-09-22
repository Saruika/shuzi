#!/usr/bin/env python3
"""Real temporary-file transactions, fake review services; no host mutations."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('review_game_upgrade',
                                             SERVER / 'operations/upgrade-review-game-plugin.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)


class PinnedContractTests(unittest.TestCase):
    def test_exact_real_manifest_and_asset_pins(self):
        self.assertEqual(u.BASELINE, '5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe')
        # This exact historical review upgrader is not a generic upgrade path.
        # The new public trait requires its own approved review transition.
        self.assertEqual(u.TARGET, '3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576')
        self.assertNotEqual(u.TARGET, u.b.manifest(SERVER))
        self.assertIn("check(map_manifest(candidate) == TARGET, 'candidate differs from reviewed release')",
                      (SERVER / 'operations/upgrade-review-game-plugin.py').read_text())
        record = (SERVER / 'releases/game-leaderboard-candidate.md').read_text()
        self.assertIn('RELEASE_MANIFEST_SHA256=' + u.TARGET, record)
        self.assertEqual(len(u.CHANGED), 6)
        self.assertEqual(len(u.ADDED), 3)
        self.assertEqual(u.WRITE_ORDER[-1], 'shuzijun-app-content.php')
        for name, expected in u.ASSET_HASHES.items():
            self.assertEqual(u.digest((SERVER / 'operations/review' / name).read_bytes()), expected)

    def test_no_schema_or_account_write_and_only_review_units(self):
        source = (SERVER / 'operations/upgrade-review-game-plugin.py').read_text()
        for forbidden in ('CREATE TABLE', 'dbDelta', 'create_user', 'update_user', 'wp_mail',
                          'INSERT INTO', 'DELETE FROM', 'DROP TABLE', 'php8.3-fpm.service'):
            self.assertNotIn(forbidden, source)
        self.assertEqual(u.UNITS, ('shuzijun-review-php.service', 'shuzijun-review-web.service'))
        self.assertIn("a.request('fan/game/leaderboard')", source)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.live = self.root / 'site/wp-content/mu-plugins'
        self.config = self.root / 'config'
        self.source = self.root / 'source'
        self.config.mkdir(mode=0o700)
        self.live.mkdir(parents=True)
        self.source.mkdir()
        self.put(self.live / '000-review-bootstrap.php', b'fixed review isolation')
        self.base_names = (*u.CHANGED, 'composer.json', 'composer.lock', 'vendor/autoload.php',
                           u.PREFIX + 'unchanged.php')
        for name in self.base_names:
            old = ('original:' + name).encode()
            new = ('candidate:' + name).encode() if name in u.CHANGED else old
            self.put(self.live / name, old)
            self.put(self.source / name, new)
        for name in u.ADDED:
            self.put(self.source / name, ('candidate:' + name).encode())
        self.assets = {}
        for name in (*u.ASSET_HASHES, 'wp-config.php'):
            path = self.root / 'assets' / name
            self.put(path, ('fixed:' + name).encode())
            self.assets[name] = path

        def local_directory(path, *, private=False):
            u.check(path.is_absolute() and path.resolve() == path and path.is_dir(), 'bad directory')
            if private:
                u.check(path.stat().st_mode & 0o777 == 0o700, 'not private')

        patches = [patch.object(u, 'ROOT_UID', os.getuid()),
                   patch.object(u, 'LIVE', self.live), patch.object(u.b, 'CONFIG', self.config),
                   patch.object(u.b, 'SITE', self.root / 'site'),
                   patch.object(u, 'directory', side_effect=local_directory),
                   patch.object(u, 'asset_paths', return_value=self.assets),
                   patch.object(u, 'ASSET_HASHES', {name: u.digest(path.read_bytes())
                                                   for name, path in self.assets.items()
                                                   if name != 'wp-config.php'})]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)
        for key, root in (('BASELINE', self.live), ('TARGET', self.source)):
            item = patch.object(u, key, u.map_manifest(u.file_map(root)))
            item.start()
            self.addCleanup(item.stop)
        self.states = dict.fromkeys(u.UNITS, True)
        self.actions = []

        def command(args, **kwargs):
            if args[0] == '/usr/bin/systemctl':
                action = args[1]
                if action == 'show':
                    unit = args[2]
                    active = self.states[unit]
                    return ('ActiveState=' + ('active' if active else 'inactive')
                            + '\nSubState=' + ('running' if active else 'dead')
                            + '\nMainPID=' + ('42' if active else '0')
                            + '\nDropInPaths=\nFragmentPath=/etc/systemd/system/' + unit + '\n')
                self.actions.append(action)
                for unit in args[2:]:
                    self.states[unit] = action == 'start'
            return 'rules-ready' if '-r' in args else ''

        for owner, name, options in (
            (u.b, 'command', {'side_effect': command}),
            (u.a, 'wp_eval', {'return_value': u.b.DATABASE}),
            (u.b, 'wait_for_php', {'return_value': None}),
            (u.a, 'request', {'return_value': (401, {})}),
        ):
            item = patch.object(owner, name, **options)
            item.start()
            self.addCleanup(item.stop)
        self.original = {name: (self.live / name).read_bytes() for name in self.base_names}

    def put(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o640)

    def assert_baseline(self):
        self.assertEqual(u.map_manifest(u.file_map(self.live)), u.BASELINE)
        for name in u.ADDED:
            self.assertFalse(os.path.lexists(self.live / name))
        for name, data in self.original.items():
            self.assertEqual((self.live / name).read_bytes(), data)

    def backup(self):
        return next(self.config.glob('game-plugin-backup-*'))

    def test_readonly_preflight_does_not_stop_or_write(self):
        before = sorted(str(path) for path in self.root.rglob('*'))
        u.preflight(self.source)
        self.assertEqual(before, sorted(str(path) for path in self.root.rglob('*')))
        self.assertEqual(self.actions, [])

    def test_live_root_unknown_plugin_or_residue_is_rejected_but_source_tools_are_allowed(self):
        self.put(self.source / 'operations/nonpayload-tool.py', b'local staging tool')
        u.preflight(self.source)
        for name in ('unknown-plugin.php', '.review-game-interrupted', 'release.sha256'):
            with self.subTest(name=name):
                self.put(self.live / name, b'foreign root item')
                with self.assertRaisesRegex(RuntimeError, 'unexpected review mu-plugin root inventory'):
                    u.preflight(self.source)
                self.assertEqual(self.actions, [])
                (self.live / name).unlink()

    def test_unknown_root_item_during_failure_is_not_deleted_or_ignored(self):
        def health_failure():
            self.put(self.live / 'unknown-plugin.php', b'foreign')
            raise RuntimeError('fixture health failure')

        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'unexpected review mu-plugin root inventory'):
            u.apply(self.source)
        self.assertFalse(any(self.states.values()))
        self.assertEqual((self.live / 'unknown-plugin.php').read_bytes(), b'foreign')
        self.assertTrue(all((self.live / name).exists() for name in u.ADDED))

    def test_success_and_explicit_restore_keep_added_file_presence_correct(self):
        with u.maintenance_lock():
            u.apply(self.source)
        self.assertEqual(u.map_manifest(u.file_map(self.live)), u.TARGET)
        self.assertEqual(self.actions, ['stop', 'start'])
        self.assertTrue((self.backup() / 'completed.json').is_file())
        for name in u.ADDED:
            self.assertEqual((self.live / name).stat().st_mode & 0o777, 0o640)
        with u.maintenance_lock():
            u.restore(self.backup())
        self.assert_baseline()
        self.assertFalse(any(self.states.values()))
        self.assertEqual(self.actions, ['stop', 'start', 'stop'])
        self.assertTrue((self.backup() / 'restored-stopped.json').is_file())

    def test_corrupted_backup_after_start_still_stops_review_before_refusing(self):
        def health_failure():
            (self.backup() / 'original' / u.CHANGED[0]).write_bytes(b'corrupt')
            raise RuntimeError('fixture health failure')

        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'backup baseline mismatch'):
            u.apply(self.source)
        self.assertFalse(any(self.states.values()))
        self.assertEqual(self.actions, ['stop', 'start', 'stop'])
        self.assertFalse((self.backup() / 'restored-stopped.json').exists())

    def test_interrupted_transaction_can_restore_repeatedly_but_never_restart(self):
        current, candidate, preserved = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved)
        u.stop_services()
        u.install_added(backup, u.ADDED[0], candidate[u.ADDED[0]][0],
                        u.metadata_record(current[u.CHANGED[0]][1]))
        for _ in range(2):
            with u.maintenance_lock():
                u.restore(backup)
            self.assert_baseline()
        self.assertNotIn('start', self.actions)

    def test_exclusive_new_file_write_failure_removes_only_own_partial_file(self):
        path = self.live / u.ADDED[0]
        metadata = u.metadata_record((self.live / u.CHANGED[0]).stat())
        with patch.object(u.os, 'fchmod', side_effect=OSError('fixture chmod failure')):
            with self.assertRaises(OSError):
                u.write_new(path, b'new bytes', metadata)
        self.assertFalse(os.path.lexists(path))
        self.assert_baseline()

    def test_concurrent_maintenance_lock_is_rejected(self):
        with u.maintenance_lock():
            with self.assertRaises(BlockingIOError), u.maintenance_lock():
                self.fail('second writer acquired the lock')

    def test_failed_health_rolls_back_and_never_restarts_after_failure(self):
        u.b.wait_for_php.side_effect = RuntimeError('fixture health failure')
        with self.assertRaises(RuntimeError):
            u.apply(self.source)
        self.assert_baseline()
        self.assertEqual(self.actions, ['stop', 'start', 'stop'])
        self.assertFalse(any(self.states.values()))

    def test_partial_new_file_install_is_recovered(self):
        real_install = u.install_added

        def fail_second_added(backup, relative, data, metadata):
            if relative == u.ADDED[1]:
                raise OSError('fixture failure before second new file')
            real_install(backup, relative, data, metadata)

        with patch.object(u, 'install_added', side_effect=fail_second_added), self.assertRaises(OSError):
            u.apply(self.source)
        self.assert_baseline()
        self.assertEqual(self.actions, ['stop', 'stop'])

    def test_each_existing_replacement_failure_restores_exact_baseline(self):
        real_replace = u.replace_exact
        for name in u.CHANGED:
            with self.subTest(name=name):
                self.states = dict.fromkeys(u.UNITS, True)

                def fail_replacement(path, data, metadata, expected, backup, operation='replace'):
                    if path == self.live / name and data.startswith(b'candidate:'):
                        raise OSError('fixture replacement failure')
                    real_replace(path, data, metadata, expected, backup, operation)

                with patch.object(u, 'replace_exact', side_effect=fail_replacement), self.assertRaises(OSError):
                    u.apply(self.source)
                self.assert_baseline()
                self.assertFalse(any(self.states.values()))

    def test_backup_failure_does_not_stop_services(self):
        with patch.object(u, 'backup_transaction', side_effect=OSError('fixture full disk')):
            with self.assertRaises(OSError):
                u.apply(self.source)
        self.assert_baseline()
        self.assertEqual(self.actions, [])

    def test_foreign_new_file_is_never_removed_during_rollback(self):
        def health_failure():
            (self.live / u.ADDED[0]).write_bytes(b'foreign')
            raise RuntimeError('fixture health failure')

        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'foreign file change'):
            u.apply(self.source)
        self.assertEqual((self.live / u.ADDED[0]).read_bytes(), b'foreign')
        self.assertEqual((self.live / u.CHANGED[-1]).read_bytes(), ('candidate:' + u.CHANGED[-1]).encode())
        self.assertFalse(any(self.states.values()))

    def test_foreign_unchanged_file_stops_rollback_before_any_overwrite(self):
        def health_failure():
            (self.live / 'vendor/autoload.php').write_bytes(b'foreign')
            raise RuntimeError('fixture health failure')

        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'foreign file change'):
            u.apply(self.source)
        self.assertTrue(all((self.live / name).exists() for name in u.ADDED))
        self.assertFalse(any(self.states.values()))

    def test_configuration_drift_stops_rollback_without_overwrite(self):
        def health_failure():
            self.assets['wp-config.php'].chmod(0o644)
            raise RuntimeError('fixture health failure')

        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'configuration changed'):
            u.apply(self.source)
        self.assertTrue((self.live / u.ADDED[0]).exists())
        self.assertFalse(any(self.states.values()))

    def test_stop_not_confirmed_means_no_plugin_writes(self):
        real_assert = u.assert_services

        def fail_stopped(stopped):
            if stopped:
                raise RuntimeError('fixture service remained active')
            real_assert(stopped)

        with patch.object(u, 'assert_services', side_effect=fail_stopped), self.assertRaises(RuntimeError):
            u.apply(self.source)
        self.assert_baseline()
        self.assertNotIn('start', self.actions)

    def test_public_exclusive_rename_never_overwrites_existing_destination(self):
        source = self.root / 'rename-source'
        target = self.root / 'rename-target'
        self.put(source, b'candidate')
        self.put(target, b'foreign')
        with self.assertRaises(FileExistsError):
            u.rename_new(source, target)
        self.assertEqual(target.read_bytes(), b'foreign')
        self.assertEqual(source.read_bytes(), b'candidate')
        target.unlink()
        u.rename_new(source, target)
        self.assertEqual(target.read_bytes(), b'candidate')
        self.assertFalse(source.exists())

    def test_interruption_with_partial_private_stage_never_leaves_live_partial(self):
        current, candidate, preserved = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved)
        u.stop_services()
        real_write = u.write_new

        def simulated_kill(path, data, metadata):
            if path.parent == backup / 'staging' and path.suffix == '.payload':
                self.put(path, data[:5])
                raise SystemExit('simulated process interruption after partial private write')
            real_write(path, data, metadata)

        with patch.object(u, 'write_new', side_effect=simulated_kill), self.assertRaises(SystemExit):
            u.install_added(backup, u.ADDED[0], candidate[u.ADDED[0]][0],
                            u.metadata_record(current[u.CHANGED[0]][1]))
        self.assertFalse((self.live / u.ADDED[0]).exists())
        residues = list((backup / 'staging').iterdir())
        self.assertEqual(len(residues), 2)  # Exact receipt + private partial payload.
        u.restore(backup)
        self.assert_baseline()
        self.assertTrue(all(path.exists() for path in residues))  # Never glob-clean leftovers.

    def test_interruption_after_atomic_new_commit_remains_fully_recoverable(self):
        current, candidate, preserved = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved)
        u.stop_services()
        real_rename = u.rename_new

        def simulated_kill(source, target):
            real_rename(source, target)
            raise SystemExit('simulated interruption after atomic commit')

        with patch.object(u, 'rename_new', side_effect=simulated_kill), self.assertRaises(SystemExit):
            u.install_added(backup, u.ADDED[0], candidate[u.ADDED[0]][0],
                            u.metadata_record(current[u.CHANGED[0]][1]))
        self.assertEqual((self.live / u.ADDED[0]).read_bytes(), candidate[u.ADDED[0]][0])
        u.restore(backup)
        self.assert_baseline()

    def test_interrupted_existing_replacement_uses_no_live_temporary_files(self):
        current, candidate, preserved = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved)
        u.stop_services()
        real_replace = u.os.replace

        def simulated_kill(source, target):
            real_replace(source, target)
            raise SystemExit('simulated interruption after existing file commit')

        name = u.CHANGED[0]
        with patch.object(u.os, 'replace', side_effect=simulated_kill), self.assertRaises(SystemExit):
            u.replace_exact(self.live / name, candidate[name][0], u.metadata_record(current[name][1]),
                            current[name][0], backup)
        self.assertFalse(any(p.name.startswith('.review-game-') for p in self.live.rglob('*')))
        u.restore(backup)
        self.assert_baseline()

    def test_missing_atomic_api_rejects_preflight_without_service_change(self):
        with patch.object(u, 'exclusive_rename_api', side_effect=u.ReviewGameError('unavailable')):
            with self.assertRaises(RuntimeError):
                u.preflight(self.source)
        self.assertEqual(self.actions, [])

    def test_tampered_backup_is_rejected_before_service_operations(self):
        transaction = u.preflight(self.source)
        backup = u.backup_transaction(*transaction)
        (backup / 'original' / u.CHANGED[0]).write_bytes(b'corrupted')
        with self.assertRaisesRegex(RuntimeError, 'backup baseline mismatch'):
            u.restore(backup)
        self.assertEqual(self.actions, [])

    def test_backup_target_injection_and_duplicate_record_rejected(self):
        backup = u.backup_transaction(*u.preflight(self.source))
        journal = json.loads((backup / 'prepared.json').read_text())
        journal['files'][0] = journal['files'][1]
        (backup / 'prepared.json').write_text(json.dumps(journal))
        with self.assertRaises(RuntimeError):
            u.load_transaction(backup)
        with self.assertRaises(RuntimeError):
            u.load_transaction(self.root)

    def test_new_path_symlink_or_existing_file_is_not_overwritten(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                path = self.live / u.ADDED[0]
                if symlink:
                    path.symlink_to(self.root / 'absent')
                else:
                    path.write_bytes(b'foreign')
                with self.assertRaises((RuntimeError, ValueError)):
                    u.preflight(self.source)
                self.assertEqual(self.actions, [])
                path.unlink()

    def test_shared_inode_or_writable_plugin_is_rejected(self):
        path = self.live / u.CHANGED[0]
        alias = self.root / 'foreign-hardlink'
        os.link(path, alias)
        with self.assertRaisesRegex(RuntimeError, 'unprotected file'):
            u.preflight(self.source)
        alias.unlink()
        path.chmod(0o666)
        with self.assertRaisesRegex(RuntimeError, 'unprotected file'):
            u.preflight(self.source)
        self.assertEqual(self.actions, [])

    def test_service_dropin_or_wrong_fragment_rejected(self):
        for replacement in ('DropInPaths=/tmp/override.conf', 'FragmentPath=/tmp/foreign.service'):
            with self.subTest(replacement=replacement):
                content = ('ActiveState=active\nSubState=running\nMainPID=42\nDropInPaths=\n'
                           'FragmentPath=/etc/systemd/system/' + u.UNITS[0])
                key = replacement.split('=')[0]
                content = '\n'.join(replacement if line.startswith(key + '=') else line
                                    for line in content.splitlines())
                with patch.object(u.b, 'command', return_value=content):
                    with self.assertRaisesRegex(RuntimeError, 'unexpected review service override'):
                        u.assert_services(False)

    def test_unexpected_candidate_or_live_manifest_is_rejected(self):
        for root in (self.source, self.live):
            path = root / 'vendor/autoload.php'
            original = path.read_bytes()
            path.write_bytes(b'unreviewed')
            with self.assertRaises(RuntimeError):
                u.preflight(self.source)
            self.assertEqual(self.actions, [])
            path.write_bytes(original)

    def test_lock_symlink_hardlink_and_nonempty_are_rejected(self):
        lock = self.config / 'plugin-maintenance.lock'
        for kind in ('symlink', 'hardlink', 'nonempty'):
            with self.subTest(kind=kind):
                target = self.root / 'lock-target'
                self.put(target, b'' if kind != 'nonempty' else b'foreign')
                target.chmod(0o600)
                if kind == 'symlink':
                    lock.symlink_to(target)
                elif kind == 'hardlink':
                    os.link(target, lock)
                else:
                    lock.write_bytes(b'foreign')
                    lock.chmod(0o600)
                with self.assertRaises((RuntimeError, OSError)), u.maintenance_lock():
                    self.fail('unsafe lock accepted')
                lock.unlink()


if __name__ == '__main__':
    unittest.main(verbosity=2)
