import UIKit
import XCTest

final class YishuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // The dedicated UI-configuration suite may finish on a landscape
        // iteration. Keep the ordinary regression suite deterministic and
        // reserve cross-orientation coverage for that dedicated suite.
        XCUIDevice.shared.orientation = .portrait
    }

    func testAppRequiresAdministratorApprovalBeforeShowingContent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
        ]
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        app.launch()

        assertExists("fan-account-heading", in: app, timeout: 12)
        assertExists("fan-register-douyin-id", in: app)
        assertExists("fan-sign-in-with-apple", in: app)
        assertExists("fan-apple-prelogin-privacy", in: app)
        assertExists("access-gate-admin-entry", in: app)
        XCTAssertFalse(app.tabBars.buttons["首页"].exists, "未审批用户不应看到主导航")
        attachScreenshot(named: "00-access-gate", app: app)
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
        app.launch()

        assertExists("fan-apple-registration-required", in: app, timeout: 12)
        assertExists("fan-apple-display-name", in: app)
        assertExists("fan-apple-douyin-id", in: app)
        assertExists("fan-apple-consent", in: app)
        assertExists("fan-apple-delete-onboarding", in: app)
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
        assertExists("about-heading", in: app)
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

        assertExists("gallery-viewer", in: app, timeout: 8)
        XCTAssertTrue(app.buttons["收藏照片"].exists || app.buttons["取消收藏"].exists)
        attachScreenshot(named: "07-gallery-viewer", app: app)
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

    func testCollaborationAndAdministratorRoutesRemainReachable() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        assertExists("about-heading", in: app)

        let collaboration = element("about-collaboration", in: app)
        scrollToElement(collaboration, in: app)
        XCTAssertTrue(collaboration.isHittable, "合作邀约入口不可点击")
        collaboration.tap()
        assertExists("collaboration-heading", in: app)
        XCTAssertTrue(app.textFields["联系人 / 称呼"].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(named: "08-collaboration", app: app)

        app.navigationBars.buttons.firstMatch.tap()
        assertExists("about-heading", in: app)

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
        assertExists("about-heading", in: app)

        let adminEntry = element("about-admin-entry", in: app)
        scrollToElement(adminEntry, in: app)
        XCTAssertTrue(adminEntry.isHittable, "管理员入口不可点击")
        adminEntry.tap()
        assertExists("admin-login-heading", in: app)
        XCTAssertTrue(app.secureTextFields["管理员访问码"].waitForExistence(timeout: 5))
        attachScreenshot(named: "10-admin-login", app: app)
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
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-open-portfolio-for-visual-testing",
        ]
        app.launch()

        assertExists("portfolio-heading", in: app, timeout: 12)
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

        assertExists("gallery-viewer", in: app, timeout: 8)
        XCTAssertTrue(app.buttons["收藏照片"].exists || app.buttons["取消收藏"].exists)
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
        let app = launchApp()

        assertExists("home-open-portfolio", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "首页", in: app)

        openTab("作品", in: app)
        assertExists("portfolio-heading", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "作品", in: app)

        openTab("关于", in: app)
        assertExists("about-heading", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "关于", in: app)
    }

    private func launchApp(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ] + arguments
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
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
            let heading = element("about-heading", in: app)
            let portrait = element("about-portrait", in: app)
            XCTAssertTrue(heading.waitForExistence(timeout: 8), "iPad 关于页标题不存在")
            XCTAssertEqual(heading.label, "关于", "iPad 关于页标题语义不正确")
            XCTAssertTrue(portrait.waitForExistence(timeout: 8), "iPad 关于页人物图不存在")
            XCTAssertEqual(portrait.label, "易姝形象照", "iPad 关于页人物图缺少 VoiceOver 语义")
            assertContainedInWindow(heading, named: "iPad 关于页标题", window: window)
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
        while (!element.isHittable || !elementCenterIsVisible(element, in: app)), attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func elementCenterIsVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        guard window.exists, element.exists else { return false }

        let frame = element.frame
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return false }
        return window.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Runs only the layout-sensitive checks across every orientation and
/// appearance configuration the app declares. This is XCTest's supported way
/// to validate iPadOS 26 windows, whose geometry can be independent from the
/// device's physical orientation.
final class YishuAdaptiveLayoutUITests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAboutLayoutMatchesTheCurrentSceneConfiguration() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let heading = element("about-heading", in: app)
        let portrait = element("about-portrait", in: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "当前 UI 配置下关于页标题没有出现")
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "当前 UI 配置下关于页人物图没有出现")

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
        XCTAssertGreaterThanOrEqual(portrait.frame.minX, scene.minX - 1, "关于页人物图超出窗口")
        XCTAssertLessThanOrEqual(portrait.frame.maxX, scene.maxX + 1, "关于页人物图超出窗口")
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

    func testAccessibilityXXXLKeepsHomeControlsComfortableInEveryConfiguration() {
        let app = launchApp(arguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-simulate-ready-weather-for-visual-testing",
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
        attachScreenshot(named: "adaptive-home-accessibility-xxxl", app: app)
    }

    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
        ] + arguments
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
