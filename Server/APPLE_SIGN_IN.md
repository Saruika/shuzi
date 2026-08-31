# Sign in with Apple 服务端运行手册

Build 34 使用 WordPress REST API 的状态型 Apple 登录流程。本文只记录部署契约，不记录任何 Team ID、Key ID、私钥、client secret、authorization code 或 token。

## 依赖与配置

- 必须把 `shuzijun-app-content.php`、`composer.json`、`composer.lock` 和完整 `vendor/` 作为一个原子发布单元。`firebase/php-jwt` 必须严格锁定为 `7.1.0`，发布前执行 `composer audit --locked --no-dev`。
- PHP 需为 8.3，并开启 OpenSSL 与 Sodium。
- 在 WordPress 运行配置（不在仓库）定义 `YISHU_APPLE_TEAM_ID`、`YISHU_APPLE_KEY_ID`、`YISHU_APPLE_PRIVATE_KEY_PATH` 和 `YISHU_APPLE_DATA_KEY_PATH`。两个密钥路径都必须在 `ABSPATH` 之外，由 PHP worker 可读，权限不得宽于 `0400`/`0600`，且不得被同组或其他用户读取。`YISHU_APPLE_DATA_KEY_PATH` 指向一个仅含 32 字节高熵密钥的 43 位 base64url 文本文件（无 `=` 填充），用于派生版本化 subject HMAC 和 refresh-token 加密密钥。
- Apple 数据密钥必须跨发布、主备节点和 WordPress salts 轮换保持稳定。不得与 `AUTH_KEY`/`SECURE_AUTH_KEY` 等 WordPress salts 绑定。需要轮换时必须先实施可读旧 key/写新 key 的版本化 key ring 和数据迁移；本版未实施 key ring，因此不可直接替换文件内容。
- Apple Developer 中 App ID `cn.com.shuzijun.yishu` 需开启 Sign in with Apple；服务端通知 URL 指向 `POST /wp-json/shuzijun/v1/fan/apple-notifications`。
- `YISHU_APPLE_TEST_MODE` 仅允许在 `WP_ENVIRONMENT_TYPE=local|development` 时启用，生产绝不定义该常量。

## 发布与拓扑

1. CI 先执行 `php -l shuzijun-app-content.php`、`php tests/plugin-contract-test.php` 和 Composer 锁定依赖审计。两台生产节点还必须预装受信任的 Composer，并按 `operations/README.md` 预建 root-only staging/backup 边界、收紧站点代码所有权。生产使用 `operations/deploy-app-content-release`，先以不创建锁文件/备份、不调用本机业务 API 的 `--dry-run` 检查 Web 根目录外的固定发布单元和可信清单哈希；dry-run 的 Composer 漏洞审计仍会访问上游安全公告源。检查通过后再显式 `--apply`；apply 在 FPM 停止状态下以 `www-data` 身份验证实际安装后的 JWT autoload。不要使用整站数据库/媒体同步脚本代替代码发布器。
2. 主、备节点都要安装相同哈希的插件与 vendor，但只有上海主节点是账号写入权威节点。新加坡备节点的 Nginx 必须继续把整个 `/wp-json/shuzijun/v1/` 代理至主节点，不能本地生成 Apple challenge 或账号。
3. 发布后验证 Composer autoload、Apple JWKS 网络访问、`GET_LOCK`/`RELEASE_LOCK`、WP-Cron 以及 challenge/撤销队列的单次调度。
4. 执行 `tests/fan-api-smoke.sh`。它会验证 challenge 只保存 nonce/state/install 哈希、失败关闭和重放拒绝，不需要或打印真实 Apple 凭据。真实 Apple 登录与删号应再使用专用测试 Apple ID 从 TestFlight 完成手工验收。

## 失败边界与监控

- JWKS 不可用时，只可在非强制刷新且上次已验证的 key set 不超过 24 小时时回退；未知 `kid` 强制刷新失败必须关闭。
- Apple `/auth/token` 交换、RS256 验签或 nonce/state/install 任一校验失败都不得创建或绑定账号。不要按邮箱、姓名、抖音 ID 或客户端上报的 Apple user identifier 合并账号。
- 用户完成新 Apple 授权删号，或服务收到已验签的 `consent-revoked` / `account-deleted` 后，必须在 subject 锁内先保存只含 HMAC subject 索引、删除/事件时间、过期时间和随机世代的 30 天 tombstone，再删除账号。已在等待锁的旧凭据 `iat <= event_time` 不得复活账号；该时间之后签发的真正新 Apple 授权可重新申请，但 tombstone 仍保留到 TTL 结束，以继续拦截迟到的旧请求。
- Apple S2S 验签成功后先把最小的 HMAC subject/事件时间写入 durable pending inbox，再向 Apple 确认接收。后台处理遇到 subject 锁忙或暂时错误时指数退避重试；`init` cursor sweeper 修复丢失的 Cron 调度。成功后立即删除 inbox 中的 subject/事件明细，仅保留 30 天无法回链的 processed marker 防重放。
- 删号会先尝试 Apple `/auth/revoke`；暂时失败后仍立即删除本地账号，仅把加密 refresh token 与计时/重试数据写入无法回链用户的队列。队列最多重试 8 次、最长 7 天，成功或超期即删除。
- 日志和安全审计仅记录事件类型与时间。严禁记录 identity token、authorization code、refresh token、Apple subject、challenge nonce/state、client secret 或私钥内容。

## 回滚

回滚必须同时回滚插件、Composer 元数据和 `vendor/`，不可留下版本不匹配的 autoload。独立发布器会在失败时只恢复这个代码单元并恢复 FPM；它绝不回滚数据库、`wp-config.php`、uploads 或外部 Apple 密钥。回滚不能恢复已删除的用户、已消费 challenge 或已撤销会话。如旧版无法安全识别 Apple 账号元数据，应关闭 Apple 入口并保持现有账号读写失败关闭，而不是清除已绑定的数据。
