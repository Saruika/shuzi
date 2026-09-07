#!/usr/bin/env python3
"""Isolated permalink transition tests; WordPress calls are mocked here."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('repair', Path(__file__).resolve().parents[1]
                                              / 'operations/repair-review-permalinks.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReviewPermalinkTests(unittest.TestCase):
    def setUp(self):
        self.before = dict(structure='', public=False, urls=['https://review.shuzijun.com.cn/?portfolio=example'],
                           contentDigest='synthetic-metadata-digest')
        self.after = dict(self.before, structure=r.TARGET, urls=['https://review.shuzijun.com.cn/portfolio/example/'])
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name)
        def write(path, text, mode):
            with path.open('x') as handle:
                handle.write(text)
            path.chmod(mode)
        for item in (patch.object(r.b, 'CONFIG', self.config), patch.object(r.b, 'write_new', side_effect=write)):
            item.start()
            self.addCleanup(item.stop)

    def test_valid_generation_does_not_require_public_browsing(self):
        self.assertTrue(r.valid_links(self.after))
        self.assertFalse(r.valid_links(self.before))
        self.assertFalse(r.valid_links(dict(self.after, public=True)))

    def test_success_has_private_original_and_completed_receipts(self):
        with patch.object(r, 'snapshot', side_effect=[self.before, self.after]), \
                patch.object(r.b, 'configure_permalink_structure') as configure:
            r.repair(self.before)
        configure.assert_called_once()
        self.assertEqual(len(list(self.config.glob('*.completed.json'))), 1)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in self.config.glob('*.json')))

    def test_nonempty_configuration_is_never_overwritten(self):
        with patch.object(r.b, 'configure_permalink_structure') as configure, self.assertRaises(RuntimeError):
            r.repair(dict(self.before, structure='/custom/'))
        configure.assert_not_called()
        self.assertFalse(list(self.config.iterdir()))

    def test_foreign_change_before_apply_is_not_rolled_back(self):
        with patch.object(r, 'snapshot', return_value=self.after), \
                patch.object(r.a, 'wp_eval') as restore, \
                patch.object(r.b, 'configure_permalink_structure') as configure, self.assertRaises(RuntimeError):
            r.repair(self.before)
        restore.assert_not_called()
        configure.assert_not_called()

    def test_failed_links_restore_only_known_structure(self):
        malformed = dict(self.after, urls=self.before['urls'])
        with patch.object(r, 'snapshot', side_effect=[self.before, malformed, malformed, self.before]), \
                patch.object(r.b, 'configure_permalink_structure'), \
                patch.object(r.a, 'wp_eval') as restore, self.assertRaises(RuntimeError):
            r.repair(self.before)
        restore.assert_called_once()
        self.assertEqual(len(list(self.config.glob('*.rollback.json'))), 1)

    def test_foreign_content_after_attempt_requires_manual_recovery(self):
        changed = dict(self.after, contentDigest='other-content')
        with patch.object(r, 'snapshot', side_effect=[self.before, changed, changed]), \
                patch.object(r.b, 'configure_permalink_structure'), \
                patch.object(r.a, 'wp_eval') as restore, self.assertRaises(RuntimeError):
            r.repair(self.before)
        restore.assert_not_called()
        self.assertFalse(list(self.config.glob('*.completed.json')))


if __name__ == '__main__':
    unittest.main()
