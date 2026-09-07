# 私有审核后台引导阶段

这不是公开部署完成，也不是 App Store 审核账号交付。用户已批准独立审核环境。
首次部署不复制正式 WordPress 数据库、配置、用户、媒体、SMTP 或 APNs 密钥。

## 固定边界

- `/srv/shuzijun-review/site`：独立核心与 App API，代码归 root；只有上传和临时目录允许 PHP 写入。
- `shuzijun-review`：独立不可交互登录的 Linux 身份，不属于 www-data。
- `shuzijun_review` 数据库/数据库用户：仅该库权限，没有全局权限或授权权限。
- `/etc/shuzijun-review`：专用配置；随机 bootstrap 密码只保存在服务器 root:root 0600 文件中。
- 单独 PHP 和 nginx 单元，不修改系统 PHP pool 或正式 nginx 配置，不重启正式服务。
- nginx 仅监听 `127.0.0.1:18089`。不是公网 HTTP 入口，不新增 DNS 或复用不匹配的正式证书。
- PHP 使用独立网络命名空间、仅 AF_UNIX，数据库经 Unix socket 连接；不可访问正式站点目录和推送密钥目录。
- 邮件直接返回 false，外部 WordPress HTTP 返回错误，WP-Cron 禁用。此阶段不具备真实邮件、Apple 登录/撤销或 APNs 投递能力。
- 读取既有 root 管理的 authority 标记，不修改该标记；独立数据库保证它不会与正式账号表混用。

## 新建步骤

