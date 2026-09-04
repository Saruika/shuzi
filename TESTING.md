# Hi，梳子测试与质量门禁

## 本地验证

执行以下命令即可复现 GitHub 的主要检查：

```bash
Scripts/security-check.sh
Scripts/ci-ios-tests.sh iPhone
Scripts/ci-ios-tests.sh iPad
Scripts/ci-release-analyze.sh
```

测试脚本会自动选择当前 Xcode 中第一台可用的 iPhone 或 iPad 模拟器，不依赖固定的设备名称或 UDID。DerivedData 位于独立临时目录并在任务结束时自动清理，不会进入 Git。

UI 回归默认不保存截图附件，避免人物影像留在本地测试产物。只有在隔离的视觉验收环境中显式设置 `YISHU_UI_TEST_ATTACH_SCREENSHOTS=1` 时才会保留附件，任务结束后必须清理。

## 覆盖的用户路径

- 未登录启动时只出现注册/登录、隐私政策和管理员审批入口，首页等主导航不会泄露。
- Debug 专用已批准视觉夹具下，首页、作品、影视、收藏和关于五个主模块都能出现并切换。
- 作品网格可打开相册，相册封面可进入全屏查看，真实翻到第二张后页码、图片、说明和关闭控件仍连续可用。
- 画廊在屏幕保护启用时仍能正确取得环境对象；用例会从竖屏旋转至横屏，验证图片区尺寸刷新、多图翻页和关闭均正常，避免全屏弹层只剩空白保护层。
- 截图专项回归保持保护层开启，使用普通 XCUIScreenshot 后由 Vision OCR 强制识别“狐狸姐姐温馨提示”和“影像内容已保护”，并拒绝出现“镜头之内”或“查看作品”；随后继续点击作品页，验证保护画布没有破坏触控与导航。
- 收藏空状态可回到作品页；图片请求只对短暂错误有界重试，失败后显示可访问的“重新加载”入口。
- 开屏、首页、相册、关于页和影视海报都从云端按需加载，图片管线仅使用隔离 HTTPS 会话与内存缓存；回归验证清理共享缓存后会取消合并下载，重回前台时无画面的视图可重新加载。
- 开屏首先显示代码绘制占位，再使用不含图片字节的启动快照加载当次海报；回归不假设启动前已经同步最新发布配置。
- 影视页 UI 验证播放、暂停与静音入口；用真机或网络调试工具模拟慢网后，另行检查视频缓冲、播放停滞和超时都会出现可见重试，不会静默卡在加载状态。
- “发送合作邀约”可进入完整表单，管理员入口可进入安全登录页。
- 粉丝注册入口可达，抖音 ID 明确标注为必填；空值客户端和服务器均拒绝，有效值执行 2–50 位归一化与唯一性约束；管理员审批说明和注册前隐私政策可读。
- 原生“通过 Apple 登录”入口可达；首次 Apple 验证夹具只能进入昵称、必填抖音 ID 和隐私同意表单，留空必须拒绝且保持 onboarding；主导航保持不可见，并同时提供退出和永久删除申请。
- Apple 登录安全单元回归覆盖 nonce SHA-256、state 恒时比对、challenge 过期/单次使用形状、凭据字段最小化、credential state 的授权/撤销/转移决策，以及系统查询失败时继续使用有效服务端会话的连续性边界。
- Apple 注册草稿在完成、退出、删号、换号、撤销凭据和 App 离开前台时清空；Apple-only 账号不出现密码修改，但登录设备与会话管理仍可用。
- 管理员目录可以加载 `accountSource=apple` 且 `requiresAppleRegistration=true` 的未完成申请，显示“等待完成账号申请”；未完成资料或存量空抖音 ID 的用户没有批准为 active 的入口。旧空 ID profile 仍能解析、登录和删号，但补全前不能取得内容；补全后 ID 可在管理目录搜索。
- 账号单元回归覆盖恢复状态未完成前失败关闭、主动改密的当前/新密码校验、会话目录的唯一当前设备约束，以及换令牌时丢弃迟到响应。
- 收藏与最近浏览单元回归覆盖账号 A/B 相互隔离、退出后不读写、删除只清理指定账号及非法 UUID 失败关闭。
- 相同用例同时在 iPhone 与 iPad 上执行；布局专用测试使用 XCTest 的 `runsForEachTargetApplicationUIConfiguration`，按工程声明的横竖屏与外观配置分别启动 App，并在 `.xcresult` 中保留关键页截图。这样也正确覆盖 iPadOS 26 中独立于物理方向的窗口几何。
- 辅助功能大字号回归会使用 Accessibility XXXL 在每种 UI 配置中重新打开首页，确认天气与主操作始终可见、可点击、不越界且不小于 44pt；作品搜索另有交互与 44pt 门禁。
- 聚焦辅助功能门禁会遍历首页、作品与关于页：iPhone 直接运行 Apple 系统审计，检查对比度、触控区域、文字裁切和语义；iPad 使用确定性的安全区、44pt、VoiceOver 语义断言，并由独立 UI 配置套件的 Accessibility XXXL 与横竖屏/窗口化用例补齐覆盖。这是为了避开 XCTest 在 iPad 快照阶段的框架错误 -56，不跳过门禁、不吞掉失败。
- 开屏回归在 Accessibility XXXL 下确认文案不会被定时关闭、跳过按钮位于状态栏安全区且不小于 44pt；Showreel 回归验证自绘进度、播放和静音控制可见可用，不依赖系统播放器外壳。

