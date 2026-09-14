# Server operation fixes

## Build 41.13 内部健康监控事务安装器

`deploy-shuzijun-health-monitor` 只升级内部健康脚本及其 service/timer，
不会运行同步、故障切换，也不会修改 Nginx、PHP-FPM、MySQL、DNS、CDN、
WordPress 内容或媒体。生产执行顺序固定为备用节点 `backup standby` 在前，
上海主节点 `primary authority` 在后；任一节点失败即停止。

生产信任锚为：

```text
DEPLOYER_SHA256=041b7f57f8136655e7829950327e479b8879b78842811107bb00f35c5f855218
```

先把 Git 标签 `v1.3.29-build41.13` 中的安装器以原子 rename 放到
`/run/deploy-shuzijun-health-build41.13`，设为 `root:root 0700`、regular、
non-link、nlink=1；三个 runtime 文件则分别放入仅含这三项的
`/run/shuzijun-health-build41.13-backup` 和
`/run/shuzijun-health-build41.13-primary`。不得直接执行仓库副本，也不得从
`/private/tmp` 或可被非 root 写入的路径启动。

Bash 会在读取脚本正文前处理调用环境中的 `BASH_ENV`，所以执行前校验和
正式启动必须位于同一个空环境 root shell。备用节点使用以下完整命令；
任何校验失败都不得继续：

```bash
sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C /bin/bash --noprofile --norc -c '
set -Eeuo pipefail
DEPLOYER=/run/deploy-shuzijun-health-build41.13
DEPLOYER_SHA256=041b7f57f8136655e7829950327e479b8879b78842811107bb00f35c5f855218
[[ ! -L "$DEPLOYER" && -f "$DEPLOYER" ]]
[[ "$(/usr/bin/realpath -e -- "$DEPLOYER")" == "$DEPLOYER" ]]
[[ "$(/usr/bin/stat -c "%F:%u:%g:%a:%h" -- "$DEPLOYER")" == "regular file:0:0:700:1" ]]
[[ "$(/usr/bin/sha256sum -- "$DEPLOYER")" == "$DEPLOYER_SHA256  $DEPLOYER" ]]
exec /bin/bash --noprofile --norc "$DEPLOYER" backup standby
'
```

备用节点完成并通过上线后只读验收后，主节点使用同一段校验，将最后一行
替换为：

```bash
exec /bin/bash --noprofile --norc "$DEPLOYER" primary authority
```

安装器会在专用 root-only 锁内重跑旧字节、角色、stage、systemd unit、
DropInPaths、typed D-Bus Exec path/argv/flags、空环境与 root 执行上下文、
NeedDaemonReload、timer Unit/Job、enable 链接及完整父目录信任检查；持久备份旧 runtime 和
status 后才原子替换。显式 health invocation 必须精确返回 degraded/exit 2，
并匹配节点固定 reason 集。timer 会在 disabled 状态启动；若启动或启用窗口
内发生调度，则最后一次 InvocationID、原始 D-Bus wall/monotonic 微秒时间窗、
status、角色、路由、业务哈希和 reason 集都必须重新通过。计时器下一次触发
还必须连续两次稳定落在 60–360 秒后，才可写入 `DONE`。

Build 41.13 保留不依赖 `stat %F` 本地化文案的空锁文件校验；它分别验证
regular `-f`、非链接、canonical path 及数值 owner/group/mode/nlink，因此
Ubuntu 返回 `regular empty file` 时也不会误拒绝，异常类型仍会 fail-closed。
它还在主事务和回滚的 timer/service 隔离后显式执行 `reset-failed`：
systemd oneshot 即使已 stop 也可能保留 `failed` 状态，现在必须归一到
`inactive/dead` 后才能备份或恢复 timer。
timer 刚启动时若立即触发，systemd 可在短暂的 running 状态中把 next-elapse
暴露为无穷大；安装器不再于 settle 前对它做有符号 Bash 整数判定，
而是等待 health oneshot 空闲后，再由两次 60–360 秒精确采样统一验收。

Build 41.11 还把首次排程从 `OnBootSec=2min` 改为 `OnActiveSec=2min`：timer
无论在开机还是维护后重新启动，都有明确的未来触发点，不会停在
`active/elapsed`。新 timer 会先在 disabled 状态启动并保持 service unit 被
active timer 引用，随后才执行和读取 health oneshot，避免 systemd 回收
inactive unit 后清空 InvocationID 与时间戳。旧状态预检必须连续两次稳定通过，
跨越五分钟触发边界时会有限重试。回滚恢复旧 timer 后会显式执行一次旧 health
service 来重新建立 `OnUnitActiveSec`，再验收 60–360 秒窗口，防止恢复出一个
表面 active、实际不再调度的 timer。

Build 41.12 修复停止 timer 后 service unit 已被 systemd 回收时的隔离误判。
`reset-failed` 在 unit 未加载时会返回非零，但这并不代表 service 仍在运行；
安装器现在无论命令返回值如何，都会重新加载并逐项证明 service 为
`inactive/dead` 且 Job 为空，只有这个终态成立才继续。主事务和 rollback 的
首次隔离共用同一严格 helper；failed、active 或残留 Job 仍会 fail-closed。

Build 41.13 不把 Ubuntu 由 rsyslog 管理的 `root:syslog 0775` `/var/log`
误当作 root-only 信任边界，也不修改系统目录或其中任何日志。健康脚本会先从
根目录到日志父目录验证整条父链；任一目录不是 root:root、可被非 root 写入、
不是实目录或路径不规范时，都会在 `exists`、mtime 或内容读取之前直接把证据
标为 untrusted。当前两个节点因此透明保持 degraded，并精确报告 snapshot 与
sync 成功证据尚未迁入可信目录；这些日志内容不能再改变可信结论或伪造成功。

`/etc/systemd/system/timers.target.wants` 允许在 disabled 阶段被 systemd
删除，但存在时必须是可信实目录；enabled 阶段必须存在 root 所有的绝对目标
链接。链接目录、systemd 父目录、status 文件系统与事务 journal 均在终态前
执行耐久性屏障并复验。安装器不会创建、删除、chmod、chown 或读取
`/var/log` 中的文件；可信快照/同步证据后续必须迁入 root:root 0700 的专用
`/var/lib` 父链并由受信 writer 原子发布，不能靠修改旧日志权限“洗白”。

回滚必须先证明 timer/service 已隔离，再从同一 root-only 事务目录恢复固定
旧哈希；恢复后的 enable 链接、timer 稳定性、status 和 `ROLLED_BACK` journal
都必须持久复验。有效 `DONE` 已是提交点，之后到达的可捕获信号只重做 journal
fsync，不会反向制造 `DONE + ROLLED_BACK` 的矛盾状态。SIGKILL/掉电恢复按
事务目录中的 `PREPARED`、`COMMITTED`、`STATUS_MAY_CHANGE`、`ACCEPTED`、
`DONE` 或 `ROLLED_BACK` marker 人工判定。

## Build 34 Nginx 路由事务安装器

`install-build34-nginx-routing` 把两个审核过的安全 snippet、账号 API
路由与 www/img 路由作为一个事务安装。生产 CLI 固定使用以下
五个目标，不接受改路参数：

- `/etc/nginx/sites-enabled/shuzijun-ssl.conf`
- `/etc/nginx/sites-available/shuzijun-ssl.conf`
- `/etc/nginx/snippets/shuzijun-sensitive-files-deny.conf`
- `/etc/nginx/snippets/shuzijun-legacy-images-alias.conf`
- `/etc/nginx/snippets/shuzijun-account-api-backup-proxy.conf`

