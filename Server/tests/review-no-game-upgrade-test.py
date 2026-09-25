#!/usr/bin/env python3
"""Exact no-game upgrade, real temporary files, mocked review services and DB reads."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[1]
SCRIPT = SERVER / 'operations/upgrade-review-no-game-plugin.py'
spec = importlib.util.spec_from_file_location('review_no_game_upgrade', SCRIPT)
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)


class PinnedContractTests(unittest.TestCase):
    def test_exact_real_transition_and_dependencies(self):
        self.assertEqual(u.BASELINE, 'ae94b05f340b82842cca32beddb2c6ad7a9b69929ac97805a59f823ea28ff8ed')
        self.assertEqual(u.TARGET, u.b.manifest(SERVER))
        record = (SERVER / 'releases/no-game-candidate.md').read_text()
        self.assertIn('RELEASE_MANIFEST_SHA256=' + u.TARGET, record)
        self.assertEqual(record.count('REVIEW_UPGRADER_SHA256=' + u.digest(SCRIPT.read_bytes())), 1)
        self.assertEqual(u.CHANGED, (u.PREFIX + 'trait-shuzijun-app-fan-identity.php',
                                    u.PREFIX + 'class-shuzijun-app-content-api.php',
                                    'shuzijun-app-content.php'))
        self.assertEqual(set(u.REMOVED), {
            u.PREFIX + 'class-shuzijun-game-rules.php',
            u.PREFIX + 'game-rules-v1.json',
            u.PREFIX + 'trait-shuzijun-app-game-leaderboard.php'})
        self.assertEqual(u.WRITE_ORDER[-1], 'release.sha256')
        for name, expected in u.DEPENDENCIES.items():
            self.assertEqual(hashlib.sha256((SERVER / 'operations' / name).read_bytes()).hexdigest(),
                             expected)
        for name, expected in u.ASSET_HASHES.items():
            self.assertEqual(u.digest((SERVER / 'operations/review' / name).read_bytes()), expected)

    def test_exact_review_scope_and_no_database_writer(self):
        self.assertEqual(u.b.SITE, Path('/srv/shuzijun-review/site'))
        self.assertEqual(u.b.CONFIG, Path('/etc/shuzijun-review'))
        self.assertEqual(u.b.DATABASE, 'shuzijun_review')
        self.assertEqual(u.UNITS, u.b.UNITS)
        self.assertEqual(u.SITE_LOCK, Path('/var/lib/shuzijun-sync/site-operation.lock'))
        source = SCRIPT.read_text()
        for forbidden in ('CREATE TABLE', 'DROP TABLE', 'INSERT INTO', 'DELETE FROM',
                          'create_user', 'update_user', 'update_option', 'php8.3-fpm.service'):
            self.assertNotIn(forbidden, source)
        self.assertIn("with existing_site_lock():", source)
        self.assertIn("a, b = load_dependencies()", source)
        self.assertIn("source.replace(loader, '')", source)

    def test_dependency_drift_rejected_before_execution(self):
        with patch.object(u.hashlib, 'sha256') as digest:
            digest.return_value.hexdigest.return_value = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'unreviewed review dependency'):
                u.load_dependencies()


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
        self.base_names = (*u.CHANGED, *u.REMOVED, 'composer.json', 'composer.lock',
                           'vendor/autoload.php', u.PREFIX + 'unchanged.php')
        for name in self.base_names:
            old = ('original:' + name).encode()
            self.put(self.live / name, old)
            if name not in u.REMOVED:
                new = ('candidate:' + name).encode() if name in u.CHANGED else old
                self.put(self.source / name, new)
        self.assets = {}
        for name in (*u.ASSET_HASHES, 'wp-config.php'):
            path = self.root / 'assets' / name
            self.put(path, ('fixed:' + name).encode())
            self.assets[name] = path
        self.site_lock = self.root / 'locks/site-operation.lock'
        self.put(self.site_lock, b'')
        self.site_lock.chmod(0o600)
        self.site_lock.parent.chmod(0o700)

        def local_directory(path, *, private=False):
            u.check(path.is_absolute() and path.resolve() == path and path.is_dir(), 'bad directory')
            if private:
                u.check(path.stat().st_mode & 0o777 == 0o700, 'not private')

        patches = [patch.object(u, 'ROOT_UID', os.getuid()), patch.object(u, 'ROOT_GID', os.getgid()),
                   patch.object(u, 'LIVE', self.live), patch.object(u.b, 'CONFIG', self.config),
                   patch.object(u.b, 'SITE', self.root / 'site'),
                   patch.object(u, 'SITE_LOCK', self.site_lock),
                   patch.object(u, 'DEPENDENCIES', {}),
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
            return ''

        def request(endpoint, **kwargs):
            if endpoint == 'app-admin/session':
                return 401, {}
            if endpoint.startswith('fan/game/'):
                return 404, {'code': 'rest_no_route'}
            if endpoint == 'public-experience':
                return 200, {'schemaVersion': 1, 'contentAudience': 'public',
                             'updatedAt': 'fixture', 'albums': []}
            raise AssertionError('unexpected request')

        for owner, name, options in (
            (u.b, 'command', {'side_effect': command}),
            (u.a, 'wp_eval', {'return_value': 'review-identity-confirmed'}),
            (u.b, 'wait_for_php', {'return_value': None}),
            (u.a, 'request', {'side_effect': request}),
        ):
            item = patch.object(owner, name, **options)
            item.start()
            self.addCleanup(item.stop)
        self.original = {name: (self.live / name).read_bytes() for name in self.base_names}
        self.original_manifest = None

    def put(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o640)

    def assert_baseline(self):
        self.assertEqual(u.map_manifest(u.file_map(self.live)), u.BASELINE)
        for name, data in self.original.items():
            self.assertEqual((self.live / name).read_bytes(), data)
            self.assertEqual((self.live / name).stat().st_mode & 0o777, 0o640)
        if self.original_manifest is None:
            self.assertFalse(os.path.lexists(self.live / u.MANIFEST))
        else:
            self.assertEqual((self.live / u.MANIFEST).read_bytes(), self.original_manifest)
            self.assertEqual((self.live / u.MANIFEST).stat().st_mode & 0o777, 0o644)

    def backup(self):
        return next(self.config.glob('no-game-plugin-backup-*'))

    def test_readonly_preflight_does_not_stop_or_write(self):
        before = sorted(str(path) for path in self.root.rglob('*'))
        u.preflight(self.source)
        self.assertEqual(before, sorted(str(path) for path in self.root.rglob('*')))
        self.assertEqual(self.actions, [])


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


    def test_missing_atomic_api_rejects_preflight_without_service_change(self):
        with patch.object(u, 'exclusive_rename_api', side_effect=u.ReviewNoGameError('unavailable')):
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



    def test_success_without_old_manifest_and_explicit_restore(self):
        with u.maintenance_lock():
            u.apply(self.source)
        self.assertEqual(u.map_manifest(u.file_map(self.live)), u.TARGET)
        self.assertEqual(u.digest((self.live / u.MANIFEST).read_bytes()), u.TARGET)
        self.assertTrue(all(not os.path.lexists(self.live / name) for name in u.REMOVED))
        self.assertTrue((self.backup() / 'completed.json').is_file())
        self.assertEqual(self.actions, ['stop', 'start'])
        with u.maintenance_lock():
            u.restore(self.backup())
        self.assert_baseline()
        self.assertFalse(any(self.states.values()))
        self.assertEqual(self.actions, ['stop', 'start', 'stop'])

    def test_existing_manifest_exact_bytes_and_mode_survive_restore(self):
        self.original_manifest = u.manifest_bytes(u.file_map(self.live))
        self.put(self.live / u.MANIFEST, self.original_manifest)
        (self.live / u.MANIFEST).chmod(0o644)
        u.apply(self.source)
        self.assertEqual((self.live / u.MANIFEST).stat().st_mode & 0o777, 0o644)
        u.restore(self.backup())
        self.assert_baseline()

    def test_each_removal_failure_restores_all_files_and_absent_manifest(self):
        real_remove = u.remove_exact
        for name in u.REMOVED:
            with self.subTest(name=name):
                self.states = dict.fromkeys(u.UNITS, True)

                def failure(relative, data, metadata):
                    if relative == name:
                        raise OSError('fixture removal failure')
                    return real_remove(relative, data, metadata)

                with patch.object(u, 'remove_exact', side_effect=failure), self.assertRaises(OSError):
                    u.apply(self.source)
                self.assert_baseline()
                self.assertFalse(any(self.states.values()))

    def test_interrupted_removal_can_restore_repeatedly(self):
        current, candidate, preserved, state = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved, state)
        u.stop_services()
        name = u.REMOVED[0]
        u.remove_exact(name, current[name][0], u.metadata_record(current[name][1]))
        for _ in range(2):
            u.restore(backup)
            self.assert_baseline()
        self.assertNotIn('start', self.actions)

    def test_manifest_commit_failure_restores_absence_and_payload(self):
        real_install = u.install_added

        def failure(backup, relative, data, metadata):
            real_install(backup, relative, data, metadata)
            if relative == u.MANIFEST:
                raise OSError('fixture failure after manifest commit')

        with patch.object(u, 'install_added', side_effect=failure), self.assertRaises(OSError):
            u.apply(self.source)
        self.assert_baseline()
        self.assertFalse(any(self.states.values()))

    def test_partial_private_manifest_stage_never_becomes_live(self):
        current, candidate, preserved, state = u.preflight(self.source)
        backup = u.backup_transaction(current, candidate, preserved, state)
        u.stop_services()
        real_write = u.write_new

        def failure(path, data, metadata):
            if path.parent == backup / 'staging' and path.suffix == '.payload':
                self.put(path, data[:5])
                raise SystemExit('fixture process interruption')
            return real_write(path, data, metadata)

        metadata = u.metadata_record(current['shuzijun-app-content.php'][1])
        with patch.object(u, 'write_new', side_effect=failure), self.assertRaises(SystemExit):
            u.install_added(backup, u.MANIFEST, u.manifest_bytes(candidate), metadata)
        self.assertFalse(os.path.lexists(self.live / u.MANIFEST))
        residues = list((backup / 'staging').iterdir())
        self.assertEqual(len(residues), 2)
        u.restore(backup)
        self.assert_baseline()
        self.assertTrue(all(path.exists() for path in residues))

    def test_foreign_removed_file_reappearance_blocks_all_rollback_overwrites(self):
        def health_failure():
            self.put(self.live / u.REMOVED[0], b'foreign')
            raise RuntimeError('fixture failure')
        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'foreign file change'):
            u.apply(self.source)
        self.assertEqual((self.live / u.REMOVED[0]).read_bytes(), b'foreign')
        self.assertEqual((self.live / u.CHANGED[-1]).read_bytes(),
                         ('candidate:' + u.CHANGED[-1]).encode())
        self.assertFalse(any(self.states.values()))

    def test_foreign_manifest_blocks_rollback(self):
        def health_failure():
            (self.live / u.MANIFEST).write_bytes(b'foreign')
            raise RuntimeError('fixture failure')
        u.b.wait_for_php.side_effect = health_failure
        with self.assertRaisesRegex(RuntimeError, 'foreign live manifest'):
            u.apply(self.source)
        self.assertEqual((self.live / u.MANIFEST).read_bytes(), b'foreign')
        self.assertFalse(any(self.states.values()))

    def test_configuration_and_unaffected_file_drift_stop_rollback(self):
        for target in (self.assets['wp-config.php'], self.live / 'vendor/autoload.php'):
            with self.subTest(target=target):
                before = target.read_bytes()
                u.apply(self.source)
                target.write_bytes(b'foreign')
                with self.assertRaisesRegex(RuntimeError, 'configuration changed|foreign file change'):
                    u.restore(self.backup())
                self.assertFalse(any(self.states.values()))
                target.write_bytes(before)
                u.restore(self.backup())
                self.assert_baseline()
                self.states = dict.fromkeys(u.UNITS, True)

    def test_bad_or_linked_live_manifest_is_not_ignored(self):
        path = self.live / u.MANIFEST
        for linked in (False, True):
            with self.subTest(linked=linked):
                if linked:
                    path.symlink_to(self.root / 'missing')
                else:
                    self.put(path, b'foreign')
                with self.assertRaises(RuntimeError):
                    u.preflight(self.source)
                self.assertEqual(self.actions, [])
                path.unlink()

    def test_corrupt_backup_manifest_and_presence_state_rejected(self):
        backup = u.backup_transaction(*u.preflight(self.source))
        path = backup / 'original.sha256'
        data = path.read_bytes()
        path.write_bytes(b'foreign')
        with self.assertRaisesRegex(RuntimeError, 'backup manifest bytes'):
            u.load_transaction(backup)
        path.write_bytes(data)
        journal = json.loads((backup / 'prepared.json').read_text())
        journal['manifest'] = {'present': False, 'mode': 0o640}
        (backup / 'prepared.json').write_text(json.dumps(journal))
        with self.assertRaisesRegex(RuntimeError, 'invalid absent manifest'):
            u.load_transaction(backup)
        self.assertEqual(self.actions, [])

    def test_site_lock_missing_or_busy_never_creates_review_lock(self):
        self.site_lock.unlink()
        with self.assertRaises(FileNotFoundError), u.maintenance_lock():
            self.fail('missing global lock accepted')
        self.assertFalse((self.config / 'plugin-maintenance.lock').exists())
        self.put(self.site_lock, b'')
        self.site_lock.chmod(0o600)
        with u.existing_site_lock():
            with self.assertRaises(BlockingIOError), u.maintenance_lock():
                self.fail('busy global lock accepted')
        self.assertFalse((self.config / 'plugin-maintenance.lock').exists())

    def test_wrong_review_identity_rejected_before_service_changes(self):
        u.a.wp_eval.return_value = 'production'
        with self.assertRaisesRegex(RuntimeError, 'unexpected review database'):
            u.preflight(self.source)
        self.assertEqual(self.actions, [])

    def test_game_route_health_failure_recovers_exact_baseline(self):
        u.a.request.side_effect = lambda *args, **kwargs: (401, {})
        with self.assertRaisesRegex(RuntimeError, 'removed game route'):
            u.apply(self.source)
        self.assert_baseline()
        self.assertFalse(any(self.states.values()))

    def test_public_health_failure_recovers_exact_baseline(self):
        real_request = u.a.request.side_effect
        u.a.request.side_effect = lambda endpoint, **kwargs: ((503, {}) if endpoint == 'public-experience'
                                                              else real_request(endpoint, **kwargs))
        with self.assertRaisesRegex(RuntimeError, 'public catalog'):
            u.apply(self.source)
        self.assert_baseline()

    def test_unknown_graph_changes_and_inventory_are_rejected(self):
        for root, relative in ((self.live, 'unknown.php'), (self.live, 'vendor/foreign.php'),
                               (self.source, 'vendor/foreign.php')):
            path = root / relative
            self.put(path, b'foreign')
            with self.assertRaises(RuntimeError):
                u.preflight(self.source)
            self.assertEqual(self.actions, [])
            path.unlink()


if __name__ == '__main__':
    unittest.main(verbosity=2)