UI 测试仅在 Debug 构建中使用参数关闭 capture-state 遮罩，避免测试进程的画面采集被误判为录屏；需要遍历主内容的视觉用例还会启用仅 Debug 编译存在的已批准夹具。门禁用例不启用该夹具，并单独验证未登录用户无法看见主导航。Release 构建中这些参数全部不生效。

生产账号 API 发布后运行：

```bash
Server/tests/fan-api-smoke.sh
```

该脚本使用随机抖音测试 ID 验证匿名内容拒绝、注册默认待审批、待审批内容拒绝、管理员拒绝/批准、已批准读取、暂停和重新登录，并额外覆盖：

- 同一账号的多设备会话目录不泄露令牌/令牌哈希，且撤销其他设备后对方会话立即失效；
- 主动改密需当前密码，成功后旧会话和旧密码都失效；
- 管理员密码恢复只显示一次、服务器不保存明文，第一台设备领取后会拒绝第二台设备重放；同一安装的后一恢复会话会撤销前一个，完成改密前无法读取内容或管理普通会话；
- 删除账号支持普通、首次设置和密码恢复三种 scope；每种状态都需匹配当前安装记录、当前凭据代次并重新验证对应密码，错误密码会被拒绝，成功后账号、会话和抖音 ID 保留位都不可再使用。
- Apple challenge 绑定 purpose、安装记录、nonce/state 哈希、TTL 并在第一次认证尝试时消费；伪造凭据失败后同一 challenge 不可重放。
- Apple 首次认证只能取得 `apple_onboarding` 会话；未提交昵称、必填抖音 ID 与隐私同意时 `/fan/session` 只能返回 `appleRegistration`，管理员目录仍可读取该申请但服务端和客户端都拒绝提前批准或读取内容。空 ID 提交必须失败并保持 onboarding；存量 Apple 账号补全时必须保留原审批状态和经白名单校验的权限（包括 `early_access`）。
- Apple 删号必须使用 `delete_account` challenge、当前 bearer 会话和同一 Apple subject 的近期重新认证；成功后撤销或排队重试撤销 Apple refresh token，并删除 onboarding/账号/会话数据。

脚本结束时自动删除测试账号和临时管理员访问码。

## 安全门禁

`Scripts/security-check.sh` 会在构建前检查：

- Git 中是否误放 `.p8`、`.p12`、描述文件、`.env` 或私钥。
- 文本中是否出现高置信度的云密钥、私钥或 URL 内嵌密码。
- iOS 生产 Swift 源码是否使用明文 HTTP。
- Xcode/Privacy/Entitlement 配置、WordPress PHP 插件和 Python 订阅校验器是否通过基础语法检查。
- 内容清单会用超量集合、重复 ID、异常时长、超长 URL 和未知缓存版本做负向单元回归。
- 屏幕捕获回归验证 `sceneCaptureState`、系统录屏通知、App 生命周期整窗遮罩、内存清理和 Build 42 的隔离截图兼容层；安全检查要求兼容实现只能存在于一个已审核文件、只能有一个不可聚焦的 secure text field、不得硬编码/动态调用私有 UIKit 类，并在画布解析失败时隐藏内容。
- 粉丝密码恢复、会话目录、迟到响应和不确定删除结果会做失败关闭单元回归；服务端合同测试另行检查恢复记录不含临时明文密码、路由权限范围和删除限流。
- Release 构建完成后再次扫描实际 `.app` 包，确认没有私钥、云密钥、环境文件或意外打包的敏感资源。