现场的 enabled/available 可以是内容不同的 root:root 0644 普通文件。安装器只以
**enabled 字节**为候选配置模板，不会把陈旧 available 内容合并回来，所以
上海/新加坡节点特有的 apex、proxy 与 header 会原样保留。它严格解析
唯一的 www/img 443 TLS block：在 www 的 sensitive include 后直接插入 legacy
include，在 img 中只替换已审核且哈希一致的
`location ^~ /images/ { ... }` block。它同时识别两种已知账号 API
拓扑：主节点 www 内的 direct block，或备节点 www 直接 include 的
`shuzijun-account-api-backup-proxy.conf`。两者只会把精确
`location ^~ /wp-json/shuzijun/v1/` 头改成普通前缀 location，block 体、
注释和节点差异保持不变；同时出现、重复、嵌套或畸形路由都会拒绝。
候选配置还必须通过固定 Web root、include 层级/顺序、内联
`/images`、全部 `^~` 和敏感文件 exact location 的语义门禁。
`sites-enabled` 文档中的顶层 include 也会被拒绝，防止隐藏重复的
canonical TLS server block。www/img 中的普通 include 会在 root:root 0644、
无硬链接且可信父目录的门禁下递归展开；只允许现网的七项 security header
snippet 与 `fastcgi-php.conf -> fastcgi.conf` 执行链。嵌套 location、可能匹配
`/images` 的未知 regex、named location、rewrite/error_page/internal redirect、
重复或改写 `SCRIPT_FILENAME` 等 FastCGI 执行参数都会拒绝。应用 regex 只接受
与独立 Web-root verifier 相同的 www/img 精确 allowlist；每一项还必须符合绑定的
`$uri =404` 静态/媒体、return-only、`deny all` 或严格 PHP body profile，不能仅靠
看似安全的路径表达式通过。静态/媒体 profile 内的 location-scoped `root`、
`alias` 与 upstream handler 全部拒绝；www PHP profile 还固定绑定
`unix:/var/run/php/php8.3-fpm.sock`，TCP 或其它 socket 不能通过。两个主机的
PHP 与 dotfile deny（以及 www 的 uploads/files PHP deny）是必需且唯一的。
Nginx regex 按声明顺序首个命中：因此 dotfile deny 必须位于通用 PHP、
静态和媒体 regex 之前，uploads/files PHP deny 必须位于通用 PHP 之前。
安装器只会将这些精确已审核 block 的完整字节原样移动到安全顺序；
dry-run 的 candidate SHA 包含该顺序变化，事务失败回滚会恢复原顺序。候选配置
随后由独立 verifier 按同一必需集与顺序契约复核。sensitive、legacy
与 account 固定 snippet 也不是不透明输入：前两者必须与版本化 AST 完全一致，
account block 则接受节点体差异但执行同一重定向与 location 安全门禁。

默认是无写入 dry-run。调用者必须从已记录的只读巡检取得 active、available
与三个旧 target 的 SHA-256（target 不存在时明确传 `absent`），并单独
提供 root 所有、非链接、无硬链接的 snippet 输入与可信哈希。第一次
dry-run 可暂时省略三个旧 block 哈希参数，它会输出现场实际存在的
`/images` 及 direct/snippet account API location 精确 directive 字节（不含行首
缩进）的哈希。审核 block 后必须带哈希重跑 dry-run。`--apply` 时
实际存在的旧 account block 必须传精确哈希，另一拓扑以及已迁移的
block 必须显式传 `absent`。

```bash
sudo /usr/local/sbin/install-build34-nginx-routing \
  --sensitive-source /root/shuzijun-build34/shuzijun-sensitive-files-deny.conf \
  --legacy-source /root/shuzijun-build34/shuzijun-legacy-images-alias.conf \
  --expected-active-sha256 <巡检记录的-enabled-哈希> \
  --expected-available-sha256 <巡检记录的-available-哈希> \
  --expected-sensitive-target <旧-sensitive-哈希或-absent> \
  --expected-legacy-target <旧-legacy-哈希或-absent> \
  --expected-account-api-snippet <旧-account-snippet-哈希或-absent> \
  --sensitive-source-sha256 <版本发布记录的-sensitive-哈希> \
  --legacy-source-sha256 <版本发布记录的-legacy-哈希> \
  --dry-run

sudo /usr/local/sbin/install-build34-nginx-routing \
  <与上面完全相同的输入与预期哈希> \
  --expected-old-images-location-sha256 <审核过的-location-哈希> \
  --expected-old-direct-account-api-location-sha256 <主节点-location-哈希或-absent> \
  --expected-old-snippet-account-api-location-sha256 <备节点-location-哈希或-absent> \
  --backup-dir /var/backups/shuzijun-nginx-build34/<节点-唯一事务名> \
  --apply
```

Apply 只允许 backup 位于
`/var/backups/shuzijun-nginx-build34` 的立即子目录，不能指向 Web root。它在
sites-enabled 目录上持有互斥锁，在第一次 backup/写入前重新比对全部字节，
包括所有递归 include 的文件身份与字节，并先确认旧 `nginx -t` 与 nginx
service 都正常。enabled symlink 必须直接指向安全 sites-available 普通文件，
不能借助二级 symlink。备份目录为 root-only，包含
enabled、available、三个旧 snippet target 的原始字节/类型/元数据清单。
只有 active 确实 include 账号 API snippet 时才改写它；direct 拓扑中未被引用的
节点文件会原样保留。新 available 与需要变更的 snippets
是同目录原子替换，enabled 最后原子切换为指向 canonical available 的相对
symlink。候选 `nginx -t`、reload、service active 或任何后置条件失败时，
会恢复五个目标的精确原状态，重验旧 Nginx 并 reload；写完后还会从实际磁盘
重新展开同一 include 图并比对锁前状态，拒绝检查与 reload 之间的漂移。

安装器故意**不删除** Web root 中的旧 `images` symlink。路由安装成功后，先运行
本机 TLS smoke 并验证真实图片；只有该步通过后才由独立、精确目标的运维操作
删除旧 symlink，再运行 `verify-webroot-security`。

## App Content API 独立发布器

当前代码候选为 **1.5.13.15 合作双通道通知修复**，保留此前相册可见性与红果默认入口修复。
精确清单、发布器摘要与验证边界见 [acceptance5](../releases/v1.4.0-build6-acceptance5.md)。当前代码只接受已审核
1.5.13.12 清单作为普通升级前置状态；审核站升级工具同样逐文件匹配该版本。
尚未执行部署。下方旧版本路径与摘要仅为历史操作说明，不得直接复制用于新候选。

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

账号数据是严格的单写者拓扑。每台节点都必须有固定、由服务器 root
管理的 `/etc/shuzijun/account-authority-role`：上海主节点的内容必须精确为
`authority\n`，新加坡备用节点必须精确为 `standby\n`。文件必须是
root:root、模式精确 `0644`、无符号/硬链接的唯一普通文件；`/etc` 与
`/etc/shuzijun` 必须是正规 root:root 目录且模式精确 `0755`。缺失、多一个字节、
CRLF、大小写不同或不安全元数据都是失败关闭。

插件只读这个固定 marker，不从 Host、`REMOTE_ADDR`、代理头、主机名、
WordPress option、数据库或 PHP 运行时常量推断角色；因此整站或数据库同步
不会把备用节点提升成写节点。备用节点的 pretty
`/wp-json/shuzijun/v1/` 仍由 Nginx 代理到上海；能绕过 path proxy 的
`/?rest_route=` 和 `/index.php?rest_route=` 会在应用层固定返回 503
`yishu_account_authority_unavailable`，也不会注册会改写账号数据的
Cron/delete hooks。

两个节点都必须安装同一版本的固定只读角色验证器：

```bash
sudo install -o root -g root -m 0755 \
  Server/operations/verify-account-authority-role.py \
  /usr/local/sbin/verify-shuzijun-account-authority-role
```

它以隔离模式 Python 运行，只通过 `O_NOFOLLOW` 读取上述固定 marker，
并检查精确负载、父目录、UID/GID、权限、文件类型和链接数。所有会调用它的
发布、bootstrap、配置与同步工具都钉住同一个已审核 SHA-256；更新验证器时
必须同步更新这些钉住值，并先在两个节点原子替换验证器，不能混用旧版。

发布器会校验验证器本身与 `/usr/local/sbin` 均为 root 所有且非 root
不可写。dry-run/apply 和独立配置事务会在站点根目录的只读文件描述符上
共用同一个独占 `flock`；不创建锁文件，且发布全程不能并发切换配置。
发布器然后在 dry-run 成功前将实际 marker 与 `--authority-role`
比对。Apply 会在第一次 HTTP 探针前完成同一检查，在创建备份/改写
代码前再检，在 FPM 仍停止时对新插件启动前再检，上线验收时继续复验。
自动回滚也必须在重启 FPM 前通过同一个离线门禁。声明角色与 marker 不符时，
dry-run 和 apply 都会在任何业务探针、备份或代码写入之前失败。
发布器从不创建、删除或更改角色 marker。