使用 [WP-CLI 官方下载命令](https://developer.wordpress.org/cli/commands/core/download/)
取得固定版本 `7.1`、`en_US`、`--skip-content` 的独立核心；不得从正式站点复制。
官方空插件/主题目录中的三份 `Silence is golden` 文件可保留，任何真实内容或 `wp-config.php` 都拒绝。
原下载与复制后的代码分别执行 [官方校验和检查](https://developer.wordpress.org/cli/commands/core/verify-checksums/)。

在已授权的主节点，使用审核过的源码目录、独立核心目录和发布清单 SHA 调用：

```sh
sudo python3 Server/operations/provision-review-bootstrap.py \
  --source /absolute/path/to/reviewed/Server \
  --core /absolute/path/to/clean/core \
  --manifest <reviewed-plugin-manifest-sha256>
```

默认只读预检。确认预检后追加 `--apply`，只创建固定审核资源。若资源已经存在则拒绝，
不得反复重跑或清空目标规避检查。失败保留资源，按实际状态修复，不删除用户数据。
FPM 的配置检查在 systemd 建立 RuntimeDirectory 后以服务身份执行；启动后必须收到
真实 PHP `/fan/login` 路由的预期错误，单独 nginx 健康页或 `systemctl start` 成功不算就绪。
单元不设置开机启动，公开部署时另行确定持久运行、证书、备份和监控策略。

## 真实流程验收

```sh
sudo python3 Server/operations/accept-review-bootstrap.py --apply
```

只允许固定的本机审核端点和站点路径。建立一位明确标注的合成用户与临时 Application
Password，验证抖音必填、待审禁入、自批拒绝、正式审批、免费读取、管理员授予、旧版本冲突、
撤销立即生效，再通过用户侧 API 删号并检查旧令牌失效。临时管理凭据在 finally 撤销；
成功清理账号后删除该次私有恢复文件。失败恢复文件只留在 `/etc/shuzijun-review`，不输出或入 Git。

已验证的非敏感摘要保存为该目录的 `acceptance-<random>.json`。`bootstrap-private.json` 和
`acceptance-private-<random>.json` 含凭据，绝不能放进日志、Git、发布附件或邮件正文。

## 2026-09-07 实际结果与剩余事项

主节点已实际建立该私有实例。初次 FPM 启动因 journald 的 stderr 套接字不能按文件重新打开
而失败；修正为 RuntimeDirectory 日志后，实际 API 恢复，23 项真实流程检查连续两次通过，临时用户
和测试管理凭据已清理。正式 nginx/PHP/MySQL/同步 timer 仍 active，正式插件清单未变。

14 项本地部署边界/就绪测试通过；完整本地检查脚本通过，其中 7 项 Linux 专用测试在 Mac
跳过。本轮没有重新运行完整 iOS 矩阵，也没有声称最终引导脚本已在第二个全新实例重装验证。

仍需独立域名 HTTPS、授权演示素材、媒体上传/发布/删除验收、Apple 登录与撤销、独立推送和
邮件配置、持久运行监控、App 显式入口与持续演示标识，以及 Test1/Test2 最终交付。
不可为了展示可用而隐藏未完成业务，也不可对审核员身份提供不同业务逻辑。

## HTTPS 阶段（preview11，当前状态）

上段的“仍需 HTTPS”是引导阶段记录；现已新增 `review` A 记录与专用 nginx vhost，外网 HTTPS
和固定主机名校验通过，公开入口仅反向代理独立实例，不访问正式站点目录。
HTTP 的 ACME 路径用于证书验证，其余请求仅重定向到固定 HTTPS 域名；不接受 HTTP 登录/管理。

`deploy-edge.sh challenge /absolute/assets` 只接受不存在的审核 vhost；证书签发后执行
`deploy-edge.sh https /absolute/assets` 只接受精确匹配的 challenge 前置文件。
应用配置前取得既有站点维护锁，失败恢复本次审核 vhost；不覆盖其他域名配置，不重启 nginx。

证书通过 [Certbot webroot](https://eff-certbot.readthedocs.io/en/stable/using.html#webroot)
方式签发，专属 webroot 为 `/var/lib/shuzijun-review-acme`，证书 lineage 为
`/etc/letsencrypt/live/review.shuzijun.com.cn`。续期部署 hook 为 root:root 0755 的
`/usr/local/sbin/reload-shuzijun-review-certificate`，仅匹配该 lineage 时语法检查并 reload。
复用已启用的 `certbot.timer`；真实 dry-run 含部署 hook 已成功，不另建重复调度器。

HTTPS 入口加入 HSTS、no-store、noindex 等响应头，并覆盖访客自填的代理身份。
内部 realip 只信任回环连接；实际 PHP location 执行按访客计数的限流。
规则依据 [nginx realip 文档](https://nginx.org/en/docs/http/ngx_http_realip_module.html)，
通过 `check-review-proxy.py` 的 76 次回环接口无账号请求实际验证，不向公网执行压力测试。

`accept-review-bootstrap.py --apply --https` 使用 CA 验证与正确 SNI 的本机 HTTPS 连接验证
公开 vhost。23 项流程已通过，外网健康与 HTTP 跳转也单独通过；没有将本机 TLS 检查等同于
真实 iPhone/iPad 或 Apple 登录验收。独立服务已加入 multi-user.target 启动依赖。

当前仍为 `configuration-in-progress`：外部发信、Apple 与 APNs 主动阻断，媒体和最终账号
尚未交付。后台的 bootstrap-state.json 中 `publicReady=false` 指完整业务尚未就绪，不能被
解释为现在没有 HTTPS 端口；公开网络状态以本节与 preview11 发布记录为准。

## 媒体阶段（preview12，当前状态）

审核实例现已配置 8 张照片、2 本相册、5 张首页轮播图、3 张开屏海报及关于页照片。
素材仅取自已经选用的玉兰青衣、汉服灯影两套作品，人工视觉复核后固定原文件 SHA-256；
不复制用户数据库，不调用 AI，不做超分辨率修复，也不将照片复制到 Mac 或 App 包中。
WordPress 可按标准流程生成展示用缩略图，但上传原始 JPEG 必须保持字节一致。

`prepare-review-catalog.py` 默认只读校验固定来源、尺寸范围和哈希，以及审核相册为空。
在服务器受保护的代码目录中执行 `--apply` 才会取得专用互斥锁并写入独立审核库：

```sh
sudo python3 Server/operations/prepare-review-catalog.py
sudo python3 Server/operations/prepare-review-catalog.py --apply
```

脚本先通过正常注册和审批建立临时用户，再绑定 App 管理员角色，用实际 HTTPS 媒体上传、
相册与配置接口发布，不用数据库直写模拟上传成功。撤销角色后确认旧会话不能继续上传或修改，
但仍可完整浏览 8 张照片。仅本次新对象转交私有站点维护身份后，再通过用户侧接口删除临时用户。
失败只恢复本次配置和新对象；已有素材或完成回执存在时拒绝重跑，不清空相册。

非敏感 `catalog-seed-state.json` 包含原图哈希、媒体 ID、分组和配置；其中检查清单记录提交前
49 项，临时用户删除成功为提交后的第 50 项。临时私有文件与 Application Password 已清理。
不要输出 `catalog-private-*.json`；中断时先检查恢复记录，不直接重新运行。

生命周期验收已改为比较实际配置的审核相册，而不是假定空库；仍严格检查全部图片来自审核域名。
填充相册后真实 HTTPS 注册、审批、绑定/撤销、删号流程 78 项检查通过（其中包含逐 URL 隔离断言）。
本机 6 项素材边界测试与原有 18 项部署测试通过。

这只是媒体与账号接口验收。Test1/Test2 最终资料、App 显式入口和演示标识、Apple 登录/撤销、
独立推送与发信，以及完整 iPhone/iPad UI 验收仍未完成；健康状态继续标记配置中。
没有上传新的 TestFlight，也没有提交 App Store 审核。

## 账号阶段（preview23，当前状态）

用户确认 Test1 / Test2 作为展示名称，继续使用 HS 身份码登录。现已按正常注册、审批与
管理员绑定流程准备 `Test1（审核测试）`、`Test2（审核测试）`，分别为普通和 App 管理员。
实际新会话的 HS/密码登录、媒体域名隔离及管理权限区分通过；引导会话和临时维护访问码已清理。
最终凭据仅保存在 root:root 0600 的 `review-accounts-private.json`，不能输出或上传 GitHub。

`prepare-review-accounts.py` 默认只读；`--apply` 只允许首次创建，已有记录或同名账号拒绝重跑。
中断时先按私有恢复记录核查，不能删除记录绕过检查、重设密码或重复注册。
这两组账号尚未交给 Apple；当前 TestFlight 仍使用生产环境，尚不能直接使用它们登录。
Release 显式入口、最终 UI 及 Apple/APNs/邮件验证仍未完成，不能标记审核环境全面就绪。

## App 入口候选（preview24）

Release 源码已加入登录页/设置页的显式环境选择、切换确认、本机偏好及持续演示标识。
当前 TestFlight 及早先导出的 Build 4 包尚不包含这一入口。入口不会自动登录或跳过审批，
最终账号完整界面、管理员编辑与外部业务仍待验收；不要更改 `publicReady` 或提前交付给 Apple。

## 审核插件升级（preview26）

`upgrade-review-plugin.py` 默认仅做只读预检；`--apply` 限定从预期审核清单升级到
preview25 的 1.5.13.10 精确清单，只替换 3 个已核对插件文件。先保存私有备份，
按依赖顺序停止/启动审核 web 与 PHP，校验实际 PHP/API，不重启生产 nginx/MySQL。
失败时恢复原文件，遇到外部编辑则拒绝覆盖；不要重跑已成功升级的 baseline 操作。

2026-09-07 实际升级成功并独立回读确认。早先失败尝试已恢复原插件字节，但遗漏启动
依赖 PHP 的 web 服务，后续已手动恢复两服务，再修复工具并补回归。保留该失败记录，
不得把第一次尝试记为成功或自动回滚完整成功。详细备份位置和证据见 preview26 发布记录。
隔离配置、内容、最终 Test1/Test2 身份码/密码均未改动；邮件/Apple/APNs 仍阻断，
`publicReady` 仍为 false。当前 TestFlight 不因此自动获得新客户端协议。
