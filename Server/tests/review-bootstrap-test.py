#!/usr/bin/env python3
"""Local filesystem/command-boundary checks; not a live deployment substitute."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import subprocess

SERVER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('review_bootstrap', SERVER / 'operations/provision-review-bootstrap.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class ReviewBootstrapTests(unittest.TestCase):
    def test_release_manifest_matches_repository_release(self):
        release = (SERVER / 'releases/v1.4.0-build4-review-env-preview17.md').read_text()
        self.assertIn(bootstrap.manifest(SERVER), release)

    def test_source_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'alias').symlink_to(SERVER / 'composer.json')
            with self.assertRaises(ValueError):
                bootstrap.regular_tree(root)

    def test_missing_source_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                bootstrap.manifest(Path(folder))

    def test_existing_resource_never_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'existing'
            path.write_text('preserve')
            with self.assertRaises(ValueError):
                bootstrap.absent(path)
            with self.assertRaises(FileExistsError):
                bootstrap.write_new(path, 'replacement')
            self.assertEqual(path.read_text(), 'preserve')

    def test_official_empty_content_stubs_accepted_but_not_site_files(self):
        with tempfile.TemporaryDirectory() as folder:
            core = Path(folder)
            for name in ('index.php', 'plugins/index.php', 'themes/index.php'):
                path = core / 'wp-content' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('<?php\n// Silence is golden.\n')
            bootstrap.clean_core(core)
            unexpected = core / 'wp-content/plugins/real-site.php'
            unexpected.write_text('<?php /* must not copy */')
            with self.assertRaises(ValueError):
                bootstrap.clean_core(core)

    def test_existing_wordpress_credentials_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            core = Path(folder)
            (core / 'wp-config.php').write_text('<?php /* no actual secret */')
            with self.assertRaises(ValueError):
                bootstrap.clean_core(core)

    def test_dangling_target_also_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'alias'
            path.symlink_to(Path(folder) / 'missing')
            with self.assertRaises(ValueError):
                bootstrap.absent(path)

    def test_command_errors_do_not_echo_secret_input_or_output(self):
        sensitive = 'generated-at-runtime-' + __import__('secrets').token_hex(8)
        failed = subprocess.CompletedProcess(['/usr/bin/mysql'], 1, sensitive, sensitive)
        with patch.object(bootstrap.subprocess, 'run', return_value=failed):
            with self.assertRaises(RuntimeError) as raised:
                bootstrap.command(['/usr/bin/mysql'], data=sensitive)
        self.assertNotIn(sensitive, str(raised.exception))

    def test_no_inherited_provider_environment(self):
        with patch.object(bootstrap.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            bootstrap.command(['/usr/bin/true'])
        env = run.call_args.kwargs['env']
        self.assertEqual(env['WP_CLI_CONFIG_PATH'], '/dev/null')
        self.assertFalse(any(key.startswith('YISHU_') for key in env))

    def test_command_configuration_home_is_private_unique_and_always_cleaned(self):
        directories = []
        for outcome in ('success', 'failure', 'timeout'):
            with self.subTest(outcome=outcome):
                def invoke(args, **kwargs):
                    directory = Path(kwargs['env']['HOME'])
                    directories.append(directory)
                    self.assertTrue(directory.is_dir())
                    self.assertFalse(directory.is_symlink())
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                    (directory / 'fixture-config').write_text('isolated')
                    if outcome == 'timeout':
                        raise subprocess.TimeoutExpired(args, kwargs['timeout'])
                    return subprocess.CompletedProcess(args, int(outcome == 'failure'), '', '')

                with patch.object(bootstrap.subprocess, 'run', side_effect=invoke):
                    if outcome == 'success':
                        bootstrap.command(['/usr/bin/true'])
                    else:
                        error = subprocess.TimeoutExpired if outcome == 'timeout' else RuntimeError
                        with self.assertRaises(error):
                            bootstrap.command(['/usr/bin/true'])
                self.assertFalse(directories[-1].exists())
        self.assertEqual(len(set(directories)), 3)

    def test_private_listener_and_source_denial(self):
        config = (SERVER / 'operations/review/nginx.conf').read_text()
        self.assertIn('listen 127.0.0.1:18089 default_server;', config)
        self.assertEqual(config.count('listen '), 1)
        self.assertIn('if ($host != review.shuzijun.com.cn) { return 444; }', config)
        self.assertIn('location / { return 404; }', config)
        self.assertIn('location = /index.php {\n            internal;', config)
        self.assertIn('HTTP_AUTHORIZATION $http_authorization', config)
        self.assertNotIn('/var/www/html', config)

    def test_php_process_has_no_external_network_or_production_files(self):
        config = (SERVER / 'operations/review/shuzijun-review-php.service').read_text()
        for required in ('User=shuzijun-review', 'PrivateNetwork=true',
                         'RestrictAddressFamilies=AF_UNIX', 'ProtectSystem=strict',
                         'InaccessiblePaths=/var/www/html /etc/shuzijun/push'):
            self.assertIn(required, config)
        self.assertNotIn('EnvironmentFile=', config)
        self.assertNotIn('[Install]', config)
        self.assertIn('ExecStartPre=/usr/sbin/php-fpm8.3 -t', config)
        fpm = (SERVER / 'operations/review/php-fpm.conf').read_text()
        self.assertNotIn('/proc/self/fd/2', fpm)
        self.assertIn('error_log = /run/shuzijun-review-php/fpm-error.log', fpm)

    def test_readiness_requires_actual_php_route_not_only_nginx_health(self):
        connection = MagicMock()
        response = connection.getresponse.return_value
        response.status = 400
        response.read.return_value = b'{"code":"fan_install_id_invalid"}'
        with patch.object(bootstrap.http.client, 'HTTPConnection', return_value=connection):
            bootstrap.wait_for_php()
        self.assertEqual(connection.request.call_args.args[:2], ('POST', '/wp-json/shuzijun/v1/fan/login'))
        connection.close.assert_called_once()

    def test_bad_gateway_never_counts_as_bootstrap_success(self):
        connection = MagicMock()
        response = connection.getresponse.return_value
        response.status = 502
        response.read.return_value = b'<html>Bad gateway</html>'
        with patch.object(bootstrap.http.client, 'HTTPConnection', return_value=connection), \
                patch.object(bootstrap.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                bootstrap.wait_for_php()
        self.assertEqual(connection.close.call_count, 20)

    def test_bootstrap_does_not_touch_production_daemons_or_copy_database(self):
        source = (SERVER / 'operations/provision-review-bootstrap.py').read_text()
        self.assertNotIn('mysqldump', source)
        self.assertNotIn("'restart'", source)
        self.assertNotIn("'reload'", source)
        self.assertIn("GRANT ALL PRIVILEGES ON `shuzijun_review`.*", source)
        self.assertNotIn('GRANT ALL PRIVILEGES ON *.*', source)
        self.assertIn("'--skip-email'", source)
        self.assertIn("--prompt=admin_password", source)
        self.assertNotIn('--admin_password=', source)

    def test_https_edge_preserves_auth_and_overwrites_forwarded_identity(self):
        config = (SERVER / 'operations/review/edge-https.conf').read_text()
        for required in ('proxy_pass http://127.0.0.1:18089;',
                         'proxy_set_header Authorization $http_authorization;',
                         'proxy_set_header X-Yishu-Install-ID $http_x_yishu_install_id;',
                         'proxy_set_header X-Yishu-Client-IP $remote_addr;',
                         'return 308 https://review.shuzijun.com.cn$request_uri;',
                         'proxy_cache off;', 'proxy_intercept_errors off;'):
            self.assertIn(required, config)
        self.assertNotIn('proxy_set_header X-Yishu-Client-IP $http_', config)
        self.assertNotIn('/var/www/html/', config)
        self.assertIn('/live/review.shuzijun.com.cn/fullchain.pem', config)

    def test_client_limits_apply_at_final_fastcgi_location(self):
        config = (SERVER / 'operations/review/nginx.conf').read_text()
        self.assertIn('set_real_ip_from 127.0.0.1;', config)
        self.assertIn('real_ip_header X-Yishu-Client-IP;', config)
        final = config.split('location = /index.php {', 1)[1].split('}', 1)[0]
        self.assertIn('limit_req zone=review_api burst=20 nodelay;', final)
        self.assertIn('limit_req_status 429;', final)

    def test_challenge_phase_cannot_proxy_application(self):
        config = (SERVER / 'operations/review/edge-challenge.conf').read_text()
        self.assertNotIn('proxy_pass', config)
        self.assertIn('location / { return 503; }', config)
        self.assertIn('/.well-known/acme-challenge/', config)

    def test_deployer_targets_only_review_and_checks_exact_predecessor(self):
        source = (SERVER / 'operations/review/deploy-edge.sh').read_text()
        self.assertIn('target=/etc/nginx/sites-available/shuzijun-review.conf', source)
        self.assertIn('enabled=/etc/nginx/sites-enabled/shuzijun-review.conf', source)
        self.assertIn('cmp --silent "$target" "$assets/edge-challenge.conf"', source)
        self.assertIn('flock -w 30 -x 9', source)
        self.assertIn('trap restore EXIT', source)
        self.assertNotIn('restart nginx', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
