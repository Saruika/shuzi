# iOS 27 适配记录

## 2026-10-19：iPhone Duo 适配（1.5 Build 5）

Xcode 27.1 已提供 iOS 27.1 SDK 与 iPhone Duo 模拟器。1.5 (5) 改用 27.1 SDK 构建，并让关于页、相册查看器按窗口尺寸类别而非设备类型选择平板布局；Duo 合拢/展开模拟器验证与边界见 [1.5 Build 5 记录](Docs/V1.5-BUILD5-IPHONE-DUO.md)。下文 9 月 18 日“本机无 Duo 运行时”为当时状态。

## 2026-09-18：正式审核与 iPhone Duo 预检

本节为当前补充，下文是既有版本的历史测试，不将旧结果冒充 Build 11 验收。

- 实际已上传 Build 10 的 IPA、xcarchive 和 Mach-O 交叉核对：Xcode 27.0
  `27A266a`、iPhoneOS 27.0 SDK `24A430`、最低 iOS 17、arm64、iPhone/iPad
  两种设备族和四方向一致。Apple 已开放 Xcode 27 / iOS 27 SDK 的正式 App Store 提交。
- Apple 的 iPhone Duo 适配视频区分“能运行”与“使用整个屏幕”：iOS 27 SDK
  改善展开屏幕利用率，iOS 27.1 SDK 才提供新的全屏及纵向系统栏行为。本机仅有
  Xcode 27.0，`simctl list devicetypes` 无 iPhone Duo。官方准备页当次仍标注
  Xcode 27.1 beta 稍后提供；不能据此宣布 Duo 专用模拟器或折叠真机测试通过。
- 可先核验的原则是使用窗口/视图的实际尺寸和 size class，前景控件遵守各边安全区，
  背景允许全幅，不能用 iPad 设备类型或方向作为折叠状态的替代。本轮针对实际
  aspect-fit 图片在连续改宽时的缩放焦点漂移进行修正；保留原有旋转回到完整照片的行为。
- 待专用运行时可用，应补测合拢、展开、折叠、旋转、左右分屏、非对称安全区、
  图片放大关闭、游戏进度延续、后台恢复和保护遮罩。普通 iPhone/iPad 尺寸测试
  不等价于这些硬件/系统姿态验收；正式商店文案不宣称已通过 Duo 全姿态验证。

本轮正式审核/元数据状态另见
[Build 11 审核预检](Documentation/app-store-build11-review-preflight.md)。

官方来源：

