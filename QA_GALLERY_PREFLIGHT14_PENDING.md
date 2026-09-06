# 相册捏合回归：历史问题未全部闭环

2026-09-06 更新：用户明确要求先上传最新 TestFlight 给他人测试。此次允许内部测试分发，
不等于下述历史间歇性失败已完成根因闭环，也不等于正式 App Store 放行。旧证据继续保留。

2026-09-06，权限已恢复。服务端认证基础已独立提交并推送：
`8197577c003d6bd807a7b976f43f19fff1f01d18` / `v1.4.0-build2-preflight14`。
该提交不包含本文或目前两个 Swift 文件的本地修改。

## 当前保留的本地 App 改动

- `GalleryZoomAccessibilityElement.accessibilityValue` 即时读取 UIScrollView 的 zoomScale。
- 一项 XCTest 直接设置 1.25x/2x/4x/1x/3x/1x，检查读值及 hosted artwork 未重建。
- 仍使用原自定义 UIPinchGestureRecognizer，没有保留下面失败的原生手势实验。
- 临时诊断日志及测试启动标志已经移除；UI 测试原有断言、手势力度和超时未放宽。

## 证据与边界

1. iPhone 17 Pro Max / iOS 26.5，新模拟器先运行首次通知授权测试：通过。
   同一设备 190 单测通过，重复捏合/复位/拖动/翻页/关闭的四种配置通过。
   `/tmp/yishu-preflight14-startup.xcresult`
   `/tmp/yishu-preflight14-phone-regression.xcresult`
2. iPad Pro 13-inch (M5) / iOS 26.5，同样先运行首次授权：通过。
   190 单测通过，8 次 UI 配置运行中 7 通过、1 失败。
   失败为横屏深色的首次捏合后仍读到 100%，断言在 UI 测试第 2005 行超时；
   其余三种重复捏合配置及全部四种查看器窗口布局配置通过。
   `/tmp/yishu-preflight14-ipad-startup.xcresult`
   `/tmp/yishu-preflight14-ipad-regression.xcresult`
3. 增加只含数值的临时手势日志后重复捏合四配置均通过。
   这只能说明问题存在间歇性，不能把重跑通过当成根因已解决。
   成功日志显示 changed 回调正常把 scale 提高到约 1.76–1.83，结束时没有被复位。
   没有捕获到失败那次的手势回调，不能据此断言失败是未接收手势或布局重置。
   `/tmp/yishu-preflight14-ipad-trace.xcresult`
   `/tmp/yishu-preflight14-zoom-trace.log`
4. 实验：保留 UIKit canvas 和全部布局，只恢复 UIScrollView 原生 pinch。
   190 单测通过，但四种捏合 UI 配置全部失败；四种窗口布局配置通过。
   此实验已撤回，不能发布。该结果不证明问题来自截图保护，也没有取消保护。
   `/tmp/yishu-preflight14-ipad-native.xcresult`

下一步应先在隔离调试构建比较实际触摸命中、手势回调与缩放后的几何状态，
必要时对受保护/普通测试容器做 A/B 诊断，再决定改动。不要再凭一次重跑通过放行，
不要通过删除用例、改为辅助功能按钮缩放或放宽断言掩盖捏合问题。
当前没有上传 TestFlight，也没有改动正式版本和真实用户。

## 2026-09-06 后续对照诊断

- 普通/受保护容器使用相同原生 pinch 实验：各四种 UI 配置，8/8 失败。
  `/tmp/yishu-pinch-ab2.xcresult`。日志确认普通容器也收到 began/changed/ended，
  手势倍率约 1.7–1.8，但 scrollView.zoomScale 保持 1；因此不能归因于保护容器。
  最初一次诊断构建因调试日志使用已移除的 NSStringFromCGRect API 编译失败，
  改用 NSCoder.string(for:) 后才得到上述运行结果；失败构建不计入 UI 测试。
