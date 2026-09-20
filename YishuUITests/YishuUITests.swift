import UIKit
import XCTest
import Vision

final class YishuUITests: XCTestCase {
    func testAlbumFirstPhotoFillsWidthAndCaptionSitsBelow() {
        for theme in ["blackGold", "ivory"] {
            let app = launchApp(arguments: ["-open-portfolio-for-visual-testing",
                "-use-deterministic-gallery-images-for-testing",
                "-cn.com.shuzijun.yishu.appearance.v1", theme], screenProtectionEnabled: true)
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-title-")).firstMatch
            let cover = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-cover-")).firstMatch
            if cover.exists { XCTAssertGreaterThanOrEqual(title.frame.minY, cover.frame.maxY, "相册名位于封面下方") }
            card.tap()
            let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-")).firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 8))
            let frame = photo.frame
            XCTAssertEqual(frame.width, app.windows.firstMatch.frame.width, accuracy: 2, "首图必须填满页面宽度")
            XCTAssertEqual(frame.height / frame.width, 1.5, accuracy: 0.02, "保留测试图的完整 2:3 比例")
            app.swipeUp()
            let caption = element("portfolio-hero-caption", in: app)
            XCTAssertTrue(caption.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(caption.frame.minY, photo.frame.maxY - 2, "标题说明不能覆盖照片")
            app.terminate()
        }
    }


    func testAboutCompactLayoutKeepsNavigationAndCompleteCaption() throws {
#if targetEnvironment(simulator)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeRight] : [.portrait]
        for theme in ["blackGold", "ivory"] {
            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation
                let app = launchApp(arguments: [
                    "-open-about-for-visual-testing",
                    "-use-deterministic-gallery-images-for-testing",
                    "-hold-home-remote-images-for-visual-testing",
                    "-expose-about-portrait-canvas-for-testing",
                    "-expose-about-visible-bottom-for-visual-testing",
                    "-cn.com.shuzijun.yishu.appearance.v1", theme,
                ], screenProtectionEnabled: true)
                let role = element("about-role-summary", in: app)
                let biography = element("about-biography", in: app)
                let portrait = element("about-portrait-canvas", in: app)
                let bottom = element("about-visible-bottom", in: app)
                XCTAssertTrue(tabButton("关于", in: app).exists, "底部/顶部导航仍须保留关于入口")
                XCTAssertFalse(element("about-heading", in: app).exists, "页面不能重复展示关于标题")
                XCTAssertTrue(role.waitForExistence(timeout: 8))
                XCTAssertTrue(biography.exists)
                XCTAssertEqual(role.label, "短剧演员 / 模特 / 视频创作者")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(role.frame))
                XCTAssertLessThanOrEqual(role.frame.maxY + 12, bottom.frame.minY + 1)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    XCTAssertEqual(biography.frame.minY - portrait.frame.minY, 36, accuracy: 3,
                                   "双栏简介应使用24+12点顶部间距，不能保留旧标题留白")
                    let before = portrait.frame
                    element("about-details-scroll", in: app).swipeUp()
                    XCTAssertEqual(portrait.frame.minY, before.minY, accuracy: 1,
                                   "右侧滚动不应移动左侧人物图")
                }
                app.terminate()
            }
        }
#else
        throw XCTSkip("本测试使用独立模拟器夹具，不操作真机账号")
#endif
    }

    func testReviewBannerLeavesNavigationControlsUncovered() {
        let app = XCUIApplication()
        app.launchArguments = ["-app-service-environment", "review",
            "-skip-startup-notification-authorization-for-testing",
            "-reset-fan-session-for-visual-testing", "-skip-launch-poster-for-visual-testing"]
        app.launch()
        defer { app.terminate() }

        let banner = element("workspace-review-banner", in: app)
        let workspaceEntry = element("access-gate-workspace-entry", in: app)
        let adminEntry = element("access-gate-admin-entry", in: app)
        XCTAssertTrue(workspaceEntry.waitForExistence(timeout: 15))
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(adminEntry.exists)
        for control in [workspaceEntry, adminEntry] {
            XCTAssertGreaterThan(control.frame.height, 0)
            XCTAssertLessThanOrEqual(banner.frame.maxY, control.frame.minY + 1,
                "演示提示不能覆盖登录页导航按钮：banner=\(banner.frame), control=\(control.frame)")
            XCTAssertTrue(control.isHittable)
        }
        workspaceEntry.tap()
        let selection = element("workspace-selection", in: app)
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let navigation = app.navigationBars.firstMatch
        XCTAssertTrue(navigation.exists)
        XCTAssertLessThanOrEqual(banner.frame.maxY, navigation.frame.minY + 1,
            "二级页面导航必须位于演示提示下方：banner=\(banner.frame), navigation=\(navigation.frame)")
    }

    func testReviewBannerKeepsTabsSearchAndGalleryCloseVisible() {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeRight] : [.portrait]
        for theme in ["blackGold", "ivory"] {
            for orientation in orientations {
                let app = XCUIApplication()
                // Deterministic account/image fixtures only; retain the real
                // secure rendering surface and every environment indicator.
                app.launchArguments = ["-app-service-environment", "review",
                    "-cn.com.shuzijun.yishu.appearance.v1", theme,
                    "-skip-startup-notification-authorization-for-testing",
                    "-skip-launch-poster-for-visual-testing", "-reset-fan-session-for-visual-testing",
                    "-bypass-access-gate-for-visual-testing", "-use-deterministic-gallery-images-for-testing",
                    "-use-multi-image-gallery-for-visual-testing", "-use-review-layout-fixtures-for-testing",
                    "-hold-home-remote-images-for-visual-testing"]
                app.launch()
                XCUIDevice.shared.orientation = orientation
                let window = app.windows.firstMatch
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    orientation.isLandscape ? window.frame.width > window.frame.height
                        : window.frame.height > window.frame.width
                }, object: window)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
                let works = tabButton("作品", in: app)
                XCTAssertTrue(works.waitForExistence(timeout: 12))
                works.tap()
                let banner = element("workspace-review-banner", in: app)
                let search = element("portfolio-search-control", in: app)
                XCTAssertTrue(search.waitForExistence(timeout: 8))
                XCTAssertTrue(banner.exists)
                for control in [works, search] {
                    XCTAssertLessThanOrEqual(banner.frame.maxY, control.frame.minY + 1,
                        "演示提示遮挡 Tab/搜索：\(theme), \(window.frame), banner=\(banner.frame), control=\(control.frame)")
                    XCTAssertTrue(control.isHittable)
                }
                let card = app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 8))
                card.tap()
                let navigation = app.navigationBars.firstMatch
                XCTAssertTrue(navigation.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(banner.frame.maxY, navigation.frame.minY + 1)
                let photo = app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-")).firstMatch
                XCTAssertTrue(photo.waitForExistence(timeout: 8))
                scrollToElement(photo, in: app)
                photo.tap()
                let close = element("gallery-close", in: app)
                XCTAssertTrue(close.waitForExistence(timeout: 8))
                XCTAssertTrue(banner.exists, "全屏图片仍须标明演示环境")
                XCTAssertLessThanOrEqual(banner.frame.maxY, close.frame.minY + 1)
                XCTAssertTrue(close.isHittable)
                close.tap()
                let dismissed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: close)
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
                XCTAssertTrue(photo.exists)
                app.terminate()
            }
        }
    }

    func testLandscapePortfolioSearchAcceptsInputAfterScrolling() throws {
#if targetEnvironment(simulator)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory",
            "-use-deterministic-gallery-images-for-testing",
            "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"])
        openTab("影视", in: app)
        XCUIDevice.shared.orientation = .landscapeRight
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: app.windows.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
        openTab("作品", in: app)
        let field = app.textFields["portfolio-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let initialFrame = field.frame
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        let beforeInput = XCTAttachment(screenshot: app.screenshot())
        beforeInput.name = "landscape-search-before-input"
        beforeInput.lifetime = .keepAlways
        add(beforeInput)
        verifySearchCanBeEditedAndCancelled(in: app)
        XCTAssertEqual(field.frame.minY, initialFrame.minY, accuracy: 1)

        // Keep the same app and search view alive across rotations. Relaunching
        // would conceal a stale query, focus, keyboard or transition control.
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = window.frame
                return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
            }, object: window)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(window.frame.contains(field.frame), "旋转后的搜索输入区域必须完整留在窗口内")
            XCTAssertFalse(app.buttons["清除搜索"].exists, "旋转后不应残留上次搜索的清除按钮")
            XCTAssertFalse(app.buttons["取消"].exists, "旋转后不应残留上次搜索的取消按钮")
            XCTAssertFalse(app.keyboards.firstMatch.exists, "旋转不能重新唤起已取消搜索的键盘")
            let clearedText = field.value as? String
            XCTAssertTrue(clearedText == "" || clearedText == "搜索作品", "旋转后不应恢复已取消的搜索词")
            verifySearchCanBeEditedAndCancelled(in: app)
        }
#else
        throw XCTSkip("此回归会重置隔离夹具会话并旋转设备，仅允许在专用模拟器执行")
#endif
    }

    private func verifySearchCanBeEditedAndCancelled(in app: XCUIApplication) {
        // iOS 27's field hittability can report false even when native tapping
        // and typing succeed. Verify the actual user workflow, including the
        // cancel button that really failed when placed above the window edge.
        let field = app.textFields["portfolio-search-field"]
        field.tap()
        field.typeText("ios27-no-match")
        XCTAssertEqual(field.value as? String, "ios27-no-match")
        let clear = app.buttons["清除搜索"]
        let cancel = app.buttons["取消"]
        for button in [clear, cancel] {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(button.frame.width, 0)
            XCTAssertGreaterThan(button.frame.height, 0)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame),
                          "搜索按钮必须完整显示，不能仅有中心点可点击：button=\(button.frame)，window=\(app.windows.firstMatch.frame)")
        }
        clear.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let text = field.value as? String
            return text == "" || text == "搜索作品"
        }, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch.waitForExistence(timeout: 5))

        // Re-enter a query so cancellation must clear real text, not only hide
        // a button after the separate clear action already emptied the field.
        field.tap()
        field.typeText("ios27-no-match")
        XCTAssertEqual(field.value as? String, "ios27-no-match")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(cancel.frame), "重新输入后取消按钮仍必须完整留在窗口内")
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let text = field.value as? String
            return !cancel.exists && !clear.exists && !app.keyboards.firstMatch.exists &&
                (text == "" || text == "搜索作品")
        }, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "取消后必须清空文本、关闭键盘并移除清除/取消按钮")
        XCTAssertFalse(app.buttons["取消"].exists)
        XCTAssertNotEqual(field.value as? String, "ios27-no-match")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch.waitForExistence(timeout: 5))
    }

    func testScrollChromeContinuityInLightAndDarkThemes() {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        func capture(_ name: String, app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for theme in ["ivory", "blackGold"] {
            let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", theme,
                "-use-deterministic-gallery-images-for-testing",
                "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"])
            for orientation in [UIDeviceOrientation.portrait, .landscapeRight] {
                XCUIDevice.shared.orientation = orientation
                let window = app.windows.firstMatch
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = window.frame
                    return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
                }, object: window)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed,
                               "滚动检查必须取得实际横竖屏窗口，不能只依赖配置名称")
                print("PRESENTATION_GEOMETRY scroll-chrome-\(theme): window=\(window.frame)")
                for tab in ["作品", "影视"] {
                    tabButton(tab, in: app).tap()
                    let heading = element(tab == "作品" ? "portfolio-heading" : "credits-heading", in: app)
                    XCTAssertTrue(heading.waitForExistence(timeout: 8))
                    let scroll = app.scrollViews.firstMatch
                    XCTAssertTrue(scroll.exists)
                    let viewport = scroll.frame
                    let search = element("portfolio-search-control", in: app)
                    let searchFrame = search.exists ? search.frame : .zero
                    capture("chrome-\(theme)-\(tab)-initial", app: app)
                    scroll.swipeUp()
                    scroll.swipeUp()
                    XCTAssertEqual(scroll.frame.minY, viewport.minY, accuracy: 1)
                    XCTAssertEqual(scroll.frame.height, viewport.height, accuracy: 1)
                    if tab == "作品" {
                        verifySearchCanBeEditedAndCancelled(in: app)
                        XCTAssertEqual(search.frame.minY, searchFrame.minY, accuracy: 1)
                        XCTAssertEqual(search.frame.height, searchFrame.height, accuracy: 1)
                    }
                    XCTAssertTrue(tabButton("关于", in: app).isHittable)
                    capture("chrome-\(theme)-\(tab)-scrolled", app: app)
                    let navigationFrame = tabButton("关于", in: app).frame
                    let geometry = XCTAttachment(string: "window=\(app.windows.firstMatch.frame); scroll=\(scroll.frame); navigationButton=\(navigationFrame); search=\(searchFrame)")
                    geometry.name = "chrome-geometry-\(theme)-\(tab)"
                    geometry.lifetime = .keepAlways
                    add(geometry)
                }
            }
            app.terminate()
        }
    }

    func testPublicWorkspaceEntryPreservesLoginGateAndLabelsFullScreenPresentation() {
        let app = XCUIApplication()
        // No account/gate bypass and no screenshot-protection bypass. Only
        // suppress the unrelated permission prompt and start in production.
        app.launchArguments = ["-app-service-environment", "production",
            "-skip-startup-notification-authorization-for-testing",
            "-reset-fan-session-for-visual-testing", "-skip-launch-poster-for-visual-testing"]
        app.launch()
        defer { app.terminate() }
        let entry = element("access-gate-workspace-entry", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertFalse(element("workspace-review-banner", in: app).exists)
        entry.tap()
        element("workspace-select-review", in: app).tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(element("workspace-selection", in: app).exists)
        XCTAssertFalse(element("workspace-review-banner", in: app).exists)
        element("workspace-select-review", in: app).tap()
        app.buttons["切换至审核演示环境"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Switch must return to the real login gate")
        XCTAssertTrue(element("workspace-review-banner", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(tabButton("首页", in: app).exists, "Selecting review must not approve or log in a user")
        element("access-gate-admin-entry", in: app).tap()
        XCTAssertTrue(element("admin-login-heading", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("workspace-review-banner", in: app).waitForExistence(timeout: 5),
                      "A separate administrator presentation must retain the environment label")
        // Relaunch without an argument override: the explicit local choice survives.
        app.terminate()
        app.launchArguments.removeFirst(2)
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertTrue(element("workspace-review-banner", in: app).waitForExistence(timeout: 5))
        entry.tap()
        element("workspace-select-production", in: app).tap()
        app.buttons["切换至正式环境"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertFalse(element("workspace-review-banner", in: app).exists)
        XCTAssertFalse(tabButton("首页", in: app).exists)
    }

    func testWorkspaceSwitchRecreatesRootAndClosesPreviousDetails() {
        let app = launchApp(arguments: ["-workspace-switch-for-testing", "-open-about-for-visual-testing"])
        let settings = element("about-settings", in: app)
        scrollToElement(settings, in: app)
        settings.tap()
        XCTAssertTrue(element("user-settings", in: app).waitForExistence(timeout: 8))
        let selector = element("settings-workspace", in: app)
        scrollToElement(selector, in: app)
        selector.tap()
        XCTAssertTrue(element("workspace-selection", in: app).waitForExistence(timeout: 5))
        let environment = element("workspace-test-environment", in: app)
        XCTAssertEqual(environment.label, "production")
        element("workspace-test-review", in: app).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "review"), object: environment)], timeout: 12), .completed)
        XCTAssertFalse(element("user-settings", in: app).exists, "旧设置导航不能挂在新环境上")
        XCTAssertTrue(tabButton("关于", in: app).waitForExistence(timeout: 8))
        element("workspace-test-production", in: app).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "production"), object: environment)], timeout: 12), .completed)
        XCTAssertFalse(element("user-settings", in: app).exists)
        XCTAssertTrue(tabButton("关于", in: app).waitForExistence(timeout: 8))
    }

    func testAdministratorBindingRequiresConfirmationAndCanRevoke() {
        let app = launchAdministratorBindingFixture()
        let action = element("fan-change-administrator", in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 12))
        scrollToElement(action, in: app)
        action.tap()
        let confirm = app.buttons["确认授予"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture-admin-binding-writes", in: app).label, "writes=0")
        confirm.tap()
        let state = element("fan-administrator-state", in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已绑定管理员身份"), object: state)], timeout: 5), .completed,
            app.debugDescription)
        scrollToElement(action, in: app)
        action.tap()
        let revoke = app.buttons["确认撤销"].firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fixture-admin-binding-writes", in: app).label, "writes=1")
        revoke.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "普通用户"), object: state)], timeout: 5), .completed,
            app.debugDescription)
        XCTAssertEqual(element("fixture-admin-binding-writes", in: app).label, "writes=2")
    }

    func testAdministratorBindingConflictRefreshesWithoutSecondMutation() {
        let app = launchAdministratorBindingFixture(conflict: true)
        let action = element("fan-change-administrator", in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 12))
        scrollToElement(action, in: app)
        action.tap()
        let confirm = app.buttons["确认授予"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let notice = app.staticTexts["已读取最新状态，请核对后再决定是否操作。"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(element("fan-administrator-state", in: app).label, "已绑定管理员身份")
        XCTAssertEqual(element("fixture-admin-binding-writes", in: app).label, "writes=1")
    }

    private func launchAdministratorBindingFixture(conflict: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-launch-poster-for-visual-testing", "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing", "-open-fan-administrator-for-testing",
            "-skip-startup-notification-authorization-for-testing"]
        if conflict { app.launchArguments.append("-fan-administrator-conflict-for-testing") }
        app.launch()
        return app
    }

    /// Explicit preflight for an isolated simulator; preserves capture protection
    /// and account state while accepting the real system permission prompt.
    func testIsolatedSimulatorNotificationPermissionPreflightWithProtection() throws {
#if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = ["-skip-launch-poster-for-visual-testing"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 15) {
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"])).firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 3), "Expected the notification permission dialog")
            allow.tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
#else
        throw XCTSkip("Permission preflight is restricted to the isolated simulator")
#endif
    }

    /// Run on a fresh simulator so notification permission is not determined.
    func testStartupAsksSystemNotificationPermissionBeforeLogin() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-app-service-environment", "production",
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionAlert = springboard.alerts.firstMatch
        XCTAssertTrue(permissionAlert.waitForExistence(timeout: 15), "未登录首次启动没有显示系统通知授权")
        let allow = permissionAlert.buttons.matching(
            NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"])
        ).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 3), "系统授权框缺少允许按钮")
        allow.tap()
        XCTAssertTrue(element("access-gate-admin-entry", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(tabButton("首页", in: app).exists, "允许通知不得跳过账号登录")
        app.terminate()
        app.launch()
        XCTAssertTrue(element("access-gate-admin-entry", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(permissionAlert.waitForExistence(timeout: 3), "已授权的下次启动不应重复弹窗")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The dedicated UI-configuration suite may finish on a landscape
        // iteration. Keep the ordinary regression suite deterministic and
        // reserve cross-orientation coverage for that dedicated suite.
        XCUIDevice.shared.orientation = .portrait
    }

    func testForcedWindowLifecycleShieldCoversEntireWindow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ]
        app.launchEnvironment["YISHU_FORCE_SCREEN_PROTECTION_COVER"] = "1"
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        let window = app.windows.firstMatch
        let shield = element("window-lifecycle-protection-shield", in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 12), "屏幕保护回归缺少应用窗口")
        XCTAssertTrue(shield.waitForExistence(timeout: 12), "强制保护状态未安装 window 级遮罩")

        XCTAssertLessThanOrEqual(abs(shield.frame.minX - window.frame.minX), 1)
        XCTAssertLessThanOrEqual(abs(shield.frame.minY - window.frame.minY), 1)
        XCTAssertLessThanOrEqual(abs(shield.frame.maxX - window.frame.maxX), 1)
        XCTAssertLessThanOrEqual(abs(shield.frame.maxY - window.frame.maxY), 1)
        XCTAssertFalse(tabButton("首页", in: app).isHittable, "保护遮罩显示时不应仍可操作底层导航")
    }

    func testProtectedStaticScreenshotArtifactAndTouchContinuity() throws {
        try verifyProtectedScreenshotAndTouch(arguments: [])
    }

    func testIvoryThemePreservesScreenshotProtectionAndTouch() throws {
        try verifyProtectedScreenshotAndTouch(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory"])
    }

    private func verifyProtectedScreenshotAndTouch(arguments: [String]) throws {
#if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ] + arguments
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        let home = tabButton("首页", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 12), "安全画布开启后主导航不可见")
        XCTAssertTrue(home.isHittable, "安全画布开启后主导航无法触控")

        let protectedScreenshot = app.screenshot()
        let screenshotText = try recognizedText(in: protectedScreenshot)
        XCTAssertTrue(
            screenshotText.contains("狐狸姐姐温馨提示"),
            "截图没有显示品牌保护提示，OCR：\(screenshotText)"
        )
        XCTAssertTrue(
            screenshotText.contains("影像内容已保护"),
            "截图没有显示影像保护标题，OCR：\(screenshotText)"
        )
        XCTAssertFalse(
            screenshotText.contains("镜头之内") || screenshotText.contains("查看作品"),
            "截图泄露首页内容，OCR：\(screenshotText)"
        )

        let attachment = XCTAttachment(screenshot: protectedScreenshot)
        attachment.name = "protected-static-screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)

        let portfolio = tabButton("作品", in: app)
        XCTAssertTrue(portfolio.isHittable, "安全画布开启后作品入口无法触控")
        portfolio.tap()
        XCTAssertTrue(
            element("portfolio-heading", in: app).waitForExistence(timeout: 8),
            "安全画布开启后页面切换失败"
        )

        let shield = element("window-lifecycle-protection-shield", in: app)
        let heading = element("portfolio-heading", in: app)
        let search = app.textFields["portfolio-search-field"]
        for cycle in 1...2 {
            XCUIDevice.shared.press(.home)
            let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed,
                           "第 \(cycle) 轮未进入后台，不能计为前后台恢复验证")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                          "第 \(cycle) 轮未恢复前台")

            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !shield.exists && heading.exists && search.isHittable
                    && home.isHittable && portfolio.isHittable
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed,
                           "第 \(cycle) 轮恢复后保护遮罩残留，或作品内容/导航仍不可操作")
            XCTAssertFalse(shield.exists, "前台已确认非捕获状态后不应残留 window 级遮罩")

            // Navigate in both directions, rather than counting a visible Tab
            // as proof that the recovered window still receives touches.
            home.tap()
            XCTAssertTrue(element("home-open-portfolio", in: app).waitForExistence(timeout: 8),
                          "第 \(cycle) 轮恢复后无法切换到首页")
            XCTAssertTrue(portfolio.isHittable)
            portfolio.tap()
            XCTAssertTrue(heading.waitForExistence(timeout: 8),
                          "第 \(cycle) 轮恢复后无法重新进入作品页")
            XCTAssertTrue(search.isHittable, "第 \(cycle) 轮作品搜索仍被遮挡")
        }

        XCTAssertTrue(home.isHittable)
        home.tap()
        XCTAssertTrue(element("home-open-portfolio", in: app).waitForExistence(timeout: 8),
                      "保护恢复回归结束后未返回首页")
