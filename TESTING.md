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

## 覆盖的用户路径

- 未登录启动时只出现注册/登录、隐私政策和管理员审批入口，首页等主导航不会泄露。
- Debug 专用已批准视觉夹具下，首页、作品、影视、收藏和关于五个主模块都能出现并切换。
- 作品网格可打开相册，相册封面可进入全屏查看，收藏操作可达。
- 受保护画廊在未禁用截屏保护的独立 UI 用例中仍能正确取得环境对象、展示画廊并保留关闭/收藏控件，避免全屏弹层只剩空白保护层。
- 收藏空状态可回到作品页；图片请求只对短暂错误有界重试，失败后显示可访问的“重新加载”入口。
- 影视页 UI 验证播放、暂停与静音入口；用真机或网络调试工具模拟慢网后，另行检查视频缓冲、播放停滞和超时都会出现可见重试，不会静默卡在加载状态。
- “发送合作邀约”可进入完整表单，管理员入口可进入安全登录页。
- 粉丝注册入口可达，抖音 ID 必填字段、管理员审批说明和注册前隐私政策可读。
- 原生“通过 Apple 登录”入口可达；首次 Apple 验证夹具只能进入昵称、必填抖音 ID 和隐私同意表单，主导航保持不可见，并同时提供退出和永久删除申请。
- Apple 登录安全单元回归覆盖 nonce SHA-256、state 恒时比对、challenge 过期/单次使用形状、凭据字段最小化、credential state 的授权/撤销/转移决策，以及系统查询失败时继续使用有效服务端会话的连续性边界。
- Apple 注册草稿在完成、退出、删号、换号、撤销凭据和 App 离开前台时清空；Apple-only 账号不出现密码修改，但登录设备与会话管理仍可用。
- 管理员目录可以加载 `accountSource=apple` 且 `requiresAppleRegistration=true` 的未完成申请，显示“等待绑定抖音 ID”；抖音 ID 为空但缺少该精确标记、来源错误或完整 profile 仍带标记时必须拒绝，且未完成资料的用户没有批准为 active 的入口。
- 账号单元回归覆盖恢复状态未完成前失败关闭、主动改密的当前/新密码校验、会话目录的唯一当前设备约束，以及换令牌时丢弃迟到响应。
- 收藏与最近浏览单元回归覆盖账号 A/B 相互隔离、退出后不读写、删除只清理指定账号及非法 UUID 失败关闭。
- 相同用例同时在 iPhone 与 iPad 上执行；布局专用测试使用 XCTest 的 `runsForEachTargetApplicationUIConfiguration`，按工程声明的横竖屏与外观配置分别启动 App，并在 `.xcresult` 中保留关键页截图。这样也正确覆盖 iPadOS 26 中独立于物理方向的窗口几何。
- 辅助功能大字号回归会使用 Accessibility XXXL 在每种 UI 配置中重新打开首页，确认天气与主操作始终可见、可点击、不越界且不小于 44pt；作品搜索另有交互与 44pt 门禁。
- 聚焦辅助功能门禁会遍历首页、作品与关于页：iPhone 直接运行 Apple 系统审计，检查对比度、触控区域、文字裁切和语义；iPad 使用确定性的安全区、44pt、VoiceOver 语义断言，并由独立 UI 配置套件的 Accessibility XXXL 与横竖屏/窗口化用例补齐覆盖。这是为了避开 XCTest 在 iPad 快照阶段的框架错误 -56，不跳过门禁、不吞掉失败。
- 开屏回归在 Accessibility XXXL 下确认文案不会被定时关闭、跳过按钮位于状态栏安全区且不小于 44pt；Showreel 回归验证自绘进度、播放和静音控制可见可用，不依赖系统播放器外壳。

