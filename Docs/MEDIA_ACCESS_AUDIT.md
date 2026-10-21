# 媒体访问权限核查

核查日期：2026-10-21（Asia/Hong_Kong）。源码基线：
`50124bb11e45f2e40fe2e792d28de218c6c3bf4d`。这是源码审阅、历史证据核对及匿名只读
检查记录，不是完整渗透测试或线上安全认证。本次没有修改服务器、账号状态或媒体文件。

## 结论

审批专区的目录有服务端账号鉴权、状态核验和细分权限控制；独立公开精选不复用会员目录。
但客户端收到的图片和 Showreel 使用独立媒体 URL，代码没有为每次媒体读取附带账号权限。
接口门禁、客户端内存清理及截图保护，不能替代媒体源站／CDN 的访问控制。

历史公开体验回执已明确指出“撤回目录不等于撤回已经收到的静态 URL”。本次经本机
配置的网络代理取得线上响应：匿名会员目录被拒绝，公开精选可读；一个已知非预览尺寸
照片及 Showreel 主清单匿名 HEAD 均为 200。后两项的结果只证明这些文件响应匿名请求，
不外推为所有媒体均可访问，也不代表视频分片已验证可播放。未读取媒体正文。
原始状态见 [匿名检查结果](media-access-observation-20261021.json)，样本 URL 仅保留哈希。
该轮完成于 2026-10-21 15:21:37（UTC+8），12 项匿名预期检查通过、2 项媒体样本
记为 finding，因此工具按设计以非零状态结束，不代表脚本异常。

## 逐段追踪

| 链路 | 源码与已确认逻辑 | 验证边界 |
| --- | --- | --- |
| 注册／Apple 登录 | `trait-shuzijun-app-fan-identity.php`、`trait-shuzijun-app-fan-endpoints.php`：服务端会话、安装绑定、nonce/state、账号资料与审批独立处理 | 已读源码；本次未创建真实账号或进行 Apple 授权 |
| 审批专区入口 | `RootView.swift`：未获批者进入 `PublicExperienceView`；获批后才准备会员内容 | 源码确认；未执行 iOS UI |
| 会员内容清单 | API 类为 `/app-content` 注册 `can_access_app_content`；fan endpoints 检查 normal scope、资料、抖音 ID、active 状态，并读取当前权限 | 本次匿名 GET 401；无效 Bearer 使用随机合法 UUID 安装 ID 复测；具体状态见 JSON；未进行真实账号操作 |
| 内容范围 | content delivery 的 `manifest()` 按 `gallery_full` 与 `video_view` 限制完整相册和视频；viewer 不会因获得相册权限变为 administrator | 静态审阅；未动态模拟真实账号的权限变化 |
| 独立公开精选 | public-experience trait 仅输出手动选片；640–1600px 非裁剪派生图，无原图回退；隐藏／草稿／无效图片不输出；no-store | 现有 PHP 合同测试可复现；本机无 PHP，未执行 |
| 图片请求 | `ArtworkImage.swift` 创建独立 `URLRequest`，设置 Accept／User-Agent，不附加会员 Bearer；校验域名、响应、大小等；仅内存保留图片 | 六个公开派生图及一个非预览尺寸照片匿名 HEAD 为 200；后者响应为 image/jpeg；未读取服务器／CDN 配置 |
| 视频请求 | `CreditsView.swift` 使用 `AVPlayer(url:)`；`Portfolio.swift` 包含静态 HLS 地址，未见此处注入账号鉴权 | 已知主清单匿名 HEAD 为 200，类型 application/vnd.apple.mpegurl；子清单、分片与密钥未请求 |
| 撤权／暂停／退出 | RootView 监听权限、账号状态、Apple 撤销；PortfolioStore 缩减范围／清理目录缓存，根界面重置时取消图片缓存 | 本次退出与 Apple 生命周期合同检查通过；真实服务端撤权、正在播放视频、已发出下载仍待动态验收 |
| 目录之外的入口 | WordPress portfolio／media REST 和附件页有隐藏／拒绝逻辑；Nginx 仍有独立静态媒体与 legacy images 路由 | 本次 WordPress media／portfolio 列表匿名 GET 均为 404；未单独核验附件页和源站路由 |

源码路径均以基线为准：

- [服务端路由](../Server/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php)
- [账号与内容门禁](../Server/vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php)
- [内容清单与分权](../Server/vendor/shuzijun/app-content/trait-shuzijun-app-content-delivery.php)
- [公开精选](../Server/vendor/shuzijun/app-content/trait-shuzijun-app-public-experience.php)
- [图片加载](../Yishu/Components/ArtworkImage.swift)、[视频播放](../Yishu/Views/CreditsView.swift)
- [根界面](../Yishu/Views/RootView.swift)、[目录缓存](../Yishu/Services/PortfolioStore.swift)
- [静态媒体配置](../Server/nginx/README.md)、[历史公开体验回执](../Server/releases/public-experience-candidate.md)

## 风险与后续验收

**高优先级：审批权限不能保证已知会员媒体 URL 失效。** 当前代码不会把账号权限
直接传到图片读取链路，Showreel 地址还存在于源码常量中。本次两个已知样本的匿名 HEAD
也确认了这一文件级边界缺口。若产品承诺完整作品只对获批用户可见，需要私有源站、
短时媒体授权以及禁止绕过 CDN 直连的配置；仅隐藏 URL 或设置 Referer 不足以完成此目标。

