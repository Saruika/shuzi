#!/usr/bin/env python3
"""One-time, private review bootstrap. No production data/config/DNS mutation.

Default is a read-only preflight. An interrupted apply is deliberately not
replayed: retained resources must first be inspected. Secrets stay on the host.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import socket
import stat
import subprocess
import time

ROOT = Path('/srv/shuzijun-review')
CONFIG = Path('/etc/shuzijun-review')
SITE = ROOT / 'site'
USER = 'shuzijun-review'
DATABASE = 'shuzijun_review'
WP_VERSION = '7.1'
UNITS = ('shuzijun-review-php.service', 'shuzijun-review-web.service')
ASSETS = ('php-fpm.conf', 'nginx.conf', '000-review-bootstrap.php', *UNITS)


def command(args, *, data=None, timeout=90):
    result = subprocess.run(args, input=data, text=True, capture_output=True,
                            timeout=timeout, check=False,
                            env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin',
                                 'HOME': '/tmp', 'LANG': 'C.UTF-8',
                                 'WP_CLI_CONFIG_PATH': '/dev/null'})
    if result.returncode:
        # SQL / install commands may contain secrets on stdin. Never relay
        # their stdout/stderr or arguments into an operator / CI transcript.
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}); inspect locally')
    return result.stdout


def regular_tree(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Source must be a real directory')
    files = []
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('Source contains a link or special file')
        if stat.S_ISREG(mode):
            files.append(path)
    return files


def plugin_files(source):
    files = [source / name for name in ('shuzijun-app-content.php', 'composer.json', 'composer.lock')]
    files += regular_tree(source / 'vendor')
    for path in files:
        if path.is_symlink() or not path.is_file():
            raise ValueError('Plugin source incomplete')
    return sorted(files, key=lambda path: path.relative_to(source).as_posix())


def manifest(source):
    lines = ''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  '
                    + path.relative_to(source).as_posix() + '\n' for path in plugin_files(source))
    return hashlib.sha256(lines.encode('ascii')).hexdigest()


def absent(path):
    if path.exists() or path.is_symlink():
        raise ValueError(f'Existing target: {path}; inspect, do not overwrite')


def clean_core(core):
    files = regular_tree(core)
    if not files or any(path.name == 'wp-config.php' for path in files):
        raise ValueError('Core must not contain site configuration')
    # Official --skip-content still includes these three inert index stubs.
    content = core / 'wp-content'
    if content.exists():
        for path in content.rglob('*'):
            relative = path.relative_to(content).as_posix()
            if path.is_dir() and relative in ('plugins', 'themes'):
                continue
            if (relative in ('index.php', 'plugins/index.php', 'themes/index.php')
                    and path.is_file() and path.read_bytes().strip() == b'<?php\n// Silence is golden.'):
                continue
            raise ValueError('Core contains site content, not only official empty stubs')


def write_new(path, value, mode=0o640, gid=0):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
        handle.write(value)
        handle.flush()
        os.fchmod(handle.fileno(), mode)
        os.fchown(handle.fileno(), 0, gid)
        os.fsync(handle.fileno())


def wait_for_php():
    for _ in range(20):
        connection = http.client.HTTPConnection('127.0.0.1', 18089, timeout=2)
        try:
            connection.request('POST', '/wp-json/shuzijun/v1/fan/login', '{}', {
                'Host': 'review.shuzijun.com.cn', 'Content-Type': 'application/json',
            })
            response = connection.getresponse()
            body = response.read(8192)
            if response.status == 400 and json.loads(body).get('code') == 'fan_install_id_invalid':
                return
        except (OSError, http.client.HTTPException, ValueError):
            pass
        finally:
            connection.close()
        time.sleep(0.5)
    raise RuntimeError('Private PHP API did not become ready; no acceptance claimed')


def preflight(source, core, expected):
    if os.geteuid() != 0:
        raise ValueError('Run on the authorized primary host as root')
    if not re.fullmatch('[0-9a-f]{64}', expected) or manifest(source) != expected:
        raise ValueError('Plugin manifest does not match the reviewed Git release')
    for path in (ROOT, CONFIG, *(Path('/etc/systemd/system') / name for name in UNITS)):
        absent(path)
    try:
        pwd.getpwnam(USER)
    except KeyError:
        pass
    else:
        raise ValueError('Review OS identity already exists')
    for name in ASSETS:
        path = source / 'operations/review' / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing review deployment asset')
    clean_core(core)
    command(['/usr/bin/wp', 'core', 'verify-checksums', '--allow-root', '--skip-packages',
             f'--path={core}', f'--version={WP_VERSION}', '--locale=en_US'], timeout=180)
    rows = command(['/usr/bin/mysql', '--batch', '--skip-column-names'], data=
                   "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='shuzijun_review';\n"
                   "SELECT user FROM mysql.user WHERE user='shuzijun_review';\n")
    if rows.strip():
        raise ValueError('Review database or database identity already exists')
    command(['/usr/local/sbin/verify-shuzijun-account-authority-role', 'authority'])
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 18089))
    for executable in ('/usr/sbin/php-fpm8.3', '/usr/sbin/nginx', '/usr/sbin/runuser'):
        if not os.access(executable, os.X_OK):
            raise ValueError('Required runtime unavailable')


def install(source, core, expected):
    command(['/usr/sbin/useradd', '--system', '--user-group', '--home-dir', str(ROOT),
             '--no-create-home', '--shell', '/usr/sbin/nologin', USER])
    identity = pwd.getpwnam(USER)
    for path in (ROOT, CONFIG):
        path.mkdir(mode=0o750)
        os.chown(path, 0, identity.pw_gid)
    shutil.copytree(core, SITE)
    # Verify the copied code too, before loading WordPress or creating a DB.
    command(['/usr/bin/wp', 'core', 'verify-checksums', '--allow-root', '--skip-packages',
             f'--path={SITE}', f'--version={WP_VERSION}', '--locale=en_US'], timeout=180)
    mu = SITE / 'wp-content/mu-plugins'
    mu.mkdir(parents=True)
    for path in plugin_files(source):
        destination = mu / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    if manifest(mu) != expected:
        raise ValueError('Copied plugin manifest mismatch')
    shutil.copyfile(source / 'operations/review/000-review-bootstrap.php', mu / '000-review-bootstrap.php')
    for path in [SITE, *SITE.rglob('*')]:
        os.chown(path, 0, identity.pw_gid)
        path.chmod(0o750 if path.is_dir() else 0o640)
    for path in (SITE / 'wp-content/uploads', ROOT / 'tmp'):
        path.mkdir(mode=0o700)
        os.chown(path, identity.pw_uid, identity.pw_gid)
    private = {'databasePassword': secrets.token_urlsafe(40),
               'bootstrapPassword': secrets.token_urlsafe(40),
               'bootstrapLogin': 'review_bootstrap', 'manifest': expected}
    write_new(CONFIG / 'bootstrap-private.json', json.dumps(private), 0o600)
    command(['/usr/bin/mysql', '--batch'], data=
            "CREATE DATABASE `shuzijun_review` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n"
            f"CREATE USER 'shuzijun_review'@'localhost' IDENTIFIED BY '{private['databasePassword']}';\n"
            "GRANT ALL PRIVILEGES ON `shuzijun_review`.* TO 'shuzijun_review'@'localhost';\n")
    settings = {
        'DB_NAME': DATABASE, 'DB_USER': DATABASE, 'DB_PASSWORD': private['databasePassword'],
        'DB_HOST': 'localhost:/var/run/mysqld/mysqld.sock', 'DB_CHARSET': 'utf8mb4', 'DB_COLLATE': '',
        'WP_HOME': 'https://review.shuzijun.com.cn', 'WP_SITEURL': 'https://review.shuzijun.com.cn',
        'YISHU_APP_SERVICE_ENVIRONMENT': 'review',
    }
    for key in ('AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
                'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'):
        settings[key] = secrets.token_urlsafe(48)
    # Generated values are constrained constants or URL-safe random strings.
    config = '<?php\n' + ''.join(f"define('{key}', '{value}');\n" for key, value in settings.items())
    config += "define('DISABLE_WP_CRON', true);\ndefine('DISALLOW_FILE_MODS', true);\n"
    config += "define('WP_HTTP_BLOCK_EXTERNAL', true);\ndefine('WP_DEBUG', false);\n"
    config += "$table_prefix = 'review_';\nif (!defined('ABSPATH')) { define('ABSPATH', __DIR__ . '/'); }\nrequire_once ABSPATH . 'wp-settings.php';\n"
    write_new(SITE / 'wp-config.php', config, gid=identity.pw_gid)
    command(['/usr/sbin/runuser', '-u', USER, '--', '/usr/bin/wp', 'core', 'install',
             f'--path={SITE}', '--skip-packages', '--url=https://review.shuzijun.com.cn',
             '--title=Hi Shuzi — isolated review', '--admin_user=review_bootstrap',
             '--admin_email=review-bootstrap@example.invalid', '--skip-email',
             '--prompt=admin_password', '--quiet'], data=private['bootstrapPassword'] + '\n')
    for name in ('php-fpm.conf', 'nginx.conf'):
        write_new(CONFIG / name, (source / 'operations/review' / name).read_text(), gid=identity.pw_gid)
    for name in UNITS:
        write_new(Path('/etc/systemd/system') / name,
                  (source / 'operations/review' / name).read_text(), 0o644)
    # FPM config validation is ExecStartPre, after systemd creates the private
    # runtime/log directory, under the same identity and sandbox as execution.
    command(['/usr/bin/systemd-analyze', 'verify', *(str(Path('/etc/systemd/system') / name) for name in UNITS)])
    command(['/usr/bin/systemctl', 'daemon-reload'])
    # These units are not enabled at boot and are independent of production
    # nginx/php8.3-fpm. No production service restart/reload occurs here.
    command(['/usr/bin/systemctl', 'start', *UNITS])
    try:
        wait_for_php()
    except RuntimeError:
        command(['/usr/bin/systemctl', 'stop', *reversed(UNITS)])
        raise
    write_new(CONFIG / 'bootstrap-state.json', json.dumps({
        'state': 'private-bootstrap-started', 'manifest': expected,
        'wordpress': WP_VERSION, 'listener': '127.0.0.1:18089',
        'externalMail': False, 'externalPush': False, 'publicReady': False,
    }, indent=2) + '\n', 0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        preflight(args.source.resolve(), args.core.resolve(), args.manifest)
        if args.apply:
            install(args.source.resolve(), args.core.resolve(), args.manifest)
        print('review-bootstrap: ' + ('private instance started; acceptance pending' if args.apply else 'preflight passed; no changes'))
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f'review-bootstrap: {type(error).__name__}: {error}')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