角色 marker 只能由独立、显式、可回滚的配置工具改变。工具不推断主机身份；
设置 `authority` 必须额外传入 `--confirm-single-writer`。它在同一个站点目录锁内
重验当前字节，先持久化 root-only 备份，再通过同目录临时文件原子替换 marker；
后置验证失败会恢复原字节，原来缺失则恢复为缺失。配置工具可安装在两节点，
但备节点平时只能配成 `standby`；任何提升都必须先确认旧 authority 已被隔离或降级。
工具还强制 `--confirm-writers-drained`，并在 dry-run/apply 中都严格确认
`php8.3-fpm` 是持久 `masked` 且完全停止的 `inactive/dead`。传入该确认前，操作者
还必须停止同步定时器、等待正在执行的 WP-CLI/Cron/帐号请求结束，并完成跨节点
fencing；这个参数不表示本机能自动证明远端已隔离。

```bash
# 两节点一次性准备；/etc/shuzijun 必须让 PHP worker 可遍历/可读 marker
sudo install -d -o root -g root -m 0755 /etc/shuzijun
sudo install -d -o root -g root -m 0700 /var/backups/shuzijun-account-authority
sudo install -o root -g root -m 0755 \
  Server/operations/configure-account-authority.py \
  /usr/local/sbin/configure-shuzijun-account-authority

# 同步、WP-CLI/Cron 与远端写入者排空后，dry-run 前就必须持久隔离 FPM。
sudo systemctl mask --now php8.3-fpm

# 先在备节点初始化 standby（先 dry-run，再用相同参数 apply）
sudo /usr/local/sbin/configure-shuzijun-account-authority \
  --role standby --expected-current-sha256 absent \
  --backup-dir /var/backups/shuzijun-account-authority/<备节点唯一事务名> \
  --confirm-writers-drained \
  --dry-run

# 备节点验证完成后，再在主节点初始化 authority
sudo /usr/local/sbin/configure-shuzijun-account-authority \
  --role authority --confirm-single-writer --expected-current-sha256 absent \
  --backup-dir /var/backups/shuzijun-account-authority/<主节点唯一事务名> \
  --confirm-writers-drained \
  --dry-run

# 审核 candidate-sha256 后原样重跑，只把 --dry-run 改成 --apply。
# 已存在 marker 的任何切换必须改用当前已审核的 64 位小写 SHA-256，
# 并使用新的备份事务名；不能使用 absent 覆盖现有 marker。
# 配置工具不会解除 mask。保持 FPM masked，直到两节点角色、路由与单写者
# 验收全部完成，再由操作者显式 unmask/start；不得在事务中途启动。
```

计划内切换时，先暂停账号写入，在旧 authority 仍是唯一写者时完成最终数据库
同步；然后把旧节点切到 `standby` 并验证，再把新节点切到 `authority`，
最后切换 Nginx/CDN 路由。旧主节点不可达时，必须先完成基础设施 fencing，确认它无法再写，
才能在备节点使用 `--confirm-single-writer` 提升。任何时刻都不允许两个 `authority`。

如果节点仍运行历史 1.5.7 单文件插件，并且还没有 `composer.json`、
`composer.lock` 与 `vendor/`，不能直接执行普通发布器。先完成新版 Nginx
敏感路由、代码所有权、最新版 verifier、Composer、staging 和 backup
边界的部署，再使用一次性 `bootstrap-legacy-app-content-release` 建立可回滚
基线。该 bridge **只允许在 authority 节点使用**；1.5.7 不识别固定 standby marker，
因此备节点不得 bootstrap 或在线运行它。历史备节点必须先从路由中移除、停止并持久
mask FPM，由已审核的完整发布镜像重建为 fail-closed 版本；不得用整站同步补齐代码。
它要求操作者同时提供 Git 中已核对的 1.5.7 PHP SHA-256 和 Build 34
清单 SHA-256；默认 dry-run，`--apply` 只补齐已验证 bundle 的 Composer
元数据与 `vendor/`，绝不替换旧 PHP：

```bash
sudo /usr/local/sbin/bootstrap-legacy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <CI 记录的 release.sha256 哈希> \
  --legacy-php-sha256 <Git 中已核对的 1.5.7 PHP 哈希> \
  --authority-role authority \
  --dry-run

sudo /usr/local/sbin/bootstrap-legacy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <同一个已核对哈希> \
  --legacy-php-sha256 <同一个已核对的 1.5.7 PHP 哈希> \
  --authority-role authority \
  --apply
```

Bootstrap 会先调用发布器的只读 `--bundle-preflight`，完成完整包、PHP、
Composer、锁定依赖和漏洞审计；随后在同一个 staging `flock` 下再次验证全部
字节。它与普通发布器使用同一个站点根目录只读锁，必须显式提供
`--authority-role authority`，任何 standby 参数在触发 HTTP、备份或发布前即被拒绝。
它在 dry-run 成功前、创建备份/发布支持文件前和事后
重复执行固定静态验证器。Apply 前后都要求插件入口和 `vendor/autoload.php` 的直接 URL 返回 404，
query-form App API 仍返回受保护的 401。它先在 Web 根目录外建立 root-only
旧 PHP 审计备份，并确认可信 1.5.7 入口不引用 Composer/JWT 支持文件。FPM
全程保持在线；缺少的支持文件先在 MU-plugin 同一文件系统的 root-only 隐藏
目录中完整校验，再按 `vendor`、`composer.lock`、`composer.json` 顺序原子发布，
避免出现元数据先于依赖。中断后留下的任何 byte-exact 支持子集都可以安全续跑；
未知或不一致的文件、目录或 staging 会立即拒绝。失败只清理尚未发布的临时项，
不会替换 1.5.7 PHP、删除已核验的支持子集或停止 FPM。Bootstrap 成功后，
必须先使用**同一个 1.5.8 bundle 与同一个 manifest SHA**执行普通发布器
authority dry-run/apply，把混合态收敛成完整 1.5.8；不得从 bootstrap 混合态
直接跳到 1.5.10。这一步完成并验证 live manifest 后，才可执行下方
1.5.10 普通发布。Bootstrap 不得当作日常升级命令重复使用。
这个一次性 authority 过渡态为精确审核的 1.5.7 PHP 加 1.5.8 Composer
支持文件，因此故意不冒充为完整 1.5.8，也不写 live `release.sha256`。
普通发布器只在 `authority` marker、目标为已审核 1.5.8、旧 PHP
与全部支持文件逐字节符合记录时接受这一次缺失状态；standby
或任何其他缺失 manifest 的情形都失败关闭。

```bash
sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 64aee00b4bb78903577ae9de737eb1cfdd3aae687c7633483fa410b8b09d4134 \
  --authority-role authority \
  --dry-run

# dry-run 成功后原样重跑，只把 --dry-run 改为 --apply。
# Apply 成功后 live release.sha256 自身 SHA-256 必须精确为上述值。
```

### Standby 历史单文件首次种子

新加坡备用节点如果仍是经审核的 1.5.7 单文件状态，使用一次性
`seed-standby-app-content-release`。它只接受固定 marker 精确为
`standby\n`的节点，不接收可由调用者改写的角色参数。Dry-run 与
apply 都要求操作者已停止同步、WP-CLI、Cron 及账号请求，传入
`--confirm-writers-drained`，并且 `php8.3-fpm` 必须始终同时是持久
`masked`、`inactive`、`dead`。该工具不会 unmask/start FPM。

首先安装已审核版本的工具，并用 Git/CI 发布记录中的两个独立
SHA-256 运行 dry-run：

```bash
sudo install -o root -g root -m 0755 \
  Server/operations/seed-standby-app-content-release \
  /usr/local/sbin/seed-standby-app-content-release

sudo /usr/local/sbin/seed-standby-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <CI 记录的 release.sha256 哈希> \
  --legacy-php-sha256 <Git 审核的现网-1.5.7-哈希> \
  --confirm-writers-drained \
  --dry-run
```

Dry-run 会输出确定性 `plan-sha256`；该值同时绑定 standby 角色、
固定目标、bundle/manifest、旧 PHP 哈希、发布器/角色验证器审核版本
以及 FPM 隔离策略。记录并审核该哈希后，使用完全相同的参数，
只增加 `--approved-plan-sha256`并改为 apply：

```bash
sudo /usr/local/sbin/seed-standby-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <同一个已审核清单哈希> \
  --legacy-php-sha256 <同一个已审核旧-PHP-哈希> \
  --approved-plan-sha256 <dry-run 输出的-plan-sha256> \
  --confirm-writers-drained \
  --apply
```

