# Hi，梳子 iOS

“Hi，梳子”是易姝的原生 iPhone / iPad 艺人作品 App，用于展示摄影作品、演员 Showreel、影视履历与合作信息。客户端使用 SwiftUI 实现，内容由 WordPress 版本化 REST API 同步，不是 WebView 封装。

> 当前版本：`1.3.1 (11)` · 最低系统：iOS 17 · Bundle ID：`cn.com.shuzijun.yishu`

## 产品功能

- **首页**：人物主视觉轮播、身份表达和作品入口；可按需通过 Apple WeatherKit 显示当地天气。
- **作品**：按造型和拍摄主题分类的原生相册，支持搜索、收藏、最近浏览和下拉刷新。
- **影视**：内嵌 Showreel 与公开影视履历，支持静音和暂停，不弹出系统全屏播放器。
- **收藏**：作品收藏保存在本机，授权暂时失效时也不删除用户的收藏记录。
- **关于**：艺人简介、社交平台、合作邀约和管理员入口。
- **内容工作台**：管理员可在 App 内更新首页封面、相册、视频和影视资料。

## 作品访问规则

| 身份 | 可见内容 | 获取方式 |
| --- | --- | --- |
| 普通用户 | 全部已发布作品 | App 专用内容清单 |
| 管理员 | 全部作品与内容编辑 | WordPress Application Password |

TestFlight 测试阶段已暂停付费订阅，App 全量展示已发布相册。完整在线清单只在运行时使用，磁盘目录缓存仍只保留每册 3 张离线预览。官网作品页、附件页及通用 WordPress 媒体接口继续关闭，管理员编辑能力保持独立鉴权。

## 技术结构

```text
iOS App (SwiftUI / WeatherKit / AVKit)
        │
        ├─ 完整展示── WordPress App REST API
        └─ 管理员─── Application Password + 最小权限角色
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
- [`Server/nginx/README.md`](Server/nginx/README.md)：REST 认证头转发配置。
- [`Server/operations/README.md`](Server/operations/README.md)：线上运维修复记录。

## 安全与隐私

- 管理员凭据仅保存在 iOS Keychain，不随备份迁移。
- 完整图片 URL 仅在运行时内存中使用，磁盘目录缓存每册只保留 3 张离线预览，不后台预取整册照片。
- 录屏、投屏或 App 失去活动状态时会显示黑色保护遮罩。
- 位置仅在用户主动启用天气时请求；定位管理器采用约三公里精度，不持久化位置，也不在后台持续定位。天气由 Apple WeatherKit 提供，并在“关于”页展示 Apple 要求的数据来源与许可入口。
- 仓库忽略 `.env`、Apple 私钥、证书、描述文件和本地构建产物。
- App 明示照片与影像均已取得合法展示授权；相关版权和肖像权归各自权利人所有，未经许可不得下载、复制、传播、改编或商业使用。

截图保护是 iOS 系统能力限制下的尽力防护，无法阻止另一台设备拍摄屏幕；已公开过的 WordPress 原图在迁移到私有对象存储前，也不能承诺绝对无法下载。完整安全边界和上线前 P0 清单见 [`SECURITY.md`](SECURITY.md)。

## v1.3.1

- App 对外名称更新为“Hi，梳子”，保留“易姝”作为艺人姓名与作品署名。
- TestFlight 阶段暂停订阅入口并全量开放 8 个相册的 58 张已发布照片。
- 更换“关于”页人物照，修复 iPad 分栏中人物图区未顶部对齐的问题。
- 优化首页天气组件的动态宽度，并将截屏保护说明统一为“此 APP 不支持截屏、录屏或保存”。

## v1.3.0

- 将第三方天气接口迁移到 Apple WeatherKit，使用系统天气图标、摄氏温度和中文天气状态。
- 增加 WeatherKit entitlement、Apple Weather 法定署名及对应位置隐私说明。
- 更新自动签名配置、出口合规声明和发布版本号；真机发布前需由 Apple 为 App ID 重新生成包含 WeatherKit 权限的描述文件。

## v1.2.1

- 移除尚未正式上线的粉丝社区、互动、粉丝信、自动平台同步与推送代码。
- 恢复「首页 / 作品 / 影视 / 收藏 / 关于」的精简导航。
- 保留「狐狸姐姐温馨提示」截屏保护页和关于页精简调整。

## v1.1.0

- 公开相册收紧为每册 3 张预览，完整内容改用授权接口。
- 管理员登录后可加载全量作品，授权失效后自动清除受保护缓存。
- 增加 StoreKit 2 凭证传递、Apple 服务端校验框架和私有存储上线清单。
- 收紧 WordPress 公开页面与 REST API，加强上传校验、授权头传递和缓存策略。
- 旗袍主题文案更新为“庭院、窗影与东方美学”。

## 更多文档

产品对标与后续路线见 [`PRODUCT_RESEARCH.md`](PRODUCT_RESEARCH.md)。安全问题可按 [`SECURITY.md`](SECURITY.md) 中的流程进行报告。
