#!/usr/bin/env python3
"""Catalog boundary tests using synthetic bytes, never artist photographs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('review_catalog', SERVER / 'operations/prepare-review-catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class ReviewCatalogTests(unittest.TestCase):
    def test_curated_groups_and_digest_pins_are_complete(self):
        data = json.loads(catalog.CATALOG_PATH.read_text())
        self.assertEqual([a['key'] for a in data['albums']], ['magnolia', 'lantern'])
        self.assertEqual(len(data['images']), 8)
        self.assertEqual(len({item['key'] for item in data['images']}), 8)
        self.assertEqual([sum(i['album'] == a for i in data['images']) for a in ('magnolia', 'lantern')], [5, 3])
        for item in data['images']:
            self.assertRegex(item['sha256'], r'^[a-f0-9]{64}$')

    def test_source_traversal_or_non_jpeg_rejected_before_io(self):
        for source in ('../wp-config.php', '/etc/passwd', '2026/09/../secret.jpg', '2026/09/image.png'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                catalog.read_source({'source': source})

    def test_only_byte_identical_bounded_regular_source_accepted(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(catalog, 'SOURCE_ROOT', Path(folder)):
            relative = '2026/09/example.jpg'
            path = Path(folder) / relative
            path.parent.mkdir(parents=True)
            data = b'\xff\xd8\xff' + bytes(100_000)
            path.write_bytes(data)
            item = {'source': relative, 'sha256': hashlib.sha256(data).hexdigest()}
            self.assertEqual(catalog.read_source(item), data)
            path.write_bytes(data[:-1] + b'x')
            with self.assertRaises(ValueError):
                catalog.read_source(item)
            path.write_bytes(b'\xff\xd8\xff')
            with self.assertRaises(ValueError):
                catalog.read_source(item)

    def test_source_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(catalog, 'SOURCE_ROOT', Path(folder)):
            path = Path(folder) / '2026/09/example.jpg'
            path.parent.mkdir(parents=True)
            path.symlink_to(SERVER / 'composer.json')
            with self.assertRaises(ValueError):
                catalog.read_source({'source': '2026/09/example.jpg'})

    def test_media_origin_credentials_and_redirect_material_rejected(self):
        base = 'https://review.shuzijun.com.cn/wp-content/uploads/example.jpg'
        self.assertEqual(catalog.verify_media_url(base), '/wp-content/uploads/example.jpg')
        for value in (base.replace('https:', 'http:'), base.replace('review.', 'www.'),
                      base.replace('https://', 'https://user@'), base + '?redirect=other',
                      base + '#fragment', base.replace('.cn/', '.cn:8443/'),
                      'https://review.shuzijun.com.cn/wp-config.php'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                catalog.verify_media_url(value)

    def test_snapshot_supports_empty_and_populated_catalog_without_mutation(self):
        empty = dict(heroImages=[], launchPosters=[], aboutPortraitURL=None, portfolios=[])
        self.assertEqual(catalog.a.catalog_snapshot(empty), empty)
        url = 'https://review.shuzijun.com.cn/wp-content/uploads/example.jpg'
        full = dict(heroImages=[url], launchPosters=[dict(imageURL=url, subtitle='审核演示')],
                    aboutPortraitURL=url, portfolios=[dict(coverURL=url, images=[dict(url=url, fullSizeURL=url)])])
        self.assertEqual(catalog.a.catalog_snapshot(full), full)
        self.assertEqual(full['launchPosters'][0]['subtitle'], '审核演示')
        full['portfolios'][0]['images'][0]['fullSizeURL'] = url.replace('review.', 'www.')
        with self.assertRaises(RuntimeError):
            catalog.a.catalog_snapshot(full)


if __name__ == '__main__':
    unittest.main(verbosity=2)
