# 易姝 iOS

易姝的原生 iPhone / iPad 艺人作品 App，用于展示摄影作品、演员 Showreel、影视履历与合作信息。客户端使用 SwiftUI 实现，内容由 WordPress 版本化 REST API 同步，不是 WebView 封装。

> 当前版本：`1.2.0 (3)` · 最低系统：iOS 17 · Bundle ID：`cn.com.shuzijun.yishu`

## 产品功能

- **首页**：人物主视觉轮播、身份表达和作品入口；可按需显示当地天气。
- **作品**：按造型和拍摄主题分类的原生相册，支持搜索、收藏、最近浏览和下拉刷新。
- **影视**：内嵌 Showreel 与公开影视履历，支持静音和暂停，不弹出系统全屏播放器。
- **动态**：易姝动态、平台新作品、直播提醒、固定回应、投票与私密粉丝信。
- **我的**：收藏、通知偏好、艺人简介、社交平台、合作邀约和管理员入口。
- **内容工作台**：管理员可在 App 内更新首页封面、相册、视频和影视资料。

## 作品访问规则

| 身份 | 可见内容 | 获取方式 |
| --- | --- | --- |
| 普通用户 | 每个相册前 3 张 | 公开预览清单 |
| 订阅用户 | 全部作品 | StoreKit 2 签名交易经服务端验证 |
| 管理员 | 全部作品与内容编辑 | WordPress Application Password |

公开清单只返回每个相册的 3 张预览图。完整清单只保存在内存，不写入持久化目录缓存；授权失效后，App 会立即清除受保护 URL 和图片缓存。当前线上已启用公开预览限制和管理员访问；正式收费前还需完成 App Store Connect 商品、Apple 凭证校验服务与私有对象存储。

## 技术结构

```text
iOS App (SwiftUI / StoreKit 2 / AVKit)
        │
        ├─ 公开预览── WordPress REST API
        ├─ 管理员─── Application Password + 最小权限角色
        └─ 订阅解锁── StoreKit JWS → Entitlement Verifier → 受保护清单
```

项目中不包含云 API 密钥、Apple 私钥、WordPress 管理员密码或签名证书。

## 本地运行

需要 Xcode 17 或兼容 iOS 17 SDK 的新版本 Xcode。

1. 克隆仓库：`git clone git@github.com:Saruika/shuzi.git`
2. 打开 `Yishu.xcodeproj`。
3. 选择 iPhone / iPad 模拟器或已加入开发团队的真机。
4. 运行 `Yishu` Scheme。

命令行验证：

```bash
xcodebuild -project Yishu.xcodeproj \
  -scheme Yishu \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build
```

## 内容与服务端

- [`ADMIN_CONTENT.md`](ADMIN_CONTENT.md)：管理员入口、上传约束与内容发布流程。
- [`SUBSCRIPTION_SETUP.md`](SUBSCRIPTION_SETUP.md)：人民币 3 元/月订阅商品、Sandbox 和 TestFlight 验收步骤。
- [`Server/entitlement-verifier/README.md`](Server/entitlement-verifier/README.md)：Apple 订阅凭证校验服务。
- [`FAN_COMMUNITY_PLAN.md`](FAN_COMMUNITY_PLAN.md)：粉丝互动、角色、审核与自动平台提醒方案。
- [`Server/push-provider/README.md`](Server/push-provider/README.md)：APNs 设备登记与幂等推送服务。
- [`Server/nginx/README.md`](Server/nginx/README.md)：REST 认证头转发配置。
- [`Server/operations/README.md`](Server/operations/README.md)：线上运维修复记录。

社交平台提醒不是由管理员重复手工发送。WordPress 定时同步器优先使用平台官方 API 或 Webhook：抖音使用创作者授权后的官方 `video.list` 接口；小红书和直播使用经过 HMAC 签名的合规数据适配器。新作品 ID 与直播场次 ID 都持久去重，数据源第一次接入只建立基线，不会把历史作品一次性推送给用户。

正式启用推送前仍需在 Apple Developer 开启 Push Notifications、配置 APNs Key，并完成抖音创作者 OAuth 与 `video.list` 权限申请。小红书官方当前尚未开放 `read_notes`，因此项目不会用绕过登录、验证码或反爬机制的抓取代替授权接口。

## 安全与隐私

- 管理员凭据仅保存在 iOS Keychain，不随备份迁移。
- 图片 URL 缓存仅使用内存，未授权用户不预取锁定内容。
- 录屏、投屏或 App 失去活动状态时会显示黑色保护遮罩。
- 位置仅在用户主动启用天气时请求，坐标会在设备上降低精度且不在后台持续定位。
- 仓库忽略 `.env`、Apple 私钥、证书、描述文件和本地构建产物。
- App 明示照片与影像均已取得合法展示授权；相关版权和肖像权归各自权利人所有，未经许可不得下载、复制、传播、改编或商业使用。

截图保护是 iOS 系统能力限制下的尽力防护，无法阻止另一台设备拍摄屏幕；已公开过的 WordPress 原图在迁移到私有对象存储前，也不能承诺绝对无法下载。完整安全边界和上线前 P0 清单见 [`SECURITY.md`](SECURITY.md)。

## v1.2.0

- 新增「动态」与「我的」栏目，支持固定回应、投票、私密粉丝信和分类通知偏好。
- 新增抖音作品、小红书作品与直播状态的服务端自动识别、去重和 APNs 推送链路。
- 新增狐狸姐姐粉丝互动工作台，可查看数据源健康、发布动态与投票、处理粉丝信和审核规则。
- 推送设备令牌使用 AES-256-GCM 加密，自动同步使用平台官方 API/Webhook 或 HMAC 签名适配器。
- 截屏保护页标题更新为「狐狸姐姐温馨提示」，并移除关于页的官网入口。

## v1.1.0

- 公开相册收紧为每册 3 张预览，完整内容改用授权接口。
- 管理员登录后可加载全量作品，授权失效后自动清除受保护缓存。
- 增加 StoreKit 2 凭证传递、Apple 服务端校验框架和私有存储上线清单。
- 收紧 WordPress 公开页面与 REST API，加强上传校验、授权头传递和缓存策略。
- 旗袍主题文案更新为“庭院、窗影与东方美学”。

## 更多文档

产品对标与后续路线见 [`PRODUCT_RESEARCH.md`](PRODUCT_RESEARCH.md)。安全问题可按 [`SECURITY.md`](SECURITY.md) 中的流程进行报告。