GitHub Actions 只有仓库内容读权限，不使用 Apple、腾讯云或服务器密钥；外部 Action 固定到完整 commit SHA。失败时保留七天 `.xcresult` 供排查。

## Build 45 发布前验收

1. 确认 App Debug/Release 均为 `1.3.33 (45)`，App Content API 插件头为 `1.5.12.1`，Bundle ID 与 APNs topic 均为 `cn.com.shuzijun.yishu`；执行推送合同、动态插件合同、iOS 单元/UI 回归、Release Analyze 和凭据扫描。
2. 对新注册、Apple 首次/存量资料补全和邀请完成分别执行同意版本矩阵：1.5.12.1 只接受 Build 42 的 `2026-09-02-approval-v3` 与 Build 45 的 `2026-09-04-approval-v4`，并逐字保存实际提交值；v2、未知、缺失和非字符串均失败关闭。Build 42 v3 请求也必须携带合法抖音 ID，不得借过渡放宽必填政策。确认该过渡白名单没有 option、环境变量、过滤器或远程开关；Build 42 过期后另发 1.5.13 收紧新提交仅 v4，已存 v2/v3/v4 仍保持有效。
3. 以普通粉丝、内容管理员和无推送权限的已认证账号分别调用接口：设备登记/解绑必须要求当前正常粉丝会话与相同安装记录；定向发送必须要求独立 `manage_yishu_push_notifications` capability，缺失权限返回 `push_capability_required`，不得锁死其他合法管理功能。
4. 在管理员目录创建超过两页的同名测试用户，验证昵称模糊搜索、身份码/抖音 ID 精确搜索以及 `page`、`perPage`、`hasMore` 远程分页；不得只返回最近 100/201 个用户。每次发送只接受 1–100 个明确收件人，同一管理员和幂等键重试不得创建第二条通知。
5. 不传 `sensitive` 或传 `true` 时，APNs 标题与正文必须降级为“Hi，梳子 / 有新消息，请登录查看”；只有显式传 `false` 时才发送经净化且不超过 60/240 字符的自定义标题和正文。数据库、PHP/FPM 日志、审计事件和接口响应不得出现设备令牌、Provider JWT 或私钥明文。
6. 在隔离预发布环境验证设备令牌按 1–256 字节不透明值处理、以 Secretbox 密文、HMAC 索引和非秘密密钥指纹保存，安装与令牌索引全局唯一；持久安装状态必须记录最新正常会话、单调 `bindingGeneration` 和期望绑定状态，Outbox 固定同一安装与代次。设备 TTL 为 90 天，通知/收件关系/Outbox TTL 为 30 天。退出、换号、撤销单个或全部会话、改密/恢复、拒绝/暂停和删号后都必须无法继续投递，迟到的低代次请求不得恢复绑定。
7. 两台节点在仓库及 Web 根目录外配置权限不宽于 `0600` 的文件，并让 PHP-FPM 读取 `YISHU_APNS_KEY_ID`、`YISHU_APNS_TEAM_ID`、`YISHU_APNS_PRIVATE_KEY_PATH`、`YISHU_APNS_DATA_KEY_PATH`；数据密钥内容必须相同。确认仅 authority 建表、调度和消费，standby 不并发发送，WP-Cron 或受管系统定时器持续保活。
8. 用 TestFlight 真机完成授权、拒绝后重试、令牌更新、单用户/明确列表、多设备、前后台、退出和删号；设备离线后在通知创建起 24 小时内恢复网络仍应收到通知，超时不得因 Worker 或密钥恢复而重新获得 24 小时。故障夹具覆盖 408/429/500/503 重试、410/BadDeviceToken 清理、最后一次处理崩溃后的租约终止、租约回收和 authority 切换；另外需注入数据密钥不可读、加密依赖不可用与密钥指纹不一致，验证设备行保留、任务回到 pending、`last_error_code=device_crypto_unavailable`、尝试次数不增长并在 60 秒后恢复。APNs 200 后数据库写回失败仍可能形成 at-least-once 重复窗口，验收时需核对 collapse-id 效果且不得承诺绝对单次送达。
9. 上线前同步核对 App Store Connect 隐私标签、App/网页隐私政策与用户关闭通知、退出和永久删号路径；未完成哈希校验发布清单、双节点部署、主备切换演练和生产 APNs 真机端到端验收时，不得把 Build 45 描述为已上线。

## Build 44 发布前验收

