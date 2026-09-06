#!/usr/bin/env python3
"""Exercise one synthetic review user via real loopback HTTP, then delete it.

Never accepts a remote URL / production path. Requires explicit --apply because
it creates and deletes a disposable user and a temporary app password.
"""
import argparse
import base64
import http.client
import importlib.util
import json
import os
from pathlib import Path
import secrets
import time
import uuid

spec = importlib.util.spec_from_file_location('bootstrap', Path(__file__).with_name('provision-review-bootstrap.py'))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
checks = []


def check(condition, label):
    if not condition:
        raise RuntimeError(label)
    checks.append(label)


def wp_eval(code):
    guard = "if (ABSPATH !== '/srv/shuzijun-review/site/' || YISHU_APP_SERVICE_ENVIRONMENT !== 'review' || home_url() !== 'https://review.shuzijun.com.cn') { exit(79); } "
    return bootstrap.command(['/usr/sbin/runuser', '-u', bootstrap.USER, '--', '/usr/bin/wp',
                              'eval', guard + code, f'--path={bootstrap.SITE}', '--skip-packages'])


def request(path, method='GET', body=None, auth=None, install=None):
    connection = http.client.HTTPConnection('127.0.0.1', 18089, timeout=15)
    headers = {'Host': 'review.shuzijun.com.cn', 'Content-Type': 'application/json'}
    if auth:
        headers['Authorization'] = auth
    if install:
        headers['X-Yishu-Install-ID'] = install
    try:
        connection.request(method, '/wp-json/shuzijun/v1/' + path,
                           json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        data = response.read(2 * 1024 * 1024)
        result = json.loads(data)
        return response.status, result
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', required=True)
    parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('Root is needed for local acceptance credential custody')
    state = json.loads((bootstrap.CONFIG / 'bootstrap-state.json').read_text())
    check(state['publicReady'] is False, 'private bootstrap state')
    bootstrap.wait_for_php()
    # No database names, identity codes, passwords or tokens are echoed.
    databases = json.loads(wp_eval("global $wpdb; echo json_encode($wpdb->get_col('SHOW DATABASES'));"))
    check(set(databases) <= {'information_schema', 'performance_schema', 'shuzijun_review'}, 'database identity cannot enumerate production databases')
    check('shuzijun_review' in databases, 'review database is accessible')
    grants = json.loads(wp_eval("global $wpdb; echo json_encode($wpdb->get_col('SHOW GRANTS'));"))
    check(len(grants) == 2 and sum(line.startswith('GRANT USAGE ON *.* TO ') for line in grants) == 1
          and sum(line.startswith('GRANT ALL PRIVILEGES ON `shuzijun_review`.* TO ') for line in grants) == 1
          and all('WITH GRANT OPTION' not in line for line in grants), 'database grants limited to review schema without delegation')
    behavior = json.loads(wp_eval("echo json_encode(array('authority' => Shuzijun_App_Content_API::account_authority_enabled(), 'mail' => wp_mail('review-test@example.invalid', 'Synthetic check', 'No personal data'), 'httpDenied' => is_wp_error(wp_remote_get('https://www.shuzijun.com.cn/'))));"))
    check(behavior == {'authority': True, 'mail': False, 'httpDenied': True}, 'authority valid and external mail/HTTP blocked')
    initial = int(wp_eval("global $wpdb; echo $wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->users}\");"))
    # Bootstrap owner is not a delivered review account. Revoke this temporary
    # app password in finally, including if any real HTTP assertion fails.
    owner = json.loads(wp_eval("$u = get_user_by('login', 'review_bootstrap'); if (!$u) { exit(80); } $p = WP_Application_Passwords::create_new_application_password($u->ID, array('name' => 'Private review acceptance')); if (is_wp_error($p)) { exit(81); } echo json_encode(array('userID' => $u->ID, 'password' => $p[0], 'uuid' => $p[1]['uuid']));"))
    basic = 'Basic ' + base64.b64encode(('review_bootstrap:' + owner['password']).encode()).decode()
    installation = str(uuid.uuid4())
    password = secrets.token_urlsafe(32) + '9aA'
    token = None
    private_path = bootstrap.CONFIG / ('acceptance-private-' + uuid.uuid4().hex + '.json')
    record = {'applicationPasswordUUID': owner['uuid'], 'ownerID': owner['userID'],
              'installID': installation, 'password': password}
    bootstrap.write_new(private_path, json.dumps(record), 0o600)
    deleted = False
    try:
        status, _ = request('app-admin/fans')
        check(status in (401, 403), 'anonymous administration denied')
        registration = {'displayName': 'Disposable review acceptance', 'douyinID': '',
                        'password': password, 'installID': installation,
                        'consentVersion': '2026-09-04-approval-v4'}
        status, data = request('fan/register', 'POST', registration, install=installation)
        check(status == 400 and data.get('code') == 'fan_douyin_id_invalid', 'Douyin ID remains mandatory')
        registration['douyinID'] = 'review.synthetic.' + uuid.uuid4().hex[:12]
        status, data = request('fan/register', 'POST', registration, install=installation)
        check(status == 201, 'real registration succeeds')
        token = 'Bearer ' + data['token']
        profile = data['profile']
        fan_id = profile['userID']
        # This private recovery file never enters Git or a tool transcript.
        with private_path.open('w') as handle:
            json.dump({**record, 'token': token, 'userID': fan_id,
                       'identityCode': profile['identityCode']}, handle)
        check(profile['status'] == 'pending' and not profile['administratorBound'], 'registration does not auto-approve or grant administrator')
        status, _ = request('app-content', auth=token, install=installation)
        check(status == 403, 'pending user cannot open App content')
        status, _ = request('app-admin/fans/' + fan_id, 'POST', {'status': 'active'}, auth=token, install=installation)
        check(status in (401, 403), 'user cannot approve themselves')
        status, data = request('app-admin/fans/' + fan_id, 'POST', {'status': 'active'}, auth=basic)
        check(status == 200, 'authorized administrator can approve')
        status, data = request('app-content', auth=token, install=installation)
        check(status == 200, 'approved user can open App content')
        check(data['heroImages'] == [] and data['portfolios'] == [] and data['aboutPortraitURL'] is None,
              'empty review does not import production photos')
        status, _ = request('app-admin/session', auth=token, install=installation)
        check(status in (401, 403), 'approved ordinary user still cannot administer')
        binding = {'administrator': True, 'expectedAdministrator': False, 'expectedRevision': 0}
        status, data = request('app-admin/fans/' + fan_id + '/administrator', 'POST', binding, auth=basic)
        check(status == 200 and data['user']['administratorBound'], 'administrator binding grants the App role')
        revision = data['user']['administratorRevision']
        status, _ = request('app-admin/session', auth=token, install=installation)
        check(status == 200, 'bound user can access management with own session')
        status, _ = request('app-admin/fans/' + fan_id + '/administrator', 'POST', binding, auth=basic)
        check(status == 409, 'stale binding revision rejected')
        status, data = request('app-admin/fans/' + fan_id + '/administrator', 'POST',
                               {'administrator': False, 'expectedAdministrator': True, 'expectedRevision': revision}, auth=basic)
        check(status == 200 and not data['user']['administratorBound'], 'administrator binding revoked')
        status, _ = request('app-admin/session', auth=token, install=installation)
        check(status in (401, 403), 'old user session loses management immediately')
    finally:
        try:
            if token:
                status, _ = request('fan/delete', 'POST', {'installID': installation,
                                    'currentPassword': password, 'confirmation': 'DELETE_ACCOUNT'}, auth=token, install=installation)
                deleted = status == 200
        finally:
            wp_eval(f"if (!WP_Application_Passwords::delete_application_password({int(owner['userID'])}, '{owner['uuid']}')) {{ exit(82); }}")
        if deleted:
            private_path.unlink()
    check(deleted, 'disposable user deleted through user-facing API')
    status, _ = request('fan/session', auth=token, install=installation)
    check(status in (401, 403), 'deleted user token no longer works')
    final_count = int(wp_eval("global $wpdb; echo $wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->users}\");"))
    check(initial == final_count, 'no disposable user left in database')
    report = {'passed': len(checks), 'checks': checks, 'timestamp': int(time.time()),
              'publicReady': False, 'test2Created': False, 'manifest': state['manifest']}
    bootstrap.write_new(bootstrap.CONFIG / ('acceptance-' + uuid.uuid4().hex + '.json'),
                        json.dumps(report, indent=2) + '\n', 0o644)
    print(f'review-bootstrap-acceptance: {len(checks)} real checks passed; disposable account and credential removed')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Do not print transport responses, account identifiers or credentials.
        print('review-bootstrap-acceptance: failed: ' + type(error).__name__
              + (': ' + str(error) if isinstance(error, RuntimeError) else ''))
        raise SystemExit(1)