UI 测试仅在 Debug 构建中使用参数关闭截屏保护；需要遍历主内容的视觉用例还会启用仅 Debug 编译存在的已批准夹具。门禁用例不启用该夹具，并单独验证未登录用户无法看见主导航。Release 构建中这些参数全部不生效。

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
- Apple 首次认证只能取得 `apple_onboarding` 会话；未绑定抖音 ID 时 `/fan/session` 只能返回 `appleRegistration`，管理员目录仍可读取该申请但服务端和客户端都拒绝提前批准或读取内容。
- Apple 删号必须使用 `delete_account` challenge、当前 bearer 会话和同一 Apple subject 的近期重新认证；成功后撤销或排队重试撤销 Apple refresh token，并删除 onboarding/账号/会话数据。

脚本结束时自动删除测试账号和临时管理员访问码。

## 安全门禁

`Scripts/security-check.sh` 会在构建前检查：

- Git 中是否误放 `.p8`、`.p12`、描述文件、`.env` 或私钥。
- 文本中是否出现高置信度的云密钥、私钥或 URL 内嵌密码。
- iOS 生产 Swift 源码是否使用明文 HTTP。
- Xcode/Privacy/Entitlement 配置、WordPress PHP 插件和 Python 订阅校验器是否通过基础语法检查。
- 内容清单会用超量集合、重复 ID、异常时长、超长 URL 和未知缓存版本做负向单元回归。
- 安全容器会模拟系统安全画布缺失或脱离层级，验证重试耗尽后只显示不含影像的保护提示，不会把受保护 SwiftUI 视图放在普通容器中。
- 粉丝密码恢复、会话目录、迟到响应和不确定删除结果会做失败关闭单元回归；服务端合同测试另行检查恢复记录不含临时明文密码、路由权限范围和删除限流。
- Release 构建完成后再次扫描实际 `.app` 包，确认没有私钥、云密钥、环境文件或意外打包的敏感资源。

GitHub Actions 只有仓库内容读权限，不使用 Apple、腾讯云或服务器密钥；外部 Action 固定到完整 commit SHA。失败时保留七天 `.xcresult` 供排查。

## Build 36 发布前验收

1. 确认构建设置为 `1.3.24 (36)`、Bundle ID `cn.com.shuzijun.yishu`，且 App ID 与本次签名描述文件同时包含 Sign in with Apple 和 WeatherKit；能力变更后必须重新生成签名描述文件。
2. 服务端运行锁定依赖的 `composer install --no-dev --classmap-authoritative`；Apple `.p8` 位于 Web 根目录外，只通过 `YISHU_APPLE_TEAM_ID`、`YISHU_APPLE_KEY_ID`、`YISHU_APPLE_PRIVATE_KEY_PATH` 引用。测试日志和仓库不得出现私钥、client secret、identity token、authorization code、nonce、state 或 Apple subject。
3. 确认服务器可通过 HTTPS 访问 `appleid.apple.com/auth/keys`、`/auth/token` 和 `/auth/revoke`，WP-Cron 或等价计划任务能执行撤销重试；反向代理继续转发 `Authorization` 与安装记录头。
4. 在真实 TestFlight 安装执行：新 Apple 账号 → 必填抖音 ID → 待审批 → 管理员批准 → 主内容；同一 Apple ID 重复登录；取消授权、网络失败与重新前台；其他设备会话撤销；onboarding 和已批准状态分别永久删号。
5. 删除后确认 App 本机收藏/最近浏览分区消失、原 bearer 不可使用、Apple 账号可按产品规则重新申请；App Store 隐私标签与 App 内政策须包含昵称、用户 ID、设备级随机标识和粗略位置，不声明未请求的 Apple 邮箱。
6. 在 iPhone、iPad 横竖屏和辅助功能字体下检查作品页：搜索框紧贴状态栏下方的系统安全区域，且聚焦、输入、清除、取消、空结果、下拉刷新和详情返回均正常。同时开启 VoiceOver、减少动态效果和减少透明度，确认保护遮罩不会让底层内容被聚焦。