- 原有自定义 pinch + 即时辅助功能读值 + 临时几何/手势日志，四种 UI 配置各两遍，
  共 8 次通过、0 失败；每次包含三轮捏合、拖动、复位及最后翻页/关闭。
  `/tmp/yishu-pinch-custom-trace2.xcresult`。这不是间歇性失败已经消失的证明。
- 日志看到同一窗口中视口高度有 32 点的改变；未捕获到失败手势与该变化同时发生，
  不能将其直接认定为根因。后续可增加缩放期间安全区/状态栏变化的确定性回归。
- 原生手势实验、对照用例、调试标志、临时日志已全部移除；UI 用例恢复原样。
  当前保留的生产改动只有即时辅助功能缩放读值及对应单测。
- 本地源码门禁通过；PHP/Composer 未安装的部分不算 macOS 运行验证，
  Linux 专用的运行用例按脚本要求跳过。
- 去掉诊断代码后的首次混合回归有 190 单测通过，但未先处理首次通知授权；
  单测宿主触发的系统通知弹窗阻挡了 UI 主导航。已截图确认并中止该次运行，
  不能将其计为相册测试通过，也不能当作捏合根因。结果为
  `/tmp/yishu-preflight15-final-ipad.xcresult`（中断）。
- 新建独立 iPad 模拟器后先执行首次通知授权测试，通过：
  `/tmp/yishu-preflight15-fresh-permission.xcresult`。
  随后的最终 iPad 单测和 UI 回归在同一已授权设备上执行完成：
  190 单测、四种重复捏合配置、四种查看器布局配置全部通过，0 失败、0 跳过。
  `/tmp/yishu-preflight15-authorized-ipad.xcresult`；最终源码门禁也通过。
  这仅证明上述局部回归通过，不代表已上传 TestFlight 或修复全部缩放问题。

## 2026-09-06 同方向视口变化的确定性修复

- 在 UIKit 查看器上设为 2x，令宽度保持 1024 点，高度在 690 / 658 点间切换，旧代码稳定
  重置到 1x / 零偏移。正确浮点期望的失败证据为 `/tmp/yishu-preflight20-resize-before2.xcresult`。
  首轮测试自身的归一化坐标用了整数字面量除法，已修正并保留 `/tmp/yishu-preflight20-resize-before.xcresult`。
- 修复只在同方向视口改变时保留倍率和归一化查看中心；真正横竖屏切换、切换图片仍恢复 1x。
  若布局变化时手势仍进行中，重新计算手势起始倍率，不注销或重建手势识别器。
- 新增两项单测；查看中心允许一个实际屏幕像素的 UIKit 对齐误差，缩放倍率仍精确验证为 2x。
  修复后的首次测试有 0.043 点与 0.01 点容差不符，记录于 `/tmp/yishu-preflight20-resize-after.xcresult`；
  没有放宽既有 UI 捏合倍率、等待时间或交互断言。
- 最终 iPad：208 单测及 8 次保护开启的横竖屏/深浅色相册测试通过，0 失败、0 跳过。
  `/tmp/yishu-preflight20-ipad-gallery.xcresult`。此次明确修复一个真实布局缺陷，但未捕获历史失败
  手势与该缺陷同时出现的证据，因此不把它宣称为全部间歇性失败的唯一成因。
- 首次手机复测误用了 iPad 专用精简产物，两个社交图标只带 2x，触发 72 像素最低尺寸检查。
  assetutil 确认原产物仅 48px，而独立 iPhone 构建包含原有 72px / 3x 资产；没有修改图标或降低断言。
  已中止错误产物的运行并保留 `/tmp/yishu-preflight20-phone-gallery.xcresult`；按手机重新构建后再验收。
- 最终 iPhone 17 Pro Max 独立构建：208 单测、8 次相册 UI 配置通过，0 失败、0 跳过；
  `/tmp/yishu-preflight20-phone-gallery-final.xcresult`。正式 IPA 同时含 1x/2x/3x 图标，验证到 72px。
  两台设备最终均未改变原有捏合测试动作或断言。本轮允许按用户请求先发 TestFlight 收集真机反馈，
  但上述全量根因与正式上架边界仍然保留。
