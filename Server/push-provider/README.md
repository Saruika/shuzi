# APNs 推送服务

该服务只监听 `127.0.0.1:8752`，接收 WordPress 转发的设备登记和已去重的社交平台事件。APNs `.p8` 私钥、内部令牌和设备加密密钥只保存在 root 管理的环境文件中，不进入 Git 或 WordPress。

上线步骤：

1. 在 Apple Developer 为 `cn.com.shuzijun.yishu` 开启 Push Notifications，创建 APNs Key 并下载一次性的 `.p8` 文件；
2. 创建无登录权限的 `yishu-push` 系统用户以及 `/var/lib/yishu-push`，权限设为仅该用户可读写；
3. 安装 `requirements.txt`，复制 systemd unit，并用 `openssl rand -base64 32` 生成设备加密密钥；
4. 把 `.p8` 和 `/etc/yishu/push-provider.env` 设为 `root:yishu-push`、权限 `0640`；
5. 启动服务并确认 `http://127.0.0.1:8752/healthz` 返回 `ok: true`；
6. 在 `wp-config.php` 定义 `YISHU_PUSH_PROVIDER_URL` 与 `YISHU_PUSH_PROVIDER_TOKEN`，分别指向 `http://127.0.0.1:8752` 和同一个内部令牌。

设备令牌使用 AES-256-GCM 加密存入本机 SQLite；查重只使用 HMAC 摘要。事件 ID 在数据库中设为唯一键，即使 WordPress 定时任务重试也不会重复推送。Apple 返回 `Unregistered`、`BadDeviceToken` 或主题不匹配时会停用对应令牌。