工具先调用固定哈希的普通发布器 `--bundle-preflight`，复用发布
manifest、PHP/Composer/JWT 依赖和漏洞审计；随后在共享站点锁和发布锁
下重新校验全部字节。Apply 在 Web root 外建立 root-only 的 1.5.7
审计/回滚备份，在 MU-plugin 同一文件系统的 root-only 隐藏目录先构建
并校验完整发布单元，再以原子 rename 安装 `vendor/`、Composer
元数据、插件入口和 `release.sha256`。安装后以 `www-data` 加载
JWT autoloader 及真实 `wp-load.php`，对 `/index.php?...` 和 `/?...`
两种 query-form 分别做离线 REST 请求，两者都必须返回
503/`yishu_account_authority_unavailable`。

任何失败都在 FPM 仍为 masked/inactive/dead 时删除未发布 staging，并用
已核验备份原子恢复精确的 1.5.7 单文件状态；回滚无法完整验证时
仍保持 FPM 隔离并要求人工恢复。该路径绝不得运行
`bootstrap-legacy-app-content-release`，不复制 `wp-config.php`、数据库、上传目录
或任何整站/代码同步内容。成功后仍由操作者先完成 marker、Nginx
路由和单写者验收，再在独立操作中显式决定是否 unmask/start FPM。

完成 1.5.8 bridge 后，普通版本升级使用目标版本自己的发布包。下面是
Build 42.8 / 服务端 1.5.10 模块化发布的已记录调用；独立信任值见
[`../releases/v1.5.10-build42.8.md`](../releases/v1.5.10-build42.8.md)。新发布器会把已上线的
Build 41 清单 `76f159…` 仅作为可验证的迁移源，不接受它作为新候选包；
候选包必须是本次 Git 发布记录中的模块化清单。SHA-256 不能替换成服务器
现场重新计算后未经 Git 发布记录核对的值。备节点先用 `standby`
dry-run/apply，上海节点再用 `authority` dry-run/apply：

```bash
sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.30-build42.8-server-1.5.10-modular \
  --manifest-sha256 b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1 \
  --authority-role standby \
  --dry-run

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.30-build42.8-server-1.5.10-modular \
  --manifest-sha256 b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1 \
  --authority-role standby \
  --apply

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.30-build42.8-server-1.5.10-modular \
  --manifest-sha256 b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1 \
  --authority-role authority \
  --dry-run

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.30-build42.8-server-1.5.10-modular \
  --manifest-sha256 b15fab2426d7fb7e11e40361c8a22933b5950e6e2e05406a576924cd9a56b9d1 \
  --authority-role authority \
  --apply
```

PHP/Composer 只从 `/usr/bin` 或 `/usr/local/bin` 的固定候选路径解析；候选
目录、解析后的真实目录和二进制必须是 root 所有且不可被非 root 写入。
Composer 在清空凭据/代理环境、禁用插件/脚本与缓存后运行。

预检会拒绝路径穿越、符号链接、硬链接、跨文件系统、非普通文件、发布单元外文件、密钥/数据库
文件名、疑似长期凭据内容、PHP 备份残留和任何清单差异，然后执行 PHP 8.3
语法检查、Composer schema/锁文件校验、漏洞审计、平台依赖检查、JWT autoload
静态检查、现有 Web 根目录安全校验、Nginx 配置检查及 FPM 状态检查。
发布包有意在 `composer.json` 与 lock 中精确钉住 `firebase/php-jwt 7.1.0`；
Composer 对未绑定/过严版本约束的 warning 通过精确的 `--no-check-all` 豁免；
`--strict` 仍把其他 schema warning 视为失败。随后独立门禁继续要求唯一锁定包
严格为 `v7.1.0`，并复验完整 manifest、平台依赖和漏洞公告。
只读 `--bundle-preflight` 在完成 bundle/runtime 检查后、接触现有发布单元前
退出，专供上面的 legacy bootstrap 复用；它不请求生产应用 origin，也不写
Web 根目录、备份或服务状态。Composer 漏洞审计仍可能访问公开安全公告源。
候选协作熔断探针不会要求 PHP worker 穿越 `0700` 的 staging 根目录：root 只把
已经通过 manifest 校验的插件入口通过标准输入送给降权、禁用常见文件流/socket/
DNS/扩展网络出口且
`open_basedir=/nonexistent` 的 PHP 进程。这样既保留 staging 的 root-only 边界，
也能在与 PHP worker 相同的身份下验证内建熔断。整个探针只执行发布记录中精确
审核的 1.5.8/1.5.10 候选入口及模块哈希，未知清单或源码在执行前失败关闭；无 gate/fuse 的兼容
路径还必须是精确审核的 1.5.8 PHP 哈希。PHP 必须在全部断言后输出唯一成功哨兵，所以候选
顶层提前 `exit(0)` 也不能跳过门禁。源码读取失败、加载失败、超时和熔断不安全
会分别失败关闭。

`--dry-run` 不创建锁/备份、不停止服务、不写入 Web 根目录，也不会发出可能
触发访问日志、缓存、Cron 或角色元数据写入的 HTTP 请求。

`--apply` 会先将当前四项 payload、live `release.sha256` 的原始字节
或其精确缺失状态完整备份到 `/var/backups/shuzijun-app-content`。
备份使用独立 `backup-integrity.sha256` 校验，不会用现场重算结果覆盖
发布 provenance；备份和 staging 都在 Web 根目录之外。发布阶段
短暂停止 `php8.3-fpm`，先安装 `vendor/`、Composer 元数据和插件入口，
最后将已审核的 bundle `release.sha256` 在同一文件系统内同步并原子换入。
发布器要求 live manifest 自身 SHA-256 等于 Git/CI 记录的独立值，并从
live 目录使用该 manifest 复验全部 payload。在 FPM 仍停止时，以
`www-data` 身份加载 JWT autoloader。
在停止服务前，发布器会使用 `systemctl mask` 安装持久启动保护；完整发布单元
的哈希和 autoloader 在离线状态通过后，发布器还会以 `www-data`、清空环境和
固定 PHP 8.3 加载实际 `wp-load.php`，离线构造
`GET /shuzijun/v1/app-content`，并严格断言 authority 为
401/`fan_session_required`、standby 为
503/`yishu_account_authority_unavailable`。这同时证明 marker 对 worker 可读及
新插件的实际 REST 语义；自动回滚也在重启前重复同一离线探针。
全部通过后才短暂 `unmask` 并启动 FPM。FPM 启动
后会立即再次持久 mask；只有 Web 根目录、Nginx、直连 PHP 404 和本机 API
权威角色验收
全部在线验收通过，才最终解除启动保护。因此复制、哈希和在线验收期间发生
SIGKILL、掉电或重启时，systemd 不会把半成品或正在验收的代码自动拉起。
`unmask`、启动、再次 mask 是三个独立 systemd 操作；这个很短的交接窗口中，
代码已经通过离线哈希、autoloader 与 WordPress REST 角色验证，但在线探针尚未完成。自动回滚使用
同一双阶段保护，失败隔离必须同时确认 FPM 已停止且 unit 仍为 persistent
masked。部署器在任何 apply HTTP/备份写入前和每次 mask 前都会再次要求
`php8.3-fpm` 原本为 exact enabled；它不会擅自改变 masked/disabled 的策略。
`--apply` 在改动前后都使用 query-form REST 路由直连本机，这样新加坡节点的
pretty-URL 代理不会把探针转到上海。改动前探针已与声明角色严格绑定，
不再存在接受任意 401/503 的 legacy 例外；新代码上线后以及自动回滚后也严格
要求 `--authority-role authority` 对应 401、`--authority-role standby` 对应
503。如果备节点回滚到不含 fail-closed 保护的旧版，回滚验收会失败并保持
PHP-FPM 停止且持久 mask，不会重新开放 query-form 绕过。探针继续校验 JSON
错误码（401 必须为 `fan_session_required`，503 必须为
`yishu_account_authority_unavailable`）、
`X-Robots-Tag`/`Vary` 安全头。它还在改动前、改动后及自动回滚验收中分别
请求插件入口和 `vendor/autoload.php`，两者都必须由 Nginx 精确返回 404；
403 或 200 都视为发布失败。安装、哈希复核、Web 根目录校验、Nginx、FPM 或
本地 API 健康检查任一步触发 `ERR`，都会在 FPM 停止状态下先恢复
四项 payload，最后恢复原 live manifest 的精确字节或精确 absent 状态，
再恢复 FPM。自动回滚绝不恢复数据库，也不触碰站点配置、媒体或
`/etc/shuzijun` 中的 Apple p8/data key。成功后保留节点本地备份，直至观察
期结束。如果删除/复制/哈希复核任一步使回滚无法完整验证，发布器会保持
FPM 停止而不是带着部分恢复的代码重新上线，并输出人工恢复所需的备份目录。

