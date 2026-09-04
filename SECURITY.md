# 易姝 App 安全说明

## 已落地的保护

- 管理员使用可单独吊销的 WordPress Application Password。App 不持久化访问码；它只留在当次短时内存会话，每次进入管理入口、退到后台、会话超过 5 分钟或服务器拒绝授权后都必须重新登录。升级会主动删除旧版保存的 Keychain 访问码。
- 管理请求使用无持久缓存、无 Cookie、无 URL 凭据库的独立 HTTPS 会话，最低 TLS 1.2，并拒绝全部 HTTP 跳转，避免 `Authorization` 头离开原始请求。
- Nginx 明确向 PHP 转发 `Authorization`；插件只在自有 REST 请求内校验专用 Application Password，并再次检查最小权限能力，不会接受普通 WordPress 用户。
- 上传文件限制为允许的图片/视频 MIME 类型、匹配的扩展名、安全文件名和 60 MB 上限，并拒绝空文件、不可读文件与符号链接。
- 受保护内容清单仅接受配置的精确 HTTPS 端点与 JSON 响应；请求必须携带绑定本机安装记录的已批准粉丝会话（或内容管理员凭据）。媒体只接受 HTTPS 受信任域名，响应体超限或异常域名会被 App 拒绝。
- 内容清单的成功、未登录、待审批、拒绝和暂停响应全部标记为 `private, no-store`，并以授权头和安装记录头区分，避免 CDN 或共享缓存复用账号状态。
- 图片使用无 Cookie、无凭据库、无持久缓存且拒绝跳转的独立 HTTPS 会话，同时校验精确 URL、受信域名、MIME、体积和像素尺寸。仅对短暂网络与指定 5xx/429 状态进行有界重试，不会绕过 URL、证书、类型或大小校验。图片字节与解码结果只保留在运行时内存中，不后台预下载整册照片，也不写入 App 文件、URLCache 或备份。
- 录屏、投屏或 App 失去活动状态时，使用 Apple 公开的 capture-state 与 scene lifecycle API 显示保护遮罩并清空内存图片缓存。Build 42 另按产品方明确风险授权，在单一隔离文件内借用安全文本渲染层级，使普通系统截图露出品牌保护页；解析器不硬编码私有类名、验证宿主从属关系，并在兼容层不可用时失败关闭、隐藏受保护内容。
- WordPress 保留最小权限内容角色，写接口按用户限流，并限制图片所有权、媒体类型、数量、文本长度和媒体域名。
- TestFlight 测试阶段只向已批准粉丝会话返回 App 内容；匿名、待审批、被拒绝和暂停状态均被拒绝。已批准用户仍由服务端对每次请求执行细分权限：无 `gallery_full` 时每册最多 3 张，无 `video_view` 时不返回 Showreel 和影视地址，撤销权限对已有 token 立即生效。官网作品页、附件页及 WordPress 作品/媒体 REST 列表仍返回 404。
- 天气功能只在用户主动开启后请求前台位置，定位精度设为约三公里；位置不持久化，也不进行后台定位。天气由 Apple WeatherKit 处理，工程包含 WeatherKit entitlement、法定署名入口与 Privacy Manifest；运行诊断只记录成功状态或数字错误分类，不记录坐标、城市或请求 URL。
- GitHub 质量门禁使用最小读权限和固定 commit SHA 的 Action，不持有生产密钥；每次推送都扫描长期凭据、明文 HTTP、敏感文件、配置语法，并在 iPhone/iPad 执行关键页面回归。
- MetricKit 与 Unified Logging 只保留版本、性能/诊断聚合数和数字网络错误类别，不记录 URL、账号、凭据或影像内容，不向第三方分析服务上传。
- WordPress 内容插件在写入与读取两侧都执行相同的 URL、长度、数量和唯一 ID 校验；数据库旧值损坏时按模块回退安全默认值，并由无 WordPress 环境依赖的 PHP 合同测试持续验证。
- 备用节点只在传输校验和通过并完成数据库/config 备份后应用主节点数据；导入后清空持久化对象缓存，避免数据库已更新但 API 继续暴露旧内容。
- iOS 在信任域名校验之外还会验证清单结构、集合数量、唯一 ID、文本长度、时间范围和 URL 长度；离线缓存带独立格式版本，未知版本或异常内容不会进入 SwiftUI 页面。
- 生产 Nginx 在通用 PHP/静态文件规则之前拒绝 `wp-config.php`、任何附加在 `.php` 后的未知后缀、密钥/数据库/压缩包、配置/源码备份和编辑器残留；主备节点同步前后都会验证 Web 根目录，恢复副本只允许放在站外 root-only 目录。
- 官网和图片 CDN 配置上海主源与新加坡备用源；状态型账号、审批和内容清单请求则通过非 CDN 域名直达上海权威数据库，并由备用节点同命名空间反向代理兜底，避免逐请求切换到未实时同步的数据副本。
- 粉丝账号与 WordPress 管理身份严格分离：注册用户只是内部随机用户名的 `subscriber`，粉丝权限白名单不包含内容管理 capability。
- 粉丝新注册、Apple 首次资料提交和邀请账号首次设置的抖音 ID 为必填：客户端与服务器均拒绝空值、邀请占位值和非法格式，并执行唯一预留。存量空 ID 账号可继续登录和删号，但内容端点失败关闭；用户必须重新验证密码或 Apple ID 并同意当前政策才能补全。系统通过网络/安装双维度注册限流及网络/身份码双维度登录限流抑制滥用。客户端地址只会从回环或固定备用节点的受信链路接受；备用节点公网/CDN 入口会覆盖自定义地址头，防止伪造限流身份。
- 原生 Apple 登录不接受客户端自报的 Apple user ID。客户端先请求绑定安装记录、purpose 和短 TTL 的服务端 challenge；服务端只保存 nonce/state/安装记录的哈希并单次消费。客户端先恒时比对回调 state，再上传 Apple identity token、authorization code、challenge ID、state 和安装记录；token/code/nonce/state 不落盘、不写日志。
- 服务端验证 Apple JWT 的签名、issuer、audience、nonce、签发/到期时间，并以 HMAC 后的 subject 关联账号；authorization code 只发往 Apple token 端点。Apple refresh token 加密保存，只用于维持登录关联和删号时撤销 Apple 授权，不能作为 App bearer token 使用。
- Apple 登录形成三重门禁：一是 Apple 签名身份验证，二是本人填写昵称和必填抖音 ID 并确认当前隐私政策，三是管理员人工批准。第一步只签发短时 `apple_onboarding` 会话；完成第二步前内容接口失败关闭，管理员目录显示“等待完成账号申请”，客户端和服务端都不允许提前批准为 active。
- 粉丝会话使用 256-bit 随机 bearer token；原令牌只保存在 ThisDeviceOnly Keychain，服务器只持久化 SHA-256 哈希并绑定本机随机安装标识哈希。会话有效期 30 天，每账号最多 8 个，不依赖 Redis 存活。
- 会话目录只返回不可用于登录的公开会话 ID、安装记录码、登录/到期时间和当前设备标志，不返回令牌或令牌哈希。普通会话可撤销任一其他设备，不允许用相同接口撤销当前会话。
- 新注册账号默认 `pending`，管理员可批准或拒绝；App 启动与每次回到前台都会复核状态，未批准时采用失败关闭策略并丢弃旧版受保护目录缓存。
- Apple 会话冷启动在展示任何受保护缓存前先调用系统 credential state。明确的 revoked/notFound/transferred 或未知状态会使用对应提示并失败关闭；Apple 系统查询本身暂时失败时不伪装成“已撤销”，而是继续以仍有效的服务端 profile/token 为权威，并采用 15 秒、60 秒、5 分钟的有界退避，退到后台立即取消。
- 管理员邀请使用 24 小时有效、只显示一次的随机临时密码。临时登录只签发 10 分钟 onboarding scope 会话；本人设置昵称、必填抖音 ID、新密码并确认当前隐私政策前，客户端和服务端都拒绝受保护内容。完成设置会递增凭据版本、撤销全部旧会话并使临时密码失效。
- 管理员密码恢复使用 15 分钟有效、只显示一次的随机临时密码；服务器不保存可读明文。创建时立即撤销全部旧会话；首次领取绑定安装记录，其他设备重放被拒绝，同一安装重新登录会撤销上一恢复会话。恢复会话只有 10 分钟且不能读取内容或会话目录；用户完成强制改密后才换发普通会话。
- 用户主动改密必须在锁内重新验证当前密码，新密码需符合强度策略且不得与当前密码相同。成功后轮换凭据版本、撤销全部旧会话，只向当前安装换发新会话。
- 粉丝创建、审批与权限管理使用独立 `manage_yishu_fan_accounts` capability；内容发布能力本身不能创建或激活粉丝账号。普通审批接口不能把未完成首次设置的邀请提前激活。
- 暂停账号、退出、到期和完整删除都会撤销现有内容会话。暂停账号不剝夺用户重新验证并进入账号管理的能力。用户在待审批、被拒绝、暂停、首次设置或密码恢复状态下仍可永久删除账号；服务端会按普通、首次设置或恢复 scope 在账号锁内分别重验当前 token、安装记录、状态标记和当前密码；错误尝试受网络和账号双维度限流。成功后删除账号、抖音 ID、身份码、权限、恢复记录、安装记录和全部会话，不以“暂停”代替删除。
- Apple 账号在已完成资料和仍处于 onboarding 两种状态下都可在 App 内删除。删除必须重新取得 purpose=`delete_account` 的服务端 challenge、携带当前 bearer，并由 Apple 原生界面重新认证同一 subject；服务端先尝试撤销 Apple refresh token，完成账号删除后将短暂失败项写入有界重试队列，并清除申请、会话和本机账号分区。退出登录不冒充永久删除。
- 客户端收藏和最近浏览按服务器账号 UUID 分区；未登录或 UUID 异常时不读写，换号不会互相暴露本机记录，账号删除成功后同步清除对应本地分区。
- App 主内容必须注册并获得批准；注册页和 App 内“关于”均有隐私政策入口，注册前需明示确认数据用途。

