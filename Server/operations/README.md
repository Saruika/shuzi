# Server operation fixes

## App Content API 独立发布器

`deploy-app-content-release` 只发布 App Content API 的固定代码单元：

- `shuzijun-app-content.php`
- `composer.json`
- `composer.lock`
- 完整的 `vendor/`

它与下面的整站主备同步脚本相互独立，不同步数据库、`wp-config.php`、
上传目录或 Apple 密钥。默认模式为 `--dry-run`；只有显式传入 `--apply`
才会修改代码。发布器必须由 root 运行，并在 staging 根目录的只读文件描述符
上使用独占 `flock`（不创建或改写锁文件），因此部署前还应
暂停任何可能同时改写 `wp-content` 的旧定时同步任务。

首次使用前由运维一次性建立两个固定边界；发布器不会在 dry-run 中代建目录：

```bash
sudo install -d -o root -g root -m 0700 \
  /var/lib/shuzijun-app-content/releases \
  /var/backups/shuzijun-app-content
```

两台节点还必须先安装受发行版签名/包管理器信任的 Composer（当前门禁接受
`/usr/bin/composer`，并兼容经过同等所有权校验的
`/usr/local/bin/composer`）。缺少 Composer 时 dry-run 会按设计失败，不能
跳过 `validate`/`audit`/平台依赖检查。安装后要确认 PHP 8.3、Composer 的
候选目录、真实解析目录和二进制均为 root 所有且不可被组/其他用户写入。
不要临时下载未经校验的 PHAR 来绕过门禁。

执行首次 dry-run 前还要暂停旧同步任务，并先运行最新版
`verify-webroot-security`。站点根、`wp-content`、`mu-plugins` 与其中代码必须
是 `root:www-data` 且不可被 PHP worker 写入；只有明确的 `uploads`/`cache`
运行目录可以归 `www-data`。发布器会额外要求站点根、`mu-plugins`、staging
和 backup 固定边界的 UID 为 0。任何节点仍由 `www-data` 拥有这些代码边界时，
应先修正所有权并重新只读验证，不能直接发布。

发布包必须是
`/var/lib/shuzijun-app-content/releases` 的直接子目录，且该目录和其中所有
条目都由 root 拥有、不可被组或其他用户写入。它只能包含上面的四项和
`release.sha256`。清单采用 `sha256sum` 的**精确两个空格**文本格式，路径按
C locale 字节序严格排序，末尾保留一个换行，并逐个列出发布单元中的每个
普通文件；Tab、CRLF、空行、重复/乱序路径都会被拒绝。例如在发布目录内生成：

```bash
LC_ALL=C find shuzijun-app-content.php composer.json composer.lock vendor \
  -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > release.sha256
sha256sum release.sha256
```

调用时还必须从可信的 CI/Git 发布记录单独取得
清单本身的 SHA-256，不能只信任与包一起上传的清单。

典型调用如下；SHA-256 是非敏感的发布校验值，不能替换成现场重新计算后
未经核对的值：

```bash
sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34 \
  --manifest-sha256 <CI 记录的 release.sha256 哈希> \
  --dry-run

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34 \
  --manifest-sha256 <同一个已核对哈希> \
  --apply
```

PHP/Composer 只从 `/usr/bin` 或 `/usr/local/bin` 的固定候选路径解析；候选
目录、解析后的真实目录和二进制必须是 root 所有且不可被非 root 写入。
Composer 在清空凭据/代理环境、禁用插件/脚本与缓存后运行。

预检会拒绝路径穿越、符号链接、硬链接、跨文件系统、非普通文件、发布单元外文件、密钥/数据库
文件名、疑似长期凭据内容、PHP 备份残留和任何清单差异，然后执行 PHP 8.3
语法检查、Composer 锁文件校验、漏洞审计、平台依赖检查、JWT autoload
静态检查、现有 Web 根目录安全校验、Nginx 配置检查及 FPM 状态检查。
`--dry-run` 不创建锁/备份、不停止服务、不写入 Web 根目录，也不会发出可能
触发访问日志、缓存、Cron 或角色元数据写入的 HTTP 请求。

`--apply` 会先将当前四项完整备份到
`/var/backups/shuzijun-app-content`。备份和 staging 都在 Web 根目录之外。
发布阶段短暂停止 `php8.3-fpm`，先安装 `vendor/` 和 Composer 元数据，最后
安装插件入口；在 FPM 仍停止时，以 `www-data` 身份加载 JWT autoloader。
`--apply` 在改动前后都使用 query-form REST 路由直连本机，这样新加坡节点的
pretty-URL 代理不会把探针转到上海；探针要求本机返回 401 JSON 及插件的
`X-Robots-Tag`/`Vary` 安全头。安装、哈希复核、Web 根目录校验、Nginx、FPM 或
本地 API 健康检查任一步触发 `ERR`，都会在 FPM 停止状态下只恢复这四项
代码，再恢复 FPM。自动回滚绝不恢复数据库，也不触碰站点配置、媒体或
`/etc/shuzijun` 中的 Apple p8/data key。成功后保留节点本地备份，直至观察
期结束。如果删除/复制/哈希复核任一步使回滚无法完整验证，发布器会保持
FPM 停止而不是带着部分恢复的代码重新上线，并输出人工恢复所需的备份目录。

双节点发布顺序是先新加坡备节点、后上海权威节点。每个节点必须先通过
dry-run，应用后再比较两边发布清单哈希。新加坡的完整 App API namespace
仍应代理到上海；本发布器不会修改该路由、CDN 或 Nginx 配置。

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
files, database exports and private-key formats including Apple `.p8` keys. The sender also removes stale
excluded files from its dedicated staging directory, while the receiver runs
the webroot verifier before and after copying files. The `wp-content` parent and
all code/config entries remain `root:www-data` and non-writable throughout the
copy; only the explicit `uploads` and `cache` runtime trees are returned to
`www-data`. This prevents the PHP worker from renaming a root-owned plugin
directory through a writable parent.

`verify-webroot-security` is the post-deployment guard for both production
nodes. It fails when common backup/config/database/private-key residue exists
under the document root, when any symbolic link or mixed-case PHP filename is
present, when a PHP file has any suffix appended after `.php`, when an
unexpected root-level PHP endpoint appears, when code ownership is writable,
when the Nginx deny include is absent, or when the resulting Nginx configuration
is invalid. Recovery copies must use a root-only directory under `/var/backups`
and must never be placed next to the live site.

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
Shanghai. Only the backup apex server's loopback hop may preserve its
edge-overwritten client-address header; the public backup `www` server replaces
the same header on CDN or direct-origin requests to prevent network rate-limit
identity spoofing. Both controls are removed together during a deliberate
promotion.
The iOS client itself uses the direct `https://shuzijun.com.cn/wp-json/...`
route installed by `install-apex-account-api-route.py`; this avoids CDN
per-response fallback entirely for normal App traffic. The public website still
redirects from the apex hostname to `www` outside the account API namespace.