双节点发布顺序是先新加坡备节点、后上海权威节点。每个节点必须先通过
dry-run，应用后再比较两边发布清单哈希。新加坡的完整 App API namespace
仍应代理到上海；本发布器不会修改该路由、CDN 或 Nginx 配置。

`shuzijun-internal-health` 每五分钟写入 root-only 私有健康快照。角色只由
固定 `/etc/shuzijun/account-authority-role` marker 与钉住哈希的验证器
确定，绝不从 failover timer 推断，也绝不在异常时默认 authority。Authority
检查 CDN 与 sender/sync scheduler；standby 检查 receiver generation 与
failover。每日同步日志的最大正常间隔为 26 小时，且日志必须 root 所有、
单链接、不可被组或其他用户写入并包含对应完成标记。`degraded` 使用 exit 2，
由 unit 的 `SuccessExitStatus=2` 接受为一次成功采样；`status.json` 中仍保留
明确 reason codes。`critical` 继续 exit 1。该工具只读系统状态，不运行同步、
ingest、服务启停或故障切换。独立信任值见
[`../releases/v1.5.10-build41.6.md`](../releases/v1.5.10-build41.6.md)。

`cdn-worker-loop-fix.patch` records the production fix for the CDN publication
queue watcher. The worker previously touched and truncated an already-empty
queue on every timer run; the systemd path unit observed its own worker change,
retrigged immediately, and eventually hit the start limit. The fixed worker
changes the queue only when it is created or actually contains URLs.

`sync-to-backup` and `apply-shuzijun-sync` form one pinned v4 transactional
uploads protocol. After
taking the site lock, the sender first proves its local marker is `authority`
and runs the exact-hash-pinned static Web-root contract. Only then does it
attest the remote receiver against the exact SHA-256 compiled into the sender
and require the exact
`shuzijun-sync-receiver-v4-transactional-uploads` protocol response before it
creates an export. Before consuming a generation, it enforces the database,
file-count, directory-count, per-file, aggregate and temporary-disk budgets,
streams the database into bounded gzip without a plaintext SQL file, copies the
uploads through no-follow file descriptors, and re-attests the receiver and
protocol. Install and attest the receiver first; an older receiver is not
backward compatible and must never be invoked as a fallback.

The batch contains only a database gzip and `wp-content/uploads/`. A canonical
JSON v2 manifest lists every allowed path, byte size, SHA-256 and a strictly
increasing generation, and is signed with the
existing root-only Ed25519 sync key under namespace and identity
`shuzijun-sync`. The receiver verifies it against the root-owned
`/etc/shuzijun/sync-signers`. The sender then streams a bounded manifest and
signature followed by the declared file bytes through encrypted SSH directly
to the root receiver; there is no remotely writable staging directory and no
database plaintext owned by the transport account. Before authentication the
receiver writes at most the bounded control records into a fresh root-only
claim below `/var/lib/shuzijun-sync/incoming`; only after signature verification
does it accept the size-bounded payload and verify every digest. It atomically
advances root-only `/var/lib/shuzijun-sync/state/highest-accepted-generation`
before any backup, media or database mutation, so the same or an older signed
batch is rejected. A failed application consumes its generation; retry by
issuing a newer batch, never by deleting or reducing either generation file.

Any extra path, code/theme/plugin/config file, executable upload, symlink,
hard-linked sender file, non-canonical manifest, oversize batch, digest mismatch,
trailing byte or missing database is rejected. The sender does not use rsync:
its bounded copier opens every source file relative to the scanned directory fd
with `O_NOFOLLOW`, checks stable inode/size/mtime/ctime before and after the
copy, and applies the actual aggregate limit to the bytes staged. Files that
appear after an already-enumerated directory are outside that signed snapshot;
they cannot bypass the bound because only staged, hashed bytes enter the
manifest. The receiver stages the complete uploads generation outside the Web
root and publishes it through a same-filesystem atomic directory exchange; it
never uses a delete-capable copy command against code or configuration paths.
`verify-webroot-security` separately rejects PHP, PHTML, PHAR, script and
per-directory config payloads already present in uploads, so
whole-site sync cannot become a second code-release path; only
`deploy-app-content-release` may replace executable code.

The receiver acquires the shared site-directory lock and proves `standby`
before protocol negotiation, before reading a batch and again immediately
before runtime activation. It requires FPM to begin in the exact
`enabled`/`loaded`/`active`/`running` state with no socket trigger, and both local
query-form REST routes to return 503/`yishu_account_authority_unavailable`
before any root claim, backup or database/media write. Once the signed database
has been bounded and the generation accepted, the receiver persistently masks
and stops `php8.3-fpm` and proves exact `masked`/`inactive`/`dead` state before
creating the backup or touching live uploads/database. This persistent guard
survives SIGKILL throughout the mutation phase. EXIT and INT/TERM/HUP paths
re-apply and re-verify it after any unsuccessful apply. Only after the offline
Web-root, role, Nginx and database checks pass does the receiver start and enable
the separately supervised `shuzijun-sync-fpm-guard.service`, then unmask/start
FPM, require its exact original enabled/running policy, and repeat both standby
probes. The guard holds an independent root-only flock lease and treats the
absence of a durable post-probe commit as a command to mask/stop FPM. Its
`Type=notify` readiness is ordered before FPM and enabling it installs a
`RequiredBy=php8.3-fpm.service` dependency. A boot/dependency start without a
commit never reports READY and fails, while an in-flight receiver reports READY
only after the independent watcher is armed. Thus SIGKILL, receiver-cgroup
termination or a reboot in the activation window cannot turn an uncommitted
apply into a serving standby. Each watcher invocation has a two-minute runtime ceiling.
Its fixed `ExecStopPost` independently masks/stops and verifies FPM whenever
that ceiling, TERM or a forced guard kill occurs without a commit, so safety
does not depend on `Requires` propagating a later service exit. After a
successful commit the short-lived guard finishes `inactive/dead` with
`Result=success`; every future FPM start pulls it in again through the installed
`RequiredBy` edge and must pass its `Type=notify` readiness gate. Exact
persistent isolation exits 77 and is excluded from restart because retrying it
adds no safety. The unit counts every activation (successful, failed, automatic
or manual) against three starts per ten-minute window. This both bounds genuine
failure retries and deliberately makes a fourth rapid FPM restart fail closed.
After inspecting the journal, proving there is no receiver/claim in flight and
verifying the durable commit plus exact FPM state, an operator may run
`systemctl reset-failed shuzijun-sync-fpm-guard.service`; never reset it during
an apply. A failed runtime probe re-isolates FPM; failure to prove isolation is a
critical manual incident rather than a swallowed cleanup error. Pre-sync
database/config backups are root-only and fsynced; the App release unit and all
other code remain `root:www-data` and non-writable.

The receiver runs `sync -f /etc/systemd/system` after publishing and verifying
the persistent FPM mask, and again after enabling/verifying the guard's
`RequiredBy` edge but before starting the watcher or removing that mask. This
orders both sides of the hard-reset boundary: an uncommitted reboot sees either
the durable mask or the durable startup guard, never merely an in-memory edge.

The receiver validates the guard's pinned unit bytes, root metadata, fragment,
drop-in absence, daemon-reload state, `Type`, `NotifyAccess`,
`RemainAfterExit`, `RuntimeMaxUSec`, restart/start-limit policy, `Before`
ordering and enabled-state before
it reads an ingest stream and again immediately before accepting the generation. Activation
repeats that validation after `systemctl enable`; at that point runtime
`RequiredBy` must include PHP-FPM before the watcher may report READY.

SSH is not a general standby login. The sender connects only as the dedicated,
password-locked `shuzijun-sync-transport` account with pinned host-key checking.
Its root-owned authorized key uses `restrict`, the reviewed sshd Match block
forces `shuzijun-sync-ssh-gate`, and that gate accepts only the exact receiver
`--attest`, `--protocol`, `--reconcile-receipt` and `--ingest` commands. The
matching sudoers file grants only those four root commands. Remove any prior
sync-key access for `ubuntu` and any broad `NOPASSWD: ALL`; otherwise the
transport boundary is not installed.