#else
        throw XCTSkip("此测试会重置隔离测试账号并保存保护页截图，仅限专用模拟器，不能用于真机现有会话")
#endif
    }

    func testProtectedAdministratorPresentationCanAlwaysClose() throws {
#if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments = [
            "-app-service-environment", "production",
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-open-about-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
            "-hold-home-remote-images-for-visual-testing",
        ]
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        // Keep protection enabled: the separate secure hosting root must
        // receive the account environment even when no account is signed in.
        app.launch()
        defer { app.terminate() }

        let aboutHeading = element("about-biography", in: app)
        XCTAssertTrue(aboutHeading.waitForExistence(timeout: 12), "保护开启后关于页没有出现")
        let adminEntry = element("about-admin-entry", in: app)
        scrollToElement(adminEntry, in: app)
        XCTAssertTrue(adminEntry.isHittable, "保护开启后管理员入口不可点击")
        adminEntry.tap()

        XCTAssertTrue(element("admin-login-heading", in: app).waitForExistence(timeout: 8),
                      "受保护管理员页未显示登录内容，需检查独立 Hosting 的账号环境")
        XCTAssertTrue(app.textFields["管理员账号"].waitForExistence(timeout: 5),
                      "管理员页缺少旧版管理员账号字段")
        XCTAssertTrue(app.secureTextFields["管理员访问码"].waitForExistence(timeout: 5),
                      "管理员页缺少旧版管理员访问码字段")
        let close = element("admin-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 8), "管理员页缺少关闭按钮")
        XCTAssertTrue(close.isHittable, "保护开启后管理员关闭按钮不可点击")
        close.tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == 0"),
            object: close
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: 5),
            .completed,
            "保护开启后管理员全屏页无法关闭"
        )
        XCTAssertTrue(aboutHeading.waitForExistence(timeout: 5), "关闭管理员页后没有返回关于页")
#else
        throw XCTSkip("此测试会重置隔离夹具会话，仅允许在专用模拟器执行")
