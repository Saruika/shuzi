#!/usr/bin/env python3
"""Seed only the empty review catalog through actual bound-admin HTTPS APIs.

Artist-approved source files are read on the server, never copied to this Mac
or the App bundle. No production database/content writes or user-data cloning.
"""
import argparse
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import time
from urllib.parse import urlsplit
import uuid

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
a.HTTPS_EDGE = True
b = a.bootstrap
SOURCE_ROOT = Path('/var/www/html/shuzijun.com.cn/wp-content/uploads')
CATALOG_PATH = Path(__file__).parent / 'review/media-catalog.json'
RECEIPT = b.CONFIG / 'catalog-seed-state.json'


def read_source(item):
    relative = item.get('source', '')
    if not re.fullmatch(r'2026/(08|09)/[a-z0-9-]+\.jpg', relative):
        raise ValueError('Source path is not a reviewed JPEG')
    path = SOURCE_ROOT / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(SOURCE_ROOT.resolve()):
        raise ValueError('Source path escapes approved upload directory')
    if not 100_000 <= path.stat().st_size <= 1_100_000:
        raise ValueError('Unexpected source size')
    data = path.read_bytes()
    if not data.startswith(b'\xff\xd8\xff') or hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('Source changed after visual selection')
    return data


def upload(data, name, token, installation):
    connection = a.LocalReviewTLS()
    try:
        connection.request('POST', '/wp-json/wp/v2/media', data, {
            'Host': 'review.shuzijun.com.cn', 'Content-Type': 'image/jpeg',
            'Content-Disposition': f'attachment; filename="{name}"',
            'Authorization': token, 'X-Yishu-Install-ID': installation,
        })
        response = connection.getresponse()
        return response.status, json.loads(response.read(2 * 1024 * 1024))
    finally:
        connection.close()


def verify_media_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or parsed.netloc != 'review.shuzijun.com.cn'
            or not parsed.path.startswith('/wp-content/uploads/') or parsed.query or parsed.fragment):
        raise ValueError('Published media escaped review origin')
    return parsed.path


