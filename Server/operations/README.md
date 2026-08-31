# Server operation fixes

`cdn-worker-loop-fix.patch` records the production fix for the CDN publication
queue watcher. The worker previously touched and truncated an already-empty
queue on every timer run; the systemd path unit observed its own worker change,
retrigged immediately, and eventually hit the start limit. The fixed worker
changes the queue only when it is created or actually contains URLs.

`apply-shuzijun-sync` is the reviewed backup-node receiver. After importing the
primary database it explicitly flushes WordPress's persistent Redis object
cache before restarting PHP-FPM. Without that step, the database is current but
the App content API can indefinitely serve an older launch poster and
`updatedAt` value from Redis. The script verifies the transfer checksum, creates
a pre-sync database/config backup, validates Nginx and fails closed via
`set -euo pipefail`.

`sync-to-backup` is the matching primary-node sender. Both sides reject or
exclude PHP files with appended suffixes, backup/editor residue, environment
files, database exports and private-key formats. The sender also removes stale
excluded files from its dedicated staging directory, while the receiver runs
the webroot verifier before and after copying files.

`verify-webroot-security` is the post-deployment guard for both production
nodes. It fails when common backup/config/database/private-key residue exists
under the document root, when a PHP file has any suffix appended after `.php`,
when an unexpected root-level PHP endpoint appears, when the Nginx deny include
is absent, or when the resulting Nginx configuration is invalid. Recovery
copies must use a root-only directory under `/var/backups` and must never be
placed next to the live site.

For end-to-end continuity, both `www.shuzijun.com.cn` (the App manifest) and
`img.shuzijun.com.cn` (media delivery) must keep Shanghai as the primary CDN
origin and Singapore as the backup origin. The failover monitor is a second
layer that swaps their priority after repeated health-check failures; it does
not replace the CDN backup-origin configuration.