#endif
    }

    func testProtectedAccessGateAdministratorPresentationCanAlwaysClose() throws {
#if targetEnvironment(simulator)
        let app = XCUIApplication()
        // Start signed out without an access-gate or screen-protection bypass.
        // Only inspect the login controls; never submit credentials.
        app.launchArguments = [
            "-app-service-environment", "production",
            "-skip-startup-notification-authorization-for-testing",
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
            "-hold-home-remote-images-for-visual-testing",
        ]
        app.launch()
        defer { app.terminate() }

        let adminEntry = element("access-gate-admin-entry", in: app)
        XCTAssertTrue(adminEntry.waitForExistence(timeout: 15), "未登录访问页缺少管理员入口")
        XCTAssertFalse(tabButton("首页", in: app).exists, "未登录夹具不能绕过 App 访问门禁")
        XCTAssertTrue(adminEntry.isHittable, "受保护访问页的管理员入口不可点击")
        adminEntry.tap()

        let loginHeading = element("admin-login-heading", in: app)
        XCTAssertTrue(loginHeading.waitForExistence(timeout: 8),
                      "未登录访问页的独立 Hosting 未显示管理员登录内容")
        XCTAssertTrue(app.textFields["管理员账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["管理员访问码"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("admin-use-bound-account", in: app).exists,
                       "未登录夹具不能显示当前账号管理员登录按钮")
        let close = element("admin-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "管理员页缺少关闭按钮")
        XCTAssertTrue(close.isHittable, "受保护管理员页的关闭按钮不可点击")
        close.tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: loginHeading)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "管理员页关闭后仍残留登录内容")
        XCTAssertTrue(adminEntry.waitForExistence(timeout: 5), "关闭后未返回未登录访问页")
        XCTAssertTrue(adminEntry.isHittable)
        XCTAssertFalse(tabButton("首页", in: app).exists, "关闭管理员页不能绕过 App 访问门禁")
#else
        throw XCTSkip("此测试会重置隔离夹具会话，仅允许在专用模拟器执行")
#endif
    }

    func testProtectedNotificationTapCanOpenReturnAndCloseInbox() {
        // Every actual portrait/landscape window is separately required by
        // YishuAdaptiveLayoutUITests; this ordinary case keeps the base flow.
        _ = verifyProtectedNotificationCurrentWindow()
    }

    private func recognizedText(in screenshot: XCUIScreenshot) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        guard let cgImage = screenshot.image.cgImage else {
            XCTFail("无法读取截图像素")
            return ""
        }

        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " | ")
    }

    func testAppRequiresAdministratorApprovalBeforeShowingContent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        assertExists("fan-account-heading", in: app, timeout: 12)
        assertExists("fan-register-douyin-id", in: app)
        assertExists("fan-sign-in-with-apple", in: app)
        assertExists("fan-apple-prelogin-privacy", in: app)
        assertExists("access-gate-admin-entry", in: app)
        XCTAssertFalse(app.tabBars.buttons["首页"].exists, "未审批用户不应看到主导航")
        attachScreenshot(named: "00-access-gate", app: app)
    }

    func testRegistrationThemeChoicePreservesDraftAndSurvivesRestart() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-reset-fan-session-for-visual-testing",
                               "-skip-startup-notification-authorization-for-testing"]
        app.launch()
        let name = app.textFields["fan-register-display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 12))
        scrollToElement(name, in: app)
        name.tap()
        name.typeText("主题回归")
        let form = app.scrollViews["fan-account-scroll"]
        let entry = app.descendants(matching: .any).matching(identifier: "theme-preference-entry").firstMatch
        for _ in 0..<10 {
            let top = app.navigationBars.firstMatch.frame.maxY + 20
            let bottom = form.frame.maxY - 60
            if entry.isHittable, entry.frame.midY > top, entry.frame.midY < bottom { break }
            let isAbove = entry.frame.midY <= top
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: isAbove ? 0.35 : 0.65))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: isAbove ? 0.65 : 0.35)))
        }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.scrollViews["appearance-settings"].waitForExistence(timeout: 5), app.debugDescription)
        let ivory = app.buttons["theme-choice-ivory"]
        scrollToElement(ivory, in: app)
        ivory.tap()
        XCTAssertEqual(ivory.value as? String, "已选择")
        XCTAssertFalse(app.tabBars.buttons["首页"].exists, "选择主题不得绕过注册审批")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(name.value as? String, "主题回归", "更换主题不能清空已填写的注册资料")
        app.terminate()
        app.launch()
        XCTAssertTrue(name.waitForExistence(timeout: 12))
        scrollToElement(entry, in: app)
        XCTAssertEqual(entry.value as? String, "月白", "重启后应恢复本机外观偏好")
        entry.tap()
        let original = app.buttons["theme-choice-blackGold"]
        for _ in 0..<6 where !original.isHittable { app.swipeDown() }
        original.tap()
        XCTAssertEqual(original.value as? String, "已选择")
    }

    func testRegistrationConsentCannotBypassRequiredDouyinID() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset-fan-session-for-visual-testing",
                               "-skip-startup-notification-authorization-for-testing",
                               "-disable-screen-protection-for-visual-testing"]
        app.launch()
        let name = app.textFields["fan-register-display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 12))
        scrollToElement(name, in: app)
        name.tap()
        name.typeText("资料验证")

        let submit = app.buttons["fan-register-submit"]
        let consent = element("fan-register-consent", in: app)
        scrollToElement(consent, in: app)
        XCTAssertFalse(submit.isEnabled, "未同意隐私政策时不能提交申请")
        consent.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed,
                       "勾选同意后提交按钮仍停留在旧状态")
        scrollToElement(submit, in: app)
        // Douyin ID stays empty. FanAccountStore rejects it before any request;
        // this regression never creates a server account or sends an email.
        submit.tap()
        let validation = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "请填写 2–50 位抖音 ID"
        )).firstMatch
        XCTAssertTrue(validation.waitForExistence(timeout: 5), "没有在本地拦截缺少抖音 ID 的申请")
        XCTAssertFalse(tabButton("首页", in: app).exists, "同意隐私政策不能绕过注册审批")
    }

    func testThemeChoicesRemainAccessibleAtXXXL() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-reset-fan-session-for-visual-testing",
                               "-skip-startup-notification-authorization-for-testing",
                               "-disable-screen-protection-for-visual-testing",
                               "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let entry = element("theme-preference-entry", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollToElement(entry, in: app)
        entry.tap()
        let black = app.buttons["theme-choice-blackGold"]
        let pine = app.buttons["theme-choice-pine"]
        XCTAssertTrue(black.waitForExistence(timeout: 5))
        scrollToElement(black, in: app)
        let firstFrame = black.frame
        XCTAssertGreaterThanOrEqual(firstFrame.width, 280)
        XCTAssertGreaterThanOrEqual(firstFrame.height, 44)
        XCTAssertGreaterThanOrEqual(pine.frame.minY, firstFrame.maxY, "辅助功能大字必须变为单列")
        black.tap()
        XCTAssertEqual(black.value as? String, "已选择")
        XCTAssertFalse(app.tabBars.buttons["首页"].exists)
    }

    func testIvoryThemeKeepsHomeStatusBarReadable() throws {
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory",
            "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"])
        XCTAssertTrue(element("home-open-portfolio", in: app).waitForExistence(timeout: 8))
        // Inspect transient pixels only; never attach or save the photograph.
        let source = try XCTUnwrap(app.screenshot().image.cgImage)
        let scene = app.windows.firstMatch.frame
        let scale = CGFloat(source.width) / scene.width
        let height = UIDevice.current.userInterfaceIdiom == .pad ? 30.0 : 60.0
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0,
            width: source.width, height: Int(height * scale))))
        let width = crop.width, rows = crop.height
        var bytes = [UInt8](repeating: 0, count: width * rows * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: rows,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: rows))
        let bright = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 200 && bytes[$0 + 1] > 200 && bytes[$0 + 2] > 200
        }.count
        XCTAssertGreaterThan(bright, 80, "照片背景上的白色时间/系统图标不可读")
        var photographic = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            if red > 80 && green > 80 && blue > 60 && green - blue > 8 {
                photographic += 1
            }
        }
        XCTAssertGreaterThan(Double(photographic) / Double(width * rows), 0.6,
                             "顶部必须延续合成照片颜色，不能是黑色或月白实色条")
    }

    func testEdgeToEdgeHomeKeepsControlsSafeWithAndWithoutProtection() throws {
        for protected in [false, true] {
            let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory",
                "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing",
                "-expose-home-hero-state-for-visual-testing"], screenProtectionEnabled: protected)
            let window = app.windows.firstMatch.frame
            let photo = element("home-hero-actual-filled-image-0", in: app)
            XCTAssertTrue(photo.waitForExistence(timeout: 8))
            XCTAssertEqual(photo.frame.minY, window.minY, accuracy: 0.5,
                           "photo=\(photo.frame), window=\(window), protected=\(protected), geometry=\(element("home-canvas-geometry", in: app).value ?? "missing")")
            XCTAssertEqual(photo.frame.maxY, window.maxY, accuracy: 0.5,
                           "photo=\(photo.frame), window=\(window), protected=\(protected)")
            for identifier in ["home-weather", "home-open-portfolio", "home-hero-subtitle"] {
                let control = element(identifier, in: app)
                XCTAssertTrue(control.exists)
                XCTAssertTrue(window.contains(control.frame))
                if app.tabBars.firstMatch.exists {
                    XCTAssertFalse(app.tabBars.firstMatch.frame.intersects(control.frame))
                }
                if app.statusBars.firstMatch.exists {
                    XCTAssertFalse(app.statusBars.firstMatch.frame.intersects(control.frame))
                }
            }
            app.terminate()
        }
    }

    func testImmersiveHomeTypographyContrast() throws {
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory",
            "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"])
        XCTAssertTrue(element("home-hero-title", in: app).waitForExistence(timeout: 8))
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .trait]) { issue in
            print("Home accessibility: \(issue.compactDescription); \(issue.element?.identifier ?? "system")")
            return false
        }
    }

    func testHomeCaptionsRemainReadableAcrossWeeklyPhotoChanges() throws {
        // Content changes weekly: a readable first photograph is not enough.
        // Synthetic per-slide artwork keeps this independent of CDN timing.
        for theme in ["blackGold", "ivory"] {
            for index in 0..<5 {
                let app = launchApp(arguments: [
                    "-cn.com.shuzijun.yishu.appearance.v1", theme,
                    "-hold-home-remote-images-for-visual-testing",
                    "-home-hero-varied-colors-for-visual-testing",
                    "-disable-home-auto-advance-for-visual-testing",
                    "-home-hero-selection-for-visual-testing", "\(index)",
                    "-expose-home-hero-state-for-visual-testing",
                ])
                let indicator = element("home-hero-page-indicator", in: app)
                XCTAssertEqual(indicator.value as? String, "第 \(index + 1) 张，共 5 张")
                XCTAssertTrue(element("home-weather", in: app).isHittable)
                let subtitle = element("home-hero-subtitle", in: app)
                XCTAssertTrue(subtitle.isHittable, "不能通过隐藏副标题使对比度检查通过")
                XCTAssertEqual(subtitle.label, "短剧演员 · 模特 · 视频创作者")
                try XCTContext.runActivity(named: "\(theme) · 照片 \(index + 1) 文案对比度") { _ in
                    try app.performAccessibilityAudit(for: [.contrast, .textClipped, .trait]) { issue in
                        print("Weekly photo audit: \(issue.compactDescription); element=\(issue.element?.label ?? "unresolved")")
                        return false
                    }
                }
                app.terminate()
            }
        }
    }

    func testHomeRestoresNonzeroPageBeforeDisplayingIt() {
        for index in [1, 4] {
            let app = launchApp(arguments: ["-hold-home-remote-images-for-visual-testing",
                "-disable-home-auto-advance-for-visual-testing",
                "-expose-home-hero-state-for-visual-testing",
                "-home-hero-selection-for-visual-testing", "\(index)"])
            let window = app.windows.firstMatch.frame
            let presentation = window.width > window.height ? "fitted" : "filled"
            let photo = element("home-hero-actual-\(presentation)-image-\(index)", in: app)
            XCTAssertTrue(photo.waitForExistence(timeout: 8))
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(photo.frame),
                          "恢复页码与可见图片不一致：index=\(index), photo=\(photo.frame), window=\(window)")
            app.terminate()
        }
    }

    func testImmersiveThemeBackgroundCoversTabsAndPushedPages() throws {
        for (theme, background) in [("ivory", UInt32(0xF4F0E8)), ("indigo", UInt32(0x131E32))] {
            let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", theme,
                "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"])
            for title in ["作品", "影视", "收藏", "关于"] {
                openTab(title, in: app)
                if title == "影视" {
                    try assertThemeAtSystemEdges(app, background: background, page: title, checkBottom: false)
                    // Photos intentionally continue underneath the translucent
                    // tab bar. As in the iPad edge audit, inspect plain page
                    // color only after reaching the image-free footer.
                    let footer = app.staticTexts["角色与品牌合作"]
                    for _ in 0..<12 where !footer.isHittable {
                        app.scrollViews.firstMatch.swipeUp()
                    }
                    XCTAssertTrue(footer.isHittable)
                    app.scrollViews.firstMatch.swipeUp()
                    try assertThemeAtSystemEdges(app, background: background, page: title, checkTop: false)
                } else {
                    let referenceY = title == "作品" ? element("portfolio-search-control", in: app).frame.midY : nil
                    try assertThemeAtSystemEdges(app, background: background, page: title, topReferenceY: referenceY)
                }
            }
            let settings = element("about-settings", in: app)
            scrollToElement(settings, in: app)
            settings.tap()
            XCTAssertTrue(element("user-settings", in: app).waitForExistence(timeout: 5))
            try assertThemeAtSystemEdges(app, background: background, page: "设置")
            let privacy = element("settings-privacy", in: app)
            scrollToElement(privacy, in: app)
            privacy.tap()
            XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 5))
            let privacyScreenshot = XCTAttachment(screenshot: app.screenshot())
            privacyScreenshot.name = "immersive-privacy-\(theme)"
            privacyScreenshot.lifetime = .keepAlways
            add(privacyScreenshot)
            try assertThemeAtSystemEdges(app, background: background, page: "隐私政策")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(element("user-settings", in: app).waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(tabButton("首页", in: app).waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func assertThemeAtSystemEdges(_ app: XCUIApplication, background: UInt32, page: String,
                                         checkTop: Bool = true, checkBottom: Bool = true,
                                         topReferenceY: CGFloat? = nil) throws {
        let window = app.windows.firstMatch.frame
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "theme-edges-\(background)-\(page)-top\(checkTop)-bottom\(checkBottom)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: window.size, format: format).image { _ in
            screenshot.image.draw(in: CGRect(origin: .zero, size: window.size))
        }
        let image = try XCTUnwrap(normalized.cgImage)
        // System screenshots are rectangular (hardware corner masks are not
        // included). Sample in both document margins, outside text glyphs and
        // the centre home indicator; never average scrolling text as background.
        // SE's compact status bar puts the battery close to y=2; its very
        // first raster row is background, unlike that battery-glyph row.
        let samples = (checkTop ? [(CGFloat(0), 1)] : [])
            + (checkBottom ? [(window.height - 6, 4)] : [])
        for (y, height) in samples {
            for x in [CGFloat(8), window.width - 12] {
                let width = 4
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x,
                    y: y, width: CGFloat(width), height: CGFloat(height))))
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                var backgroundPixels = 0
                // A pinned material bar legitimately tints its background.
                // Compare the top edge with the same bar's empty side margin,
                // so a separate black strip still fails with the original
                // tolerance. Other edges retain the exact theme-color check.
                var reference = [UInt8](repeating: 0, count: 4)
                if y == 0, let topReferenceY {
                    let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: topReferenceY, width: 1, height: 1)))
                    try reference.withUnsafeMutableBytes { buffer in
                        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                    XCTAssertGreaterThan(reference.prefix(3).max() ?? 0, 25,
                                         "有色主题的搜索栏不能退化成黑色安全区")
                }
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let matches = [16, 8, 0].enumerated().allSatisfy { channel, shift in
                        let expected = y == 0 && topReferenceY != nil
                            ? Int(reference[channel]) : Int((background >> shift) & 0xff)
                        return abs(Int(pixels[offset + channel]) - expected) <= 18
                    }
                    if matches { backgroundPixels += 1 }
                }
                XCTAssertGreaterThan(Double(backgroundPixels) / Double(width * height), 0.65,
                                     "\(page) 系统边缘未延续主题：x=\(x), y=\(y)")
            }
        }
    }

    func testAppleFirstUseStillRequiresRegistrationAndApproval() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-simulate-apple-registration-for-visual-testing",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        assertExists("fan-apple-registration-required", in: app, timeout: 12)
        assertExists("fan-apple-display-name", in: app)
        assertExists("fan-apple-douyin-id", in: app)
        assertExists("fan-apple-consent", in: app)
        assertExists("fan-apple-delete-onboarding", in: app)
        assertExists("theme-preference-entry", in: app)
        XCTAssertFalse(app.tabBars.buttons["首页"].exists, "Apple 首次申请不得直接进入主页")
        attachScreenshot(named: "00-apple-first-use", app: app)
    }

    func testLaunchPosterRespectsSafeAreaAndAccessibilityReadingTime() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        let skip = element("launch-poster-skip", in: app)
        let copy = element("launch-poster-copy", in: app)
        XCTAssertTrue(skip.waitForExistence(timeout: 12), "开屏跳过按钮没有出现")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "辅助功能字号下开屏文案没有出现")
        assertMinimumTapTarget(skip, named: "开屏跳过")
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(
                skip.frame.minY,
                statusBar.frame.maxY - 1,
                "开屏跳过按钮侵入状态栏或灵动岛安全区域"
            )
        }

        // Accessibility XXXL disables automatic dismissal so the user has
        // enough reading time. Verify the poster remains rather than racing
        // the screenshot after the ordinary timeout.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(copy.exists, "辅助功能字号下开屏仍被自动关闭")
        attachScreenshot(named: "00-launch-poster-accessibility", app: app)
    }

    func testLaunchPosterCanvasCoversTheWindowAcrossOrientations() {
        // Every actual portrait/landscape window is separately required by
        // YishuAdaptiveLayoutUITests; this ordinary case keeps the base flow.
        _ = verifyLaunchPosterCurrentWindow()
    }

    func testPrimaryTabsExposeTheirCoreContent() {
        let app = launchApp()

        assertExists("home-open-portfolio", in: app)
        attachScreenshot(named: "01-home", app: app)

        openTab("作品", in: app)
        assertExists("portfolio-heading", in: app)
        attachScreenshot(named: "02-portfolio", app: app)

        openTab("影视", in: app)
        assertExists("credits-heading", in: app)
        assertExists("showreel-play", in: app)
        let dramaLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "drama-link-"))
            .firstMatch
        scrollToElement(dramaLink, in: app)
        XCTAssertTrue(dramaLink.waitForExistence(timeout: 8), "影视页缺少可访问的短剧外链")
        XCTAssertTrue(
            dramaLink.label.hasPrefix("观看") && dramaLink.label.count > "观看".count,
            "短剧海报外链没有向 VoiceOver 提供剧名"
        )
        attachScreenshot(named: "03-credits", app: app)

        openTab("收藏", in: app)
        assertExists("favorites-heading", in: app)
        attachScreenshot(named: "04-favorites", app: app)

        openTab("关于", in: app)
        assertExists("about-biography", in: app)
        let aboutPortrait = element("about-portrait", in: app)
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(
                aboutPortrait.frame.minY,
                statusBar.frame.maxY - 1,
                "关于页人物图侵入了状态栏或灵动岛安全区域"
            )
        }
        attachScreenshot(named: "05-about", app: app)
    }

    func testIPadPortraitPortfolioDoesNotReflowWhenOpeningOrReturning() throws {
        try verifyIPadPortfolioNavigation(theme: "blackGold", screenProtectionEnabled: false)
    }

    func testIPadLightThemePortfolioNavigationKeepsGeometryAndSearch() throws {
        try verifyIPadPortfolioNavigation(theme: "ivory", screenProtectionEnabled: true)
    }

    private func verifyIPadPortfolioNavigation(theme: String, screenProtectionEnabled: Bool) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad 竖屏导航回归") }
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", theme,
            "-trace-portfolio-layout-for-testing",
            "-use-deterministic-gallery-images-for-testing",
            "-hold-home-remote-images-for-visual-testing", "-disable-home-auto-advance-for-visual-testing"],
            screenProtectionEnabled: screenProtectionEnabled)
        tabButton("作品", in: app).tap()
        let search = element("portfolio-search-control", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        let initial = search.frame
        let initialScreenshot = XCTAttachment(screenshot: app.screenshot())
        initialScreenshot.name = "ipad-portfolio-before-push"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)
        for _ in 0..<3 {
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            let portfolioID = card.identifier.replacingOccurrences(of: "portfolio-card-", with: "")
            card.tap()
            XCTAssertTrue(element("portfolio-detail-\(portfolioID)", in: app).waitForExistence(timeout: 8))
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 8))
            let returnedScreenshot = XCTAttachment(screenshot: app.screenshot())
            returnedScreenshot.name = "ipad-portfolio-after-pop"
            returnedScreenshot.lifetime = .keepAlways
            add(returnedScreenshot)
            print("IPAD_PORTFOLIO_TRACE \(element("portfolio-layout-trace", in: app).value ?? "missing")")
            XCTAssertEqual(search.frame.minY, initial.minY, accuracy: 1)
            XCTAssertEqual(search.frame.height, initial.height, accuracy: 1)
        }
        let trace = element("portfolio-layout-trace", in: app)
        let recorded = trace.value as? String ?? ""
        let attachment = XCTAttachment(string: recorded)
        attachment.name = "portfolio-portrait-navigation-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        let topPositions = recorded.split(separator: ";").compactMap { Double($0.split(separator: ",")[0]) }
        XCTAssertFalse(topPositions.isEmpty)
        XCTAssertLessThanOrEqual((topPositions.max() ?? 0) - (topPositions.min() ?? 0), 2,
                                 "进入相册或返回时发生二次纵向重排：\(recorded)")
        verifySearchCanBeEditedAndCancelled(in: app)
    }

    func testHomeTouchDefersAutomaticPagingUntilAFullNewInterval() {
        verifyHomeTouchDefersAutomaticPaging(screenProtectionEnabled: false)
    }

    func testProtectedHomeTouchDefersAutomaticPagingUntilAFullNewInterval() {
        verifyHomeTouchDefersAutomaticPaging(screenProtectionEnabled: true)
    }

    private func verifyHomeTouchDefersAutomaticPaging(screenProtectionEnabled: Bool) {
        let app = launchApp(arguments: ["-hold-home-remote-images-for-visual-testing",
                                       "-expose-home-hero-state-for-visual-testing"],
                            screenProtectionEnabled: screenProtectionEnabled)
        let counter = element("home-hero-auto-advance-count", in: app)
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let before = counter.value as? String
        let page = element("home-hero-page-indicator", in: app)
        let pageBefore = page.value as? String
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
        start.press(forDuration: 6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        let releasedAt = Date()
        XCTAssertEqual(counter.value as? String, before, "手指操作期间不应触发自动翻页")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 2 张，共 5 张"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 2), .completed,
                       "观察触摸不能吞掉翻页，之前：\(pageBefore ?? "nil")，之后：\(page.value ?? "nil")")
        let prematurelyAdvanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? "0"), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [prematurelyAdvanced], timeout: max(0.1, 4 - Date().timeIntervalSince(releasedAt))), .timedOut,
                       "松手后还没等满停留时间就自动切换")
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? "0"), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 8), .completed, "松手后自动翻页没有恢复")
    }

    func testHomeStationaryLongTouchAlsoRestartsTheFullInterval() {
        let app = launchApp(arguments: ["-hold-home-remote-images-for-visual-testing",
                                       "-expose-home-hero-state-for-visual-testing"])
        let counter = element("home-hero-auto-advance-count", in: app)
        let before = counter.value as? String ?? "0"
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).press(forDuration: 6)
        XCTAssertEqual(counter.value as? String, before, "只按住而不翻页时也必须暂停自动切换")
        XCTAssertEqual(element("home-hero-page-indicator", in: app).value as? String, "第 1 张，共 5 张")
        let premature = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [premature], timeout: 3), .timedOut, "没有翻页的触摸结束后未重置停留时间")
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
    }

    func testHomeManualPagingUpdatesTheCurrentPageInBothDirections() {
        let arguments = ["-hold-home-remote-images-for-visual-testing",
                         "-expose-home-hero-state-for-visual-testing",
                         "-disable-home-auto-advance-for-visual-testing"]
        let app = launchApp(arguments: arguments)
        let page = element("home-hero-page-indicator", in: app)
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
        right.press(forDuration: 0.05, thenDragTo: left)
        let quickSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 2 张，共 5 张"), object: page)
        let settledResult = XCTWaiter.wait(for: [quickSettled], timeout: 2)
        XCTAssertEqual(settledResult, .completed)
        XCTAssertEqual(page.value as? String, "第 2 张，共 5 张", "快速滑动没有更新当前页")
        right.press(forDuration: 6, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0)
        let heldSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 3 张，共 5 张"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [heldSettled], timeout: 2), .completed)
        XCTAssertEqual(page.value as? String, "第 3 张，共 5 张", "长按滑动没有更新当前页")
        left.press(forDuration: 0.05, thenDragTo: right)
        let reversed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 2 张，共 5 张"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [reversed], timeout: 2), .completed, "反向滑动没有更新当前页")
    }

    func testLiveHomePhotosRemainLoadedWhenSwipingInBothDirections() throws {
        guard ProcessInfo.processInfo.environment["YISHU_UI_TEST_LIVE_MEDIA"] == "1" else {
            throw XCTSkip("真实媒体只读检查需显式开启，离线 CI 不依赖公网")
        }
        let app = launchApp(arguments: ["-expose-home-hero-state-for-visual-testing",
                                       "-disable-home-auto-advance-for-visual-testing"])
        verifyLiveHomePaging(in: app, expectsLandscape: false)
    }

    func testLiveIPadHomePhotosSurviveRotationAndBidirectionalPaging() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              ProcessInfo.processInfo.environment["YISHU_UI_TEST_LIVE_MEDIA"] == "1" else {
            throw XCTSkip("真实横竖屏媒体专项需 iPad 并显式开启公网检查")
        }
        let app = launchApp(arguments: ["-expose-home-hero-state-for-visual-testing",
                                       "-disable-home-auto-advance-for-visual-testing"])
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        // Keep the SAME application and loaded media across rotation; relaunch
        // would hide continuity failures caused by a changing viewport.
        XCUIDevice.shared.orientation = .landscapeRight
        verifyLiveHomePaging(in: app, expectsLandscape: true)
        XCUIDevice.shared.orientation = .portrait
        verifyLiveHomePaging(in: app, expectsLandscape: false)
    }

    private func verifyLiveHomePaging(in app: XCUIApplication, expectsLandscape: Bool) {
        let window = app.windows.firstMatch
        let geometry = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                return frame.width > 0 && frame.height > 0 &&
                    (expectsLandscape ? frame.width > frame.height : frame.height > frame.width)
            }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 8), .completed,
                       "真实媒体检查未取得要求的窗口方向")
        let ready = element("home-hero-ready-count", in: app)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "5"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 40), .completed, "真实首页五张照片没有准备好")
        let page = element("home-hero-page-indicator", in: app)
        XCTAssertEqual(page.value as? String, "第 1 张，共 5 张", "旋转后首页页码意外变化")
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.42))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.42))
        for _ in 0..<2 {
            for index in 1...4 {
                right.press(forDuration: 0.05, thenDragTo: left)
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 \(index + 1) 张，共 5 张"), object: page)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 2), .completed)
                XCTAssertEqual(page.value as? String, "第 \(index + 1) 张，共 5 张")
                XCTAssertTrue(element("home-hero-actual-\(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height ? "fitted" : "filled")-image-\(index)", in: app).waitForExistence(timeout: 5))
                XCTAssertFalse(element("artwork-image-retry", in: app).exists)
                assertLivePhotoFrame(index, in: app, expectsLandscape: expectsLandscape)
            }
            for index in (0...3).reversed() {
                left.press(forDuration: 0.05, thenDragTo: right)
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 \(index + 1) 张，共 5 张"), object: page)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 2), .completed)
                XCTAssertEqual(page.value as? String, "第 \(index + 1) 张，共 5 张")
                XCTAssertTrue(element("home-hero-actual-\(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height ? "fitted" : "filled")-image-\(index)", in: app).waitForExistence(timeout: 5))
                XCTAssertFalse(element("artwork-image-retry", in: app).exists)
                assertLivePhotoFrame(index, in: app, expectsLandscape: expectsLandscape)
            }
        }
    }

    private func assertLivePhotoFrame(_ index: Int, in app: XCUIApplication, expectsLandscape: Bool) {
        let mode = expectsLandscape ? "fitted" : "filled"
        let photo = element("home-hero-actual-\(mode)-image-\(index)", in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(photo.frame.width, 1)
        XCTAssertGreaterThan(photo.frame.height, 1)
        if expectsLandscape {
            XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(photo.frame),
                          "真实横屏照片超出窗口，不能视为完整显示")
        }
    }

    func testAboutRoleSummaryIsCompleteInLandscapeAndLargeText() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let app = launchApp(arguments: [
            "-open-about-for-visual-testing",
            "-expose-about-portrait-canvas-for-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryXXXL",
        ])
        let portrait = element("about-portrait-canvas", in: app)
        let roleSummary = element("about-role-summary", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "横屏关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "横屏关于页职业说明没有出现")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")
        print("ABOUT_LANDSCAPE portrait=\(portrait.frame) role=\(roleSummary.frame); portraitElement=\(portrait.debugDescription)")
        XCTAssertEqual(portrait.frame.width, min(app.windows.firstMatch.frame.width, 720), accuracy: 1)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(roleSummary.frame), "职业说明必须完整显示在当前窗口")
        attachScreenshot(named: "about-landscape-before-boundary-assertion", app: app)
        XCTAssertTrue(
            portrait.frame.insetBy(dx: -1, dy: -1).contains(roleSummary.frame),
            "横屏关于页职业说明超出人物图"
        )
        try app.performAccessibilityAudit(for: [.textClipped])
        attachScreenshot(named: "05-about-landscape-xxxl", app: app)
    }

    func testAboutRoleSummaryIsCompleteAtAccessibilityXXXL() throws {
        let app = launchApp(arguments: [
            "-open-about-for-visual-testing",
            "-expose-about-portrait-canvas-for-testing",
            "-expose-about-visible-bottom-for-visual-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let portrait = element("about-portrait-canvas", in: app)
        let roleSummary = element("about-role-summary", in: app)
        let visibleBottom = element("about-visible-bottom", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "辅助功能字号下关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "辅助功能字号下职业说明没有出现")
        XCTAssertTrue(visibleBottom.waitForExistence(timeout: 8), "缺少关于页可见区域边界")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")
        print("ABOUT_AXXXL portrait=\(portrait.frame) role=\(roleSummary.frame); portraitElement=\(portrait.debugDescription)")
        XCTAssertEqual(portrait.frame.width, min(app.windows.firstMatch.frame.width, 720), accuracy: 1)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(roleSummary.frame), "职业说明必须完整显示在当前窗口")
        attachScreenshot(named: "about-axxxl-before-boundary-assertion", app: app)
        XCTAssertTrue(
            portrait.frame.insetBy(dx: -1, dy: -1).contains(roleSummary.frame),
            "辅助功能字号下职业说明超出人物图"
        )
        XCTAssertLessThanOrEqual(
            roleSummary.frame.maxY + 12,
            visibleBottom.frame.minY,
            "辅助功能字号下职业说明没有留足底部安全余量"
        )
        try app.performAccessibilityAudit(for: [.textClipped])
        attachScreenshot(named: "05-about-accessibility-xxxl", app: app)
    }

    func testAboutRoleSummaryStaysAboveTheVisibleBottomOnPhone() {
        let app = launchApp(arguments: [
            "-open-about-for-visual-testing",
            "-expose-about-visible-bottom-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
        ])
        let window = app.windows.firstMatch
        let roleSummary = element("about-role-summary", in: app)
        let visibleBottom = element("about-visible-bottom", in: app)
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "关于页职业说明没有出现")
        XCTAssertTrue(visibleBottom.waitForExistence(timeout: 8), "缺少关于页可见区域边界")
        XCTAssertTrue(window.frame.contains(roleSummary.frame), "关于页职业说明超出窗口")
        XCTAssertLessThanOrEqual(
            roleSummary.frame.maxY + 12,
            visibleBottom.frame.minY,
            "关于页职业说明没有留足底部安全余量"
        )
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertLessThan(
                roleSummary.frame.maxY,
                tabBar.frame.minY,
                "关于页职业说明被底部导航遮挡"
            )
        }
        attachScreenshot(named: "05-about-visible-bottom", app: app)
    }

    func testTransparentAlbumCaptionsKeepNavigationWorkingInLightAndDarkThemes() {
        for theme in ["blackGold", "ivory"] {
            let app = launchApp(arguments: ["-open-portfolio-for-visual-testing",
                "-use-deterministic-gallery-images-for-testing",
                "-cn.com.shuzijun.yishu.appearance.v1", theme])
            let card = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 12))
            XCTAssertTrue(card.isHittable)
            attachScreenshot(named: "transparent-album-grid-\(theme)", app: app)
            card.tap()
            let firstImage = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-")).firstMatch
            XCTAssertTrue(firstImage.waitForExistence(timeout: 8))
            XCTAssertTrue(firstImage.isHittable)
            attachScreenshot(named: "transparent-album-detail-\(theme)", app: app)
            firstImage.tap()
            let close = element("gallery-close", in: app)
            XCTAssertTrue(close.waitForExistence(timeout: 8))
            assertMinimumTapTarget(close, named: "图片查看器关闭")
            close.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            XCTAssertTrue(firstImage.exists)
            app.terminate()
        }
    }

    func testPortfolioCanOpenAnAlbumAndFullScreenViewer() {
        let app = launchApp(arguments: ["-open-portfolio-for-visual-testing"])
        assertExists("portfolio-heading", in: app)

        let card = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12), "作品网格中没有可打开的相册")
        card.tap()

        let detail = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-detail-"))
            .firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 8), "相册详情页没有出现")
        attachScreenshot(named: "06-portfolio-detail", app: app)

        let firstImage = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-"))
            .firstMatch
        XCTAssertTrue(firstImage.waitForExistence(timeout: 8), "相册封面无法打开")
        firstImage.tap()

        assertExists("gallery-close", in: app, timeout: 8)
        XCTAssertTrue(app.buttons["收藏照片"].exists || app.buttons["取消收藏"].exists)
        attachScreenshot(named: "07-gallery-viewer", app: app)

        let close = element("gallery-close", in: app)
        assertMinimumTapTarget(close, named: "图片查看器关闭")
        XCTAssertTrue(close.isHittable, "图片查看器关闭按钮不可点击")
        close.tap()
        let viewerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [viewerDismissed], timeout: 3),
            .completed,
            "点击关闭后图片查看器仍停留在屏幕上"
        )
        XCTAssertTrue(detail.exists, "关闭图片后没有返回当前相册")
    }

    func testFailedThumbnailCenterStillOpensAlbumAndPhoto() {
        for protectionEnabled in [false, true] {
            let app = launchApp(arguments: [
                "-open-portfolio-for-visual-testing",
                "-use-multi-image-gallery-for-visual-testing",
                "-fail-artwork-for-visual-testing",
            ], screenProtectionEnabled: protectionEnabled)
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            XCTAssertTrue(card.images["photo"].firstMatch.waitForExistence(timeout: 5), "测试必须在封面失败状态下操作")
            XCTAssertFalse(card.buttons["artwork-image-retry"].exists, "卡片不能嵌套另一个抢占点击的重试按钮")
            card.tap()
            let firstImage = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-")).firstMatch
            XCTAssertTrue(firstImage.waitForExistence(timeout: 8), "封面加载失败不能阻止进入相册")
            XCTAssertFalse(firstImage.buttons["artwork-image-retry"].exists)
            firstImage.tap()
            let close = element("gallery-close", in: app)
            XCTAssertTrue(close.waitForExistence(timeout: 8), "照片加载失败不能阻止打开查看器")
            XCTAssertTrue(element("artwork-image-retry", in: app).waitForExistence(timeout: 5), "独立查看器仍应提供重试")
            close.tap()
            XCTAssertTrue(firstImage.waitForExistence(timeout: 8), "照片失败时仍需可以关闭查看器")
            app.terminate()
        }
    }

    func testFailedShowreelPosterCenterStillStartsInlinePlayback() {
        let app = launchApp(arguments: [
            "-open-credits-for-visual-testing",
            "-fail-artwork-for-visual-testing",
        ])
        let play = element("showreel-play", in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        scrollToElement(play, in: app)
        play.tap()
        XCTAssertTrue(element("showreel-video-surface", in: app).waitForExistence(timeout: 8),
                      "海报加载失败时点击中心也应播放，不应被嵌套重试按钮拦截")
        XCTAssertTrue(element("showreel-playback-control", in: app).exists)
        XCTAssertTrue(element("showreel-mute-control", in: app).exists)
    }

    func testCustomShowreelControlsRemainUsable() {
        let app = launchApp(arguments: [
            "-open-credits-for-visual-testing",
            "-play-showreel-for-visual-testing",
        ])

        let progress = element("showreel-progress", in: app)
        let playback = element("showreel-playback-control", in: app)
        let mute = element("showreel-mute-control", in: app)
        assertMinimumTapTarget(progress, named: "Showreel 播放进度")
        assertMinimumTapTarget(playback, named: "Showreel 播放控制")
        assertMinimumTapTarget(mute, named: "Showreel 静音控制")
        scrollToElement(playback, in: app)
        scrollToElement(mute, in: app)
        XCTAssertTrue(playback.isHittable, "Showreel 播放控制不可点击")
        XCTAssertTrue(mute.isHittable, "Showreel 静音控制不可点击")
        playback.tap()
        mute.tap()
        attachScreenshot(named: "04-custom-showreel-controls", app: app)
    }

    func testShowreelCompletionKeepsThePictureClean() {
        let app = launchApp(arguments: [
            "-open-credits-for-visual-testing",
            "-play-showreel-for-visual-testing",
            "-simulate-ended-showreel-for-visual-testing",
        ])

        let surface = element("showreel-video-surface", in: app)
        let playback = element("showreel-playback-control", in: app)
        XCTAssertTrue(surface.waitForExistence(timeout: 8), "视频结束后画面区域消失")
        scrollToElement(playback, in: app)
        assertMinimumTapTarget(playback, named: "视频结束后的重播控制")
        XCTAssertEqual(playback.label, "重新播放视频")
        XCTAssertEqual(surface.value as? String, "播放结束")
        let obsoleteEndOverlay = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "视频播放结束，可使用下方按钮重新播放"
            )
        )
        XCTAssertEqual(obsoleteEndOverlay.count, 0, "视频结束后不应覆盖中央提示")
        XCTAssertTrue(
            (element("showreel-progress", in: app).value as? String)?.contains("总时长") == true,
            "结束状态应保留完整时长"
        )
        attachScreenshot(named: "04-showreel-ended-clean", app: app)

        playback.tap()
        expectation(
            for: NSPredicate(format: "label == %@", "暂停视频"),
            evaluatedWith: playback
        )
        waitForExpectations(timeout: 3)
    }

    func testPortfolioSearchStaysNearTheSafeAreaAndCanClearAndCancel() {
        let app = launchApp(arguments: ["-open-portfolio-for-visual-testing"])
        assertExists("portfolio-heading", in: app)

        let searchField = element("portfolio-search-field", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), "作品搜索框没有出现")
        let maximumTopRatio: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 0.13 : 0.095
        XCTAssertLessThan(
            searchField.frame.minY,
            app.windows.firstMatch.frame.height * maximumTopRatio,
            "作品搜索框距离顶部过远"
        )
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(
                searchField.frame.minY,
                statusBar.frame.maxY - 1,
                "作品搜索框侵入了状态栏或灵动岛安全区域"
            )
        }

        let cards = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
        XCTAssertGreaterThan(cards.count, 0, "搜索前应显示作品卡片")

        searchField.tap()
        searchField.typeText("不存在的主题")
        let emptyExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 0"),
            object: cards
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [emptyExpectation], timeout: 5),
            .completed,
            "无匹配搜索仍显示了作品卡片"
        )

        let clear = app.buttons["清除搜索"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "输入搜索内容后没有清除按钮")
        clear.tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "清除搜索后作品卡片没有恢复")

        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "聚焦搜索时没有取消按钮")
        cancel.tap()
        let cancelDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: cancel
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cancelDismissed], timeout: 2),
            .completed,
            "取消搜索后按钮仍停留在界面上"
        )
        attachScreenshot(named: "02-portfolio-search", app: app)
    }

    func testSearchQueryFitsAtAccessibilityXXXL() {
        let app = launchApp(arguments: ["-open-portfolio-for-visual-testing",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let field = app.textFields["portfolio-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("婚纱\n")
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        print("SEARCH_ACTUAL_XXXL frame=\(field.frame) requiredLineHeight=\(font.lineHeight)")
        XCTAssertGreaterThanOrEqual(field.frame.height, ceil(font.lineHeight),
                                   "搜索文字的输入区域不能被固定高度裁切")
        XCTAssertEqual(field.value as? String, "婚纱")
        // Text only: retain direct evidence of the real maximum-size input,
        // independently from the native audit's heuristic prediction.
        let fieldShot = XCTAttachment(screenshot: field.screenshot())
        fieldShot.name = "search-actual-xxxl-\(Int(app.windows.firstMatch.frame.width))"
        fieldShot.lifetime = .keepAlways
        add(fieldShot)
        XCTAssertTrue(app.buttons["清除搜索"].isHittable)
        app.buttons["清除搜索"].tap()
        let clearedValue = field.value as? String
        XCTAssertTrue(clearedValue == "" || clearedValue == "搜索作品",
                      "清除后只能为空或系统提供的占位提示")
    }

    func testUnavailableMailOffersCopyWithoutClaimingItAlreadyCopied() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing",
            "-hold-home-remote-images-for-visual-testing"], screenProtectionEnabled: true)
        defer { app.terminate() }
        let collaboration = element("about-collaboration", in: app)
        scrollToElement(collaboration, in: app)
        collaboration.tap()
        let name = app.textFields["联系人 / 称呼"].firstMatch
        let contact = app.textFields["手机 / 微信 / 邮箱"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("QA mail fallback")
        // Bring the next field above the on-screen keyboard before typing.
        app.scrollViews.firstMatch.swipeUp()
        scrollToElement(contact, in: app)
        contact.tap()
        contact.typeText("qa@example.invalid")
        let email = element("collaboration-email", in: app)
        scrollToElement(email, in: app)
        XCTAssertTrue(email.isHittable)
        email.tap()

        // The simulator has no configured mail handler; no mail is sent.
        let fallback = app.alerts["未找到可用的邮件应用"]
        guard fallback.waitForExistence(timeout: 8) else {
            XCTFail("必须实际复现邮件应用不可用的分支，不能跳过")
            return
        }
        XCTAssertTrue(fallback.staticTexts[
            "邀约尚未发送，也未自动复制。你可以选择复制，再粘贴到邮件中发送。"].exists)
        XCTAssertTrue(fallback.buttons["复制邀约内容"].exists)
        fallback.buttons["取消"].tap()
        XCTAssertTrue(element("collaboration-heading", in: app).exists)
        XCTAssertEqual(name.value as? String, "QA mail fallback")
        XCTAssertEqual(contact.value as? String, "qa@example.invalid")
    }

    func testCollaborationAndAdministratorRoutesRemainReachable() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        assertExists("about-biography", in: app)

        let collaboration = element("about-collaboration", in: app)
        scrollToElement(collaboration, in: app)
        XCTAssertTrue(collaboration.isHittable, "合作邀约入口不可点击")
        collaboration.tap()
        assertExists("collaboration-heading", in: app)
        XCTAssertTrue(app.textFields["联系人 / 称呼"].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(named: "08-collaboration", app: app)

        app.navigationBars.buttons.firstMatch.tap()
        assertExists("about-biography", in: app)

        let fanEntry = element("about-fan-account", in: app)
        scrollToElement(fanEntry, in: app)
        XCTAssertTrue(fanEntry.isHittable, "粉丝账号入口不可点击")
        fanEntry.tap()
        assertExists("fan-account-heading", in: app)
        assertExists("fan-register-douyin-id", in: app)
        let privacyPolicy = element("fan-register-privacy-policy", in: app)
        scrollToElement(privacyPolicy, in: app)
        XCTAssertTrue(privacyPolicy.isHittable, "注册前隐私政策入口不可点击")
        privacyPolicy.tap()
        assertExists("privacy-policy-heading", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        assertExists("fan-account-heading", in: app)
        attachScreenshot(named: "09-fan-registration", app: app)

        app.navigationBars.buttons.firstMatch.tap()
        assertExists("about-biography", in: app)

        let adminEntry = element("about-admin-entry", in: app)
        scrollToElement(adminEntry, in: app)
        XCTAssertTrue(adminEntry.isHittable, "管理员入口不可点击")
        adminEntry.tap()
        assertExists("admin-login-heading", in: app)
        XCTAssertTrue(app.secureTextFields["管理员访问码"].waitForExistence(timeout: 5))
        attachScreenshot(named: "10-admin-login", app: app)
    }

    func testAboutSocialLinksKeepCompleteAccessiblePlatformAndAccountNames() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        let expectedLinks = [
            ("about-xiaohongshu-link", "小红书", "一只梳子君"),
            ("about-douyin-link", "抖音", "一只梳子君"),
            ("about-hongguo-link", "红果短剧", "易姝"),
        ]

        for (identifier, platform, account) in expectedLinks {
            let link = element(identifier, in: app)
            scrollToElement(link, in: app)
            XCTAssertTrue(link.isHittable, "\(platform) 外链不可点击")
            assertMinimumTapTarget(link, named: "\(platform) 外链")
            XCTAssertTrue(link.label.contains(platform), "\(platform) 外链缺少平台名")
            XCTAssertTrue(link.label.contains(account), "\(platform) 外链缺少账号名")
            XCTAssertEqual(
                link.label.components(separatedBy: platform).count - 1,
                1,
                "\(platform) 装饰图标不应被 VoiceOver 重复朗读"
            )
        }

        attachScreenshot(named: "10-about-social-brand-icons", app: app)
    }

    func testEmptyLibraryCanReturnToPortfolio() {
        let app = launchApp(arguments: ["-open-favorites-for-visual-testing"])
        assertExists("favorites-heading", in: app)
        let openPortfolio = element("library-open-portfolio", in: app)
        XCTAssertTrue(openPortfolio.waitForExistence(timeout: 5))
        openPortfolio.tap()
        assertExists("portfolio-heading", in: app)
    }

    func testProtectedGalleryPresentationKeepsItsEnvironmentAndControls() {
        // Every actual portrait/landscape window is separately required by
        // YishuAdaptiveLayoutUITests; this ordinary case keeps the base flow.
        _ = verifyProtectedGalleryCurrentWindow()
    }

    func testAccessibilityTextSizeKeepsPrimaryActionsComfortable() {
        let app = launchApp(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])

        let weather = element("home-weather", in: app)
        let portfolioAction = element("home-open-portfolio", in: app)
        assertMinimumTapTarget(weather, named: "首页天气")
        assertMinimumTapTarget(portfolioAction, named: "查看作品")
        XCTAssertTrue(portfolioAction.isHittable, "辅助功能大字号下首页主操作不可点击")

        portfolioAction.tap()
        let searchField = element("portfolio-search-field", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), "大字号下作品搜索框未出现")
        assertMinimumTapTarget(searchField, named: "作品搜索")
        attachScreenshot(named: "11-accessibility-xxxl", app: app)
    }

    func testWeatherAttributionAppearsOnlyOnAboutPage() {
        let app = launchApp(
            arguments: [
                "-simulate-ready-weather-for-visual-testing",
            ],
            environment: ["YISHU_SIMULATE_READY_WEATHER_FOR_VISUAL_TESTING": "1"]
        )

        let weather = element("home-weather", in: app)
        assertMinimumTapTarget(weather, named: "首页天气")
        XCTAssertFalse(
            weather.label.contains("Apple Weather"),
            "天气胶囊本身只应读出地点和当前天气：\(weather.label)"
        )
        let homeAttribution = element("home-weather-attribution-control", in: app)
        XCTAssertFalse(homeAttribution.exists, "首页不应再显示 Apple Weather 来源入口")
        XCTAssertFalse(element("home-weather-provider", in: app).exists)
        XCTAssertFalse(element("home-weather-legal-link", in: app).exists)
        attachScreenshot(named: "11-home-weather-without-source", app: app)

        openTab("关于", in: app)
        // SwiftUI exposes this styled Link as XCUIElementTypeOther on iOS 26,
        // even when it carries the `.isLink` accessibility trait. Locate it
        // by its stable identifier and separately gate its label and action.
        let legalLink = element("about-weather-legal-link", in: app)
        scrollToElement(legalLink, in: app)
        assertMinimumTapTarget(legalLink, named: "关于页 Apple Weather 数据与许可")
        XCTAssertTrue(legalLink.isHittable, "关于页 Apple Weather 数据与许可链接不可点击")
        XCTAssertTrue(
            legalLink.label.contains("Apple Weather"),
            "关于页没有标明 Apple Weather：\(legalLink.label)"
        )
        attachScreenshot(named: "11-about-weather-attribution", app: app)
    }

    func testPrimaryPagesMeetFocusedAccessibilityGate() throws {
        try verifyPrimaryPagesAccessibility(theme: "blackGold")
    }

    func testLightThemesKeepPrimaryPagesReadable() throws {
        for theme in ["ivory", "blush", "bamboo"] {
            try verifyPrimaryPagesAccessibility(theme: theme)
        }
    }

    private func verifyPrimaryPagesAccessibility(theme: String) throws {
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", theme])

        assertExists("home-open-portfolio", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "首页", in: app)

        openTab("作品", in: app)
        assertExists("portfolio-heading", in: app)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The iOS 26 audit can crop a below-viewport title as an empty
            // strip of the page and report that strip as failed contrast.
            // Search each fixture album so every title is fully rendered;
            // still audit all four categories without filtering any issues.
            let search = app.textFields["portfolio-search-field"]
            for title in ["婚纱", "新中式", "旗袍"] {
                search.tap()
                let clear = app.buttons["清除搜索"]
                if clear.exists { clear.tap() }
                search.typeText(title + "\n")
                let albumTitle = app.staticTexts[title]
                XCTAssertTrue(albumTitle.waitForExistence(timeout: 5))
                scrollFullyAbovePhoneTabBar(albumTitle, in: app)
                try auditPrimaryPageAccessibilityBaseline(pageNamed: "作品 · \(title) · \(theme)", in: app)
            }
        } else {
            try auditPrimaryPageAccessibilityBaseline(pageNamed: "作品", in: app)
        }

        openTab("关于", in: app)
        assertExists("about-biography", in: app)
        // A fixed swipe can leave the copyright paragraph below the floating
        // tab bar. iOS 26 then audits a crop containing only the home indicator
        // as that text's contrast. Establish complete visibility first, then
        // retain the unfiltered contrast/clipping/hit-region/trait audit.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let copyrightText = app.staticTexts.matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "本 App 展示的照片与影像均已取得合法展示授权"
                )
            ).firstMatch
            scrollFullyAbovePhoneTabBar(copyrightText, in: app)
            // The attribution follows the copyright block. Bring this final
            // card in too, otherwise its not-yet-visible title can produce
            // the same blank-strip contrast artifact on light page surfaces.
            scrollFullyAbovePhoneTabBar(element("about-weather-legal-link", in: app), in: app)
        }
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "关于", in: app)
        app.terminate()
    }

    private func launchApp(
        arguments: [String] = [],
        screenProtectionEnabled: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-app-service-environment", "production",
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ] + arguments
        if !screenProtectionEnabled {
            app.launchArguments.append("-disable-screen-protection-for-visual-testing")
            app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()
        XCTAssertTrue(tabButton("首页", in: app).waitForExistence(timeout: 12), "主导航未出现")
        return app
    }

    private func openTab(_ title: String, in app: XCUIApplication) {
        let button = tabButton(title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "缺少“\(title)”导航")
        button.tap()
    }

    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let phoneTab = app.tabBars.buttons[title]
        return phoneTab.exists ? phoneTab : app.buttons[title].firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertExists(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element(identifier, in: app).waitForExistence(timeout: timeout),
            "缺少关键界面元素 \(identifier)",
            file: file,
            line: line
        )
    }

    private func assertMinimumTapTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name)不存在", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "\(name)宽度不足 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(name)高度不足 44pt", file: file, line: line)
    }

    private func assertLaunchPosterCanvas(
        _ canvas: XCUIElement,
        covers window: XCUIElement,
        orientation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = window.frame
        let visibleFrame = windowFrame.intersection(canvas.frame)
        XCTAssertGreaterThanOrEqual(
            visibleFrame.width / max(windowFrame.width, 1),
            0.995,
            "\(orientation)开屏未覆盖窗口全宽：window=\(windowFrame), canvas=\(canvas.frame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visibleFrame.height / max(windowFrame.height, 1),
            0.995,
            "\(orientation)开屏未覆盖窗口全高：window=\(windowFrame), canvas=\(canvas.frame)",
            file: file,
            line: line
        )
    }

    private func auditPrimaryPageAccessibilityBaseline(
        pageNamed pageName: String,
        in app: XCUIApplication
    ) throws {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // XCTest's system accessibility audit repeatedly deadlocks while
            // snapshotting an otherwise responsive iPad hierarchy (framework
            // error -56). Keep the Apple audit on iPhone for shared contrast,
            // clipping, hit-region and trait coverage. On iPad, gate the
            // layout-specific contract with deterministic safe-area, 44pt and
            // VoiceOver-label assertions. The same iPad suite separately runs
            // accessibility XXXL and portrait/landscape adaptation tests.
            auditDeterministicIPadAccessibilityBaseline(pageNamed: pageName, in: app)
            return
        }

        try auditAppleAccessibilityBaseline(pageNamed: pageName, in: app)
    }

    private func auditDeterministicIPadAccessibilityBaseline(
        pageNamed pageName: String,
        in app: XCUIApplication
    ) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "\(pageName)缺少可访问的 iPad 窗口")

        switch pageName {
        case "首页":
            let weather = element("home-weather", in: app)
            let portfolioAction = element("home-open-portfolio", in: app)
            assertMinimumTapTarget(weather, named: "iPad 首页天气")
            assertMinimumTapTarget(portfolioAction, named: "iPad 查看作品")
            assertMeaningfulAccessibilityLabel(weather, named: "iPad 首页天气")
            assertMeaningfulAccessibilityLabel(portfolioAction, named: "iPad 查看作品")
            assertContainedInWindow(weather, named: "iPad 首页天气", window: window)
            assertContainedInWindow(portfolioAction, named: "iPad 查看作品", window: window)
            assertBelowStatusBar(weather, named: "iPad 首页天气", in: app)

        case "作品":
            let heading = element("portfolio-heading", in: app)
            let searchControl = element("portfolio-search-control", in: app)
            let searchField = element("portfolio-search-field", in: app)
            let firstCard = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
                .firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 8), "iPad 作品页标题不存在")
            XCTAssertEqual(heading.label, "作品", "iPad 作品页标题语义不正确")
            assertMinimumTapTarget(searchControl, named: "iPad 作品搜索控件")
            assertMeaningfulAccessibilityLabel(searchField, named: "iPad 作品搜索")
            assertBelowStatusBar(searchField, named: "iPad 作品搜索", in: app)
            XCTAssertTrue(firstCard.waitForExistence(timeout: 8), "iPad 作品页缺少可访问的相册卡片")
            assertMeaningfulAccessibilityLabel(firstCard, named: "iPad 作品相册")

        case "关于":
            let heading = element("about-biography", in: app)
            let portrait = element("about-portrait", in: app)
            XCTAssertTrue(heading.waitForExistence(timeout: 8), "iPad 关于页简介不存在")
            XCTAssertTrue(heading.label.hasPrefix("专注于短剧表演"), "iPad 关于页应直接呈现简介")
            XCTAssertTrue(portrait.waitForExistence(timeout: 8), "iPad 关于页人物图不存在")
            XCTAssertEqual(portrait.label, "易姝形象照", "iPad 关于页人物图缺少 VoiceOver 语义")
            assertContainedInWindow(heading, named: "iPad 关于页简介", window: window)
            assertContainedInWindow(portrait, named: "iPad 关于页人物图", window: window)
            assertBelowStatusBar(portrait, named: "iPad 关于页人物图", in: app)

        default:
            XCTFail("未定义的 iPad 辅助功能页面门禁：\(pageName)")
        }
    }

    private func assertMeaningfulAccessibilityLabel(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name)不存在", file: file, line: line)
        XCTAssertFalse(
            element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(name)缺少 VoiceOver 标签",
            file: file,
            line: line
        )
    }

    private func assertContainedInWindow(
        _ element: XCUIElement,
        named name: String,
        window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name)不存在", file: file, line: line)
        XCTAssertTrue(
            window.frame.contains(element.frame),
            "\(name)超出 iPad 可视窗口",
            file: file,
            line: line
        )
    }

    private func assertBelowStatusBar(
        _ element: XCUIElement,
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let statusBar = app.statusBars.firstMatch
        guard statusBar.exists else { return }
        XCTAssertGreaterThanOrEqual(
            element.frame.minY,
            statusBar.frame.maxY - 1,
            "\(name)侵入状态栏安全区域",
            file: file,
            line: line
        )
    }

    private func auditAppleAccessibilityBaseline(
        pageNamed pageName: String,
        in app: XCUIApplication
    ) throws {
        try XCTContext.runActivity(named: "\(pageName)辅助功能审计") { _ in
            do {
                try performAppleAccessibilityAudit(in: app)
            } catch {
                let auditError = error as NSError
                guard auditError.domain == "com.apple.xcode.xctest.accessibilityAudit",
                      auditError.code == -56 else {
                    throw error
                }

                try XCTContext.runActivity(named: "审计框架暂时超时，2 秒后重试一次") { _ in
                    Thread.sleep(forTimeInterval: 2)

                    // Keep the recovery bounded. A window query can itself
                    // enter XCTest's long snapshot timeout, so after checking
                    // that the app is foregrounded we retry the audit directly.
                    _ = app.wait(for: .runningForeground, timeout: 2)

                    // Intentionally do not catch the retry: a second timeout
                    // or a real accessibility issue must fail unchanged.
                    try performAppleAccessibilityAudit(in: app)
                }
            }
        }
    }

    private func performAppleAccessibilityAudit(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: [.contrast, .hitRegion, .textClipped, .trait]
        )
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        // iPad's About portrait intentionally does not scroll. Drag the actual
        // right-hand details column rather than the center of the whole window.
        let details = app.scrollViews["about-details-scroll"]
        let scrollTarget = details.exists ? details : app
        while (!element.isHittable || !elementCenterIsVisible(element, in: app)), attempts < 8 {
            scrollTarget.swipeUp()
            attempts += 1
        }
    }

    private func scrollFullyAbovePhoneTabBar(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "待审计内容不存在", file: file, line: line)
        let window = app.windows.firstMatch
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3), "缺少底部导航边界", file: file, line: line)
        guard window.exists, tabBar.exists, element.exists else { return }

        for _ in 0..<8 {
            let windowFrame = window.frame
            let statusBar = app.statusBars.firstMatch
            let top = statusBar.exists ? statusBar.frame.maxY + 8 : windowFrame.minY + 8
            let bottom = min(tabBar.frame.minY, windowFrame.maxY) - 12
            let visibleFrame = CGRect(
                x: windowFrame.minX,
                y: top,
                width: windowFrame.width,
                height: max(0, bottom - top)
            )
            let textFrame = element.frame
            if !textFrame.isEmpty, visibleFrame.contains(textFrame) { return }

            let overflow = textFrame.maxY > bottom
                ? textFrame.maxY - bottom + 12
                : textFrame.minY - top - 12
            let movement = min(abs(overflow), visibleFrame.height * 0.5)
                * (overflow >= 0 ? 1.0 : -1.0)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: windowFrame.midX, dy: visibleFrame.midY))
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -movement)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        }
        XCTFail("内容未能完整滚入底部导航上方，不能执行有效的对比度审计：\(element.frame)", file: file, line: line)
    }

    private func elementCenterIsVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        guard window.exists, element.exists else { return false }

        let frame = element.frame
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return false }
        return window.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["YISHU_UI_TEST_ATTACH_SCREENSHOTS"] == "1" else {
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCTestCase {
    func verifyLaunchPosterCurrentWindow() -> CGRect {
        let app = XCUIApplication()
        app.launchArguments = [
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        let window = app.windows.firstMatch
        let canvas = presentationElement("launch-poster-canvas", in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 12), "开屏缺少应用窗口")
        XCTAssertTrue(canvas.waitForExistence(timeout: 12), "开屏缺少可验证的全屏画布")
        presentationAssertCanvas(canvas, covers: window, orientation: "当前窗口")
        let measuredFrame = window.frame
        let close = presentationElement("launch-poster-skip", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "开屏缺少可操作的跳过入口")
        XCTAssertTrue(close.isHittable, "当前窗口的开屏跳过入口不可点击")
        close.tap()
        XCTAssertTrue(app.buttons["首页"].firstMatch.waitForExistence(timeout: 8), "关闭开屏后未恢复主导航")
        return measuredFrame
    }

    func verifyProtectedGalleryCurrentWindow() -> CGRect {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-open-portfolio-for-visual-testing",
            "-use-multi-image-gallery-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
        ]
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        presentationAssertExists("portfolio-heading", in: app, timeout: 12)
        let card = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()

        let firstImage = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-"))
            .firstMatch
        XCTAssertTrue(firstImage.waitForExistence(timeout: 8))
        firstImage.tap()

        presentationAssertExists("gallery-close", in: app, timeout: 8)
        XCTAssertTrue(app.buttons["收藏照片"].exists || app.buttons["取消收藏"].exists)

        let window = app.windows.firstMatch
        let firstGalleryImage = presentationElement("gallery-image-18", in: app)
        let measuredFrame = window.frame
        let caption = presentationElement("gallery-caption", in: app)
        let counter = presentationElement("gallery-counter", in: app)
        let close = presentationElement("gallery-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "受保护图片查看器缺少关闭按钮")
        XCTAssertTrue(firstGalleryImage.waitForExistence(timeout: 5), "受保护图片查看器没有显示照片")
        XCTAssertTrue(close.isHittable, "受保护图片查看器关闭按钮不可点击")
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
        let statusBarHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.statusBars.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [statusBarHidden], timeout: 3),
            .completed,
            "受保护全屏图片查看器没有隐藏系统状态栏"
        )

        XCTAssertTrue(window.frame.contains(firstGalleryImage.frame), "当前窗口内受保护照片超出窗口")
        if window.frame.width >= 700 {
            XCTAssertGreaterThanOrEqual(
                firstGalleryImage.frame.minY,
                close.frame.maxY - 1,
                "iPad 当前窗口内照片上边缘被工具栏遮挡"
            )
            XCTAssertLessThanOrEqual(
                firstGalleryImage.frame.maxY,
                caption.frame.minY + 1,
                "iPad 当前窗口内照片下边缘被说明遮挡"
            )
        }

        XCTAssertEqual(counter.label, "第 1 张，共 3 张")
        firstGalleryImage.swipeLeft()
        let protectedPageChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "第 2 张，共 3 张"),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [protectedPageChanged], timeout: 5),
            .completed,
            "受保护图片查看器当前窗口切图失败"
        )
        let secondGalleryImage = presentationElement("gallery-image-33", in: app)
        XCTAssertTrue(secondGalleryImage.waitForExistence(timeout: 5), "当前窗口切图后照片没有出现")
        XCTAssertTrue(window.frame.contains(secondGalleryImage.frame), "当前窗口切图后照片超出窗口")

        close.tap()
        let viewerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [viewerDismissed], timeout: 3),
            .completed,
            "受保护图片查看器无法关闭"
        )
        return measuredFrame
    }

    func verifyProtectedNotificationCurrentWindow() -> CGRect {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-skip-startup-notification-authorization-for-testing",
            "-notification-inbox-ui-fixture",
        ]
        // Deliberately do not disable protection. This exercises the separate
        // secure UIHostingController and its explicit account environment.
        app.launch()
        let detail = presentationElement("fan-message-detail", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "点通知后受保护详情没有加载，可能缺少账号环境")
        XCTAssertTrue(app.staticTexts["消息箱界面测试"].exists, "详情必须来自认证消息API的假数据而非推送正文")
        let measuredFrame = app.windows.firstMatch.frame
        let back = app.navigationBars.buttons["消息箱"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "消息详情缺少返回消息箱入口")
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(measuredFrame.contains(back.frame), "消息返回入口超出当前窗口")
        back.tap()
        let message = presentationElement("fan-message-11111111-2222-4333-8444-555555555555", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 5), "返回消息箱后列表必须可见，不能重复自动打开通知")
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 1"), object: detail)
        reopened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed,
                       "返回后同一条推送不得再次抢占导航")
        // A consumed automatic deep link must not disable an intentional tap.
        message.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "用户仍可主动重开消息")
        app.navigationBars.buttons["消息箱"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5), "再次返回消息箱仍须成功")
        let close = presentationElement("fan-notification-presentation-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(measuredFrame.contains(close.frame), "消息箱关闭入口超出当前窗口")
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5)
        XCTAssertTrue(close.isHittable, "当前窗口的消息箱关闭必须可触控")
        // iPadOS 26 sizes this native toolbar control to 36pt high. A measured
        // ±21.5pt probe did not hit; do not claim a 44pt target or replace the
        // system navigation layout merely to satisfy that additional target.
        // Actual in-window, center-hit, return and dismissal remain mandatory.
        print("PRESENTATION_NATIVE_CLOSE window=\(measuredFrame) close=\(close.frame) bars=\(app.navigationBars.allElementsBoundByIndex.map(\.frame))")
        close.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == 0"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(presentationElement("access-gate-admin-entry", in: app).waitForExistence(timeout: 5), "假消息回归不得绕过真实App登录门禁")
        XCTAssertFalse(app.buttons["发送"].exists)
        XCTAssertFalse(app.buttons["回复"].exists)
        return measuredFrame
    }

    func presentationElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func presentationAssertExists(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(presentationElement(identifier, in: app).waitForExistence(timeout: timeout), "缺少关键界面元素 \(identifier)")
    }

    func presentationAssertCanvas(
        _ canvas: XCUIElement,
        covers window: XCUIElement,
        orientation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = window.frame
        let visibleFrame = windowFrame.intersection(canvas.frame)
        XCTAssertGreaterThanOrEqual(
            visibleFrame.width / max(windowFrame.width, 1),
            0.995,
            "\(orientation)开屏未覆盖窗口全宽：window=\(windowFrame), canvas=\(canvas.frame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            visibleFrame.height / max(windowFrame.height, 1),
            0.995,
            "\(orientation)开屏未覆盖窗口全高：window=\(windowFrame), canvas=\(canvas.frame)",
            file: file,
            line: line
        )
    }

}


