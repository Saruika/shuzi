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