管理员审批和内容清单鉴权可以阻止未授权 App 客户端取得完整目录，但目前部分历史媒体文件与随 App 打包的备用素材并非端到端加密资产。它们迁移到私有对象存储和短时签名 URL 前，不能把审批门禁描述为防止所有直接文件访问的绝对 DRM。

## Build 33 Apple 登录上线前置

- Apple Developer 的显式 App ID `cn.com.shuzijun.yishu` 必须启用 Sign in with Apple 与 WeatherKit；开发、Ad Hoc 和 App Store 描述文件须在能力开启后重新生成。归档中应同时存在 `com.apple.developer.applesignin` 和 WeatherKit entitlement。
- Apple 登录私钥仅放在 Web 根目录外的受限路径，通过 `YISHU_APPLE_TEAM_ID`、`YISHU_APPLE_KEY_ID`、`YISHU_APPLE_PRIVATE_KEY_PATH` 引用；仓库、构建产物、日志和巡检报告均不得包含 `.p8`、client secret 或任何 Apple 用户凭据。
- 生产服务器必须安装 `Server/composer.lock` 锁定的非开发依赖，并允许受控出站 HTTPS 访问 Apple JWKS、token 与 revoke 端点。WP-Cron 或等价任务必须能执行 Apple 授权撤销重试与过期 challenge 清理。
- 发布前须运行 iPhone/iPad 单元与 UI 回归、Release 分析和实际 `.app` 敏感文件扫描，再在 TestFlight 真机完整验收 Apple 新注册、空抖音 ID 双端拒绝、有效 ID 提交、存量空 ID 迁移、审批、重复登录、凭据撤销、网络中断、onboarding 删号和已批准账号删号。
- App Store Connect 隐私标签、App 内政策和网页版政策必须一致说明昵称、抖音 ID、用户/安装标识、短时 Apple token/code、加密 refresh token 与 Apple 登录处理关系；客户端不请求 `.fullName` 或 `.email`，因此不得宣称收集 Apple 返回的姓名或邮箱。