/// Runs only the layout-sensitive checks across every orientation and
/// appearance configuration the app declares. This is XCTest's supported way
/// to validate iPadOS 26 windows, whose geometry can be independent from the
/// device's physical orientation.
final class YishuAdaptiveLayoutUITests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }
    // ci-ios-tests.sh deliberately disables parallel testing: the process-local
    // evidence must cover all UI configurations before this class tears down.
    private static var presentationGeometries: [String: Set<String>] = [:]

    override class func setUp() {
        super.setUp()
        presentationGeometries = [:]
    }

    override class func tearDown() {
        // A physical orientation label is not proof of a rotated iPad window.
        // Fail the suite when any exercised presentation never actually ran
        // in both geometries, even if all its portrait assertions passed.
        for (name, geometries) in presentationGeometries.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(geometries.contains("portrait"), "\(name) 未取得真实竖屏窗口证据：\(geometries)")
            XCTAssertTrue(geometries.contains("landscape"), "\(name) 未取得真实横屏窗口证据，不能视为完成横屏验收：\(geometries)")
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchPosterCoversEveryActualWindowConfiguration() {
        recordPresentationGeometry("launch-poster", frame: verifyLaunchPosterCurrentWindow())
    }

    func testIvoryPrimaryAndPushedPagesPaintBothScreenEdges() throws {
        let app = launchApp(arguments: [
            "-cn.com.shuzijun.yishu.appearance.v1", "ivory",
            "-use-deterministic-gallery-images-for-testing",
            "-expose-about-portrait-canvas-for-testing",
            "-hold-home-remote-images-for-visual-testing",
            "-disable-home-auto-advance-for-visual-testing"
        ])
        let window = app.windows.firstMatch
        recordPresentationGeometry("ivory-page-edges", frame: window.frame)
        for (tab, heading) in [("作品", "portfolio-heading"), ("影视", "credits-heading"),
                               ("收藏", "favorites-heading"), ("关于", "about-biography")] {
            tabButton(tab, in: app).tap()
            XCTAssertTrue(element(heading, in: app).waitForExistence(timeout: 8))
            if tab == "影视" {
                try assertIvoryScreenEdges(app, page: tab, edges: [.top])
                // In landscape the existing showreel poster legitimately
                // extends underneath the bottom safe area. Check the page
                // background after reaching the footer, not its dark image
                // caption; do not remove or restyle the player's backdrop.
                let footer = app.staticTexts["角色与品牌合作"]
                for _ in 0..<12 where !footer.isHittable {
                    app.scrollViews.firstMatch.swipeUp()
                }
                XCTAssertTrue(footer.isHittable, "影视页必须能滚动至合作区域")
                app.scrollViews.firstMatch.swipeUp()
                // Scrolling intentionally moves photos under translucent top
                // chrome. Its source is no longer the plain page background.
                try assertIvoryScreenEdges(app, page: tab, edges: [.bottom])
            } else {
                try assertIvoryScreenEdges(app, page: tab)
            }
        }

        tabButton("作品", in: app).tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let albumID = card.identifier.replacingOccurrences(of: "portfolio-card-", with: "")
        card.tap()
        XCTAssertTrue(element("portfolio-detail-\(albumID)", in: app).waitForExistence(timeout: 8))
        try assertIvoryScreenEdges(app, page: "相册详情")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element("portfolio-heading", in: app).waitForExistence(timeout: 8))
        try assertIvoryScreenEdges(app, page: "相册返回")

        tabButton("关于", in: app).tap()
        let invitation = element("about-collaboration", in: app)
        // A full-speed swipe across the central gap of the landscape layout
        // can miss the text column or overshoot the button. Use small drags
        // inside the details column, steering back if the target passed above.
        for _ in 0..<16 where !invitation.isHittable {
            let scene = window.frame
            let details = element("about-details-scroll", in: app)
            let visible = details.exists ? details.frame.intersection(scene) : scene
            let x = details.exists ? visible.midX : scene.width * (scene.width > scene.height ? 0.75 : 0.5)
            let towardBottom = !invitation.exists || invitation.frame.midY >= visible.midY
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: visible.minY + visible.height * (towardBottom ? 0.65 : 0.35)))
            let end = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: visible.minY + visible.height * (towardBottom ? 0.35 : 0.65)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(invitation.isHittable,
                      "合作入口必须可触达：button=\(invitation.frame), window=\(window.frame)")
        invitation.tap()
        XCTAssertTrue(element("collaboration-heading", in: app).waitForExistence(timeout: 8))
        try assertIvoryScreenEdges(app, page: "合作邀约")
    }

    private enum CheckedScreenEdge: Hashable { case top, bottom }

    private func assertIvoryScreenEdges(
        _ app: XCUIApplication, page: String, edges: Set<CheckedScreenEdge> = [.top, .bottom]
    ) throws {
        let size = app.windows.firstMatch.frame.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            XCUIScreen.main.screenshot().image.draw(in: CGRect(origin: .zero, size: size))
        }
        // app.screenshot() can crop a landscape iPad using portrait storage
        // coordinates. Keep the normalized full-screen evidence used below,
        // including when the first edge assertion fails.
        let attachment = XCTAttachment(image: image)
        attachment.name = "ivory-edges-\(page)-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        let source = try XCTUnwrap(image.cgImage)
        // Avoid rounded corners, the island, status glyphs and home indicator.
        // These tiny patches are outside content: a dark photo elsewhere must
        // not be mistaken for a global black safe-area strip.
        for x in [0.25, 0.75] {
            for (position, edge, y) in [(CheckedScreenEdge.top, "顶部", 2.0), (CheckedScreenEdge.bottom, "底部", size.height - 6)]
                where edges.contains(position) {
                let patch = try XCTUnwrap(source.cropping(to: CGRect(x: size.width * x, y: y, width: 4, height: 4)))
                var rgba = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let point = CGPoint(x: size.width * x + 2, y: y + 2)
                let portrait = element("about-portrait-canvas", in: app)
                if page == "关于", edge == "顶部", portrait.exists,
                   portrait.frame.contains(point) {
                    // Landscape iPhone has no top status bar. Its fitted
                    // portrait correctly reaches y=0; require the known cyan
                    // fixture (or a white stripe), not an ivory replacement.
                    let cyan = rgba[0] < 15 && (185...210).contains(Int(rgba[1]))
                        && (198...224).contains(Int(rgba[2]))
                    let white = rgba[0] > 230 && rgba[1] > 230 && rgba[2] > 230
                    XCTAssertTrue(cyan || white, "关于顶部照片被黑边遮住或未正常显示：\(rgba)")
                    continue
                }
                XCTAssertGreaterThan(rgba[0], 190, "\(page)\(edge)没有延续浅色背景：\(rgba)")
                XCTAssertGreaterThan(rgba[1], 185, "\(page)\(edge)出现黑边或深色遮挡：\(rgba)")
                XCTAssertGreaterThan(rgba[2], 175, "\(page)\(edge)没有延续浅色背景：\(rgba)")
            }
        }
    }

    func testThemesFromAboutKeepNavigationAndFitActualWindow() throws {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        let entry = element("about-settings", in: app)
        let scene = app.windows.firstMatch.frame
        for _ in 0..<16 {
            // A partly exposed row may be reported as hittable while its
            // center is still covered by the floating landscape tab bar.
            if entry.isHittable, entry.frame.midY > scene.minY + 80,
               entry.frame.midY < scene.maxY - 130 { break }
            let details = app.scrollViews["about-details-scroll"]
            let scroll = details.exists ? details : app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.2)))
        }
        XCTAssertTrue(entry.isHittable, "关于页必须能进入用户设置：entry=\(entry.frame)，window=\(app.windows.firstMatch.frame)")
        entry.tap()
        let themeEntry = element("theme-preference-entry", in: app)
        XCTAssertTrue(themeEntry.waitForExistence(timeout: 5))
        // Settings is not only a color chooser: both existing routes must
        // remain usable and return to the same navigation context.
        element("settings-account", in: app).tap()
        XCTAssertTrue(element("fan-account-heading", in: app).waitForExistence(timeout: 6))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(tabButton("首页", in: app).isHittable, "iPad 账号页不能让顶部标签栏消失")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("settings-privacy", in: app).waitForExistence(timeout: 5))
        element("settings-privacy", in: app).tap()
        XCTAssertTrue(element("privacy-policy-heading", in: app).waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(tabButton("首页", in: app).isHittable, "iPad 隐私页不能让顶部标签栏消失")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(themeEntry.waitForExistence(timeout: 5))
        themeEntry.tap()
        let window = app.windows.firstMatch
        recordPresentationGeometry("appearance-settings", frame: window.frame)
        for theme in ["blackGold", "pine", "indigo", "ivory", "plum", "rouge", "blush", "bamboo"] {
            let choice = app.buttons["theme-choice-\(theme)"]
            scrollThemeCardFullyIntoView(choice, in: app, towardBeginning: false)
            XCTAssertTrue(choice.isHittable, "\(theme) 主题选项不可操作")
            XCTAssertGreaterThanOrEqual(choice.frame.width, 44)
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
            choice.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: choice)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 2), .completed, "\(theme) 主题未选中")
            XCTAssertEqual(choice.value as? String, "已选择")
            XCTAssertTrue(element("appearance-settings", in: app).exists, "换色不能重建导航并退出设置")
            XCTAssertGreaterThanOrEqual(choice.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(choice.frame.maxX, window.frame.maxX)
            // This settings-only screenshot contains no photographs or account data.
            // Capture the display, not XCUIApplication's crop: on iOS 26
            // its landscape crop can use portrait coordinates and truncate
            // the evidence even when the actual window is correctly laid out.
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "theme-\(theme)-\(Int(window.frame.width))x\(Int(window.frame.height))"
            shot.lifetime = .keepAlways
            add(shot)
        }
        // Audit the entire light page, including UIKit's navigation title,
        // rather than inferring readability from palette values alone.
        if window.frame.height > window.frame.width {
            try app.performAccessibilityAudit(for: [.contrast, .textClipped, .trait])
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("settings-account", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(themeEntry.value as? String, "竹青")
        themeEntry.tap()
        let original = app.buttons["theme-choice-blackGold"]
        scrollThemeCardFullyIntoView(original, in: app, towardBeginning: true)
        original.tap()
        XCTAssertEqual(original.value as? String, "已选择")
    }

    private func scrollThemeCardFullyIntoView(_ card: XCUIElement, in app: XCUIApplication, towardBeginning: Bool) {
        let scene = app.windows.firstMatch
        let window = scene.frame
        let top = max(window.minY + 12, app.navigationBars.firstMatch.frame.maxY + 8)
        let bottom = window.maxY - 24
        for _ in 0..<12 {
            let frame = card.exists ? card.frame : .zero
            if card.isHittable, frame.minY >= top, frame.maxY <= bottom { return }
            // `isHittable` alone includes partly clipped cards. Their center
            // can lie under the navigation bar, where a synthesized tap goes
            // to the bar instead of the card. Use short, directed drags.
            let delta: CGFloat
            if frame.isEmpty {
                delta = towardBeginning ? 100 : -100
            } else if frame.minY < top {
                delta = top - frame.minY + 12
            } else {
                delta = bottom - frame.maxY - 12
            }
            let limit = (bottom - top) * 0.4
            let origin = scene.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: window.width * 0.75, dy: (top + bottom) / 2))
            let end = start.withOffset(CGVector(dx: 0, dy: max(-limit, min(limit, delta))))
            // End stationary: inertial flicks otherwise alternate between
            // overshooting the same row above and below a short landscape view.
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("主题卡片没有完整进入可点击区域：\(card.frame)，范围 \(top)...\(bottom)")
    }

    func testAdministratorLaunchPreviewMatchesWindowAndUpdatesDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-preview-admin-launch-poster-for-testing"]
        app.launch()
        let window = app.windows.firstMatch
        let preview = app.descendants(matching: .any).matching(identifier: "admin-launch-poster-preview").firstMatch
        let update = app.buttons["admin-launch-preview-update-draft"]
        XCTAssertTrue(window.waitForExistence(timeout: 12))
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "后台海报缺少真实布局预览")
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        print("ADMIN_PREVIEW_GEOMETRY window=\(window.frame) preview=\(preview.frame) edit=\(update.frame)")
        XCTAssertTrue(update.isHittable, "缩小的预览不能挡住编辑操作")
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertGreaterThan(preview.frame.height, 0)
        XCTAssertEqual(preview.frame.width / preview.frame.height,
                       window.frame.width / window.frame.height, accuracy: 0.015,
                       "后台预览仍使用固定旧比例，没有跟随当前窗口")
        XCTAssertGreaterThanOrEqual(preview.frame.minX, window.frame.minX - 1)
        XCTAssertLessThanOrEqual(preview.frame.maxX, window.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(preview.frame.minY, window.frame.minY - 1)
        XCTAssertLessThanOrEqual(preview.frame.maxY, window.frame.maxY + 1)
        XCTAssertTrue((preview.value as? String)?.contains("很高兴，在这里遇见你。") == true)
        update.tap()
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "这是一条未发布的测试文案"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                       "编辑草稿后预览还停留在旧文案")
        let vanished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: preview)
        vanished.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [vanished], timeout: 6), .completed,
                       "后台预览错误启动了开屏自动关闭计时器")
        XCTAssertFalse(app.buttons["launch-poster-skip"].exists,
                       "后台缩略预览不应暴露可误触的跳过控件")
        recordPresentationGeometry("admin-launch-preview", frame: window.frame)
    }

    func testProtectedGalleryWorksInEveryActualWindowConfiguration() {
        recordPresentationGeometry("protected-gallery", frame: verifyProtectedGalleryCurrentWindow())
    }

    func testProtectedNotificationWorksInEveryActualWindowConfiguration() {
        recordPresentationGeometry("protected-notification", frame: verifyProtectedNotificationCurrentWindow())
    }

    private func recordPresentationGeometry(_ name: String, frame: CGRect) {
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        let geometry = frame.width > frame.height ? "landscape" : "portrait"
        Self.presentationGeometries[name, default: []].insert(geometry)
        let evidence = "\(name): \(geometry), window=\(frame)"
        print("PRESENTATION_GEOMETRY \(evidence)")
        XCTContext.runActivity(named: "Actual window geometry — \(name)") { activity in
            let attachment = XCTAttachment(string: evidence)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    func testAboutLayoutMatchesTheCurrentSceneConfiguration() {
        verifyAboutCanvasCurrentConfiguration(imageFailure: false)
    }

    func testAboutImageFailureKeepsCaptionWithinActualCanvas() {
        verifyAboutCanvasCurrentConfiguration(imageFailure: true)
    }

    private func verifyAboutCanvasCurrentConfiguration(imageFailure: Bool) {
        var arguments = [
            "-open-about-for-visual-testing",
            "-expose-about-visible-bottom-for-visual-testing",
            "-expose-about-portrait-canvas-for-testing",
        ]
        if imageFailure {
            arguments.append("-fail-artwork-for-visual-testing")
        } else {
            // Exercise an actual decoded 2:3 image, not another accidental
            // network-failure placeholder. Fixture is DEBUG-only and in RAM.
            arguments.append("-use-deterministic-gallery-images-for-testing")
        }
        let app = launchApp(arguments: arguments)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let heading = element("about-biography", in: app)
        // SwiftUI forwards the image identifier to its retry button when
        // loading fails. Measure the real canvas in BOTH success and failure
        // states, just as the large-text About regressions already do.
        let portrait = element("about-portrait-canvas", in: app)
        let roleSummary = element("about-role-summary", in: app)
        let visibleBottom = element("about-visible-bottom", in: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "当前 UI 配置下关于页标题没有出现")
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "当前 UI 配置下关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "当前 UI 配置下职业说明没有出现")
        XCTAssertTrue(visibleBottom.waitForExistence(timeout: 8), "当前 UI 配置下缺少可见区域边界")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")
        if imageFailure {
            let retry = app.buttons["about-portrait"].firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 8),
                           "必须实际进入图片加载失败状态，不能用正常图片代替失败验收")
            XCTAssertTrue(portrait.frame.contains(retry.frame), "图片重试按钮超出人物画布")
        } else {
            XCTAssertTrue(app.images["about-portrait"].firstMatch.waitForExistence(timeout: 8),
                          "正常状态必须实际显示解码后的图片")
            XCTAssertFalse(app.buttons["about-portrait"].exists,
                           "不能把加载失败的重试按钮当作正常图片验收")
        }
        let imageDescription = element("about-portrait", in: app).debugDescription
        let stateName = imageFailure ? "failed" : "loaded"
        print("ABOUT_CANVAS failure=\(imageFailure) canvas=\(portrait.frame) role=\(roleSummary.frame) image=\(imageDescription)")
        attachScreenshot(named: "adaptive-about-before-boundary-assertions-\(stateName)", app: app)

        let scene = window.frame
        let expectsTwoColumns = scene.width >= 700 || scene.width > scene.height
        if expectsTwoColumns {
            XCTAssertGreaterThan(
                heading.frame.minX,
                scene.midX - 24,
                "规则宽度或横屏配置下，关于页没有形成左图右文布局"
            )
            XCTAssertLessThanOrEqual(
                portrait.frame.maxX,
                scene.midX + 24,
                "规则宽度或横屏配置下，人物图越过了左侧栏"
            )
        } else {
            XCTAssertGreaterThanOrEqual(
                heading.frame.minY,
                portrait.frame.maxY - 1,
                "紧凑竖屏配置下，关于页没有形成先图片后文字的单列布局"
            )
        }

        XCTAssertLessThanOrEqual(heading.frame.maxX, scene.maxX + 1, "关于页标题超出窗口")
        XCTAssertGreaterThanOrEqual(portrait.frame.minY, scene.minY - 1, "关于页人物图顶部超出窗口")
        XCTAssertGreaterThanOrEqual(portrait.frame.minX, scene.minX - 1, "关于页人物图超出窗口")
        XCTAssertLessThanOrEqual(portrait.frame.maxX, scene.maxX + 1, "关于页人物图超出窗口")
        XCTAssertTrue(
            portrait.frame.insetBy(dx: -1, dy: -1).contains(roleSummary.frame),
            "关于页职业说明超出人物图"
        )
        XCTAssertLessThanOrEqual(
            roleSummary.frame.maxY + 12,
            visibleBottom.frame.minY,
            "关于页职业说明没有留足当前窗口的底部安全余量"
        )
        XCTAssertLessThanOrEqual(
            portrait.frame.maxY,
            scene.maxY + 1,
            "关于页人物图没有完整收进当前窗口"
        )
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(
                portrait.frame.minY,
                statusBar.frame.maxY - 1,
                "关于页人物图侵入状态栏或灵动岛安全区域"
            )
        }

        let homeTab = tabButton("首页", in: app)
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "当前 UI 配置下主导航不存在")
        XCTAssertTrue(homeTab.isHittable, "当前 UI 配置下主导航不可点击")
        attachScreenshot(named: "adaptive-about", app: app)
    }

    func testIPadAboutPortraitRemainsFixedWhileOnlyDetailsScroll() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("固定双栏滚动是 iPad 专属行为")
        }
        let app = launchApp(arguments: ["-open-about-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        guard window.frame.width >= 700 else {
            throw XCTSkip("窄窗口使用可滚动的单列布局")
        }
        recordPresentationGeometry("about-pinned-scroll", frame: window.frame)
        let portrait = element("about-portrait", in: app)
        let role = element("about-role-summary", in: app)
        let heading = element("about-biography", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 8))
        XCTAssertTrue(role.waitForExistence(timeout: 8))
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        let portraitBefore = portrait.frame
        let roleBefore = role.frame
        let headingBefore = heading.frame.minY
        let details = app.scrollViews["about-details-scroll"].firstMatch
        // The fallback also makes this regression fail against the former
        // whole-page scroll view: dragging the right half moved both columns.
        let scroll = details.exists ? details : app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertLessThan(heading.frame.minY, headingBefore - 30, "右侧详情没有滚动")
        XCTAssertEqual(portrait.frame.minY, portraitBefore.minY, accuracy: 1, "滚动右栏时左图跟着移动")
        XCTAssertEqual(portrait.frame.maxY, portraitBefore.maxY, accuracy: 1, "滚动右栏时左图尺寸变化")
        XCTAssertEqual(role.frame.minY, roleBefore.minY, accuracy: 1, "左侧职业介绍跟着滚动")

        let headingAfter = heading.frame.minY
        portrait.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: portrait.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
            ))
        XCTAssertEqual(heading.frame.minY, headingAfter, accuracy: 1, "左图上的滑动不应驱动右栏")

        let privacy = element("about-privacy-policy", in: app)
        for _ in 0..<6 where !privacy.isHittable { scroll.swipeUp() }
        XCTAssertTrue(privacy.isHittable, "右栏底部隐私入口无法滚动到达")
        let lastLink = element("about-weather-legal-link", in: app)
        for _ in 0..<6 where !lastLink.isHittable { scroll.swipeUp() }
        XCTAssertTrue(lastLink.isHittable, "右栏最后的许可入口无法滚动到达")
        XCTAssertEqual(portrait.frame.minY, portraitBefore.minY, accuracy: 1)
        XCTAssertEqual(role.frame.minY, roleBefore.minY, accuracy: 1)
        XCTAssertTrue(window.frame.contains(role.frame), "固定职业介绍超出窗口")
        XCTAssertTrue(tabButton("首页", in: app).isHittable)
        attachScreenshot(named: "adaptive-about-pinned-after-scroll", app: app)
    }

    func testPortfolioSearchMatchesTheCurrentSceneConfiguration() {
        let app = launchApp(arguments: ["-open-portfolio-for-visual-testing"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let searchField = element("portfolio-search-field", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), "当前 UI 配置下作品搜索框没有出现")

        let scene = window.frame
        XCTAssertLessThan(
            searchField.frame.minY,
            scene.height * 0.13,
            "当前 UI 配置下作品搜索框距离顶部过远"
        )
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(
                searchField.frame.minY,
                statusBar.frame.maxY - 1,
                "当前 UI 配置下作品搜索框侵入状态栏安全区域"
            )
        }
        attachScreenshot(named: "adaptive-portfolio-search", app: app)
    }

    func testProtectedIPadPortfolioSearchSurvivesRepeatedNavigation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad 导航与保护容器回归") }
        let app = launchApp(arguments: [
            "-open-portfolio-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
            "-hold-home-remote-images-for-visual-testing",
            "-disable-home-auto-advance-for-visual-testing"
        ], screenProtectionEnabled: true)
        let window = app.windows.firstMatch
        recordPresentationGeometry("protected-portfolio-navigation", frame: window.frame)
        let search = element("portfolio-search-control", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        let initial = search.frame

        for _ in 0..<3 {
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            let portfolioID = card.identifier.replacingOccurrences(of: "portfolio-card-", with: "")
            card.tap()
            XCTAssertTrue(element("portfolio-detail-\(portfolioID)", in: app).waitForExistence(timeout: 8))
            XCTAssertFalse(app.navigationBars.textFields["portfolio-search-field"].exists,
                           "作品搜索栏不应留在相册详情的导航栏中")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 8))
            XCTAssertEqual(search.frame.minY, initial.minY, accuracy: 1)
            XCTAssertEqual(search.frame.height, initial.height, accuracy: 1)
        }

        // Verify real keyboard input rather than XCTest's isHittable estimate.
        let field = app.textFields["portfolio-search-field"]
        field.tap()
        field.typeText("ios27-no-match")
        XCTAssertEqual(field.value as? String, "ios27-no-match")
        app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["取消"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "取消搜索后键盘应关闭")
        XCTAssertEqual(search.frame.minY, initial.minY, accuracy: 1)
        XCTAssertTrue(tabButton("首页", in: app).isHittable)
    }

    func testGalleryViewerMatchesTheCurrentSceneConfiguration() {
        let app = launchApp(arguments: [
            "-open-portfolio-for-visual-testing",
            "-use-multi-image-gallery-for-visual-testing",
            "-use-deterministic-gallery-images-for-testing",
        ])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let card = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12), "作品网格中没有可打开的相册")
        card.tap()

        let firstImage = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-"))
            .firstMatch
        XCTAssertTrue(firstImage.waitForExistence(timeout: 8), "相册封面无法打开")
        let imageIdentifier = firstImage.identifier.replacingOccurrences(
            of: "portfolio-open-image-",
            with: "gallery-image-"
        )
        firstImage.tap()

        let image = element(imageIdentifier, in: app)
        let caption = element("gallery-caption", in: app)
        let close = element("gallery-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 8), "图片查看器没有出现")
        XCTAssertTrue(image.waitForExistence(timeout: 8), "图片查看器没有显示当前照片")
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "图片查看器缺少底部说明")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "图片查看器缺少关闭按钮")
        assertMinimumTapTarget(close, named: "图片查看器关闭")
        XCTAssertTrue(window.frame.contains(image.frame), "当前照片超出窗口")

        if window.frame.width >= 700 {
            XCTAssertGreaterThanOrEqual(
                image.frame.minY,
                close.frame.maxY - 1,
                "iPad 照片上边缘被顶部控件遮挡"
            )
            XCTAssertLessThanOrEqual(
                image.frame.maxY,
                caption.frame.minY + 1,
                "iPad 照片下边缘被底部说明遮挡"
            )
        }

        let counter = element("gallery-counter", in: app)
        XCTAssertTrue(counter.waitForExistence(timeout: 3), "图片查看器缺少页码")
        XCTAssertEqual(counter.label, "第 1 张，共 3 张", "多图回归数据没有生效")
        let initialCounter = counter.label
        image.swipeLeft()
        let pageChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialCounter),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [pageChanged], timeout: 5),
            .completed,
            "iPad 左右翻页没有切换到下一张照片"
        )
        XCTAssertTrue(close.exists, "切换照片时查看器丢失")
        XCTAssertTrue(caption.exists, "切换照片时查看器内容中断")
        XCTAssertEqual(counter.label, "第 2 张，共 3 张")

        let secondImage = element("gallery-image-33", in: app)
        XCTAssertTrue(secondImage.waitForExistence(timeout: 5), "切换后的第二张照片没有显示")
        XCTAssertTrue(window.frame.contains(secondImage.frame), "切换后的照片超出窗口")
        if window.frame.width >= 700 {
            XCTAssertGreaterThanOrEqual(
                secondImage.frame.minY,
                close.frame.maxY - 1,
                "iPad 切图后照片上边缘被顶部控件遮挡"
            )
            XCTAssertLessThanOrEqual(
                secondImage.frame.maxY,
                caption.frame.minY + 1,
                "iPad 切图后照片下边缘被底部说明遮挡"
            )
        }

        attachScreenshot(named: "adaptive-gallery-viewer", app: app)
        close.tap()
        let viewerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [viewerDismissed], timeout: 3),
            .completed,
            "当前 UI 配置下图片查看器无法关闭"
        )
    }

    func testGalleryRepeatedPinchPreservesPagingAndClose() {
        verifyGalleryRepeatedPinch(imageFailure: false)
    }

    func testGalleryFailureKeepsRetryAndZoomResetAndCloseUsable() {
        verifyGalleryRepeatedPinch(imageFailure: true)
    }

    private func verifyGalleryRepeatedPinch(imageFailure: Bool) {
        let app = launchApp(arguments: [
            "-open-portfolio-for-visual-testing",
            "-use-multi-image-gallery-for-visual-testing",
            "-trace-gallery-gestures-for-testing",
            imageFailure ? "-fail-artwork-for-visual-testing" : "-use-deterministic-gallery-images-for-testing",
        ], screenProtectionEnabled: true)
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-card-")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        card.tap()
        let thumbnail = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "portfolio-open-image-")
        ).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 8))
        let identifier = thumbnail.identifier.replacingOccurrences(
            of: "portfolio-open-image-", with: "gallery-image-"
        )
        thumbnail.tap()
        let photo = element(identifier, in: app)
        let close = element("gallery-close", in: app)
        let counter = element("gallery-counter", in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        recordPresentationGeometry(imageFailure ? "gallery-failure-gestures" : "gallery-loaded-gestures",
                                   frame: app.windows.firstMatch.frame)
        let retries = app.buttons.matching(identifier: "artwork-image-retry")
        if imageFailure {
            XCTAssertTrue(retries.firstMatch.waitForExistence(timeout: 5))
            guard let retry = retries.allElementsBoundByIndex.first(where: {
                $0.isHittable && photo.frame.intersects($0.frame)
            }) else {
                XCTFail("当前照片缺少可点击的重试按钮：\(app.debugDescription)")
                return
            }
            retry.tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 5), "持续加载失败仍必须允许再次重试")
        } else {
            XCTAssertTrue(retries.allElementsBoundByIndex.allSatisfy { !$0.isHittable || !photo.frame.intersects($0.frame) },
                          "正常图片手势用例不能在网络失败占位图上假装验收成功")
        }

        for _ in 0..<3 {
            photo.pinch(withScale: 1.8, velocity: 0.9)
            let zoomed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", "缩放 100%"), object: photo
            )
            XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
            let dragStart = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6))
            let dragEnd = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
            dragEnd.press(forDuration: 0.05, thenDragTo: dragStart)
            XCTAssertEqual(counter.label, "第 1 张，共 3 张", "缩放不应意外翻页")
            if imageFailure {
                // Retry is an intentional interactive button in the centre,
                // not the photograph. Exercise zoom on unobstructed canvas.
                photo.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).doubleTap()
            } else {
                photo.doubleTap()
            }
            let reset = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "缩放 100%"), object: photo
            )
            let resetResult = XCTWaiter.wait(for: [reset], timeout: 3)
            if resetResult != .completed {
                let details = XCTAttachment(string: "photo=\(photo.debugDescription)\napp=\(app.debugDescription)")
                details.name = "gallery-double-tap-failure-state"
                details.lifetime = .keepAlways
                add(details)
            }
            XCTAssertEqual(resetResult, .completed, "native zoom=\(String(describing: photo.value)); \(photo.debugDescription)")
            XCTAssertTrue(close.isHittable, "缩放后关闭按钮不可操作")
        }
        photo.swipeLeft()
        let paged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "第 2 张，共 3 张"), object: counter
        )
        XCTAssertEqual(XCTWaiter.wait(for: [paged], timeout: 5), .completed)
        close.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: close
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
    }

    func testHomeBlackGoldAndPineMatchThePage() throws {
        try verifyHomeThemes([("blackGold", 0x060606), ("pine", 0x10201B)])
    }

    func testHomeIndigoAndIvoryMatchThePage() throws {
        try verifyHomeThemes([("indigo", 0x131E32), ("ivory", 0xF4F0E8)])
    }

    func testHomePlumAndRougeMatchThePage() throws {
        try verifyHomeThemes([("plum", 0x231D2B), ("rouge", 0x2B1E22)])
    }

    func testHomeBlushAndBambooMatchThePage() throws {
        try verifyHomeThemes([("blush", 0xF4EBED), ("bamboo", 0xEBF1E8)])
    }

    private func verifyHomeThemes(_ themes: [(String, UInt32)]) throws {
        var referencePhotoSamples: [[UInt8]]?
        for (theme, _) in themes {
            let app = launchApp(arguments: [
                "-cn.com.shuzijun.yishu.appearance.v1", theme,
                "-hold-home-remote-images-for-visual-testing",
                "-disable-home-auto-advance-for-visual-testing",
                "-expose-home-hero-state-for-visual-testing",
            ])
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(element("home-open-portfolio", in: app).waitForExistence(timeout: 8))
            for (title, heading) in [("作品", "portfolio-heading"), ("影视", "credits-heading"),
                                     ("收藏", "favorites-heading"), ("关于", "about-biography")] {
                tabButton(title, in: app).tap()
                XCTAssertTrue(element(heading, in: app).waitForExistence(timeout: 6), "\(theme)：\(title)丢失")
            }
            tabButton("首页", in: app).tap()
            assertMinimumTapTarget(element("home-weather", in: app), named: "天气")
            assertMinimumTapTarget(element("home-open-portfolio", in: app), named: "查看作品")
            let title = element("home-hero-title", in: app)
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            if window.height > window.width {
                XCTAssertEqual(title.frame.minX - window.minX, 22, accuracy: 1,
                               "经典首页文案必须靠左，不能居中成画廊说明")
            }
            let photo = heroPhoto(0, in: app)
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            for identifier in ["home-hero-title", "home-hero-subtitle", "home-weather", "home-open-portfolio"] {
                let control = element(identifier, in: app)
                XCTAssertTrue(control.exists)
                // Classic 1.3 deliberately overlays copy on the full photo.
                // Keep every overlay inside the safe window and above tabs.
                XCTAssertTrue(window.contains(control.frame), "\(theme)：\(identifier) 超出窗口")
                if app.tabBars.firstMatch.exists {
                    XCTAssertFalse(app.tabBars.firstMatch.frame.intersects(control.frame),
                                   "\(theme)：\(identifier) 被底部导航遮挡")
                }
            }
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(photo.frame),
                          "\(theme)：照片被窗口裁切，window=\(window)，photo=\(photo.frame)")
            if window.height > window.width {
                XCTAssertGreaterThanOrEqual(photo.frame.width / window.width, 0.98,
                                           "经典首页不应缩进成画廊照片框")
                XCTAssertGreaterThanOrEqual(photo.frame.height / window.height, 0.995,
                                           "照片必须覆盖状态栏及底部安全区")
            }
            let screenshot = XCUIScreen.main.screenshot()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let normalized = UIGraphicsImageRenderer(size: window.size, format: format).image { _ in
                screenshot.image.draw(in: CGRect(origin: .zero, size: window.size))
            }
            let source = try XCTUnwrap(normalized.cgImage)
            // iPadOS 26's native audit can hang with XCTest -56. Check the
            // rendered capsule itself in every configuration as well as the
            // source palette contrast tests; retain the native audit on phone.
            let weather = element("home-weather", in: app).frame.offsetBy(dx: -window.minX, dy: -window.minY)
            let weatherCrop = try XCTUnwrap(source.cropping(to: weather.insetBy(dx: 8, dy: 10)))
            let pixelCount = weatherCrop.width * weatherCrop.height
            var weatherPixels = [UInt8](repeating: 0, count: pixelCount * 4)
            let weatherContext = try XCTUnwrap(CGContext(data: &weatherPixels, width: weatherCrop.width,
                height: weatherCrop.height, bitsPerComponent: 8, bytesPerRow: weatherCrop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            weatherContext.draw(weatherCrop, in: CGRect(x: 0, y: 0, width: weatherCrop.width, height: weatherCrop.height))
            func linear(_ value: UInt8) -> Double {
                let component = Double(value) / 255
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            let luminances = stride(from: 0, to: weatherPixels.count, by: 4).map { offset in
                0.2126 * linear(weatherPixels[offset]) + 0.7152 * linear(weatherPixels[offset + 1])
                    + 0.0722 * linear(weatherPixels[offset + 2])
            }.sorted()
            XCTAssertGreaterThanOrEqual((luminances[pixelCount * 95 / 100] + 0.05)
                / (luminances[pixelCount * 5 / 100] + 0.05), 4.5, "\(theme)：实际天气胶囊文字不清晰")
            // The system regions must contain photograph pixels, not the
            // previous solid theme strips. Use the synthetic artwork only.
            if window.height > window.width {
                let crop = try XCTUnwrap(source.cropping(to: CGRect(x: window.width * 0.18, y: 2,
                                                                   width: window.width * 0.12, height: 4)))
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                XCTAssertGreaterThan(pixel[0], 80, "顶部出现黑边：\(pixel)")
                XCTAssertGreaterThan(Int(pixel[1]) - Int(pixel[2]), 8,
                                     "顶部没有显示照片颜色：\(pixel)")
                let bottomCrop = try XCTUnwrap(source.cropping(to: CGRect(
                    x: window.width * 0.25, y: window.height - 6, width: 4, height: 4)))
                context.draw(bottomCrop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                XCTAssertGreaterThan(pixel[1], 35, "底部安全区出现黑边：\(pixel)")
                XCTAssertGreaterThan(Int(pixel[1]) - Int(pixel[2]), 5,
                                     "底部没有延续照片：\(pixel)")
            }
            // Sample inside the actual photo, not a window coordinate that may
            // belong to a landscape safe area. In every configuration the
            // underlying photograph must remain unchanged across themes.
            var samples: [[UInt8]] = []
            for fraction in [0.2, 0.8] {
                let photoCrop = try XCTUnwrap(source.cropping(to: CGRect(
                    x: photo.frame.minX - window.minX + photo.frame.width * fraction,
                    y: photo.frame.minY - window.minY + photo.frame.height * fraction,
                    width: 8, height: 8)))
                var sample = [UInt8](repeating: 0, count: 4)
                try sample.withUnsafeMutableBytes { buffer in
                    let sampler = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    sampler.draw(photoCrop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                samples.append(sample)
            }
            let photoVariation = (0..<3).reduce(0.0) { total, channel in
                total + abs(Double(samples[0][channel]) - Double(samples[1][channel]))
            } / 3
            XCTAssertGreaterThan(photoVariation, 25, "\(theme)：照片内容没有正常显示；像素=\(samples)")
            if let referencePhotoSamples {
                for index in samples.indices {
                    for channel in 0..<3 {
                        XCTAssertEqual(Double(samples[index][channel]), Double(referencePhotoSamples[index][channel]),
                                       accuracy: 3, "\(theme)：主题改变了照片原始色彩")
                    }
                }
            } else {
                referencePhotoSamples = samples
            }
            // Only the synthetic gradient fixture is saved, never a photograph.
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "home-theme-\(theme)-\(Int(window.width))x\(Int(window.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            if UIDevice.current.userInterfaceIdiom == .phone, window.height > window.width {
                try app.performAccessibilityAudit(for: [.contrast, .textClipped, .trait])
            }
            app.terminate()
        }
    }

    func testHomeHeroKeepsTheFullIPadCompositionAndNeverTurnsBlank() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("该构图与黑屏门禁只适用于 iPad；iPhone 由首页控件与辅助功能用例覆盖")
        }
        let heroArguments = [
            "-hold-home-remote-images-for-visual-testing",
            "-expose-home-hero-state-for-visual-testing",
        ]
        let staticHeroArguments = heroArguments + [
            "-disable-home-auto-advance-for-visual-testing",
        ]
        var app = launchApp(arguments: staticHeroArguments + [
            "-home-hero-selection-for-visual-testing", "0",
        ])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的 iPad 窗口")

        let state = element("home-hero-visual-state-0", in: app)
        let pageIndicator = element("home-hero-page-indicator", in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 8), "缺少首页图片显示状态")
        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 8), "缺少首页轮播页码")

        let expectsFullComposition = window.frame.width > window.frame.height
        XCTAssertEqual(
            state.label,
            expectsFullComposition ? "完整显示" : "铺满显示",
            "首页应恢复竖屏铺满，同时保留横屏完整构图"
        )
        XCTAssertEqual(pageIndicator.value as? String, "第 1 张，共 5 张")
        if expectsFullComposition {
            let fittedImage = element("home-hero-actual-fitted-image-0", in: app)
            XCTAssertTrue(fittedImage.waitForExistence(timeout: 5), "缺少 iPad 横屏完整图片范围")
            let visibleImageFrame = window.frame.intersection(fittedImage.frame)
            XCTAssertGreaterThanOrEqual(
                visibleImageFrame.width / fittedImage.frame.width,
                0.98,
                "完整图片左右超出首页可视范围：window=\(window.frame)，image=\(fittedImage.frame)"
            )
            XCTAssertGreaterThanOrEqual(
                visibleImageFrame.height / fittedImage.frame.height,
                0.95,
                "完整图片上下超出首页可视范围：window=\(window.frame)，image=\(fittedImage.frame)"
            )
            XCTAssertEqual(
                fittedImage.frame.width / fittedImage.frame.height,
                959.0 / 1_440.0,
                accuracy: 0.02,
                "iPad 横屏首页仍在裁切竖版照片"
            )
        }
        assertHomeHeroIsVisiblyRendered(in: app, page: 1)

        for page in [2, 3, 4, 5, 1] {
            app.terminate()
            app = launchApp(arguments: staticHeroArguments + [
                "-home-hero-selection-for-visual-testing", "\(page - 1)",
            ])
            let pageState = element("home-hero-visual-state-\(page - 1)", in: app)
            XCTAssertTrue(
                pageState.waitForExistence(timeout: 8),
                "首页轮播没有显示第 \(page) 张的可验证状态"
            )
            XCTAssertEqual(pageState.value as? String, "第 \(page) 张，共 5 张")
            assertHomeHeroIsVisiblyRendered(in: app, page: page)
        }

        attachScreenshot(named: "adaptive-home-hero-continuity", app: app)
    }

    func testAccessibilityXXXLKeepsHomeControlsComfortableInEveryConfiguration() {
        let app = launchApp(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-simulate-ready-weather-for-visual-testing",
            "-hold-home-remote-images-for-visual-testing",
            "-disable-home-auto-advance-for-visual-testing",
        ])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let weather = element("home-weather", in: app)
        let weatherAttribution = element("home-weather-attribution-control", in: app)
        let portfolioAction = element("home-open-portfolio", in: app)
        assertMinimumTapTarget(weather, named: "当前 UI 配置的首页天气")
        assertMinimumTapTarget(portfolioAction, named: "当前 UI 配置的查看作品")
        XCTAssertTrue(weather.isHittable, "辅助功能大字号下天气入口不可点击")
        XCTAssertFalse(weatherAttribution.exists, "辅助功能大字号下首页不应出现天气署名入口")
        XCTAssertTrue(portfolioAction.isHittable, "辅助功能大字号下查看作品不可点击")
        XCTAssertTrue(window.frame.contains(weather.frame), "辅助功能大字号下天气入口超出窗口")
        XCTAssertTrue(window.frame.contains(portfolioAction.frame), "辅助功能大字号下查看作品超出窗口")
        let copy = app.scrollViews["home-hero-copy-scroll"]
        let role = element("home-hero-subtitle", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        for _ in 0..<4 where role.frame.maxY > copy.frame.maxY + 1 {
            copy.swipeUp()
        }
        XCTAssertEqual(role.label, "短剧演员 · 模特 · 视频创作者")
        XCTAssertLessThanOrEqual(role.frame.maxY, copy.frame.maxY + 1,
                                "超大字号下应能滚动读到职业说明末尾，而不是永久裁掉")
        XCTAssertGreaterThan(role.frame.maxY, copy.frame.minY)
        XCTAssertTrue(portfolioAction.isHittable, "阅读长文后查看作品仍应可用")
        attachScreenshot(named: "adaptive-home-accessibility-xxxl", app: app)
    }

    func testClassicWeeklyHeroHandlesMixedAspectsWithoutMovingTheOverlay() throws {
        let app = launchApp(arguments: ["-hold-home-remote-images-for-visual-testing",
            "-disable-home-auto-advance-for-visual-testing", "-expose-home-hero-state-for-visual-testing",
            "-home-hero-varied-aspects-for-visual-testing"])
        let title = element("home-hero-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let titleFrame = title.frame
        if app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width {
            XCTAssertEqual(titleFrame.minX - app.windows.firstMatch.frame.minX, 22, accuracy: 1,
                           "经典首页标题必须保留 1.3 左对齐")
        }
        let weather = element("home-weather", in: app)
        let weatherFrame = weather.frame
        let page = element("home-hero-page-indicator", in: app)
        let ratios = [959.0 / 1440, 1440.0 / 959, 1, 4, 0.5]
        for index in 0..<5 {
            let photo = heroPhoto(index, in: app)
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            XCTAssertEqual(page.value as? String, "第 \(index + 1) 张，共 5 张")
            if app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height {
                XCTAssertEqual(photo.frame.width / photo.frame.height, ratios[index], accuracy: 0.02)
            } else {
                XCTAssertGreaterThanOrEqual(photo.frame.width / app.windows.firstMatch.frame.width, 0.98)
                XCTAssertGreaterThanOrEqual(photo.frame.height / app.windows.firstMatch.frame.height, 0.70)
                XCTAssertTrue(photo.frame.contains(title.frame), "经典文案应叠在照片左下角")
            }
            XCTAssertTrue(app.windows.firstMatch.frame.contains(photo.frame))
            XCTAssertFalse(title.frame.intersects(weather.frame))
            XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1)
            XCTAssertEqual(title.frame.minX, titleFrame.minX, accuracy: 1)
            XCTAssertEqual(weather.frame, weatherFrame)
            assertHomeHeroIsVisiblyRendered(in: app, page: index + 1)
            if index < 4 { swipeHero(in: app, forward: true) }
        }
        for index in (0...3).reversed() {
            swipeHero(in: app, forward: false)
            XCTAssertTrue(heroPhoto(index, in: app).waitForExistence(timeout: 5))
            XCTAssertEqual(page.value as? String, "第 \(index + 1) 张，共 5 张")
            XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1)
        }
        // Safe to retain: these are generated color fixtures, not remote photos.
        attachScreenshot(named: "classic-weekly-hero-mixed-aspects", app: app)
    }

    private func heroPhoto(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        return element("home-hero-actual-\(window.width > window.height ? "fitted" : "filled")-image-\(index)", in: app)
    }

    private func swipeHero(in app: XCUIApplication, forward: Bool) {
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        (forward ? right : left).press(forDuration: 0.05, thenDragTo: forward ? left : right)
    }

    private func launchApp(arguments: [String], screenProtectionEnabled: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-app-service-environment", "production",
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ] + arguments
        if screenProtectionEnabled {
            app.launchArguments.removeAll { $0 == "-disable-screen-protection-for-visual-testing" }
        } else {
            app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        }
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()
        XCTAssertTrue(tabButton("首页", in: app).waitForExistence(timeout: 12), "主导航未出现")
        return app
    }

    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let phoneTab = app.tabBars.buttons[title]
        return phoneTab.exists ? phoneTab : app.buttons[title].firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertHomeHeroIsVisiblyRendered(
        in app: XCUIApplication,
        page: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // app.screenshot().cgImage can retain portrait storage coordinates
        // under XCTest's landscape UI configurations. Draw the screen UIImage
        // first so orientation metadata and the AX window use the same space.
        let screenshot = XCUIScreen.main.screenshot()
        let normalized = UIGraphicsImageRenderer(size: window.size, format: format).image { _ in
            screenshot.image.draw(in: CGRect(origin: .zero, size: window.size))
        }
        guard let source = normalized.cgImage else {
            XCTFail("无法读取第 \(page) 张首页截图", file: file, line: line)
            return
        }
        let photo = heroPhoto(page - 1, in: app)
        guard photo.waitForExistence(timeout: 5) else {
            XCTFail("缺少第 \(page) 张照片的实际显示范围", file: file, line: line)
            return
        }
        let scale = CGFloat(source.width) / window.width
        let frame = photo.frame.offsetBy(dx: -window.minX, dy: -window.minY).insetBy(dx: 4, dy: 4)
        let cropRect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                              width: frame.width * scale, height: frame.height * scale).integral
        guard let crop = source.cropping(to: cropRect) else {
            XCTFail("无法裁取第 \(page) 张首页图片区", file: file, line: line)
            return
        }

        let sampleSide = 24
        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSide,
            height: sampleSide,
            bitsPerComponent: 8,
            bytesPerRow: sampleSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("无法分析第 \(page) 张首页图片", file: file, line: line)
            return
        }
        context.interpolationQuality = .low
        context.draw(crop, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))

        var luminanceTotal = 0.0
        var visiblyLitSamples = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            luminanceTotal += luminance
            if luminance > 0.16 { visiblyLitSamples += 1 }
        }
        let sampleCount = sampleSide * sampleSide
        let meanLuminance = luminanceTotal / Double(sampleCount)
        let visiblyLitRatio = Double(visiblyLitSamples) / Double(sampleCount)
        XCTAssertGreaterThan(
            meanLuminance,
            0.10,
            "第 \(page) 张首页轮播变成黑屏",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            visiblyLitRatio,
            0.12,
            "第 \(page) 张首页没有持续显示照片内容",
            file: file,
            line: line
        )
    }

    private func assertMinimumTapTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name)不存在", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "\(name)宽度不足 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "\(name)高度不足 44pt", file: file, line: line)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["YISHU_UI_TEST_ATTACH_SCREENSHOTS"] == "1" else {
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
