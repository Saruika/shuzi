import UIKit
import XCTest

final class YishuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        attachScreenshot(named: "03-credits", app: app)

        openTab("收藏", in: app)
        assertExists("favorites-heading", in: app)
        attachScreenshot(named: "04-favorites", app: app)

        openTab("关于", in: app)
        assertExists("about-heading", in: app)
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

    func testCollaborationAndAdministratorRoutesRemainReachable() {
        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        assertExists("about-heading", in: app)

        let collaboration = element("about-collaboration", in: app)
        scrollToElement(collaboration, in: app)
        XCTAssertTrue(collaboration.isHittable, "合作邀约入口不可点击")
        collaboration.tap()
        assertExists("collaboration-heading", in: app)
        XCTAssertTrue(app.textFields["必填"].firstMatch.waitForExistence(timeout: 5))
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

    func testIPadSupportsLandscapeAndKeepsAdaptiveContentVisible() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("横屏窗口回归仅在 iPad 上执行")
        }

        let app = launchApp(arguments: ["-open-about-for-visual-testing"])
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                return window.exists && frame.width > frame.height
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscapeExpectation], timeout: 8),
            .completed,
            "iPad 窗口没有切换到横屏布局"
        )

        assertExists("about-heading", in: app)
        assertExists("about-portrait", in: app)
        XCTAssertTrue(tabButton("首页", in: app).isHittable, "横屏下主导航不可点击")
        attachScreenshot(named: "10-ipad-landscape-about", app: app)
    }

    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-skip-launch-poster-for-visual-testing",
            "-disable-screen-protection-for-visual-testing",
            "-reset-fan-session-for-visual-testing",
        ] + arguments
        app.launchEnvironment["YISHU_DISABLE_SCREEN_PROTECTION_FOR_VISUAL_TESTING"] = "1"
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

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