- [App Store 接受最新 SDK 提交](https://developer.apple.com/news/?id=k1mtkt1k)
- [iPhone Duo 准备页](https://developer.apple.com/iphone-duo/)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)

---

日期：2026-09-16。开发分支：`codex/ios27-compatibility`。

本次为兼容性开发，不重新设计页面，不修改生产服务器、账号、截图保护规则、隐私收集行为或 TestFlight 分发状态。版本号暂时保留，发布前需分配新的构建号，不能覆盖已经上传的 Build 7。

## 工具链与支持范围

- 本机实测 Xcode 27.0（27A266a），iOS / iOS Simulator SDK 27.0。
- iPhone 18 Pro Max、iPad Pro 13 英寸 M5：模拟器 iOS 27.0（24A434）。
- 旧系统对照：iPhone 17 Pro Max，模拟器 iOS 26.5（23F77）。
- 最低部署版本保持 iOS 17.0；当前未安装 iOS 17 runtime，不能将编译通过称作 iOS 17 运行实测。
- Apple 公布的 iOS 27 正式系统版本为 24A437，与本机模拟器 24A434 不同。真机系统和线上服务仍需另行验收。

## 适配变更

1. **TabView 选择有效性**：iOS 27 对指向隐藏或不存在页面的 selection 增加限制。影视权限撤销时，绑定读取立即回到有效页；不再仅依靠渲染后的 `onChange` 修正。此项是依据官方变更做的预防修复，未宣称已复现线上崩溃。
2. **相册分页同步**：用同一可见照片快照构造标签与 selection；照片移除、初始索引过期、权限撤销及空相册均不向分页容器传入无效页面。Tab 与相册合计补充 5 项选择状态单元测试。
3. **模拟器系统选择**：新增只读、确定性的 runtime 选择器，支持显式指定 `27.0` / `26.5`，缺失时失败，不默默降级。新增 9 项脚本单元测试；原通知授权独立设备与完整测试流程保留。
4. **手机横屏搜索**：复现取消按钮顶部坐标为 -1、实际点击无法取消的问题。紧凑高度下增加 8 点内部顶部留白，不沿用平板竖屏的负偏移；新增滚动后输入、取消、列表恢复的真实操作断言。XCTest 对输入框的 `isHittable` 判断在本系统上会误报，因此不以这一属性代替真实操作验证。
5. **iPad 返回后的搜索栏跳动**：复现搜索栏从 y=94.5 跳到 30.5，覆盖顶部 Tab 的 64 点位移。iPadOS 27 将原有搜索控件交给系统导航栏承载，保持根页／详情页的导航栏布局连续；不硬编码状态栏或 Tab 高度，也不改变相册、首页和播放器内容。iPhone 和旧系统继续使用原布局。
6. **iPad 导航栏搜索取消**：真实输入成功时，导航栏内的焦点状态未回传，导致取消按钮缺失。非空查询也显示取消，用户点击后使用公开的 responder API 收起键盘；保护容器仍保持开启。回归同时检查返回位置、详情不残留搜索框、输入值、取消、键盘关闭和列表恢复。
7. **沉浸式边缘测试**：影视海报可正常透过系统磨砂导航栏。在图像之外的页脚验证底部页面背景，不以照片颜色误判黑边；顶部搜索材质与同一材质的无内容边缘比较。像素比例与颜色阈值没有降低。

## 验收记录

证据目录：`/Users/mathiashu/Library/Developer/Hi-Shuzi-QA/ios27-adaptation-NHio64`。失败结果保留，不用后续成功覆盖原始证据。测试使用隔离模拟器，导航／缩放专项使用生成的图片夹具，主题检查另保留本地页面截图；这些 QA 附件不纳入 Git 或 App 资源。没有删除用户现有模拟器或修改生产账号，正式 App 的图片不落盘规则保持不变。

| 检查 | 结果／证据 |
| --- | --- |
| SDK 27 Release 编译、静态分析、包内容检查 | 通过；`release-source-final.log`。不含打包照片、密钥及检查范围内的 Debug 专用夹具。 |
| iOS 27 全部单元测试 | 287 项，286 通过，1 项跳过；跳过的是需要显式隔离审核环境授权的在线账号审批／删除测试，不操作真实用户。 |
| iPhone iOS 27 主题边缘、横屏输入、滚动导航 | 3 项通过；`iphone-acceptance.xcresult`（同包还含 287 项单元测试，总计 289 通过、1 跳过）。 |
| iPhone iOS 27 最终 UI 补跑 | 4 项通过、0 失败，完整结果包正常写入；`iphone-bounded-1VsTrA/result.xcresult`。包含横屏搜索、主要 Tab、截图保护与截图后操作、浅深色滚动导航。 |
| iPhone iOS 26.5 对照 | 290 通过、0 失败、1 跳过；`legacy-acceptance.xcresult`。包含全部单元测试、主要 Tab、横屏输入、受保护图片打开关闭、截图后继续操作。 |
| iPadOS 27 搜索／进入／返回最终回归 | 9 次运行通过、0 失败；`ipad-search-acceptance.xcresult`。搜索几何 4 组配置、保持保护开启的反复进入／返回与实际输入取消 4 组配置、竖屏逐帧布局轨迹 1 次。xcresult 将动态配置合并为 3 个测试函数，不能误读为只跑了 3 次。 |
| iPadOS 27 浅色入口与主题边缘 | 各 1 项通过；`ipad-light-navigation.xcresult` 从深色首页进入月白作品页、三次进入返回及输入取消通过；`ipad-theme-acceptance.xcresult` 检查月白／靛蓝主题的主要页面与设置、隐私二级页。 |
| 首次通知授权 | iPhone iOS 27、iPadOS 27、iPhone iOS 26.5 各 1 项通过；`iphone-permission`、`ipad-permission`、`legacy-permission` 的 xcresult。不是 APNs 真推送送达证明。 |
| 模拟器选择器与 CI 隔离流程 | 9 项选择器测试通过；两类设备的原有授权／全套测试同设备流程及失败清理契约通过。 |

早期 `ipad-ui.xcresult` 中关于页布局／固定左图、首页切图不空白、图片缩放与关闭等 25 次配置运行通过，1 次返回跳动失败已由最终回归确认修复；该历史结果不会伪装成全绿报告。搜索焦点问题的两轮失败证据 `ipad-protected-navigation.xcresult`、`ipad-focus-owner.xcresult` 同样保留。

iPhone 截图保护复测用例曾执行通过，但 `iphone-protection-acceptance` 和 `iphone-final-gnUpr7` 的 Xcode 结果收集长时间未完成；终止这些测试任务并保留日志，不将未完成写入的 xcresult 当作正式通过证据。重启专用模拟器后仍曾复现结果收集停滞。最后一轮使用 Xcode 支持的 `-collect-test-diagnostics never`，不收集额外 sysdiagnose，仍保留全部测试断言、截图附件及结果包，并补跑滚动导航；4 项全部通过且完整结果包生成。该参数只用于本地补跑，没有更改 CI 默认诊断策略，也不能据此断言收集停滞的底层原因已完全定位。

本地源码／资源契约检查通过。完整 `security-check.sh` 曾运行通过，但本机没有 PHP 和 Composer，对应可选检查未执行，不能称作服务端或依赖漏洞审计全部完成。此次适配没有更改服务端。

结论：本轮兼容性代码与所列本地回归已完成；不是整套线上功能、所有系统版本或真机验收。尚未上传 iOS 27 适配的新 TestFlight 包。

## 尚不能由模拟器证明的项目

- iOS 27 正式真机上的 Apple 登录、WeatherKit 定位与联网响应、APNs 真推送送达及真实后台恢复。
- 静态截图兼容保护依赖系统渲染行为，不是 Apple 对任意内容提供的公开 DRM 保证；模拟器截图测试通过不保证所有真机或未来系统版本。
- 本轮使用本地测试，不声称 GitHub Actions 已运行通过，不产生新 TestFlight 上传或正式商店提交。

## 官方参考

- [Apple 开发者发行记录](https://developer.apple.com/news/releases/)
- [iOS / iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- [Xcode 27 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)

## 2026-09-16 真机问题后的本地修复

真机 Build 7 的跟进记录位于 `Hi-Shuzi-QA/ios27-physical-20260916-H2OORT/FOLLOWUP_REPORT.md`：镜像可见照片、手机横屏取消按钮部分越界。以下属于本地候选代码，不能据此把手机上的 Build 7 标为已修复。

### 捕获与窗口生命周期

- 捕获状态改为明确的 active / inactive / unknown。初次未取得有效状态时保留遮罩；后续 unknown 不再覆盖已知 active。只有所属前台场景明确 inactive 且屏幕未捕获，才能解除捕获遮罩。
- 观察实际所属 UIWindowScene 的 trait 和同一 screen 的捕获通知，不再混合所有 connectedScenes，也不依赖嵌套安全 UIHostingController 的临时 trait。SwiftUI 捕获覆盖层移至安全宿主外侧，并取消保护页淡入淡出。
- 窗口级遮罩独立于根页面，采用同场景、非 key 的高一层窗口。沿用「狐狸姐姐温馨提示」；后台快照仍使用原黑色遮罩。不改变页面设计、账号数据、截图保护开关或服务端。
- 新增等待 UIKit 全屏呈现完成的回归，实际复现底层视图移出窗口后遮罩被解除。修复后临时移出不等于销毁；SwiftUI dismantle / scene disconnect 才明确解绑。模态仍打开时的 scene 解挂与重新绑定也纳入断言；旧窗口先解除 rootViewController，避免复用控制器时跨窗口挂载。
- 横屏搜索沿用本分支已完成的紧凑高度修复，补充左横屏／竖屏／右横屏连续切换及输入、清除、取消、键盘关闭的真实操作验证，没有重新设计搜索栏。

### 证据边界

本次证据目录：`/Users/mathiashu/Library/Developer/Hi-Shuzi-QA/capture-fix-3FFgxN`。`phone-final.xcresult` 保留全屏遮罩断言失败的原始记录，后续成功结果另存，不覆盖失败。`phone-fixed.xcresult` 是中间修复版本；最终验收以 `phone-acceptance.xcresult` 及后续设备对照结果为准。

| 最终代码检查 | 结果／证据 |
| --- | --- |
| iPhone iOS 27 单元＋UI | `phone-acceptance.xcresult`：301 通过、1 跳过、0 失败。包括 297 项单测（296 通过、1 在线审核环境测试跳过）和 5 项 UI：连续旋转搜索、窗口级遮罩、浅色及深色截图后继续操作和两轮前后台恢复、全屏图片翻页与关闭。 |
| iPadOS 27 UI | `ipad-acceptance.xcresult`：7 次运行通过、0 失败。保护开启的浅深色／横竖屏图片翻页关闭共 4 组，另含窗口遮罩、浅色反复进入返回与搜索、截图后操作及两轮前后台恢复。结果包将动态配置合并为 4 个测试函数，实际执行 7 次。 |
| iPhone iOS 26.5 对照 | `legacy-acceptance.xcresult`：299 通过、1 在线审核环境测试跳过、0 失败。包括全部 297 项单测及横屏旋转搜索、受保护图片翻页关闭、截图后操作与前后台恢复 3 项 UI。 |
| 新设备通知授权 | `ipad-permission.xcresult`、`legacy-permission.xcresult`：各 1 项通过；分别为 iPadOS 27、iOS 26.5 新建隔离模拟器，不是真 APNs 送达验收。 |
| SDK 27 Release 模拟器编译、静态分析、包内容检查 | `release-acceptance.log`：通过；warnings-as-errors，不含受保护照片、凭据或被检查的 Debug 专用夹具。不是已签名的上传 IPA。 |
| 本地源码与资源契约 | `security-acceptance.log`：通过。Linux flock / 部分真实部署、PHP / Composer 等本地无法执行的检查不计作服务端验证。 |

捕获信号边界由单元测试注入；模拟器截图检查证明所测渲染和操作路径，不是真机镜像的零帧保护证明。窗口夹具测试仍产生 UIKit appearance-transition 告警，不能把断言通过写成系统日志完全无警告。需要安装包含修复的新测试版本后，重新做真机镜像／录屏和停止捕获后的恢复验收；本轮不覆盖手机 TestFlight、不修改账号、不上传或发布。

另记录既有性能警告：影视页退出时同步 `AVAudioSession.setActive` 可能影响主线程响应，早期适配日志中已存在；本轮未修改播放器或音频策略，也未宣称此项已修复。

本轮最终代码的上述检查均已完成，专用模拟器已关闭，原始失败与通过证据均保留。最低 iOS 17 仍只是编译兼容，未进行该 runtime 的运行测试；GitHub CI、TestFlight 上传、正式真机新包验收均不包含在本地通过结论中。