def fetch_image(value):
    path = verify_media_url(value)
    connection = a.LocalReviewTLS()
    try:
        connection.request('GET', path)
        response = connection.getresponse()
        data = response.read(2 * 1024 * 1024)
        a.check(response.status == 200 and response.getheader('Content-Type') == 'image/jpeg'
                and data.startswith(b'\xff\xd8\xff'), 'published review JPEG actually loads over HTTPS')
        return len(data)
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Server root required for local source selection and credential custody')
    # Serialize only this isolated catalog operation, never production work.
    if args.apply:
        lock = os.open(b.CONFIG / 'catalog-seed.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    catalog = json.loads(CATALOG_PATH.read_text())
    b.absent(RECEIPT)
    images = {item['key']: read_source(item) for item in catalog['images']}
    a.check(len(images) == 8 and len(catalog['albums']) == 2, 'eight selected photos in two coherent groups')
    counts = json.loads(a.wp_eval("global $wpdb; echo json_encode(array('media' => (int)$wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type='attachment'\"), 'albums' => (int)$wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type='portfolio'\")));"))
    a.check(counts == {'media': 0, 'albums': 0}, 'only seed an empty review catalog')
    if not args.apply:
        print('review-catalog: preflight passed; source hashes verified, no changes')
        return
    owner = json.loads(a.wp_eval("$u=get_user_by('login','review_bootstrap'); $p=WP_Application_Passwords::create_new_application_password($u->ID,array('name'=>'One-time review catalog')); if(is_wp_error($p)){exit(81);} echo json_encode(array('userID'=>$u->ID,'password'=>$p[0],'uuid'=>$p[1]['uuid']));"))
    basic = 'Basic ' + base64.b64encode(('review_bootstrap:' + owner['password']).encode()).decode()
    run_id = uuid.uuid4().hex
    installation = str(uuid.uuid4())
    password = secrets.token_urlsafe(32) + '9aA'
    temporary = b.CONFIG / ('catalog-private-' + run_id + '.json')
    state = {'runID': run_id, 'installation': installation, 'password': password,
             'appPasswordUUID': owner['uuid'], 'ownerID': owner['userID'],
             'mediaIDs': [], 'albumIDs': [], 'committed': False}
    b.write_new(temporary, json.dumps(state), 0o600)
    token = None
    publisher_id = 0
    original = None
    deleted = False
    committed = False
    uploaded = {}
    albums = {}

    def save_state():
        with temporary.open('w') as handle:
            json.dump(state, handle)
            handle.flush()
            os.fsync(handle.fileno())

    try:
        status, original = a.request('app-content', auth=basic)
        a.check(status == 200 and original['heroImages'] == [] and original['launchPosters'] == []
                and original['aboutPortraitURL'] is None, 'review visual configuration is empty')
        status, auth = a.request('fan/register', 'POST', {
            'displayName': '临时媒体验收账号', 'douyinID': 'review.media.' + run_id[:12],
            'password': password, 'installID': installation, 'consentVersion': '2026-09-04-approval-v4',
        }, install=installation)
        a.check(status == 201 and auth['profile']['status'] == 'pending', 'publisher uses real pending registration')
        token = 'Bearer ' + auth['token']
        fan_id = auth['profile']['userID']
        state.update({'token': token, 'userID': fan_id})
        save_state()
        status, _ = a.request('app-admin/fans/' + fan_id, 'POST', {'status': 'active'}, auth=basic)
        a.check(status == 200, 'publisher approved through normal management API')
        status, bound = a.request('app-admin/fans/' + fan_id + '/administrator', 'POST', {
            'administrator': True, 'expectedAdministrator': False, 'expectedRevision': 0,
        }, auth=basic)
        a.check(status == 200 and bound['user']['administratorBound'], 'publisher receives only bound App administrator role')
        publisher_id = int(a.wp_eval("$u=get_users(array('meta_key'=>'_yishu_fan_uuid','meta_value'=>" + json.dumps(fan_id) + ", 'fields'=>'ids')); if(count($u)!==1){exit(82);} echo $u[0];"))
        state['publisherID'] = publisher_id
        save_state()
        for item in catalog['images']:
            status, data = upload(images[item['key']], 'review-' + run_id[:12] + '-' + item['key'] + '.jpg', token, installation)
            a.check(status == 201 and isinstance(data.get('id'), int), 'bound user uploads real JPEG through native media API')
            media_id = data['id']
            state['mediaIDs'].append(media_id)
            save_state()
            verify_media_url(data['source_url'])
            metadata = json.loads(a.wp_eval(f"$p=wp_get_original_image_path({media_id}); $s=getimagesize($p); echo json_encode(array('sha256'=>hash_file('sha256',$p),'width'=>$s[0],'height'=>$s[1],'author'=>(int)get_post_field('post_author',{media_id}),'inside'=>str_starts_with(realpath($p),'/srv/shuzijun-review/site/wp-content/uploads/')));"))
            a.check(metadata['sha256'] == item['sha256'] and metadata['inside']
                    and metadata['author'] == publisher_id, 'uploaded original is byte-identical and owned inside review storage')
            a.check(max(metadata['width'], metadata['height']) >= 2560, 'original high-resolution dimensions retained')
            served_bytes = fetch_image(data['source_url'])
            uploaded[item['key']] = {'id': media_id, 'url': data['source_url'], 'album': item['album'],
                                     'originalSHA256': item['sha256'], 'servedBytes': served_bytes}
        for album in catalog['albums']:
            status, created = a.request('app-content/portfolio', 'POST', {
                key: album[key] for key in ('title', 'subtitle', 'eyebrow')
            }, auth=token, install=installation)
            a.check(status == 201, 'bound administrator creates genre-specific album')
            album_id = int(created['portfolioID'])
            state['albumIDs'].append(album_id)
            save_state()
            ids = [entry['id'] for entry in uploaded.values() if entry['album'] == album['key']]
            status, result = a.request(f'app-content/portfolio/{album_id}/gallery', 'POST', {'mediaIDs': ids}, auth=token, install=installation)
            a.check(status == 200 and result['mediaIDs'] == ids, 'album contains exactly its own selected group')
            albums[album['key']] = {'id': album_id, 'mediaIDs': ids}
        configuration = {
            'heroImages': [entry['url'] for entry in uploaded.values() if entry['album'] == 'magnolia'],
            'aboutPortraitURL': uploaded['lantern-03']['url'],
            'launchPosters': [dict(id='review-' + key, isEnabled=True, imageURL=uploaded[key]['url'],
                                  eyebrow='东方美学', title='易姝', subtitle='审核演示 · 古风影像',
                                  startsAt='1970-01-01T00:00:00+00:00', endsAt='2100-01-01T00:00:00+00:00',
                                  displaySeconds=2.5) for key in ('lantern-01', 'lantern-02', 'lantern-03')],
        }
        status, published = a.request('app-content', 'POST', configuration, auth=token, install=installation)
        a.check(status == 200 and published['heroImages'] == configuration['heroImages']
                and published['aboutPortraitURL'] == configuration['aboutPortraitURL'], 'real image settings published and read back')
        a.check([p['subtitle'] for p in published['launchPosters']] == ['审核演示 · 古风影像'] * 3,
                'poster text matches stored management configuration')
        status, revoked = a.request('app-admin/fans/' + fan_id + '/administrator', 'POST', {
            'administrator': False, 'expectedAdministrator': True,
            'expectedRevision': bound['user']['administratorRevision'],
        }, auth=basic)
        a.check(status == 200 and not revoked['user']['administratorBound'], 'publisher management rights revoked normally')
        status, _ = upload(next(iter(images.values())), 'must-not-create.jpg', token, installation)
        a.check(status in (401, 403, 404), 'revoked administrator cannot upload another image')
        status, _ = a.request('app-content', 'POST', {'heroImages': []}, auth=token, install=installation)
        a.check(status in (401, 403), 'revoked administrator cannot change poster or home configuration')
        status, ordinary = a.request('app-content', auth=token, install=installation)
        a.check(status == 200 and ordinary['heroImages'] == configuration['heroImages'], 'revoked manager remains an approved ordinary fan')
        a.check(sum(len(p['images']) for p in ordinary['portfolios']) == 8,
                'approved ordinary fan receives all eight photos without subscription clipping')
        # Transfer only this transaction's review objects to the private site
        # owner before deleting the temporary user. No production reassignment.
        ids = state['mediaIDs'] + state['albumIDs']
        a.wp_eval(f"$ids=json_decode('{json.dumps(ids)}',true); foreach($ids as $id){{ if((int)get_post_field('post_author',$id)!=={publisher_id}){{exit(83);}} }} foreach($ids as $id){{ $r=wp_update_post(array('ID'=>$id,'post_author'=>{int(owner['userID'])}),true); if(is_wp_error($r)){{exit(84);}} }}")
        state['transferred'] = True
        save_state()
        b.write_new(RECEIPT, json.dumps({'runID': run_id, 'media': uploaded, 'albums': albums,
                    'configuration': configuration, 'checks': a.checks, 'timestamp': int(time.time()),
                    'source': 'existing-artist-selected-photographs', 'finalAccountsCreated': False}, indent=2) + '\n', 0o644)
        committed = True
        state['committed'] = True
        save_state()
    finally:
        try:
            if not committed and original is not None:
                status, _ = a.request('app-content', 'POST', {key: original[key] for key in ('heroImages', 'aboutPortraitURL', 'launchPosters')}, auth=basic)
                if status != 200:
                    raise RuntimeError('Review configuration recovery failed; private receipt retained')
                for media_id in state['mediaIDs']:
                    a.wp_eval(f"$p=get_post({int(media_id)}); if($p && $p->post_type==='attachment' && in_array((int)$p->post_author,array({publisher_id},{int(owner['userID'])}),true)){{wp_delete_attachment($p->ID,true);}}")
                for album_id in state['albumIDs']:
                    a.wp_eval(f"$p=get_post({int(album_id)}); if($p && $p->post_type==='portfolio' && in_array((int)$p->post_author,array({publisher_id},{int(owner['userID'])}),true)){{wp_delete_post($p->ID,true);}}")
            if token:
                status, _ = a.request('fan/delete', 'POST', {'installID': installation,
                    'currentPassword': password, 'confirmation': 'DELETE_ACCOUNT'}, auth=token, install=installation)
                deleted = status == 200
        finally:
            a.wp_eval(f"if (!WP_Application_Passwords::delete_application_password({int(owner['userID'])},'{owner['uuid']}')) {{exit(85);}}")
        if deleted:
            temporary.unlink()
    a.check(deleted, 'temporary publisher deleted through user-side API')
    print(f'review-catalog: {len(a.checks)} checks passed; 8 originals, 2 albums, 5 heroes and 3 posters; temporary publisher removed')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('review-catalog: failed: ' + type(error).__name__
              + (': ' + str(error) if isinstance(error, (ValueError, RuntimeError)) else ''))
        raise SystemExit(1)
