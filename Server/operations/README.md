# Server operation fixes

## Build 34 Nginx 路由事务安装器

`install-build34-nginx-routing` 把两个审核过的 snippet 与 www/img 路由作为
一个事务安装。生产 CLI 固定使用以下四个目标，不接受改路参数：

- `/etc/nginx/sites-enabled/shuzijun-ssl.conf`
- `/etc/nginx/sites-available/shuzijun-ssl.conf`
- `/etc/nginx/snippets/shuzijun-sensitive-files-deny.conf`
- `/etc/nginx/snippets/shuzijun-legacy-images-alias.conf`

现场的 enabled/available 可以是内容不同的 root:root 0644 普通文件。安装器只以
**enabled 字节**为候选配置模板，不会把陈旧 available 内容合并回来，所以
上海/新加坡节点特有的 apex、proxy 与 header 会原样保留。它严格解析
唯一的 www/img 443 TLS block：在 www 的 sensitive include 后直接插入 legacy
include，在 img 中只替换已审核且哈希一致的
`location ^~ /images/ { ... }` block。候选配置还必须通过固定 Web root、
include 层级/顺序、内联 `/images` 与受保护 `^~` 路径的完整语义门禁。

默认是无写入 dry-run。调用者必须从已记录的只读巡检取得 active、available
与两个旧 target 的 SHA-256（target 不存在时明确传 `absent`），并单独
提供 root 所有、非链接、无硬链接的 snippet 输入与可信哈希。第一次
dry-run 可暂时省略 `--expected-old-images-location-sha256`，它会输出旧
location 精确 directive 字节（不含行首缩进）的哈希；审核 block 后必须带该
哈希重跑 dry-run，`--apply` 缺少它会直接拒绝。

```bash
sudo /usr/local/sbin/install-build34-nginx-routing \
  --sensitive-source /root/shuzijun-build34/shuzijun-sensitive-files-deny.conf \
  --legacy-source /root/shuzijun-build34/shuzijun-legacy-images-alias.conf \
  --expected-active-sha256 <巡检记录的-enabled-哈希> \
  --expected-available-sha256 <巡检记录的-available-哈希> \
  --expected-sensitive-target <旧-sensitive-哈希或-absent> \
  --expected-legacy-target <旧-legacy-哈希或-absent> \
  --sensitive-source-sha256 <版本发布记录的-sensitive-哈希> \
  --legacy-source-sha256 <版本发布记录的-legacy-哈希> \
  --dry-run

sudo /usr/local/sbin/install-build34-nginx-routing \
  <与上面完全相同的输入与预期哈希> \
  --expected-old-images-location-sha256 <审核过的-location-哈希> \
  --backup-dir /var/backups/shuzijun-nginx-build34/<节点-唯一事务名> \
  --apply
```

Apply 只允许 backup 位于
`/var/backups/shuzijun-nginx-build34` 的立即子目录，不能指向 Web root。它在
sites-enabled 目录上持有互斥锁，在第一次 backup/写入前重新比对全部字节，
并先确认旧 `nginx -t` 与 nginx service 都正常。备份目录为 root-only，包含
enabled、available、旧 snippets 的原始字节/类型/元数据清单。新 available 与 snippets
是同目录原子替换，enabled 最后原子切换为指向 canonical available 的相对
symlink。候选 `nginx -t`、reload、service active 或任何后置条件失败时，
会恢复四个目标的精确原状态，重验旧 Nginx 并 reload。

安装器故意**不删除** Web root 中的旧 `images` symlink。路由安装成功后，先运行
本机 TLS smoke 并验证真实图片；只有该步通过后才由独立、精确目标的运维操作
删除旧 symlink，再运行 `verify-webroot-security`。

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

如果节点仍运行历史 1.5.7 单文件插件，并且还没有 `composer.json`、
`composer.lock` 与 `vendor/`，不能直接执行普通发布器。先完成新版 Nginx
敏感路由、代码所有权、最新版 verifier、Composer、staging 和 backup
边界的部署，再使用一次性 `bootstrap-legacy-app-content-release` 建立可回滚
基线。它要求操作者同时提供 Git 中已核对的 1.5.7 PHP SHA-256 和 Build 34
清单 SHA-256；默认 dry-run，`--apply` 只补齐已验证 bundle 的 Composer
元数据与 `vendor/`，绝不替换旧 PHP：

```bash
sudo /usr/local/sbin/bootstrap-legacy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34 \
  --manifest-sha256 <CI 记录的 release.sha256 哈希> \
  --legacy-php-sha256 <Git 中已核对的 1.5.7 PHP 哈希> \
  --dry-run

sudo /usr/local/sbin/bootstrap-legacy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34 \
  --manifest-sha256 <同一个已核对哈希> \
  --legacy-php-sha256 <同一个已核对的 1.5.7 PHP 哈希> \
  --apply
```