1. 确认 App Debug/Release 均为 `1.3.32 (44)`；“关于”页工作联系、合作邀约邮件回退和服务端合作收件人均为 `369476120@qq.com`。
2. App 内与网页版隐私政策都必须把个人信息查阅、更正、删除、账号资料更正及政策反馈指向 `sariki@me.com`，并保留 QQ 邮箱的商务合作用途；两类邮箱不得互换。
3. App Store Connect API 重新读取 Bundle ID capability，确认 `PUSH_NOTIFICATIONS` 已启用；工程 entitlement 包含 `aps-environment`，且自动签名生成的新开发/分发描述文件包含相应环境值。
4. APNs `.p8` 只能从 Apple Developer 门户下载一次，必须保存于仓库和 Web 根目录之外且权限不宽于 `0600`。在客户端授权、设备令牌注册、服务端提供方、失效令牌清理和真机端到端验收完成前，不得宣称推送已经上线。
5. 执行邮箱职责单元测试、全量 iOS 单元测试、Release 构建与 `Scripts/security-check.sh`；扫描 Git 暂存区和最终 `.app`，确认没有 APNs 私钥、JWT、设备令牌或其他凭据。

## Build 43 发布前验收

1. 确认 App 1.3.31 Build 43 对新注册、Apple 首次资料提交、邀请完成和存量空 ID 补全均提交 `2026-09-04-approval-v4`，客户端和服务器都拒绝空抖音 ID。
2. 合同测试必须证明新确认只接受 v4，而服务器中已存的 v2/v3/v4 记录仍有效；不得把新提交的 v2/v3 当作存量兼容。
3. 使用密码账号和 Apple 账号各验证一次存量空 ID 迁移：补全前可登录、退出和删号但不可读取影像；补全后旧会话失效。Apple 迁移还必须保留原审批状态和全部已校验权限，包括 `early_access`。
4. 仅在 Build 43 已具备分发条件后才能部署将新确认收紧为 v4 的服务端 1.5.11；部署前要明确验证 Build 42 仍会提交 v3。本轮只准备代码和 GitHub 版本，不对生产服务执行原地修改。
5. 在 iPad Pro 13 英寸横屏用真实云端首页图连续滑动至少 0→1→2：前景照片必须保持完整比例，任一请求未就绪时不得显示纯黑帧；横竖屏后再打开相册并确认关闭可用。
6. 检查 App 容器只有受保护的内容清单元数据，图片下载使用 ephemeral session、内存 `NSCache` 与零磁盘 `URLCache`；退后台、换号和内存告警继续清空共享图片缓存，横屏连续帧只保留在易失内存且绝不落盘。

## Build 42 发布前验收

1. 确认主 App target 的 Debug/Release 均为 `1.3.30 (42)`，Bundle ID 为 `cn.com.shuzijun.yishu`，Sign in with Apple 与 WeatherKit 签名能力保持完整。
2. 在 iPhone 17 Pro Max 和 iPad 横竖屏保持屏幕保护开启，分别检查首页、相册查看器、影视、收藏、关于和管理员全屏层；普通系统截图必须只显示完整“狐狸姐姐温馨提示”，正常界面必须仍可滚动、点击、切图和关闭。
3. 执行 OCR 截图门禁：截图必须识别到“狐狸姐姐温馨提示 / 影像内容已保护”，不得识别到“镜头之内 / 查看作品”。`simctl io screenshot` 是会绕过模拟器安全合成的开发者帧缓冲工具，其输出单独归档为已知边界，不得误算作普通用户截图。
4. 在 App 进入后台、任务切换器、录屏、投屏、连续截图和快速前后台切换中验证遮罩及时出现、返回后及时消失；不得出现永久黑屏、提示计时竞态、底层仍可操作或图片内存未清理。
5. 清洁安装并让生产 `aboutPortraitURL` 分别为有效 URL 与空值：有效值显示指定古风人物图，空值使用首页首图/相册封面兜底；管理员保存其他内容时仍必须保持该权威字段未配置，替换人物图后应立即单字段发布，不能连带发布其他草稿。
6. 关于页使用 2:3 人物画布；在 iPhone 普通/大/Accessibility XXXL 字号及 iPad 横竖屏、明暗配置下，验证姓名和“短剧演员 / 模特 / 视频创作者”完整落在实际照片范围内，并与可见底部保留至少 12pt。
7. 执行全量 iPhone/iPad UI 回归、全部单元测试、`Scripts/security-check.sh` 与 `Scripts/ci-release-analyze.sh`。任何失败、截图泄露、触控中断或 secure canvas 进入不可用回退，都不得上传 TestFlight。
8. TestFlight 真机用电源键加音量上键截图复核，保存结果应为品牌保护页；再检查录屏、横竖屏旋转、相册切图和关于页照片。正式 App Store 审核前必须重新评估该非公开兼容行为的 2.5.1 风险。

