#!/usr/bin/env python3
"""Read-only drama-link patrol. No cookies, credentials, page bodies or media stored.

Uses fixed-host-key WP-CLI read access to discover the CURRENT configured links.
Exit 0: verified; 1: expired/mismatched; 2: uncertain or check unavailable.
"""
import argparse
import collections
import json
import re
import shlex
import signal
import subprocess
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 524288
HOSTS = {'novelquickapp.com', 'www.novelquickapp.com'}
SSH = '/Users/mathiashu/Documents/Guai Website/.codex-temp/ssh_guai.sh'


def trusted(url):
    try:
        u = urllib.parse.urlsplit(url)
        return (len(url.encode()) <= 8192 and u.scheme == 'https' and u.hostname in HOSTS
                and u.port in (None, 443) and u.username is None and u.password is None)
    except (ValueError, AttributeError):
        return False


def evaluate(status, body, expected_titles=()):
    if status in (404, 410):
        return 'expired'
    if status != 200 or len(body) > MAX_BYTES:
        return 'unverified'
    try:
        error = json.loads(body)
        if isinstance(error, dict) and str(error.get('message', '')).strip().lower() == '404 not found':
            return 'expired'
    except (ValueError, UnicodeError):
        pass
    try:
        # ModernJS now emits a bare assignment and may append more JS after the
        # JSON. Decode only the JSON value; never execute the following script.
        match = re.search(r'(?:window\.)?\b_ROUTER_DATA\s*=\s*(.*?)</script>', body.decode('utf-8'), re.S)
        if not match:
            return 'unverified'
        root, _ = json.JSONDecoder().raw_decode(match[1].lstrip())
        for page in root['loaderData'].values():
            if not isinstance(page, dict):
                continue
            data = page.get('pageData', {})
            if data.get('BaseResp', {}).get('StatusCode') != 0:
                continue
            actor = data.get('actor_data', {})
            if actor.get('actor_name') == '易姝':
                titles = {v.get('series_title') for v in actor.get('works', [])}
                if not titles:
                    return 'unverified'
                return 'available' if set(expected_titles) <= titles else 'content-mismatch'
            series = data.get('series_data', {}).get('title', '')
            if series:
                return 'available' if not expected_titles or set(expected_titles) == {series} else 'content-mismatch'
    except (ValueError, UnicodeError, KeyError, TypeError, AttributeError):
        pass
    return 'unverified'


class Redirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not trusted(newurl):
            raise ValueError('untrusted redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check(url, titles=()):
    if not trusted(url):
        return 'unverified'
    def deadline(*_):
        raise TimeoutError('deadline')
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(15)
    try:
        opener = urllib.request.build_opener(Redirects())
        request = urllib.request.Request(url, headers={'User-Agent': 'Hi-Shuzi-Link-Check/1.0', 'Cache-Control': 'no-cache'})
        with opener.open(request, timeout=8) as response:
            if not trusted(response.url):
                return 'unverified'
            return evaluate(response.status, response.read(MAX_BYTES + 1), titles)
    except urllib.error.HTTPError as error:
        return 'expired' if error.code in (404, 410) else 'unverified'
    except (OSError, ValueError, TimeoutError):
        return 'unverified'
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def current_dramas(node):
    code = "$c=get_option('shuzijun_app_content_config',array());echo wp_json_encode($c['dramas']??array());"
    command = 'sudo -n -u www-data wp --path=/var/www/html/shuzijun.com.cn eval ' + shlex.quote(code)
    result = subprocess.run([SSH, node, command], capture_output=True, text=True, timeout=35, check=True)
    dramas = json.loads(result.stdout)
    if not isinstance(dramas, list) or not 1 <= len(dramas) <= 50:
        raise ValueError('unexpected catalog')
    return dramas


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', help='Optional single public link, instead of discovering production links')
    args = parser.parse_args()
    groups = collections.defaultdict(lambda: {'nodes': set(), 'titles': set()})
    try:
        if args.url:
            groups[args.url]
        else:
            for node in ('primary', 'backup'):
                for drama in current_dramas(node):
                    group = groups[drama['destinationURL']]
                    group['nodes'].add(node)
                    group['titles'].add(drama['title'])
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        print(json.dumps({'status': 'check-unavailable', 'message': 'Could not read current configuration; no healthy result assumed.'}))
        return 2
    output = []
    for url, group in groups.items():
        result = check(url, group['titles'])
        if result != 'available':
            # Two independent reads before reporting a hard failure; disagreement is uncertain.
            again = check(url, group['titles'])
            if again != result:
                result = 'unverified'
        try:
            parts = urllib.parse.urlsplit(url)
            label = parts.hostname + parts.path if parts.hostname else 'invalid-url'
        except ValueError:
            label = 'invalid-url'
        output.append({'link': label, 'status': result, 'nodes': sorted(group['nodes']),
                       'works': sorted(group['titles'])})
    print(json.dumps({'checks': output}, ensure_ascii=False))
    states = {item['status'] for item in output}
    return 1 if states & {'expired', 'content-mismatch'} else (2 if states != {'available'} else 0)


if __name__ == '__main__':
    raise SystemExit(main())