`shuzijun-sync.service` and `shuzijun-sync.timer` are installed only on the
Shanghai primary. The timer runs once per day at 03:30 Asia/Shanghai with up
to ten minutes of jitter; `Persistent=true` catches one missed run after a
reboot without creating a high-frequency database/config backup stream. The
sender service has an eight-hour deadline, uses low CPU/I/O priority and
explicitly fails when
MySQL, Nginx, PHP-FPM, the sender, either verifier, the SSH key or generation
state is unavailable. These gates are `ExecStartPre`, not systemd `Condition*`,
so a missing dependency is recorded as a failed run rather than a successful
skip. It must run as root because the sender reads the root-only pinned SSH key,
invokes the root-owned static verifier and exports WordPress through WP-CLI.
Its systemd sandbox removes all capabilities, makes the system and primary Web
root read-only, keeps `/root` read-only, gives it a private temporary directory,
and permits writes only below `/run` and `/var/log` plus the root-only generation
state below `/var/lib/shuzijun-sync` on the primary. The only remote write path
remains the reviewed receiver reached through pinned SSH host-key verification.

Every start of the sender service requires and is ordered after the separate
`shuzijun-sync-preflight.service`. That short-lived unit runs only
`/usr/sbin/nginx -t -q` in a private network namespace. It cannot see `/root`,
the sync generation state or `/var/backups`; the system is read-only and only
`/var/log/nginx` is writable. `CAP_DAC_OVERRIDE` and `CAP_NET_BIND_SERVICE` are
bounded to this Nginx-only preflight and never reach the eight-hour sender, its
WP-CLI/SSH/Python children or the remote transport. The sender's static wrapper
opens and hashes the exact reviewed full verifier, replaces exactly its final
live `nginx -t` boundary, and executes all remaining filesystem and parsed-
Nginx contracts without capabilities. A missing or duplicate replacement
boundary fails before any transformed verifier command runs.

The eight-hour deadline is deliberate: the reviewed v4 transactional protocol
still sends the complete signed uploads payload. The accepted generation 6
baseline contains 943 media files and 209,133,527 bytes. Early live samples fit approximately
8.6 seconds of per-file verification/durable-write overhead plus a roughly
360 KB/s data segment, which initially projected about 2.4 hours before the
final apply and smoke checks. The continuing live TCP evidence instead showed
about 31.5% retransmitted bytes, a congestion window of two segments and only
about 13 KB/s cumulatively acknowledged. The eight-hour bound covers that
measured lossy-path envelope plus apply and smoke time while retaining a finite
failure deadline. The daily schedule cannot
overlap because the service lock is exclusive. A failed run does not reuse a consumed generation.
Failure before the receiver's anti-replay acceptance leaves its counter
unchanged; failure after acceptance deliberately leaves that counter advanced
even when no apply-completion log exists. Never roll it back or reuse the number:
retry only with the sender's next strictly increasing generation. If hardened
generation 7 is accepted but does not complete, this release's four-way `=7`
timer gate cannot be met; keep the timer disabled and establish a newly reviewed
next-generation gate. Signed delta transfer remains a future protocol change
and is not part of this v4 transactional-activation recovery.

Every scheduled or manual sync must start `shuzijun-sync.service`; never invoke
`sync-to-backup` directly, even behind an operator-created `flock`, because that
would bypass the required Nginx preflight. The service itself takes
`/run/shuzijun-sync/sync.lock`.

The sole migration exception is the reviewed, static
`shuzijun-sync-reconcile-generation7.service`. It carries the frozen generation
7 evidence from the already-committed legacy run, requires the same Nginx
preflight, reuses the same runtime lock and sandbox, and cannot be enabled by a
timer or install target. Start it once with `systemctl start` only after both
nodes have the matching recovery release; do not reproduce its sender command
manually.

Before a two-node release, stop the timer first and do not interrupt a
receiver/sender that is already applying a database dump:

```bash
systemctl stop shuzijun-sync.timer
if systemctl is-active --quiet shuzijun-sync.service; then
  echo 'sync still active; wait for it to finish before deployment' >&2
  exit 1
fi
```

After both nodes pass their release manifests and smoke tests, install the
hardened full verifier, its hash-pinned consumers, the activation-guard unit and
the current receiver on Singapore first. Then install the same verifier chain,
the static verifier, known-hosts, sender and versioned units on Shanghai.
Validate every installed byte/unit, run hardened foreground generation 7, and
only after issued/accepted/completion-log evidence all equal 7 enable the
persistent timer:

When a candidate bundle is transferred from macOS with `tar`, set
`COPYFILE_DISABLE=1` at archive creation and require the staging directory to
contain exactly the reviewed filenames. Any `._*` AppleDouble entry is an
unexpected file and must fail closed; never delete or ignore it merely to make
the candidate pass. Establish the exact-path cleanup trap before validating the
candidate file list so a rejected preflight cannot leave stale `/run` input for
the next attempt.