## Build 41 发布前验收

1. 确认主 App target 的 Debug/Release 均为 `1.3.29 (41)`、Bundle ID 为 `cn.com.shuzijun.yishu`，Sign in with Apple 和 WeatherKit 签名能力保持完整；测试 target 版本不随之改写。
2. 在全新 DerivedData 中构建 Release 并检查最终 `.app`/`Assets.car`：除 App Icon 与三个平台标识外，不得包含人物、开屏、首页、相册或影视照片；扫描旧 `Hero*`、`AboutPortrait`、`ShowreelPoster` 和 `LaunchPoster*` 资源名必须为零命中。
3. 验证三张默认古风开屏的 HTTPS 地址均返回 `image/jpeg`，尺寸约为 1801×2700，单张约 850–950 KB；对源图、下采样结果和发布文件做哈希核对，确认未换入 Q 版、AI 放大或模糊修复素材。
4. 在冷启动、慢网、断网、切后台后立即返回以及内存告警后分别验收：代码占位铺满窗口、不闪现旧图或黑屏，有网时图片可恢复加载，App 容器和 URL 缓存中没有任何照片字节。
5. 在管理员内容工作台检查三张海报均以 `fit` 完整显示；再在 iPhone 和 iPad 横竖屏实际启动，确认窄屏 `fill` 铺满、宽窗口同图模糊铺底且 `fit` 前景完整，并确认安全区文案完整。
6. 首页仍只显示地点、天气与温度，Apple Weather 商标、数据来源和许可链接仅在“关于”页。这是产品方明确要求的 WeatherKit 例外，存在 App Review 风险；商店提交前必须重新评估，不得把它记录为“已通过归属合规验收”。
7. 确认合作邀约服务端 Phase 1 没有部署或启用，测试报告不得宣称管理员收件箱、自动邮件、幂等或重试队列已上线。
8. 执行全量 iOS 单元测试、Pro Max 与 iPad 横竖屏 UI 回归、`Scripts/security-check.sh` 和 `Scripts/ci-release-analyze.sh`；任一项失败，或最终包资源扫描不为零，都不得上传 TestFlight。
9. 在上传 TestFlight 前，先完成生产账号 API 的同意版本迁移，并以密码账号、Apple 待审批账号、Apple 已审批账号验证注册、审批、登录、权限撤销和 App 内永久删号；任一旧身份码或旧会话在删号后仍可访问时不得发布。
10. 创建长期有效、已预审批且只具备粉丝全量查看权限的 Apple 审核专用账号；正式 App Review 与外部 TestFlight Beta Review 都必须填写该账号、稳定密码、进入路径和删号路径。不得提供生产最高权限管理员账号。
11. App Store Connect 的版本必须与 `1.3.29 (41)` 一致，并人工核对隐私标签至少覆盖姓名、用户 ID、随机安装记录、粗略位置、诊断及实际收集的管理端上传数据；隐私标签、App 内政策和公网政策必须使用同一口径。
12. 归档后检查最终签名产物，而非只检查工程文件：`application-identifier`、Sign in with Apple、WeatherKit、Bundle ID、版本和构建号必须与分发描述文件及 App Store Connect 一致。
13. 提交审核前准备可立即提供的摄影作品、肖像、视频、音乐、影视海报、App 图标、开屏图和第三方平台标识权利证明；任何来源不明或仅经过 AI 放大/模糊修复的媒体不得进入发布内容。
14. 在匿名媒体地址仍可直接访问期间，不得对 Apple 或用户宣称传输层已经实现私有媒体保护。App Store 正式提交前需完成短时签名媒体与旧公开地址下线，或由产品方重新定义并如实披露公开预览范围。

## Build 40 发布前验收