## 恢复付费订阅前必须完成

当前 TestFlight 版本向已批准账号提供完整相册，但账号审批本身不等同于付费凭证，也不构成私有媒体安全边界。恢复收费前必须完成以下链路：

1. 在 App Store Connect 创建月度订阅并补齐 App Apple ID。
2. 启用 `Server/entitlement-verifier`，用 Apple App Store Server Library 校验签名、Bundle ID、商品 ID、到期时间和撤销状态。
3. 将付费原图迁移到私有对象存储；公开接口只保留 3 张预览，校验通过后返回数分钟有效的 CDN 签名地址。
4. CDN 禁止绕过签名直连私有原图并配置 WAF 限流。
5. 处理 App Store Server Notifications V2，使退款、撤销和订阅到期及时失效。

上述私有存储与签名 URL 是当前 P0 遗留项。在它完成前，不应将“无法下载原图”作为绝对安全承诺。

## 屏幕捕获保护边界

iOS 对普通静态图片没有向第三方 App 开放与 Netflix、Apple Music 的 DRM 视频画面等价的公开截屏阻止接口。Build 42 的 TestFlight 实验层借用 `UITextField` 安全文本渲染行为：受保护 SwiftUI 内容位于安全画布内，普通 XCUIScreenshot 会隐藏该内容并露出下层“狐狸姐姐温馨提示”。OCR 回归验证截图包含保护标题、不包含首页文案，保护开启时页面切换和触控保持可用。

该行为不是 Apple 承诺的通用截图 API，可能随 iOS 更新失效或触发 App Review 2.5.1 风险。模拟器开发者命令 `simctl io screenshot` 会直接导出帧缓冲并绕过安全合成；另一台设备拍屏、越狱/调试环境和已经公开的媒体 URL 同样不受保护。因此只能描述为“普通系统截图保护”，不得宣称端到端 DRM 或绝对无法取得图片。正式 App Store 审核前应再次决定保留该兼容层、移除它，或将需要强 DRM 的视频改用 HLS + FairPlay Streaming。

## 密钥与应急处置

- 仓库不得提交 `.env`、`.p8`、`.p12`、描述文件、私钥或管理员访问码。
- 任何曾发送到聊天、截图或日志中的长期云 API 密钥，即使当时是私密环境，也应在云控制台轮换并改为最小权限子账号。
- iPhone/iPad 丢失时，先在 WordPress 中吊销该设备的 Application Password，再创建新凭据。
- 发布服务端插件时应保留旧版备份，运行 PHP 语法检查，再验证匿名和未批准内容读取被拒绝、已批准会话可读取、未登录写入被拒绝及管理员写入等用例。
- 服务端备份不得保存在 WordPress 文档根目录。若配置备份曾可公开访问，应同时执行 URL 阻断、站外隔离、国内外 CDN 清理，并轮换数据库密码与全部 WordPress 身份验证密钥；轮换后已有后台会话失效属于预期行为。
