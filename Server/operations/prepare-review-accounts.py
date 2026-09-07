#!/usr/bin/env python3
"""Prepare Test1/Test2 display names with normal HS logins in review only.

Default is read-only. --apply retains private recovery state on interruption;
an existing record is never overwritten or silently replayed. No ASC delivery.
"""
import argparse
import base64
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import stat
import time
import uuid

spec = importlib.util.spec_from_file_location('review_acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
a.HTTPS_EDGE = True
b = a.bootstrap
PRIVATE = b.CONFIG / 'review-accounts-private.json'
LABELS = ('Test1（审核测试）', 'Test2（审核测试）')


def check(condition, label):
    if not condition:
        raise RuntimeError(label)


def validate_registration(profile, account):
    check(profile.get('displayName') == account['displayName']
          and profile.get('douyinID') == account['douyinID'], 'registration identity mismatch')
    identifier = uuid.UUID(profile['userID'])
    check(identifier.version == 4 and str(identifier) == profile['userID'], 'invalid registered user identifier')
    check(re.fullmatch(r'HS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}',
                      profile['identityCode']) is not None, 'invalid registered HS code')
    check(profile['status'] == 'pending' and profile['administratorBound'] is False,
          'registration unexpectedly bypassed approval')


def save(record):
    metadata = PRIVATE.lstat()
    check(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == 0
          and stat.S_IMODE(metadata.st_mode) == 0o600, 'private record ownership changed')
    temporary = b.CONFIG / ('accounts-update-' + uuid.uuid4().hex + '.json')
    b.write_new(temporary, json.dumps(record, ensure_ascii=False), 0o600)
    os.replace(temporary, PRIVATE)


def user_count():
    return int(a.wp_eval('global $wpdb; echo $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->users}");'))


def preflight():
    check(os.geteuid() == 0, 'root required for private credential custody')
    check(b.CONFIG.resolve() == b.CONFIG and b.CONFIG.is_dir(), 'configuration path is not canonical')
    metadata = b.CONFIG.stat()
    check(metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) & 0o022 == 0,
          'configuration directory is not protected')
    b.absent(PRIVATE)
    count = int(a.wp_eval("global $wpdb; echo $wpdb->get_var($wpdb->prepare(\"SELECT COUNT(*) FROM {$wpdb->users} WHERE display_name IN (%s, %s, %s, %s)\", 'Test1', 'Test2', 'Test1（审核测试）', 'Test2（审核测试）'));"))
    check(count == 0, 'review account names already exist; inspect without resetting passwords')
    status, _ = a.request('app-admin/session')
    check(status in (401, 403), 'anonymous review management is not rejected')
    return user_count()


def prepare(initial):
    record = {'environment': 'review', 'accountsPrepared': False, 'deliveredToApple': False,
              'createdAt': int(time.time()), 'accounts': []}
    for index, label in enumerate(LABELS):
        record['accounts'].append({'displayName': label, 'administrator': index == 1,
            'password': secrets.token_urlsafe(32) + '9aA',
            'douyinID': 'review.synthetic.' + uuid.uuid4().hex[:16],
            'installID': str(uuid.uuid4())})
    b.write_new(PRIVATE, json.dumps(record, ensure_ascii=False), 0o600)
    owner = None
    try:
        owner = json.loads(a.wp_eval("$u = get_user_by('login', 'review_bootstrap'); if (!$u) { exit(80); } $p = WP_Application_Passwords::create_new_application_password($u->ID, array('name' => 'Review account preparation')); if (is_wp_error($p)) { exit(81); } echo json_encode(array('userID' => $u->ID, 'password' => $p[0], 'uuid' => $p[1]['uuid']));"))
        record['ownerID'] = owner['userID']
        record['temporaryManagementCredentialUUID'] = owner['uuid']
        save(record)
        basic = 'Basic ' + base64.b64encode(('review_bootstrap:' + owner['password']).encode()).decode()
        for account in record['accounts']:
            install = account['installID']
            status, registered = a.request('fan/register', 'POST', {
                'displayName': account['displayName'], 'douyinID': account['douyinID'],
                'password': account['password'], 'installID': install,
                'consentVersion': '2026-09-04-approval-v4'}, install=install)
            check(status == 201, 'review registration failed; private recovery record retained')
            profile = registered['profile']
            validate_registration(profile, account)
            account.update({'userID': profile['userID'], 'identityCode': profile['identityCode'],
                            'bootstrapSession': registered['token']})
            save(record)
            status, approved = a.request('app-admin/fans/' + account['userID'], 'POST',
                                         {'status': 'active'}, auth=basic)
            check(status == 200, 'review approval failed')
            if account['administrator']:
                user = approved['user']
                status, granted = a.request('app-admin/fans/' + account['userID'] + '/administrator',
                    'POST', {'administrator': True, 'expectedAdministrator': user['administratorBound'],
                             'expectedRevision': user['administratorRevision']}, auth=basic)
                check(status == 200 and granted['user']['administratorBound'] is True,
                      'review administrator binding failed')
            status, _ = a.request('fan/logout', 'POST', {'installID': install},
                                  auth='Bearer ' + account['bootstrapSession'], install=install)
            check(status == 200, 'registration session cleanup failed')
            account.pop('bootstrapSession')
            account['installID'] = install = str(uuid.uuid4())
            save(record)
            status, login = a.request('fan/login', 'POST', {'identityCode': account['identityCode'],
                'password': account['password'], 'installID': install}, install=install)
            check(status == 200, 'normal HS/password login failed')
            account['bootstrapSession'] = login['token']
            save(record)
            token = 'Bearer ' + login['token']
            check(login['profile']['administratorBound'] is account['administrator'], 'login role mismatch')
            status, content = a.request('app-content', auth=token, install=install)
            check(status == 200 and len(content['portfolios']) >= 2, 'review gallery access failed')
            a.catalog_snapshot(content)
            status, session = a.request('app-admin/session', auth=token, install=install)
            if account['administrator']:
                check(status == 200 and session.get('canManageFanAdministrators') is True,
                      'bound review administrator lacks management capability')
            else:
                check(status in (401, 403), 'ordinary review account can administer')
            status, _ = a.request('fan/logout', 'POST', {'installID': install}, auth=token, install=install)
            check(status == 200, 'verification session cleanup failed')
            account.pop('bootstrapSession')
            account['verified'] = True
            save(record)
        check(user_count() == initial + 2, 'unexpected review user count change')
    finally:
        if owner is not None:
            a.wp_eval(f"if (!WP_Application_Passwords::delete_application_password({int(owner['userID'])}, '{owner['uuid']}')) {{ exit(82); }} echo 'true';")
            record.pop('temporaryManagementCredentialUUID', None)
            record.pop('ownerID', None)
            save(record)
    record['accountsPrepared'] = True
    save(record)
    print('review-accounts: 2 HS logins verified; ordinary/admin separation verified; credentials remain private; not delivered to Apple')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not args.apply:
        preflight()
        print('review-accounts: read-only preflight passed; no accounts created')
        return
    check(os.geteuid() == 0, 'root required')
    descriptor = os.open(b.CONFIG / 'review-accounts.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        prepare(preflight())


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('review-accounts: failed: ' + type(error).__name__)
        raise SystemExit(1) from None