1. 确认构建设置为 `1.3.28 (40)`、Bundle ID `cn.com.shuzijun.yishu`，且 Sign in with Apple 和 WeatherKit 签名能力保持完整。
2. 在 iPhone 17 Pro Max 普通字号与 Accessibility XXXL 下打开关于页，确认“短剧演员 / 模特 / 视频创作者”全文位于人物图内，并与浮动底部导航至少保留 12pt 安全余量。
3. 在 iPad 横屏检查全部五张首页图片：人物照片应完整显示，侧边使用同一张图的模糊背景；竖屏 iPad 和 iPhone 仍保持原有铺满构图。
4. 从第五张等待轮播回到第一张，确认首尾切换不使用非循环跨页动画，画面没有黑屏；替换为不同比例的管理员图片后，前景与模糊背景必须来自同一张新图。
5. 执行 68 项 iOS 单元测试、iPad 四组横竖屏/明暗首页与关于页配置、Pro Max 普通字号与 Accessibility XXXL 专项回归，以及 `Scripts/security-check.sh`；任一项失败都不得发布。

## Build 39 发布前验收

1. 确认构建设置为 `1.3.27 (39)`、Bundle ID `cn.com.shuzijun.yishu`，且 Sign in with Apple 和 WeatherKit 签名能力保持完整。
2. 在 iPhone 17e、iPhone 17 Pro Max 和 Accessibility XXXL 下打开关于页，确认“短剧演员 / 模特 / 视频创作者”全文位于人物图内、底部导航上方，不被截断或省略。
3. 在 iPad 横屏、竖屏和窗口化尺寸中打开照片，确认整张图以 1 倍比例完整显示在顶部工具栏与底部说明之间；放大后旋转或调整窗口时应立即恢复完整构图。
4. 在普通画廊和 capture-state 保护修饰器启用的画廊中连续左右切换至少三张图，确认缩略预览连续、没有黑屏闪帧，页码正确；从作品和收藏两个入口分别点击关闭，都应返回原页面。
5. 用限速网络重复打开和翻页，确认已有预览会保留到对应原图加载完成；请求失败时应保留可达的“重新加载”操作。
6. 执行 66 项 iOS 单元测试、iPad 四组横竖屏/明暗画廊与关于页配置、受保护画廊竖转横回归，以及 `Scripts/security-check.sh`；任一项失败都不得发布。

## Build 38 发布前验收

1. 确认构建设置为 `1.3.26 (38)`、Bundle ID `cn.com.shuzijun.yishu`，且 App ID 与本次签名描述文件同时包含 Sign in with Apple 和 WeatherKit；能力变更后必须重新生成签名描述文件。
2. 服务端运行锁定依赖的 `composer install --no-dev --classmap-authoritative`；Apple `.p8` 位于 Web 根目录外，只通过 `YISHU_APPLE_TEAM_ID`、`YISHU_APPLE_KEY_ID`、`YISHU_APPLE_PRIVATE_KEY_PATH` 引用。测试日志和仓库不得出现私钥、client secret、identity token、authorization code、nonce、state 或 Apple subject。
3. 确认服务器可通过 HTTPS 访问 `appleid.apple.com/auth/keys`、`/auth/token` 和 `/auth/revoke`，WP-Cron 或等价计划任务能执行撤销重试；反向代理继续转发 `Authorization` 与安装记录头。
4. 在真实 TestFlight 安装执行：新 Apple 账号 → 昵称与隐私同意（抖音 ID 分别测试留空和有值）→ 待审批 → 管理员批准 → 主内容；同一 Apple ID 重复登录；取消授权、网络失败与重新前台；其他设备会话撤销；onboarding 和已批准状态分别永久删号。
5. 删除后确认 App 本机收藏/最近浏览分区消失、原 bearer 不可使用、Apple 账号可按产品规则重新申请；App Store 隐私标签与 App 内政策须包含昵称、用户 ID、设备级随机标识和粗略位置，不声明未请求的 Apple 邮箱。
6. 在 iPhone、iPad 横竖屏和辅助功能字体下检查作品页：搜索框紧贴状态栏下方的系统安全区域，且聚焦、输入、清除、取消、空结果、下拉刷新和详情返回均正常。同时开启 VoiceOver、减少动态效果和减少透明度，确认保护遮罩不会让底层内容被聚焦。
7. 开启天气后确认首页仅显示地点、天气和温度，不出现 Apple Weather 标记或“来源”入口；“关于”页应完整显示 Apple Weather 商标、数据来源说明和可点击许可链接。
8. 将 Showreel 播放至结束，确认画面停留在最后一帧且没有中央“播放结束”卡片；底部播放键应切换为重播，并在点击后恢复播放，暂停、静音和进度控制保持可用。
9. 在 iPhone 横屏、普通大字号、Accessibility XXXL 和 iPad 各 UI 配置中打开关于页，确认“短剧演员 / 模特 / 视频创作者”内容完整，没有省略号，且全部位于人物图内。
