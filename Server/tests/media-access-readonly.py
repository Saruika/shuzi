#!/usr/bin/env python3
"""Bounded anonymous GET/HEAD checks. Never downloads media or changes accounts."""

import argparse
import hashlib
import json
import secrets
import socket
import ssl
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener
from uuid import uuid4

HOSTS = {"shuzijun.com.cn", "www.shuzijun.com.cn", "img.shuzijun.com.cn"}
MAX_JSON = 256 * 1024


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def owned_url(value):
    parts = urlsplit(value)
    if (parts.scheme != "https" or parts.hostname not in HOSTS
            or parts.port not in (None, 443) or parts.username or parts.password
            or parts.fragment):
        raise ValueError("only fixed project HTTPS origins are permitted")
    return value


def fetch(url, timeout, method="GET", headers=None):
    owned_url(url)
    # No browser cookies or account headers; retain the machine's network proxy policy.
    opener = build_opener(NoRedirect(), HTTPSHandler(context=ssl.create_default_context()))
    request = Request(url, method=method, headers={
        "Accept": "application/json", "User-Agent": "Shuzi-ReadOnly-Audit/1.0", **(headers or {})})
    try:
        try:
            response = opener.open(request, timeout=timeout)
        except HTTPError as error:
            response = error
        with response:
            body = response.read(MAX_JSON + 1) if method == "GET" else b""
            if len(body) > MAX_JSON:
                return {"status": response.code, "error": "body_limit"}, None
            try:
                payload = json.loads(body) if body else None
            except (ValueError, UnicodeError):
                payload = None
            result = {"status": response.code, "content_type": response.headers.get("Content-Type", ""),
                      "cache_control": response.headers.get("Cache-Control", ""),
                      "vary": response.headers.get("Vary", ""),
                      "content_length": response.headers.get("Content-Length")}
            if isinstance(payload, dict) and isinstance(payload.get("code"), str):
                result["code"] = payload["code"][:100]
            return result, payload
    except (URLError, OSError, TimeoutError) as error:
        # Avoid writing private paths, query strings or signed URLs into results.
        reason = "dns_resolution_failed" if isinstance(getattr(error, "reason", error), socket.gaierror) else "transport_or_tls_error"
        return {"status": None, "error": reason}, None


def selected_images(payload):
    if (not isinstance(payload, dict)
            or set(payload) != {"schemaVersion", "contentAudience", "updatedAt", "albums"}
            or payload["schemaVersion"] != 1 or payload["contentAudience"] != "public"
            or not isinstance(payload["updatedAt"], str)
            or not isinstance(payload["albums"], list) or len(payload["albums"]) > 30):
        raise ValueError("invalid public root DTO")
    images = []
    album_ids = set()
    for album in payload["albums"]:
        if (not isinstance(album, dict) or set(album) != {"id", "title", "subtitle", "images"}
                or type(album["id"]) is not int or album["id"] <= 0 or album["id"] in album_ids
                or not isinstance(album["title"], str) or not 1 <= len(album["title"].strip()) <= 160
                or not isinstance(album["subtitle"], str) or len(album["subtitle"]) > 400
                or not isinstance(album["images"], list) or not 1 <= len(album["images"]) <= 6):
            raise ValueError("invalid public album DTO")
        album_ids.add(album["id"])
        image_ids = set()
        for item in album["images"]:
            if (not isinstance(item, dict) or set(item) != {"id", "url", "altText"}
                    or type(item["id"]) is not int or item["id"] <= 0 or item["id"] in image_ids
                    or not isinstance(item["altText"], str) or len(item["altText"]) > 400
                    or not isinstance(item["url"], str)):
                raise ValueError("invalid public image DTO")
            image_ids.add(item["id"])
            parts = urlsplit(owned_url(item["url"]))
            encoded = parts.path.lower()
            if (not parts.path.startswith("/wp-content/uploads/") or parts.query
                    or "\\" in parts.path or any(s in encoded for s in ("%2e", "%2f", "%5c", "%25"))
                    or any(s in (".", "..") for s in parts.path.split("/"))):
                raise ValueError("invalid public media path")
            images.append(item["url"])
    return images


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--max-media", type=int, choices=range(0, 7), default=6)
    parser.add_argument("--protected-media-url", action="append", default=[],
                        help="Owner-known private image or playlist URL; HEAD only; at most two")
    args = parser.parse_args()
    if not 0 < args.timeout <= 20 or len(args.protected_media_url) > 2:
        parser.error("timeout must be 0–20 seconds; at most two private media samples")
    try:
        for url in args.protected_media_url:
            owned_url(url)
    except ValueError:
        parser.error("private samples must use fixed project HTTPS origins")
    checks = []
    endpoints = [
        ("anonymous_member_manifest", "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-content", {401, 403}, {}),
        ("invalid_bearer_member_manifest", "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-content", {401, 403},
         {"Authorization": "Bearer " + secrets.token_urlsafe(32), "X-Yishu-Install-ID": str(uuid4())}),
        ("anonymous_premium_manifest", "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-content/premium", {401, 403}, {}),
        ("anonymous_wordpress_media", "https://www.shuzijun.com.cn/wp-json/wp/v2/media", {404}, {}),
        ("anonymous_wordpress_portfolio", "https://www.shuzijun.com.cn/wp-json/wp/v2/portfolio", {404}, {}),
    ]
    for name, url, allowed, headers in endpoints:
        result, payload = fetch(url, args.timeout, headers=headers)
        passed = result["status"] in allowed and isinstance(payload, dict) and "code" in result
        if "manifest" in name:
            passed = passed and "no-store" in result.get("cache_control", "").lower()
        checks.append({"check": name, **result, "result": "pass" if passed else "inconclusive" if result["status"] is None else "fail"})
    result, payload = fetch("https://shuzijun.com.cn/wp-json/shuzijun/v1/public-experience", args.timeout)
    try:
        images = selected_images(payload)
        valid = result["status"] == 200 and "no-store" in result.get("cache_control", "").lower()
    except (ValueError, TypeError, KeyError):
        images, valid = [], False
    checks.append({"check": "anonymous_public_selection", **result,
                   "result": "pass" if valid else "inconclusive" if result["status"] is None else "fail",
                   "selected_images": len(images)})
    for index, url in enumerate(images[:args.max_media] if valid else []):
        result, _ = fetch(url, args.timeout, method="HEAD")
        passed = result["status"] == 200 and result.get("content_type", "").lower().startswith("image/")
        checks.append({"check": "public_image_head", "sample": index + 1, **result,
                       "result": "pass" if passed else "inconclusive" if result["status"] is None else "fail"})
    for url in args.protected_media_url:
        result, _ = fetch(url, args.timeout, method="HEAD")
        status = result["status"]
        checks.append({"check": "owner_supplied_private_media_head", "url_sha256": hashlib.sha256(url.encode()).hexdigest(),
                       **result, "result": "finding" if status is not None and 200 <= status < 300
                       else "denied_for_this_request" if status in (401, 403, 404)
                       else "inconclusive"})
    report = {"observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "anonymous GET JSON and HEAD only; no redirects; no media bodies or account mutations",
              "authenticated_lifecycle": "not_tested", "checks": checks}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 2 if any(c["result"] in ("fail", "finding", "inconclusive") for c in checks) else 0


if __name__ == "__main__":
    raise SystemExit(main())