Bootstrap 会先调用发布器的只读 `--bundle-preflight`，完成完整包、PHP、
Composer、锁定依赖和漏洞审计；随后在同一个 staging `flock` 下再次验证全部
字节。Apply 前后都要求插件入口和 `vendor/autoload.php` 的直接 URL 返回 404，
query-form App API 仍返回受保护的 401。它先在 Web 根目录外建立 root-only
旧 PHP 审计备份，并确认可信 1.5.7 入口不引用 Composer/JWT 支持文件。FPM
全程保持在线；缺少的支持文件先在 MU-plugin 同一文件系统的 root-only 隐藏
目录中完整校验，再按 `vendor`、`composer.lock`、`composer.json` 顺序原子发布，
避免出现元数据先于依赖。中断后留下的任何 byte-exact 支持子集都可以安全续跑；
未知或不一致的文件、目录或 staging 会立即拒绝。失败只清理尚未发布的临时项，
不会替换 1.5.7 PHP、删除已核验的支持子集或停止 FPM。Bootstrap 成功后立即
执行下方普通发布器 dry-run/apply，不要把它当作日常升级命令重复使用。

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
只读 `--bundle-preflight` 在完成 bundle/runtime 检查后、接触现有发布单元前
退出，专供上面的 legacy bootstrap 复用；它不请求生产应用 origin，也不写
Web 根目录、备份或服务状态。Composer 漏洞审计仍可能访问公开安全公告源。
`--dry-run` 不创建锁/备份、不停止服务、不写入 Web 根目录，也不会发出可能
触发访问日志、缓存、Cron 或角色元数据写入的 HTTP 请求。

`--apply` 会先将当前四项完整备份到
`/var/backups/shuzijun-app-content`。备份和 staging 都在 Web 根目录之外。
发布阶段短暂停止 `php8.3-fpm`，先安装 `vendor/` 和 Composer 元数据，最后
安装插件入口；在 FPM 仍停止时，以 `www-data` 身份加载 JWT autoloader。
在停止服务前，发布器会使用 `systemctl mask` 安装持久启动保护；完整发布单元
的哈希和 autoloader 在离线状态通过后，才短暂 `unmask` 并启动 FPM。FPM 启动
后会立即再次持久 mask；只有 Web 根目录、Nginx、直连 PHP 404 和本机 API 401
全部在线验收通过，才最终解除启动保护。因此复制、哈希和在线验收期间发生
SIGKILL、掉电或重启时，systemd 不会把半成品或正在验收的代码自动拉起。
`unmask`、启动、再次 mask 是三个独立 systemd 操作；这个很短的交接窗口中，
代码已经通过离线哈希和 autoloader 验证，但在线探针尚未完成。自动回滚使用
同一双阶段保护，失败隔离必须同时确认 FPM 已停止且 unit 仍为 persistent
masked。部署器在任何 apply HTTP/备份写入前和每次 mask 前都会再次要求
`php8.3-fpm` 原本为 exact enabled；它不会擅自改变 masked/disabled 的策略。
`--apply` 在改动前后都使用 query-form REST 路由直连本机，这样新加坡节点的
pretty-URL 代理不会把探针转到上海；探针要求本机返回 401 JSON 及插件的
`X-Robots-Tag`/`Vary` 安全头。它还在改动前、改动后及自动回滚验收中分别
请求插件入口和 `vendor/autoload.php`，两者都必须由 Nginx 精确返回 404；
403 或 200 都视为发布失败。安装、哈希复核、Web 根目录校验、Nginx、FPM 或
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
when the Nginx deny include is absent, when that include does not return 404 for
every direct `/wp-content/...php` request, or when the resulting Nginx
configuration is invalid. This ensures the MU-plugin's locked `vendor/` PHP is
reachable only through WordPress `/index.php`. Recovery copies must use a
root-only directory under `/var/backups` and must never be placed next to the
live site. Install `verify-nginx-server-block-contract.py` beside the webroot
verifier; its semantic active-config check is local-only and therefore remains
safe to run during a release dry-run.

The legacy `/images/...` public URLs must be provided by the constrained
`shuzijun-legacy-images-alias.conf` include in both `www` and `img` TLS blocks,
not by a document-root symbolic link. Install the sensitive-file snippet first,
validate and reload Nginx, then install the alias include, validate it against a
known image and a denied `.php` probe, and only then remove the old `images`
symlink. The Web-root verifier requires two alias includes and rejects any
remaining symlink, so a partial migration fails closed.

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
