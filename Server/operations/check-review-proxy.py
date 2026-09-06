#!/usr/bin/env python3
"""Bounded loopback-only proxy checks. No accounts, credentials or external load."""
import http.client
import importlib.util
from pathlib import Path
import secrets

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).with_name('accept-review-bootstrap.py'))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


def probe(connection, claimed_client):
    connection.request('POST', '/wp-json/shuzijun/v1/fan/login', '{}', {
        'Host': 'review.shuzijun.com.cn', 'Content-Type': 'application/json',
        'X-Yishu-Client-IP': claimed_client,
    })
    response = connection.getresponse()
    response.read()
    return response.status


def main():
    # RFC 5737 documentation addresses are only header fixtures, not targets.
    client_a = '198.51.100.' + str(secrets.randbelow(90) + 10)
    client_b = '198.51.100.' + str(secrets.randbelow(90) + 110)
    private = http.client.HTTPConnection('127.0.0.1', 18089, timeout=5)
    try:
        statuses = [probe(private, client_a) for _ in range(35)]
        independent = probe(private, client_b)
    finally:
        private.close()
    if not set(statuses) <= {400, 429} or 429 not in statuses or independent != 400:
        raise RuntimeError('Per-client limiting failed or one client affected another')
    # Through the actual TLS edge, changing the supplied header must not reset
    # the real loopback client's bucket. Reuse the connection to bound time.
    public = acceptance.LocalReviewTLS()
    try:
        edge = [probe(public, '203.0.113.' + str(index + 10)) for index in range(40)]
    finally:
        public.close()
    if not set(edge) <= {400, 429} or 429 not in edge:
        raise RuntimeError('TLS edge did not preserve real-client limiting')
    print('review-proxy: passed; independent client bucket, actual 429, and overwritten forwarded identity; 76 loopback requests')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('review-proxy: failed: ' + type(error).__name__
              + (': ' + str(error) if isinstance(error, RuntimeError) else ''))
        raise SystemExit(1)
