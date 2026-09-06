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