**公开预览撤回具有残留窗口。** no-store 控制的是目录，不会抹除客户端、第三方
或 CDN 已经取得的图片。本次图片响应声明 `public, immutable, max-age=2592000`（30 天）；
Showreel 主清单声明 `public, max-age=300, stale-while-revalidate=30`。
撤回文件时，必须同时确认公开副本的访问策略与缓存处理。
已经合法或非法保存的副本无法通过接口撤销远程删除，不应作绝对防复制承诺。

**HLS 不能只保护 master.m3u8。** 后续引入签名机制时，子清单、分片、密钥及源站
都必须有相应控制。短时 URL 在到期前仍可能可用；若要求立即撤权，需额外的服务端
会话／撤销检查并明确缓存策略。此次未读取播放列表正文或媒体分片。

**真实账号完整闭环尚未验收。** 在隔离环境使用专门测试账号依次验证：

1. 待审批请求会员目录被拒绝，但仍可读取明确选定的公开预览。
2. 批准后，仅获得当前 gallery／video 权限允许的内容；无权限不返回对应受限地址。
3. 保存一个允许访问的媒体地址，随后分别撤销单项权限、暂停账号、撤销会话、删除账号。
4. 同时检查目录拒绝、App 当前画面／播放器清理，以及保存的媒体 URL 在到期前后、
   CDN 和已配置源站入口上的响应。仅用 HEAD 或受控的最小测试媒体，避免复制艺人影像。
5. 隐藏相册、撤回公开选片后，分别验证公开目录、会员目录和既有文件 URL；不把三者混淆。

本次未改造媒体鉴权，也未部署私有存储；以上风险不能标记为已修复。

## 本次执行结果

| 检查 | 结果 |
| --- | --- |
| `python Scripts/test-signout-contract.py` | 通过：同步清理、不可变凭据与迟到响应隔离 |
| `python Scripts/test-apple-login-lifecycle-contract.py` | 通过：inactive 保留、后台取消及旧回调隔离 |
| `python Scripts/test-no-game-release.py` | 4 项通过，确认当前源码无游戏实现／入口／资源 |
| `python Server/tests/media-access-readonly-test.py` | 8 项离线测试通过；检查域名边界、公开 DTO、重定向拒绝、HEAD 不读媒体、响应体上限、错误脱敏与风险非零退出 |
| `python Server/tests/account-authority-role-contract-test.py` | 无法完成：Windows 缺少 Unix `fcntl`；保留原失败，不改写测试以制造通过 |
| 既有 PHP 公开精选／身份／内容合同测试 | 未执行：本机未发现 PHP 运行时；官方运行时下载元数据请求返回 504，未安装替代软件 |
| 匿名线上检查 | 会员与 premium 接口拒绝匿名访问，WordPress 列表 404，公开精选 200 且六张图 HEAD 200；两个额外媒体样本匿名 HEAD 200，记为 finding；详见 JSON |
| Xcode／iPhone／iPad／真实账号撤权 | 未执行；本机为 Windows，未使用生产用户凭据 |

工具初次直连遇到 DNS 失败；改为遵循本机代理后取得响应。第一轮无效会话探针的
安装 ID 不符合服务端 UUIDv4 约束，因此得到 400 `fan_install_id_invalid`，不算验证
会话拒绝；已将探针改为随机 UUIDv4 和随机无效 Bearer 再测。中间复测曾有两项网络
结果不确定，保留为 [复测原始记录](media-access-followup-20261021.json)，没有改记通过。
最终增加超时时间后的完整结果见主记录。以上初次结果不计为通过。

新增脚本通过 Python 编译检查与 Ruff `E9,F,I` 检查；离线测试已加入
`Scripts/security-check.sh`。生产站点在线检查未加入默认 CI。

## 复现

先执行离线检查；在线工具会明确发起匿名请求，不在默认 CI 中自动访问生产站点：

```sh
python Server/tests/media-access-readonly-test.py
python Server/tests/media-access-readonly.py
```

在线工具只对固定项目 HTTPS 域名发起有限的 GET JSON 与 HEAD 请求，禁止重定向，
JSON 最大 256 KiB；最多检查六张公开图片。`--max-media 0` 可只检查目录。
可用 `--protected-media-url` 显式提供最多两个权利人已知的会员媒体样本，工具仅作 HEAD，
输出 URL 的 SHA-256 而不输出地址或签名。不要从目录猜测、枚举媒体地址。
私有签名地址不宜直接放进共享 shell 历史；使用不含秘密的专用测试媒体。

退出码 0 仅表示已执行的匿名检查符合预期，不代表完整账号生命周期通过；
退出码 2 表示发现风险、响应不符合预期或网络结果不确定。无账号样本时不会验证撤权。

具备 PHP 8.3 的隔离环境可继续运行现有测试：

```sh
php Server/tests/public-experience-regression.php
php Server/tests/fan-bound-administrator-auth-test.php
php Server/tests/plugin-contract-test.php
```

这些是合成／合同测试，不代替真实 WordPress、数据库、CDN 或 Apple 登录验收。