```bash
# This initializer creates exactly `0\n` only when a generation file is absent.
# An existing inode is opened read-only with O_NOFOLLOW and must already satisfy
# the root:root, 0600, nlink=1 and canonical integer contract. It is never reset.
initialize_generation_state() {
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C \
    /usr/bin/python3 -I - "$1" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

state_path = Path(sys.argv[1])
allowed = {
    Path("/var/lib/shuzijun-sync/highest-issued-generation"),
    Path("/var/lib/shuzijun-sync/state/highest-accepted-generation"),
}
if state_path not in allowed:
    raise SystemExit(1)
parent = state_path.parent
metadata = parent.lstat()
if (parent.resolve(strict=True) != parent or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != 0 or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) != 0o700):
    raise SystemExit(1)

read_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW

def validate_existing():
    descriptor = os.open(state_path, read_flags)
    try:
        current = os.fstat(descriptor)
        payload = os.read(descriptor, 32)
        if os.read(descriptor, 1):
            raise SystemExit(1)
    finally:
        os.close(descriptor)
    if (not stat.S_ISREG(current.st_mode) or current.st_uid != 0
            or current.st_gid != 0 or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_nlink != 1
            or not re.fullmatch(rb"(?:0|[1-9][0-9]{0,18})\n", payload)):
        raise SystemExit(1)

try:
    validate_existing()
except FileNotFoundError:
    descriptor, temp_name = tempfile.mkstemp(prefix=".generation-init.", dir=parent)
    temp_path = Path(temp_name)
    published = False
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(b"0\n")
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise SystemExit(1)
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(temp_path, state_path, follow_symlinks=False)
        except FileExistsError:
            pass
        else:
            published = True
        temp_path.unlink()
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
    validate_existing()
    if published:
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

if list(parent.glob(".generation-init.*")):
    # A stale candidate indicates an interrupted/manual initializer and must be
    # reviewed rather than silently deleted by installation instructions.
    raise SystemExit(1)
PY
}

# Singapore standby, first:
install -d -o root -g root -m 0700 /var/lib/shuzijun-sync
install -d -o root -g root -m 0700 \
  /var/lib/shuzijun-sync/incoming \
  /var/lib/shuzijun-sync/state
initialize_generation_state \
  /var/lib/shuzijun-sync/state/highest-accepted-generation
install -d -o root -g root -m 0755 /etc/shuzijun
# Each line is: shuzijun-sync <reviewed public key corresponding to the
# primary's /root/.ssh/shuzijun_sync_ed25519>. Never place a private key here.
install -o root -g root -m 0644 <reviewed-allowed-signers-file> \
  /etc/shuzijun/sync-signers
install -o root -g root -m 0755 Server/operations/verify-webroot-security \
  /usr/local/sbin/verify-shuzijun-webroot-security
install -o root -g root -m 0755 Server/operations/deploy-app-content-release \
  /usr/local/sbin/deploy-app-content-release
install -o root -g root -m 0755 Server/operations/seed-standby-app-content-release \
  /usr/local/sbin/seed-standby-app-content-release
install -o root -g root -m 0644 Server/operations/shuzijun-sync-fpm-guard.service \
  /etc/systemd/system/shuzijun-sync-fpm-guard.service
install -o root -g root -m 0755 Server/operations/apply-shuzijun-sync \
  /usr/local/sbin/apply-shuzijun-sync
install -o root -g root -m 0755 Server/operations/shuzijun-sync-ssh-gate \
  /usr/local/sbin/shuzijun-sync-ssh-gate
install -o root -g root -m 0440 \
  Server/operations/shuzijun-sync-transport.sudoers \
  /etc/sudoers.d/shuzijun-sync-transport
visudo -cf /etc/sudoers.d/shuzijun-sync-transport
useradd --system --home-dir /var/lib/shuzijun-sync-transport \
  --shell /bin/sh shuzijun-sync-transport
usermod --lock shuzijun-sync-transport
install -d -o root -g root -m 0755 \
  /var/lib/shuzijun-sync-transport \
  /var/lib/shuzijun-sync-transport/.ssh
# The reviewed public-key line must begin with `restrict ` and must be the only
# line. Do not include a private key or a command supplied by the sender.
install -o root -g root -m 0644 <restrict-prefixed-authorized-key> \
  /var/lib/shuzijun-sync-transport/.ssh/authorized_keys
install -o root -g root -m 0644 \
  Server/operations/shuzijun-sync-transport.sshd \
  /etc/ssh/sshd_config.d/60-shuzijun-sync-transport.conf
sshd -t
sshd -T -C user=shuzijun-sync-transport,host=localhost,addr=127.0.0.1 \
  | grep -Fx 'forcecommand /usr/local/sbin/shuzijun-sync-ssh-gate'
systemd-analyze verify /etc/systemd/system/shuzijun-sync-fpm-guard.service
systemctl daemon-reload
test "$(systemctl is-enabled shuzijun-sync-fpm-guard.service)" = disabled
test "$(systemctl show shuzijun-sync-fpm-guard.service -p NeedDaemonReload --value)" = no
test "$(systemctl show shuzijun-sync-fpm-guard.service -p Type --value)" = notify
test "$(systemctl show shuzijun-sync-fpm-guard.service -p NotifyAccess --value)" = all
test "$(systemctl show shuzijun-sync-fpm-guard.service -p RemainAfterExit --value)" = no
test "$(systemctl show shuzijun-sync-fpm-guard.service -p RuntimeMaxUSec --value)" = 2min
test "$(systemctl show shuzijun-sync-fpm-guard.service -p Restart --value)" = on-failure
test "$(systemctl show shuzijun-sync-fpm-guard.service -p RestartUSec --value)" = 1s
test "$(systemctl show shuzijun-sync-fpm-guard.service -p StartLimitIntervalUSec --value)" = 10min
test "$(systemctl show shuzijun-sync-fpm-guard.service -p StartLimitBurst --value)" = 3
systemctl show shuzijun-sync-fpm-guard.service -p Before --value \
  | tr ' ' '\n' | grep -Fx php8.3-fpm.service
systemctl reload ssh
sha256sum /usr/local/sbin/apply-shuzijun-sync
sudo /usr/local/sbin/apply-shuzijun-sync --protocol

# Compare the printed SHA-256 and protocol with REMOTE_RECEIVER_SHA256 and
# SYNC_PROTOCOL in the reviewed sender source, then install Shanghai second:
install -d -o root -g root -m 0700 /var/lib/shuzijun-sync
install -d -o root -g root -m 0755 /etc/shuzijun
initialize_generation_state \
  /var/lib/shuzijun-sync/highest-issued-generation
install -o root -g root -m 0755 Server/operations/verify-webroot-security \
  /usr/local/sbin/verify-shuzijun-webroot-security
install -o root -g root -m 0755 Server/operations/deploy-app-content-release \
  /usr/local/sbin/deploy-app-content-release
install -o root -g root -m 0755 Server/operations/bootstrap-legacy-app-content-release \
  /usr/local/sbin/bootstrap-legacy-app-content-release
install -o root -g root -m 0600 \
  Server/operations/shuzijun-sync-known-hosts \
  /etc/shuzijun/sync-known-hosts
test "$(sha256sum /etc/shuzijun/sync-known-hosts | awk '{ print $1 }')" = \
  b48cc29b7506423ba402b954cb8c0fedc748706549ed704e84647b70a517d6f3
install -o root -g root -m 0755 Server/operations/verify-shuzijun-sync-source \
  /usr/local/sbin/verify-shuzijun-sync-source
install -o root -g root -m 0755 Server/operations/sync-to-backup \
  /usr/local/sbin/sync-to-backup
install -o root -g root -m 0644 Server/operations/shuzijun-sync-preflight.service \
  /etc/systemd/system/shuzijun-sync-preflight.service
install -o root -g root -m 0644 Server/operations/shuzijun-sync.service \
  /etc/systemd/system/shuzijun-sync.service
install -o root -g root -m 0644 Server/operations/shuzijun-sync.timer \
  /etc/systemd/system/shuzijun-sync.timer
systemd-analyze verify /etc/systemd/system/shuzijun-sync-preflight.service \
  /etc/systemd/system/shuzijun-sync.service \
  /etc/systemd/system/shuzijun-sync.timer
systemctl daemon-reload
systemctl start shuzijun-sync.service
systemctl show shuzijun-sync-preflight.service \
  -p ExecMainStatus -p Result -p CapabilityBoundingSet -p PrivateNetwork
systemctl show shuzijun-sync.service \
  -p ExecMainStatus -p Result -p CapabilityBoundingSet
journalctl -u shuzijun-sync-preflight.service \
  -u shuzijun-sync.service --since '-1 hour' --no-pager
# STOP: do not create or enable the timer until every generation-7 assertion
# below succeeds. On Shanghai:
test "$(cat /var/lib/shuzijun-sync/highest-issued-generation)" = 7
tail -n 1 /var/log/wp-sync.log | grep -Eq 'incremental sync completed generation=7$'
# On Singapore, in a separate operator shell:
test "$(cat /var/lib/shuzijun-sync/state/highest-accepted-generation)" = 7
tail -n 1 /var/log/shuzijun-sync-receiver.log \
  | grep -Eq 'signed uploads/database sync applied; generation=7 backup='
test "$(systemctl is-enabled shuzijun-sync-fpm-guard.service)" = enabled
test "$(systemctl show shuzijun-sync-fpm-guard.service -p ActiveState --value)" = inactive
test "$(systemctl show shuzijun-sync-fpm-guard.service -p SubState --value)" = dead
test "$(systemctl show shuzijun-sync-fpm-guard.service -p Result --value)" = success
test "$(systemctl show shuzijun-sync-fpm-guard.service -p ExecMainStatus --value)" = 0
systemctl show shuzijun-sync-fpm-guard.service -p RequiredBy --value \
  | tr ' ' '\n' | grep -Fx php8.3-fpm.service
test -z "$(find /var/lib/shuzijun-sync/incoming -mindepth 1 -maxdepth 1 -print -quit)"
# Return to Shanghai only after recording those exact Singapore results. Both
# nodes must have no sender/receiver process or job. Then initialize
# Persistent=true without an immediate catch-up run. This block deliberately
# fails if a stamp already exists; review an existing stamp instead of replacing it.
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C \
  /usr/bin/python3 -I - <<'PY'
import os
import stat
from pathlib import Path

root = Path("/var/lib/systemd/timers")
stamp = root / "stamp-shuzijun-sync.timer"
metadata = root.lstat()
if (root.resolve(strict=True) != root or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != 0 or metadata.st_gid != 0
        or stat.S_IMODE(metadata.st_mode) & 0o022):
    raise SystemExit(1)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
descriptor = os.open(stamp, flags, 0o644)
try:
    os.fchmod(descriptor, 0o644)
    current = os.fstat(descriptor)
    if (not stat.S_ISREG(current.st_mode) or current.st_uid != 0
            or current.st_gid != 0 or stat.S_IMODE(current.st_mode) != 0o644
            or current.st_nlink != 1 or current.st_size != 0):
        raise SystemExit(1)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
systemctl enable shuzijun-sync.timer
systemctl start shuzijun-sync.timer
systemctl is-enabled --quiet shuzijun-sync.timer
systemctl is-active --quiet shuzijun-sync.timer
! systemctl is-active --quiet shuzijun-sync.service
systemctl show shuzijun-sync.timer \
  -p ActiveState -p SubState -p LastTriggerUSec -p NextElapseUSecRealtime
```

Before these production steps, exercise the guard on a disposable Linux clone,
never on either serving node. The fixture must prove four state transitions:
boot-like/no-lease with no commit does not report READY, leaves the guard
failed with exit 77, prevents or masks FPM and does not restart; the prior
durable commit permits FPM and leaves the guard inactive/dead with success;
releasing an in-flight lease by both TERM and SIGKILL without a commit
automatically reaches exact masked/inactive/dead/masked FPM; a deliberately
SIGSTOP-hung receiver crosses the two-minute runtime ceiling and `ExecStopPost`
reaches that same exact isolation even though the lease remains held; and a
post-probe commit leaves the guard inactive/dead with success while FPM remains
enabled/loaded/active/running. The timeout case must also prove the nested
`systemctl mask --now`/stop transaction does not deadlock and completes within
`TimeoutStopSec=1min`. Also force the isolation command to fail and prove the
unit permits at most three starts per ten-minute window; separately prove a
fourth rapid successful/manual activation also fails closed until a reviewed
`reset-failed`. Record the
systemd journal and exact `systemctl show` properties for the generation-7
release evidence.

