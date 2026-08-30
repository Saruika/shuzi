# Hi，梳子平台架构 v2

决策日期：2026-08-31。状态：已确定方向，采用分阶段迁移；在新链路完成影子验证前，不切断 WordPress，也不迁移或删除线上原始媒体。

## 结论

粉丝端继续使用原生 SwiftUI，不改成以 WebView 为主体的网页壳。新的内容后台和官网采用 [Payload CMS](https://github.com/payloadcms/payload) 3、Next.js 与 PostgreSQL；照片和视频迁移到腾讯云 COS，并通过 CDN 分发。CMS 只负责编辑、权限、草稿和发布，App 不在每次打开时直接查询 CMS 数据库或 REST 列表。

每次正式发布内容时，发布任务生成一份小型、版本化、不可变的 `manifest.json`：

```text
管理员浏览器
      │
      ▼
Payload CMS + PostgreSQL ──发布──► 内容清单构建任务
      │                                  │
      └──照片 / 视频直传 COS             ├──► manifest.<version>.json
                                         └──► manifest.json（短缓存入口）
                                                        │
                                                        ▼
SwiftUI App ◄────────────── 腾讯云 CDN / COS ───────────┘
```

这样做把“内容编辑系统”和“用户读取链路”分开。即使后台正在升级或短暂不可用，已经发布的 App 内容仍可由 CDN 和本机三张预览缓存继续显示。

## 现状测量

- App 普通用户启动目前只读取一份自定义内容清单，不会逐张调用 WordPress API；旧的通用 `wp/v2` 相册回退代码已移除。
- 2026-08-31 实测清单为 20,690 字节，包含 8 个相册、58 张照片、5 张首页图和 1 张开屏图；上海访问首字节约 0.43 秒。
- 当前响应为 `private, no-store`，所以每次启动都会回源。真正占主要带宽的是图片与 HLS 视频，而不是这 20 KB JSON；单纯把 App 改成 WebView 不会降低媒体流量。
- 上海主节点为 4 vCPU / 3.7 GB 内存，备用节点为 2 vCPU / 3.7 GB 内存，当前均未安装 Node.js 或 Docker。生产 Payload 不与现有 WordPress、MySQL 强行混跑，先使用独立环境完成验证。

## 为什么选 Payload

调研时的 GitHub 数据如下。Star 只是成熟度信号，最终选择依据仍是功能匹配、许可证和维护成本。

| 方案 | GitHub 状态（2026-08-31） | 适配结论 |
| --- | --- | --- |
| [Payload](https://github.com/payloadcms/payload) | 44.5k Star，MIT，持续更新 | 推荐。Next.js 原生、类型安全、后台可深度定制；官方 [Website Template](https://github.com/payloadcms/payload/blob/main/templates/website/README.md) 已包含后台、权限、页面构建、草稿、实时预览、SEO、搜索、重定向和定时发布，最接近艺人作品站需求。 |
| [Strapi](https://github.com/strapi/strapi) | 73.0k Star，持续更新 | 成熟，但官网前端、发布清单和深度定制仍需另建工程，整体维护面更大。 |
| [Directus](https://github.com/directus/directus) | 37.7k Star，持续更新 | 无代码后台体验很好，但当前许可证不是 MIT，且仍需单独建设官网前端。可作为 Payload 试点失败时的备选。 |
| WordPress | 现网稳定 | 暂时保留为迁移源和回滚点；长期不再承担 App 的高频读取链路。 |

官网使用 Next.js，页面动效只在需要的地方采用 [Motion](https://github.com/motiondivision/motion)。Motion 为 MIT 许可证、约 33.4k Star，适合做克制的转场、滚动揭示和画廊动效。若以后要快速增加 Android 版本，可评估 [Capacitor](https://github.com/ionic-team/capacitor)，但它不替换当前 iOS 原生客户端。

## 为什么不把 iOS App 改成 WebView

- 现在已有 WeatherKit、原生视频、收藏、本地缓存、推送准备、iPad 自适应和截屏时的尽力保护；网页壳会重新实现这些能力，并增加网络依赖。
- 大图、相册手势、视频和页面切换在原生端更容易保持稳定帧率，也更容易针对 iPhone 与 iPad 分别排版。
- Apple 的 [App Review Guidelines 4.2](https://developer.apple.com/app-store/review/guidelines/) 要求 App 的功能、内容和界面明显超越“重新包装的网站”；把现有原生 App 改成普通 WebView 会增加审核风险。
- Web 技术非常适合管理员后台和官网。管理员可直接在 Safari、Chrome 或手机浏览器使用响应式 Payload 后台，不需要把完整后台塞进粉丝端 App。

## 内容模型

Payload 首期只建立当前确实在使用的模型：

1. `Users`：`admin`、`editor` 两级角色；只有管理员可以管理账号和最终发布。
2. `Media`：原图、展示图、尺寸、方向、替代文字、版权/肖像授权状态与内部备注。
3. `Albums`：名称、短文案、类型标签、封面、照片顺序、草稿/发布状态。
4. `Home`：首页轮播顺序和首页文案。
5. `LaunchPosters`：开屏图、文案、启停时间和展示秒数。
6. `About`：人物图、简介、合作方式和社交平台链接。
7. `Showreels` 与 `Credits`：视频、海报、角色、年份、跳转链接和排序。

所有正式内容启用版本、草稿和发布前预览。Payload 官方文档支持 [细粒度访问控制](https://payloadcms.com/docs/access-control/overview)、[版本恢复](https://payloadcms.com/docs/versions/overview)、[草稿](https://payloadcms.com/docs/versions/drafts) 与 [S3 存储适配器](https://payloadcms.com/docs/upload/storage-adapters)；腾讯云 COS 提供 S3 兼容接口，因此可以沿用官方存储适配器，但仍需在试点中验证签名、分片上传和图片处理。

## 分阶段实施

### 阶段 0：客户端解耦（本版本已开始）

- App 只理解 `AppContentManifest` 合同，不再解析 WordPress `portfolio` 或 `media` 类型。
- 网络失败时使用上次缓存或内置基础内容，不再向通用 WordPress REST 接口发起多次回退请求。
- 现有管理员发布功能和线上数据保持不变。

### 阶段 1：隔离试点

- 在独立目录和独立数据库中建立 Payload Website Template，不使用线上 WordPress 数据库。
- 实现上述七类内容、最小权限角色、上传限制、审计日志和中文后台标签。
- COS 使用单独的最小权限子账号；密钥只放服务器密钥存储，不进入 Git、App 或浏览器包。

### 阶段 2：只读迁移与双重校验

- 从 WordPress 导出 8 个相册、58 张已发布照片及所有页面配置。
- 按文件哈希去重，逐项校验照片数量、顺序、尺寸、版权字段和链接。
- 新后台只在预览域名开放，WordPress 仍是线上唯一写入源。

### 阶段 3：CDN 发布链路

- Payload 发布成功后生成带校验值的不可变清单和一个短缓存入口清单。
- App 先做影子读取：同时拉取新旧清单，只记录非敏感差异，不改变用户所见内容。
- 连续通过功能、性能、主备切换和安全验收后，再把 App 的公开读取地址切到 CDN。

### 阶段 4：切换与回滚窗口

- Payload 成为唯一编辑入口；WordPress 改成只读，至少保留 14 天。
- 若发生异常，只需把清单入口指回上一版本，不回滚媒体原文件。
- 稳定后再决定是否下线 WordPress，绝不在迁移当天删除旧库和上传目录。

## 上线门槛

- iPhone 与 iPad 全页面视觉回归通过，断网和弱网仍能进入 App。
- 新旧清单的相册数、照片数、顺序、开屏、首页、关于、视频与影视履历完全一致。
- 管理员、编辑者和未登录访问的权限测试全部通过；公开 API 不返回草稿、内部备注或账号信息。
- COS/CDN 配置 HTTPS、来源限制、合理缓存和日志脱敏。付费订阅重新启用前，必须增加服务端权益校验和短时签名媒体地址，不能依赖“隐藏 URL”。
- 数据库、COS 和发布清单均有可验证备份，并完成一次实际恢复演练。

