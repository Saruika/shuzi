import importlib.util
import json
import re
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).resolve().parents[2] / 'Scripts/check-drama-links.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class DramaLinkMonitorTests(unittest.TestCase):
    def test_server_and_app_defaults_stay_in_sync(self):
        root = Path(__file__).resolve().parents[2]
        php = (root / 'Server/vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php').read_text()
        swift = (root / 'Yishu/Models/Portfolio.swift').read_text()
        backend = re.search(r"\$hongguo = '([^']+)'", php)[1]
        client = re.search(r'static let hongguoURL = AppURL.make\("([^"]+)"\)', swift)[1]
        self.assertEqual(backend, client)
        self.assertNotIn('wHlfrwqog1g', backend)
        self.assertTrue(monitor.trusted(backend))

    def test_soft_and_hard_404(self):
        self.assertEqual(monitor.evaluate(200, b'{"message":"404 not found"}'), 'expired')
        self.assertEqual(monitor.evaluate(404, b''), 'expired')
        self.assertEqual(monitor.evaluate(410, b''), 'expired')

    def test_challenges_and_network_errors_are_not_expired(self):
        for status, body in [(200, b'<html>verify</html>'), (429, b''), (503, b''), (200, b'x' * 524289)]:
            self.assertEqual(monitor.evaluate(status, body), 'unverified')

    def test_actor_and_expected_works(self):
        data = {'loaderData': {'page': {'pageData': {'BaseResp': {'StatusCode': 0},
                'actor_data': {'actor_name': '易姝', 'works': [{'series_title': '京春夜'}]}}}}}
        body = ('<script>window._ROUTER_DATA = ' + json.dumps(data) + '</script>').encode()
        self.assertEqual(monitor.evaluate(200, body, ['京春夜']), 'available')
        self.assertEqual(monitor.evaluate(200, body, ['往生酒店']), 'content-mismatch')
        modern = ('<script>_ROUTER_DATA=' + json.dumps(data)
                  + ';window.someOtherData = {};</script>').encode()
        self.assertEqual(monitor.evaluate(200, modern, ['京春夜']), 'available')
        self.assertEqual(monitor.evaluate(200, modern, ['往生酒店']), 'content-mismatch')

    def test_host_and_redirect_boundary(self):
        self.assertTrue(monitor.trusted('https://novelquickapp.com/s/example/'))
        for url in ['https://novelquickapp.com.evil.test/', 'https://127.0.0.1/',
                    'https://novelquickapp.com:444/', 'https://user@novelquickapp.com/', 'file:///tmp/a']:
            self.assertFalse(monitor.trusted(url))
            with self.assertRaises(ValueError):
                monitor.Redirects().redirect_request(None, None, 302, '', {}, url)


if __name__ == '__main__':
    unittest.main()
