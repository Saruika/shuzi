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
the files. The same snippet denies every PHP path below writable `uploads` and
`cache` trees, irrespective of filename case.

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
