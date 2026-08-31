# Nginx REST authentication

`shuzijun-rest-auth.conf` must be included inside the WordPress PHP FastCGI
location, after the standard FastCGI parameter include. Without it, PHP cannot
see the App's `Authorization` header and administrator login always fails.

The production servers currently use the equivalent inline directive. After
editing Nginx, run `nginx -t` before reloading the service.

`shuzijun-sensitive-files-deny.conf` must be included inside every TLS server
block that can read from the WordPress document root, before the generic PHP
and static-file locations. It returns 404 for `wp-config.php`, configuration or
source backups, any file with a suffix appended after `.php`, database/key/env
files, package metadata, source-control internals, editor swap files and
similarly named residue. Backups belong under a root-only directory outside the
document root; blocking URLs is a second boundary, not a substitute for moving
the files. The same snippet denies every direct PHP request below
`/wp-content/`, irrespective of filename case, PATH_INFO or a canonically
percent-encoded dot. WordPress, MU plugins and locked Composer dependencies are
loaded through `/index.php`; their PHP source is never a public endpoint. Keep
the include before the server's generic PHP location, otherwise that handler
can execute a plugin or `vendor/` file first.

After installing the snippet on each node, run the routing smoke test against
the local TLS virtual host. It requires direct plugin variants to return 404
while both query-form REST routes continue returning the expected unauthenticated
401:

```bash
YISHU_SMOKE_RESOLVE=www.shuzijun.com.cn:443:127.0.0.1 \
  Server/tests/nginx-sensitive-routing-smoke.sh https://www.shuzijun.com.cn www

YISHU_SMOKE_RESOLVE=img.shuzijun.com.cn:443:127.0.0.1 \
  Server/tests/nginx-sensitive-routing-smoke.sh https://img.shuzijun.com.cn img
```

The smoke test accepts only the fixed `www` and `img` roles. Its HTTPS base
host and explicit port must exactly match the mandatory curl
`host:port:127.0.0.1` resolve value, so a local-origin check cannot silently
escape to DNS or a different virtual host. The `www` run additionally parses
both unauthenticated 401 responses: the JSON code must be
`fan_session_required`, and the no-store, MIME-sniffing, framing, referrer,
robots and `Vary` security headers must all remain intact.

`verify-nginx-server-block-contract.py` is the no-HTTP semantic preflight used
by `verify-webroot-security`. Install both operation scripts together. The
checker parses comments, quoted strings and balanced blocks instead of grepping
raw text. It requires exactly one enabled TLS server block for each fixed `www`
and `img` hostname; the canonical `sites-enabled/shuzijun-ssl.conf` must be a
root-owned symlink to the reviewed `sites-available` file, never a copied
regular file that can drift. In both blocks, the fixed WordPress root and the
sensitive/legacy snippet includes must be direct children, occur exactly once,
and precede every `location` (with the sensitive include first). It also rejects
protected `^~` prefixes, inline legacy `/images` locations, a remaining
document-root `images` entry, writable configuration/snippets, and unsafe root
ownership. This preflight reads only local files, so release dry-runs never send
HTTP requests.

`shuzijun-legacy-images-alias.conf` replaces the historical document-root
`images -> wp-content/uploads/hero-images` symbolic link. Include it immediately
after the sensitive-file deny snippet and before generic PHP/static locations in
the `www` and `img` TLS server blocks, then remove the symbolic link. The alias
accepts only one flat, conservative image filename and returns 404 for nested or
unknown paths; exact PHP payloads under `/images/` are denied independently by
the sensitive-file snippet. This preserves existing `/images/...` URLs without
letting a writable upload directory participate in PHP routing or exposing
arbitrary file types.

`shuzijun-account-api-backup-proxy.conf` is only for the Singapore backup
node's `www.shuzijun.com.cn` TLS server. Tencent CDN may retry a 401/403 from
the primary against its backup origin. Because account/session data is not
real-time multi-primary, the backup must forward `/wp-json/shuzijun/v1/` to
the authoritative Shanghai origin rather than answer from its local database.
The proxy validates the Shanghai TLS certificate, preserves authorization and
installation headers, disables proxy caching, and fails closed if Shanghai is
unavailable. Its client-address header is preserved only when the immediate
peer is loopback (the backup apex route); CDN and direct-origin requests always
overwrite that header with their immediate peer address so callers cannot
forge network rate-limit identities. Remove it only as part of a deliberate
disaster-recovery promotion after a final database sync.

`shuzijun-account-api-apex-route.conf` is included in the
`shuzijun.com.cn` TLS server on both nodes. The App uses this direct, non-CDN
hostname for the stateful namespace, while ordinary apex website traffic still
redirects to `www`. On the authoritative node the route loops through the local
`www` TLS virtual host so WordPress retains its canonical origin and existing
FastCGI security rules. It preserves authentication and installation headers,
validates TLS, and never caches API responses.
