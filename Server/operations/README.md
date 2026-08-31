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

For ordinary website and media continuity, both `www.shuzijun.com.cn` and
`img.shuzijun.com.cn` keep Shanghai as the primary CDN origin and Singapore as
the backup origin. The account API under `/wp-json/shuzijun/v1` is stateful,
while the two WordPress databases are synchronized in batches rather than
shared in real time. `configure-account-api-origin.py` therefore adds a
path-based origin rule that pins this API namespace to Shanghai and fails
closed if it is unavailable. This prevents a registration on one node from
being followed by an invalid-session response from the other. The global
backup origin remains active for non-account paths, and the rule can be removed
after a deliberate disaster-recovery promotion and final database sync.
Because the CDN can still retry 401/403 responses against the backup origin,
the Singapore Nginx server also uses
`shuzijun-account-api-backup-proxy.conf` to forward this namespace to
Shanghai. Both controls are removed together during a deliberate promotion.
The iOS client itself uses the direct `https://shuzijun.com.cn/wp-json/...`
route installed by `install-apex-account-api-route.py`; this avoids CDN
per-response fallback entirely for normal App traffic. The public website still
redirects from the apex hostname to `www` outside the account API namespace.
