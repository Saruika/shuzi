# iOS 27 适配记录

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
