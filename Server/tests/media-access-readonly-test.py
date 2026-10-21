#!/usr/bin/env python3
"""Offline failure-boundary checks; never contacts the real project."""

import contextlib
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.error import URLError

SPEC = importlib.util.spec_from_file_location("media_audit", Path(__file__).with_name("media-access-readonly.py"))
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)
MEDIA_URL = "https://www.shuzijun.com.cn/wp-content/uploads/fixture-preview.jpg"


def public_payload():
    return {"schemaVersion": 1, "contentAudience": "public", "updatedAt": "2026-10-21T00:00:00Z",
            "albums": [{"id": 1, "title": "Fixture", "subtitle": "", "images": [
                {"id": 2, "url": MEDIA_URL, "altText": ""}]}]}


class MediaAuditTests(unittest.TestCase):
    def test_only_fixed_https_origins(self):
        for url in ("http://shuzijun.com.cn/", "https://example.com/", "https://www.shuzijun.com.cn:444/",
                    "https://" + "user:password@www.shuzijun.com.cn/", "https://www.shuzijun.com.cn/#fragment"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                audit.owned_url(url)

    def test_public_catalogue_rejects_extra_private_fields(self):
        for target in ("root", "album", "image"):
            payload = public_payload()
            record = {"root": payload, "album": payload["albums"][0],
                      "image": payload["albums"][0]["images"][0]}[target]
            record["private"] = "must not enter public contract"
            with self.subTest(target=target), self.assertRaises(ValueError):
                audit.selected_images(payload)

    def test_public_media_rejects_external_and_ambiguous_paths(self):
        for url in ("https://example.com/a.jpg", "https://www.shuzijun.com.cn/wp-content/uploads/%2e/a.jpg",
                    "https://www.shuzijun.com.cn/wp-content/uploads/../a.jpg", MEDIA_URL + "?token=fixture"):
            payload = public_payload()
            payload["albums"][0]["images"][0]["url"] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                audit.selected_images(payload)
        self.assertEqual(audit.selected_images(public_payload()), [MEDIA_URL])

    def test_head_never_reads_media_body(self):
        response = MagicMock(code=200)
        response.headers = {"Content-Type": "image/jpeg"}
        response.__enter__.return_value = response
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(audit, "build_opener", return_value=opener):
            result, payload = audit.fetch(MEDIA_URL, 1, method="HEAD")
        response.read.assert_not_called()
        self.assertEqual(result["status"], 200)
        self.assertIsNone(payload)
        self.assertEqual(opener.open.call_args.args[0].get_method(), "HEAD")

    def test_json_body_limit(self):
        response = MagicMock(code=200)
        response.__enter__.return_value = response
        response.read.return_value = b"x" * (audit.MAX_JSON + 1)
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(audit, "build_opener", return_value=opener):
            result, payload = audit.fetch(MEDIA_URL, 1)
        self.assertEqual(result["error"], "body_limit")
        self.assertIsNone(payload)

    def test_transport_failure_is_redacted(self):
        opener = MagicMock()
        opener.open.side_effect = URLError("secret-path?token=fixture")
        with patch.object(audit, "build_opener", return_value=opener):
            result, _ = audit.fetch(MEDIA_URL, 1)
        self.assertIsNone(result["status"])
        self.assertNotIn("secret-path", json.dumps(result))

    def test_redirect_is_not_followed(self):
        self.assertIsNone(audit.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://example.com/"))

    def test_private_200_reports_finding_and_nonzero_exit(self):
        def fake_fetch(url, timeout, method="GET", headers=None):
            if "/public-experience" in url:
                return {"status": 200, "cache_control": "no-store"}, public_payload()
            if method == "HEAD":
                return {"status": 200, "content_type": "image/jpeg"}, None
            return {"status": 404 if "/wp/v2/" in url else 401,
                    "cache_control": "private, no-store", "code": "fixture_denied"}, {"code": "fixture_denied"}
        output = io.StringIO()
        with patch.object(audit, "fetch", side_effect=fake_fetch), patch("sys.argv", ["audit", "--protected-media-url", MEDIA_URL]), contextlib.redirect_stdout(output):
            exit_code = audit.main()
        self.assertEqual(exit_code, 2)
        report = json.loads(output.getvalue())
        self.assertEqual(report["checks"][-1]["result"], "finding")
        self.assertNotIn(MEDIA_URL, output.getvalue())


if __name__ == "__main__":
    unittest.main()
