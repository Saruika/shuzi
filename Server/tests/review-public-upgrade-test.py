#!/usr/bin/env python3
"""Pinned public transition plus the existing real-file transaction contracts.

No production calls or writes: all filesystem transactions use private temporary
directories, and service/WordPress/HTTP operations are explicitly replaced.
"""
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


public = load('review_public_upgrade', SERVER / 'operations/upgrade-review-public-plugin.py')
u = public.engine
historical = load('review_public_transaction_contracts', SERVER / 'tests/review-game-upgrade-test.py')


def empty_payload():
    return {'schemaVersion': 1, 'contentAudience': 'public',
            'updatedAt': '2026-09-22T00:00:00+00:00', 'albums': []}


class PublicTransitionContractTests(unittest.TestCase):
    def test_exact_live_predecessor_and_candidate_graph(self):
        self.assertEqual(u.BASELINE, '3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576')
        self.assertEqual(u.TARGET, 'ae94b05f340b82842cca32beddb2c6ad7a9b69929ac97805a59f823ea28ff8ed')
        self.assertEqual(u.b.manifest(SERVER), u.TARGET)
        self.assertEqual(u.CHANGED, (u.PREFIX + 'class-shuzijun-app-content-api.php',
                                     'shuzijun-app-content.php'))
        self.assertEqual(u.ADDED, (u.PREFIX + 'trait-shuzijun-app-public-experience.php',))
        self.assertEqual(u.WRITE_ORDER, u.ADDED + u.CHANGED)
        self.assertEqual(u.WRITE_ORDER[-1], 'shuzijun-app-content.php')

    def test_dependencies_and_isolation_assets_are_byte_pinned(self):
        for name, expected in public.DEPENDENCIES.items():
            self.assertEqual(hashlib.sha256((SERVER / 'operations' / name).read_bytes()).hexdigest(), expected)
        for name, expected in u.ASSET_HASHES.items():
            self.assertEqual(u.digest((SERVER / 'operations/review' / name).read_bytes()), expected)
        self.assertEqual(u.UNITS, ('shuzijun-review-php.service', 'shuzijun-review-web.service'))
        self.assertEqual(historical.u.TARGET, u.BASELINE, 'Historical transition was not changed')

    def test_dependency_drift_fails_before_loading_engine(self):
        with patch.object(public.hashlib, 'sha256') as sha:
            sha.return_value.hexdigest.return_value = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'Unreviewed'):
                public.load_engine()

    def test_additional_health_check_keeps_private_baseline_checks(self):
        source = (SERVER / 'operations/upgrade-review-game-plugin.py').read_text()
        self.assertIn("a.request('app-admin/session')", source)
        self.assertIn("a.request('fan/game/leaderboard')", source)
        self.assertIs(u.b.wait_for_php, public.wait_for_public_php)
        with patch.object(public, 'original_wait_for_php') as readiness, \
                patch.object(u.a, 'request', return_value=(200, empty_payload())) as request:
            public.wait_for_public_php()
            readiness.assert_called_once_with()
            request.assert_called_once_with('public-experience')

    def test_public_health_requires_exact_empty_anonymous_dto(self):
        bad = [(404, {}), (401, {}), (200, []), (200, {**empty_payload(), 'originalURL': 'x'}),
               (200, {**empty_payload(), 'schemaVersion': True}),
               (200, {**empty_payload(), 'schemaVersion': 2}),
               (200, {**empty_payload(), 'contentAudience': 'member'}),
               (200, {**empty_payload(), 'updatedAt': None}),
               (200, {**empty_payload(), 'updatedAt': ''}),
               (200, {**empty_payload(), 'albums': [{'id': 1}]}),
               (200, {**empty_payload(), 'albums': {}})]
        for response in bad:
            with self.subTest(response=response), patch.object(u.a, 'request', return_value=response):
                with self.assertRaisesRegex(RuntimeError, 'valid and empty'):
                    public.verify_empty_public_catalog()


class PublicTransactionTests(historical.TransactionTests):
    def setUp(self):
        engine_patch = patch.object(historical, 'u', u)
        engine_patch.start()
        self.addCleanup(engine_patch.stop)
        super().setUp()

    def test_partial_new_file_install_is_recovered(self):
        # This transition adds one file (not the historical game's three).
        # Inject failure immediately after that one atomic new-file commit.
        real_install = u.install_added

        def fail_after_add(backup, relative, data, metadata):
            real_install(backup, relative, data, metadata)
            raise OSError('fixture failure after public trait install')

        with patch.object(u, 'install_added', side_effect=fail_after_add), self.assertRaises(OSError):
            u.apply(self.source)
        self.assert_baseline()
        self.assertEqual(self.actions, ['stop', 'stop'])

    def test_invalid_public_health_rolls_back_without_completed_receipt(self):
        u.b.wait_for_php.side_effect = public.verify_empty_public_catalog
        u.a.request.return_value = (404, {})
        with self.assertRaisesRegex(RuntimeError, 'valid and empty'):
            u.apply(self.source)
        self.assert_baseline()
        self.assertFalse(any(self.states.values()))
        self.assertFalse((self.backup() / 'completed.json').exists())
        self.assertTrue((self.backup() / 'restored-stopped.json').is_file())

    def test_empty_public_health_and_private_denials_complete_transaction(self):
        u.b.wait_for_php.side_effect = public.verify_empty_public_catalog
        u.a.request.side_effect = lambda endpoint: ((200, empty_payload())
                                                   if endpoint == 'public-experience' else (401, {}))
        with u.maintenance_lock():
            u.apply(self.source)
        self.assertEqual(u.map_manifest(u.file_map(self.live)), u.TARGET)
        self.assertTrue((self.backup() / 'completed.json').is_file())
        self.assertEqual([call.args[0] for call in u.a.request.call_args_list],
                         ['public-experience', 'app-admin/session', 'fan/game/leaderboard'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
