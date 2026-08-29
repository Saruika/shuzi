# Server operation fixes

`cdn-worker-loop-fix.patch` records the production fix for the CDN publication
queue watcher. The worker previously touched and truncated an already-empty
queue on every timer run; the systemd path unit observed its own worker change,
retrigged immediately, and eventually hit the start limit. The fixed worker
changes the queue only when it is created or actually contains URLs.
