# 易姝 App 安全说明

## 已落地的保护

- 管理员使用可单独吊销的 WordPress Application Password，凭据仅保存在 iOS Keychain，并设为解锁后可用、不随备份迁移。
- 管理请求使用无持久缓存、无 Cookie、无 URL 凭据库的独立 HTTPS 会话，并拒绝跳转到非 `www.shuzijun.com.cn` 主机。
- Nginx 明确向 PHP 转发 `Authorization`；插件只在自有 REST 请求内校验专用 Application Password，并再次检查最小权限能力，不会接受普通 WordPress 用户。
- 上传文件限制为允许的图片/视频 MIME 类型、安全文件名和 60 MB 上限。
- 公开内容清单和媒体只接受 HTTPS 受信任域名，响应体超限或异常域名会被 App 拒绝。
- 完整图片 URL 仅在内存中保留，不会后台预下载整册照片；磁盘目录缓存使用 iOS 完整文件保护、从备份中排除，并将每册裁剪为 3 张离线预览。
- 录屏、投屏、App 失去活动状态时显示保护遮罩；Release 构建不包含调试解锁与视觉测试绕过。
- WordPress 保留最小权限内容角色，写接口按用户限流，并限制图片所有权、媒体类型、数量、文本长度和媒体域名。
- TestFlight 测试阶段 App 内容清单返回全部已发布照片，但官网作品页、附件页及 WordPress 作品/媒体 REST 列表仍返回 404；完整目录不写入磁盘缓存，离线缓存每册只保留 3 张预览。
- 天气功能只在用户主动开启后请求前台位置，定位精度设为约三公里；位置不持久化，也不进行后台定位。天气由 Apple WeatherKit 处理，工程包含 WeatherKit entitlement、法定署名入口与 Privacy Manifest。

## 恢复付费订阅前必须完成

当前 TestFlight 版本主动向 App 提供完整相册，因此不构成付费内容安全边界。恢复收费前必须重新启用公开预览清单，并完成以下链路：

1. 在 App Store Connect 创建月度订阅并补齐 App Apple ID。
2. 启用 `Server/entitlement-verifier`，用 Apple App Store Server Library 校验签名、Bundle ID、商品 ID、到期时间和撤销状态。
3. 将付费原图迁移到私有对象存储；公开接口只保留 3 张预览，校验通过后返回数分钟有效的 CDN 签名地址。
4. CDN 禁止绕过签名直连私有原图并配置 WAF 限流。
5. 处理 App Store Server Notifications V2，使退款、撤销和订阅到期及时失效。

上述私有存储与签名 URL 是当前 P0 遗留项。在它完成前，不应将“无法下载原图”作为绝对安全承诺。

## 截屏保护边界

iOS 对普通静态图片没有向第三方 App 开放与 Netflix 视频 DRM 等价的官方接口。现有实现会尽量使系统截图/录屏呈现黑色保护页，但它属于尽力保护，无法阻止另一台设备拍屏。受 DRM 保护的视频应使用 HLS + FairPlay Streaming，而不是把该机制延伸为静态照片承诺。

## 密钥与应急处置

- 仓库不得提交 `.env`、`.p8`、`.p12`、描述文件、私钥或管理员访问码。
- 任何曾发送到聊天、截图或日志中的长期云 API 密钥，即使当时是私密环境，也应在云控制台轮换并改为最小权限子账号。
- iPhone/iPad 丢失时，先在 WordPress 中吊销该设备的 Application Password，再创建新凭据。
- 发布服务端插件时应保留旧版备份，运行 PHP 语法检查，再验证公开读取、未登录写入拒绝和管理员写入三类用例。