Because `Persistent=true` catches missed calendar runs, never replace this
first-install sequence with `systemctl enable --now`: with no prior stamp it can
immediately issue an unplanned generation after the foreground acceptance.
Read the timer twice and require `active/waiting`, an inactive sender, unchanged
generation counters and a `NextElapseUSecRealtime` in the next 03:30--03:41
Asia/Shanghai window. If an unexpected generation starts, stop only the timer;
do not interrupt a sender or receiver that has entered transfer or apply.

The two `0\n` initializations are one-time setup on fresh state only. The
generation files are part of the security boundary: never reset, delete,
roll back from a snapshot, or copy one node's file over the other. If a restore
leaves the primary's issued value at or below Singapore's accepted value, keep
the timer stopped and advance the primary state under change control to a value
strictly above the accepted state before generating a new signed batch. Gaps are
expected after failed exports or applies and must not be reused.

The fixed full/static Web-root verifier chain checks the live source tree for
regular files with link count greater than one, including under uploads, before
the sender stages anything. This check must remain on the source: rsync copies
a hard-linked source inode into an ordinary nlink=1 staging inode and therefore
cannot prove after staging that the source was safe.

The signed database member is never expanded with an unbounded `gunzip` shell
redirection. The receiver streams exactly one CRC-valid gzip member into a
root-only temporary inode, rejects trailing or concatenated data, caps the SQL
at 4 GiB, checks the 1 GiB free-space reserve before every write, and publishes
the completed `shuzijun-sync.sql` with an atomic no-replace hard link. This
preflight completes before the accepted-generation counter advances and before
uploads or the database are applied.

The sender applies the same fail-closed envelope before it issues a generation:
at most 100,000 payload files and 100,000 upload directories, 8 GiB per staged
file, 64 GiB for the signed batch, and 4 GiB for the uncompressed database
stream. It budgets the logical database before export, caps the gzip at 8 GiB,
and preserves at least 1 GiB plus the estimated candidate footprint on its
private temporary filesystem. The raw database is piped through the 4 GiB
limiter into gzip and a root-only atomic writer, so no uncompressed SQL file is
created. Uploads are copied with no-follow/nonblocking descriptors and per-read
reserve checks; a FIFO, socket, device, link, oversize file, or source inode that
changes while copied rejects the whole candidate. Only after these checks and
a fresh receiver attestation does the sender atomically advance
`highest-issued-generation` and sign the manifest.

Managed rollback archives are retained as exactly seven completed
`/var/backups/shuzijun-sync-v1-YYYYMMDD-HHMMSS` directories. Retention considers only
root:root 0700 directories on the `/var/backups` filesystem containing exactly
the three root:root 0600, nlink=1 regular files `wordpress.sql.gz`,
`wp-config.php`, and `backup.sha256`. Before final publication and again before
any retention deletion, the manifest must be exactly two ASCII lines in fixed
`wordpress.sql.gz`, `wp-config.php` order using GNU SHA-256's two-space format,
and both freshly calculated hashes must match. Any malformed or tampered
lookalike fails closed and is never removed. Stale receiver-owned hidden
candidates are also name-, type-,
owner-, mode- and device-checked before fd-safe removal. An interrupted hidden
candidate may additionally contain only a `.wordpress-sql-gz.<random>` regular
temporary file satisfying the same root:root 0600, nlink=1 and same-device
contract; this exception never applies to a completed backup. Any other hidden
child fails closed and is not removed. Before creating the
next archive, the receiver budgets twice the current logical database size plus
64 MiB (at least 128 MiB), preserves a 1 GiB disk reserve while streaming, and
caps the compressed archive at 8 GiB. The archive is built under a hidden
root-only directory and renamed into the retained namespace only after all
three files and their hashes are durable. The receiver fsyncs that publication
before revalidating every managed restore point. It atomically renames each
oldest excess entry to the dedicated hidden `.shuzijun-sync-v1-*.retiring`
namespace, fsyncs the parent, and only then removes it. A kill during removal
therefore leaves seven completed restore points plus a strict partial tombstone;
the next prepare validates its root-owned same-device directory and remaining
regular-file subset before retrying fd-safe cleanup. A failed export, manifest
validation or publication leaves the previous seven backups untouched; a crash
after publication can leave seven or more completed backups, and the next run
safely reconciles the excess without treating a partial deletion as a corrupt
completed backup.
The newly published backup is never selected for deletion, even if the wall
clock moved backwards. Historical `pre-sync-*` directories
belong to the legacy receiver: the v1 retention scanner does not inspect,
modify, remove or reject them. Their bytes still reduce `statvfs` free space and
therefore remain covered by the same pre-export and per-write disk gate.

The sender never consults user or system SSH configuration and never reads
default known-hosts databases. `/etc/shuzijun/sync-known-hosts` is the exact
root:root 0600, single-line ED25519 pin shipped with this release; its fixed
SHA-256 is checked before every connection, while `-F /dev/null`, explicit user
and global known-hosts paths, strict host-key checking and an ED25519-only host
key algorithm make the transport decision reproducible.

Never install the timer on Singapore and never call `sync-to-backup` directly.
If the foreground service sync or its post-sync standby smoke fails,
leave both the sync timer and `shuzijun-failover.timer` stopped. A timer run
that finds the lock busy fails visibly and does not start a second transfer;
operators finish a release with the explicit foreground sync above, so a
maintenance collision cannot postpone the release baseline until the next
03:30 run.

`verify-webroot-security` is the post-deployment guard for both production
nodes. It fails when common backup/config/database/private-key residue exists
under the document root, when any symbolic link or mixed-case PHP filename is
present, when a PHP file has any suffix appended after `.php`, when an
unexpected root-level PHP endpoint appears, when uploads contain executable or
per-directory config payloads, when code ownership is writable,
when the Nginx deny include is absent, when that include does not return 404 for
every direct `/wp-content/...php` request, or when the resulting Nginx
configuration is invalid. This ensures the MU-plugin's locked `vendor/` PHP is
reachable only through WordPress `/index.php`. Recovery copies must use a
root-only directory under `/var/backups` and must never be placed next to the
live site. The semantic checker is not discovered relative to the wrapper or
accepted from an argument. Install the reviewed files at their fixed paths:

```bash
sudo install -o root -g root -m 0755 \
  Server/operations/verify-nginx-server-block-contract.py \
  /usr/local/sbin/verify-nginx-server-block-contract.py
sudo install -o root -g root -m 0755 \
  Server/operations/verify-webroot-security \
  /usr/local/sbin/verify-shuzijun-webroot-security
```

`verify-shuzijun-webroot-security` pins the reviewed checker SHA-256 and accepts
only the canonical `/usr/local/sbin/verify-nginx-server-block-contract.py`
regular file with exact root:root 0755 metadata and link count one. `/usr`,
`/usr/local` and `/usr/local/sbin` must be canonical root-owned directories and
must not be writable by a non-root identity. The wrapper opens the checker,
revalidates metadata and the review hash through `/proc/self/fd`, then executes
that same inode with `/usr/bin/python3 -I`; symlinks, writable copies, hash
drift and path-replacement races fail before checker code runs. The release
deployer, authority-only bootstrap and standby seed apply the same fixed-path,
parent-chain, metadata, hash and open-FD execution contract to the wrapper
itself. The semantic active-config check remains local-only and therefore safe
to run during a release dry-run.

The legacy `/images/...` public URLs must be provided by the constrained
`shuzijun-legacy-images-alias.conf` include in both `www` and `img` TLS blocks,
not by a document-root symbolic link. Install the sensitive-file snippet first,
validate and reload Nginx, then install the alias include, validate it against a
known image and a denied `.php` probe, and only then remove the old `images`
symlink. Inside the legacy snippet the flat-image allowlist regex is immediately
followed by an ordered `^/images/` regex that returns 404. A normal prefix
fallback is not sufficient because later application regex locations can outrank
it. The Web-root verifier requires two alias includes and rejects any remaining
symlink, so a partial migration fails closed.

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
