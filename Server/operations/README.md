# Server operation fixes

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
不会替换 1.5.7 PHP、删除已核验的支持子集或停止 FPM。Bootstrap 成功后立即
执行下方普通发布器 dry-run/apply，不要把它当作日常升级命令重复使用。

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

典型调用如下；SHA-256 是非敏感的发布校验值，不能替换成现场重新计算后
未经核对的值。备节点先用 `standby` dry-run/apply，上海节点再用
`authority` dry-run/apply：

```bash
sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <CI 记录的 release.sha256 哈希> \
  --authority-role standby \
  --dry-run

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <同一个已核对哈希> \
  --authority-role standby \
  --apply

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <同一个已核对哈希> \
  --authority-role authority \
  --dry-run

sudo /usr/local/sbin/deploy-app-content-release \
  --bundle /var/lib/shuzijun-app-content/releases/v1.3.23-build34.2 \
  --manifest-sha256 <同一个已核对哈希> \
  --authority-role authority \
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

`sync-to-backup` and `apply-shuzijun-sync` form one pinned v3 protocol. The
sender first proves its local marker is `authority`, attests the remote receiver
against the exact SHA-256 compiled into the sender, and requires the exact
`shuzijun-sync-receiver-v3-signed-uploads-only` protocol response before it
issues a generation or creates an export. Install and attest the receiver first;
an older receiver is not backward compatible and must never be invoked as a
fallback.

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
trailing byte or missing database is rejected. The sender's staging rsync
independently excludes pure/mixed-case PHP and ends with an uploads-only include
followed by a catch-all exclude; the receiver's rsync has fixed uploads-only
source and destination roots, so its `--delete` cannot reach code or config.
`verify-webroot-security` separately rejects PHP, PHTML, PHAR, script and
per-directory config payloads already present in uploads, so
whole-site sync cannot become a second code-release path; only
`deploy-app-content-release` may replace executable code.

The receiver acquires the shared site-directory lock and proves `standby`
before protocol negotiation, before reading a batch and again immediately
before restart. It requires both local query-form REST routes to return
503/`yishu_account_authority_unavailable` before any root claim, backup or
database/media write. After importing it flushes the persistent cache, reloads
Nginx, restarts FPM and repeats both standby probes. A failed post-sync probe
must both stop and persistently mask `php8.3-fpm`, then prove exact
`masked`/`inactive`/`dead` state; failure to prove isolation is a critical manual
incident rather than a swallowed cleanup error. Pre-sync database/config backups
are root-only and fsynced; the App release unit and all other code remain
`root:www-data` and non-writable.

SSH is not a general standby login. The sender connects only as the dedicated,
password-locked `shuzijun-sync-transport` account with pinned host-key checking.
Its root-owned authorized key uses `restrict`, the reviewed sshd Match block
forces `shuzijun-sync-ssh-gate`, and that gate accepts only the exact receiver
`--attest`, `--protocol` and `--ingest` commands. The matching sudoers file grants
only those three root commands. Remove any prior sync-key access for `ubuntu` and
any broad `NOPASSWD: ALL`; otherwise the transport boundary is not installed.

`shuzijun-sync.service` and `shuzijun-sync.timer` are installed only on the
Shanghai primary. The timer runs once per day at 03:30 Asia/Shanghai with up
to ten minutes of jitter; `Persistent=true` catches one missed run after a
reboot without creating a high-frequency database/config backup stream. The
oneshot service has a 45-minute deadline, uses low CPU/I/O priority and first
requires MySQL, Nginx and PHP-FPM to be active. It must run as root because the
sender reads the root-only pinned SSH key, invokes the root-owned verifier and
exports WordPress through WP-CLI. Its systemd sandbox removes all capabilities,
makes the system and primary Web root read-only, keeps `/root` read-only, gives
it a private temporary directory, and permits writes only below `/run` and
`/var/log` plus the root-only generation state below `/var/lib/shuzijun-sync` on
the primary. The only remote write path remains the reviewed receiver reached
through pinned SSH host-key verification.

Every scheduled or manual sender invocation must take
`/run/shuzijun-sync.lock`. Before a two-node release, stop the timer first and
do not interrupt a receiver/sender that is already applying a database dump:

```bash
systemctl stop shuzijun-sync.timer
if systemctl is-active --quiet shuzijun-sync.service; then
  echo 'sync still active; wait for it to finish before deployment' >&2
  exit 1
fi
```

After both nodes pass their release manifests and smoke tests, install the
current receiver on Singapore first. Then install the sender and versioned
units on Shanghai, validate the units, perform one foreground locked sync, and
only then enable the persistent timer:

```bash
# Singapore standby, first:
install -d -o root -g root -m 0700 /var/lib/shuzijun-sync
install -d -o root -g root -m 0700 \
  /var/lib/shuzijun-sync/incoming \
  /var/lib/shuzijun-sync/state
install -o root -g root -m 0600 /dev/null \
  /var/lib/shuzijun-sync/state/highest-accepted-generation
printf '0\n' > /var/lib/shuzijun-sync/state/highest-accepted-generation
# Each line is: shuzijun-sync <reviewed public key corresponding to the
# primary's /root/.ssh/shuzijun_sync_ed25519>. Never place a private key here.
install -o root -g root -m 0644 <reviewed-allowed-signers-file> \
  /etc/shuzijun/sync-signers
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
systemctl reload ssh
sha256sum /usr/local/sbin/apply-shuzijun-sync
sudo /usr/local/sbin/apply-shuzijun-sync --protocol

# Compare the printed SHA-256 and protocol with REMOTE_RECEIVER_SHA256 and
# SYNC_PROTOCOL in the reviewed sender source, then install Shanghai second:
install -d -o root -g root -m 0700 /var/lib/shuzijun-sync
install -o root -g root -m 0600 /dev/null \
  /var/lib/shuzijun-sync/highest-issued-generation
printf '0\n' > /var/lib/shuzijun-sync/highest-issued-generation
install -o root -g root -m 0755 Server/operations/sync-to-backup \
  /usr/local/sbin/sync-to-backup
install -o root -g root -m 0644 Server/operations/shuzijun-sync.service \
  /etc/systemd/system/shuzijun-sync.service
install -o root -g root -m 0644 Server/operations/shuzijun-sync.timer \
  /etc/systemd/system/shuzijun-sync.timer
systemd-analyze verify /etc/systemd/system/shuzijun-sync.service \
  /etc/systemd/system/shuzijun-sync.timer
systemctl daemon-reload
/usr/bin/flock -n /run/shuzijun-sync.lock \
  /usr/local/sbin/sync-to-backup
systemctl enable --now shuzijun-sync.timer
systemctl is-enabled --quiet shuzijun-sync.timer
systemctl is-active --quiet shuzijun-sync.timer
```

The two `0\n` initializations are one-time setup on fresh state only. The
generation files are part of the security boundary: never reset, delete,
roll back from a snapshot, or copy one node's file over the other. If a restore
leaves the primary's issued value at or below Singapore's accepted value, keep
the timer stopped and advance the primary state under change control to a value
strictly above the accepted state before generating a new signed batch. Gaps are
expected after failed exports or applies and must not be reused.

Never install the timer on Singapore and never call `sync-to-backup` directly
without `flock`. If the foreground sync or its post-sync standby smoke fails,
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
