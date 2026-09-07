#!/usr/bin/env python3
"""Repair only the empty permalink setting of the existing isolated review site.

Default is read-only. Keep a private metadata receipt; never change media,
accounts, public routes, credentials, production options or service state.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit
import uuid

spec = importlib.util.spec_from_file_location('review_acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
b = a.bootstrap
TARGET = '/%postname%/'


def snapshot():
    result = json.loads(a.wp_eval("if (DB_NAME !== 'shuzijun_review') { exit(79); } "
        "if (!defined('REST_REQUEST')) { define('REST_REQUEST', true); } "
        "$r = new ReflectionMethod('Shuzijun_App_Content_API', 'manifest'); "
        "echo json_encode(array('structure' => get_option('permalink_structure'), "
        "'public' => get_post_type_object('portfolio')->publicly_queryable, 'content' => $r->invoke(null, 'admin')));"))
    paths = []
    for album in result['content']['portfolios']:
        paths.append(album.pop('websiteURL'))
    return {'structure': result['structure'], 'public': result['public'], 'urls': paths,
            'contentDigest': hashlib.sha256(json.dumps(result['content'], sort_keys=True).encode()).hexdigest()}


def valid_links(state):
    if not state['urls'] or state['public'] is not False:
        return False
    for value in state['urls']:
        url = urlsplit(value)
        if (url.scheme != 'https' or url.netloc != 'review.shuzijun.com.cn'
                or not url.path.startswith('/portfolio/') or url.query or url.fragment):
            return False
    return True


def repair(before):
    if before['structure'] != '' or before['public'] is not False:
        raise RuntimeError('Unexpected initial configuration; refuse to overwrite')
    receipt = b.CONFIG / ('permalink-repair-' + uuid.uuid4().hex + '.json')
    b.write_new(receipt, json.dumps({'state': 'prepared', 'before': before}), 0o600)
    mutation_attempted = False
    try:
        if snapshot() != before:
            raise RuntimeError('Review configuration changed after preflight')
        mutation_attempted = True
        b.configure_permalink_structure()
        after = snapshot()  # Fresh WordPress request reconstructs its permastruct.
        if (after['structure'] != TARGET or not valid_links(after)
                or after['contentDigest'] != before['contentDigest']):
            raise RuntimeError('Native permalink or unchanged-content verification failed')
        b.write_new(receipt.with_suffix('.completed.json'), json.dumps({'state': 'verified', 'after': after}), 0o600)
        print('review-permalinks: verified; catalog and public denial unchanged; receipt=' + str(receipt))
    except Exception:
        if not mutation_attempted:
            raise
        current = snapshot()
        if (current['structure'] not in ('', TARGET) or current['public'] != before['public']
                or current['contentDigest'] != before['contentDigest']):
            raise RuntimeError('Foreign change requires manual recovery') from None
        a.wp_eval("if (get_option('permalink_structure') !== '' && get_option('permalink_structure') !== '/%postname%/') { exit(80); } "
                  "update_option('permalink_structure', ''); echo 'restored';")
        if snapshot() != before:
            raise RuntimeError('Original permalink state not restored') from None
        b.write_new(receipt.with_suffix('.rollback.json'), json.dumps({'state': 'restored'}), 0o600)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0 or b.CONFIG.resolve() != b.CONFIG:
        raise RuntimeError('Root and canonical private configuration directory required')
    info = b.CONFIG.stat()
    if info.st_uid != 0 or not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o022:
        raise RuntimeError('Unprotected configuration directory')
    if args.apply:
        descriptor = os.open(b.CONFIG / 'permalink-maintenance.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            repair(snapshot())
    else:
        state = snapshot()
        print(json.dumps({'emptyStructure': state['structure'] == '', 'validNativeLinks': valid_links(state),
                          'albumCount': len(state['urls']), 'publiclyQueryable': state['public']}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('review-permalinks: failed: ' + type(error).__name__ + '; inspect private receipt')
        raise SystemExit(1) from None
