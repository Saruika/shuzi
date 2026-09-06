# 全屏背景与原生沉浸栏位（iOS 17+）

## 全局配置

实际实现位于 `Yishu/App/AppTheme.swift`：

```swift
private struct ThemeNavigationChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbarBackground(.automatic, for: .navigationBar, .tabBar)
        } else {
            content
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar, .tabBar)
                .toolbarBackground(.automatic, for: .navigationBar, .tabBar)
        }
    }
}
```

- 根内容的 `appAppearance` 使用 `.background { AppTheme.ink.ignoresSafeArea(.container) }`，
  背景覆盖系统栏与底部安全区，但正文不全局 `ignoresSafeArea`。
- 移除旧 `UITabBarAppearance.configureWithOpaqueBackground()` 和每页实色导航栏覆盖。
- 普通导航使用 `AppNavigationStack` 包装原生 `NavigationStack`，根页面与容器共同采用统一修饰器。
  带绑定路径的作品导航保留原来的 NavigationStack/path 身份，同样应用该修饰器；不重建导航栈。
- `SecureCaptureSurface` 的 UIKit 承载面覆盖整个窗口，让内层 SwiftUI 背景能绘制到屏幕边缘。
  不修改截图保护逻辑、不关闭保护、不把照片放到保护容器外面。
- 浅色、深色与自选主题继续使用原来的颜色令牌；首页是照片画布，系统时间使用白色，
  状态栏只保留轻微透明渐变，不设置整块黑色或主题色背景。离开首页恢复所选主题的系统配色。

## 单个页面与 push 示例

项目入口已应用 `appAppearance(isAppRoot: true)`；下面展示同一套配置如何接入新的
Tab 页面。不要给背景以外的整个 TabView 或 NavigationStack 忽略安全区。

```swift
struct ExampleRoot: View {
    var body: some View {
        TabView {
            ExampleTab()
                .tabItem { Label("作品", systemImage: "square.grid.2x2") }
        }
        .appAppearance(isAppRoot: true)
    }
}

// 项目内共用的容器：将规则传给根页面与 push 目的页面。
struct AppNavigationStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            content.themeNavigationChrome()
        }
        .background { AppTheme.ink.ignoresSafeArea(.container) }
        .themeNavigationChrome()
    }
}

struct ExampleTab: View {
    var body: some View {
        AppNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("介绍")
                    NavigationLink("查看详情") { ExampleDetail() }
                }
                .padding()
            }
            .navigationTitle("作品")
        }
    }
}

struct ExampleDetail: View {
    var body: some View {
        ScrollView {
            Text("详情内容").frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("详情")
        .background { AppTheme.ink.ignoresSafeArea(.container) }
    }
}
```

不要在每个页面再添加 `.toolbarBackground(.visible, ...)` 或实色背景，否则会覆盖全局策略。
List/Form 通过全局 `.scrollContentBackground(.hidden)` 使用主题背景，不另铺系统灰底。
ScrollView/List 的安全滚动边距由系统管理；不要给整个正文加 `.ignoresSafeArea()`，
否则返回按钮、输入框、键盘和最后一行可能被系统栏遮挡。

## 首页照片

外层 GeometryReader 保留当前状态栏/TabBar 的实际安全边距，内层照片画布使用
`.ignoresSafeArea(.container)`。HomeHeroOverlayLayout 在完整画布中单独计算安全的天气和文案位置。
横屏完整照片仍按比例放入安全展示区，同一张图的背景延伸到屏幕边缘，避免重新出现只显示人头。
不增加图片下载、磁盘缓存或第三方依赖。

首页使用原生 `ScrollView(.horizontal)`、`.scrollTargetLayout()`、
`.scrollTargetBehavior(.paging)` 与 `.scrollPosition(id:)`。旧嵌套分页 TabView 在实测中
会让照片向上偏移约 10.67pt（整个窗口 956pt），仅叠加 ignoresSafeArea 不能解决；
改用原生滚动分页后，保护开启/关闭的照片窗口边界与双向翻页已通过专项。
`ScrollViewReader` 在首次出现及窗口尺寸改变后将原选中页定位到 `.leading`，
避免从非第 1 张启动或旋转时页码与实际可见照片分离；不重建相册或导航状态。
iOS 26 的首页额外关闭垂直 `scrollEdgeEffectHidden`，避免横向照片轮播触发底部深色
滚动边缘遮罩；普通纵向页面继续保留系统磨砂行为，导航控件仍使用自身原生材质。

## 平台边界与验收

`.automatic` 让原生栏背景跟随 ScrollView/List 的位置变化；不是手写滚动位移动画。
iOS 26 使用系统 Liquid Glass，iOS 17–18 使用原生 Material。iOS 17 没有同等的原生
TabBar 滚动最小化接口，因此采用题目允许的“自动磨砂”方案，不用私有 API 模拟自动隐藏。
是否显示导航标题、媒体详情页是否隐藏栏位，保留原页面的产品决定。

不能承诺所有系统及设备“完美兼容”而不实测。当前机器只有 iOS 26.5 模拟器运行时，
iOS 17 路径可编译但运行时验收仍需相应设备/运行时。新增照片覆盖全屏和控件安全边界测试，
需同时测试保护开启/关闭、主流 iPhone/iPad 横竖屏、浅深主题、push/pop、键盘与大字号。

官方依据：[toolbarBackground 自动行为](https://developer.apple.com/documentation/swiftui/view/toolbarbackground(_:for:)-7lv0f)、
[TabBarMinimizeBehavior](https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior)。

本文说明实现与验收边界，不代替最终测试报告。
