import UIKit
import XCTest
import Vision

final class YishuUITests: XCTestCase {
    /// Run on a fresh simulator so notification permission is not determined.
    func testStartupAsksSystemNotificationPermissionBeforeLogin() {
        let app = XCUIApplication()
        app.launchArguments = [
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
    }

    func testProtectedAdministratorPresentationCanAlwaysClose() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
            "-bypass-access-gate-for-visual-testing",
            "-open-about-for-visual-testing",
        ]
        app.launchArguments.append("-skip-startup-notification-authorization-for-testing")
        app.launch()

        let aboutHeading = element("about-heading", in: app)
        XCTAssertTrue(aboutHeading.waitForExistence(timeout: 12), "保护开启后关于页没有出现")
        let adminEntry = element("about-admin-entry", in: app)
        scrollToElement(adminEntry, in: app)
        XCTAssertTrue(adminEntry.isHittable, "保护开启后管理员入口不可点击")
        adminEntry.tap()

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
        let app = launchApp(arguments: ["-cn.com.shuzijun.yishu.appearance.v1", "ivory"])
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
        XCTAssertGreaterThan(bright, 80, "浅色主题首页的时间/系统图标消失在深色图片背景中")
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

    func testAboutRoleSummaryIsCompleteInLandscapeAndLargeText() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let app = launchApp(arguments: [
            "-open-about-for-visual-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryXXXL",
        ])
        let portrait = element("about-portrait", in: app)
        let roleSummary = element("about-role-summary", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "横屏关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "横屏关于页职业说明没有出现")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")
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
            "-expose-about-visible-bottom-for-visual-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let portrait = element("about-portrait", in: app)
        let roleSummary = element("about-role-summary", in: app)
        let visibleBottom = element("about-visible-bottom", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "辅助功能字号下关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "辅助功能字号下职业说明没有出现")
        XCTAssertTrue(visibleBottom.waitForExistence(timeout: 8), "缺少关于页可见区域边界")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")
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
        let app = launchApp()

        assertExists("home-open-portfolio", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "首页", in: app)

        openTab("作品", in: app)
        assertExists("portfolio-heading", in: app)
        try auditPrimaryPageAccessibilityBaseline(pageNamed: "作品", in: app)

        openTab("关于", in: app)
        assertExists("about-heading", in: app)
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
        }
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

    private func scrollFullyAbovePhoneTabBar(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "待审计版权正文不存在", file: file, line: line)
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
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -movement))
            )
        }
        XCTFail("版权正文未能完整滚入底部导航上方，不能执行有效的对比度审计：\(element.frame)", file: file, line: line)
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
        XCTAssertTrue(presentationElement("fan-message-11111111-2222-4333-8444-555555555555", in: app).waitForExistence(timeout: 5))
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
        themeEntry.tap()
        let window = app.windows.firstMatch
        recordPresentationGeometry("appearance-settings", frame: window.frame)
        for theme in ["blackGold", "pine", "indigo", "ivory"] {
            let choice = app.buttons["theme-choice-\(theme)"]
            for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
            XCTAssertTrue(choice.isHittable, "\(theme) 主题选项不可操作")
            XCTAssertGreaterThanOrEqual(choice.frame.width, 44)
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
            choice.tap()
            XCTAssertEqual(choice.value as? String, "已选择")
            XCTAssertTrue(element("appearance-settings", in: app).exists, "换色不能重建导航并退出设置")
            XCTAssertGreaterThanOrEqual(choice.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(choice.frame.maxX, window.frame.maxX)
            // This settings-only screenshot contains no photographs or account data.
            let shot = XCTAttachment(screenshot: app.screenshot())
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
        XCTAssertEqual(themeEntry.value as? String, "月白")
        themeEntry.tap()
        let original = app.buttons["theme-choice-blackGold"]
        for _ in 0..<6 where !original.isHittable { app.swipeDown() }
        original.tap()
        XCTAssertEqual(original.value as? String, "已选择")
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
        let app = launchApp(arguments: [
            "-open-about-for-visual-testing",
            "-expose-about-visible-bottom-for-visual-testing",
        ])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "缺少可验证的应用窗口")

        let heading = element("about-heading", in: app)
        let portrait = element("about-portrait", in: app)
        let roleSummary = element("about-role-summary", in: app)
        let visibleBottom = element("about-visible-bottom", in: app)
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "当前 UI 配置下关于页标题没有出现")
        XCTAssertTrue(portrait.waitForExistence(timeout: 8), "当前 UI 配置下关于页人物图没有出现")
        XCTAssertTrue(roleSummary.waitForExistence(timeout: 8), "当前 UI 配置下职业说明没有出现")
        XCTAssertTrue(visibleBottom.waitForExistence(timeout: 8), "当前 UI 配置下缺少可见区域边界")
        XCTAssertEqual(roleSummary.label, "短剧演员 / 模特 / 视频创作者")

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
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        guard window.frame.width >= 700 else {
            throw XCTSkip("窄窗口使用可滚动的单列布局")
        }
        recordPresentationGeometry("about-pinned-scroll", frame: window.frame)
        let portrait = element("about-portrait", in: app)
        let role = element("about-role-summary", in: app)
        let heading = element("about-heading", in: app)
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

    func testGalleryViewerMatchesTheCurrentSceneConfiguration() {
        let app = launchApp(arguments: [
            "-open-portfolio-for-visual-testing",
            "-use-multi-image-gallery-for-visual-testing",
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
        let app = launchApp(arguments: [
            "-open-portfolio-for-visual-testing",
            "-use-multi-image-gallery-for-visual-testing",
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
            photo.doubleTap()
            let reset = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "缩放 100%"), object: photo
            )
            XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 3), .completed)
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

        let expectsFullComposition = UIDevice.current.userInterfaceIdiom == .pad
            && window.frame.width > window.frame.height
        XCTAssertEqual(
            state.label,
            expectsFullComposition ? "完整显示" : "铺满显示",
            "首页没有按当前 iPad 窗口方向选择正确构图"
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

    private func launchApp(arguments: [String], screenProtectionEnabled: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
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
        guard let source = app.screenshot().image.cgImage else {
            XCTFail("无法读取第 \(page) 张首页截图", file: file, line: line)
            return
        }
        let cropRect = CGRect(
            x: CGFloat(source.width) * 0.34,
            y: CGFloat(source.height) * 0.18,
            width: CGFloat(source.width) * 0.32,
            height: CGFloat(source.height) * 0.48
        ).integral
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
