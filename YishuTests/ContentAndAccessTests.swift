import XCTest
import AuthenticationServices
import Combine
import SwiftUI
import UIKit
import UserNotifications
import WeatherKit
@testable import Yishu

private enum TestCredentialFixture {
    static let currentValue = makeValue(label: "current")
    static let replacementValue = makeValue(label: "replacement")
    static let unchangedValue = makeValue(label: "unchanged")
    static let temporaryValue = "Tmp-" + String(repeating: "T", count: 24) + "-9!"
    static let weakValue = "weak"

    private static func makeValue(label: String) -> String {
        ["not", "a", "credential", label, "2026"].joined(separator: "-")
    }
}

@MainActor
private final class TestPushAuthorizationClient: PushAuthorizationClient {
    enum Outcome {
        case granted
        case denied
        case interrupted
    }

    var status: UNAuthorizationStatus
    var outcomes: [Outcome]
    var requestStarted: (() -> Void)?
    var pauseRequest = false
    private(set) var requestCount = 0
    private var requestContinuation: CheckedContinuation<Void, Never>?

    init(status: UNAuthorizationStatus = .notDetermined, outcomes: [Outcome] = []) {
        self.status = status
        self.outcomes = outcomes
    }

    func currentStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if pauseRequest, requestCount == 1 {
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
                requestStarted?()
            }
        }
        guard !outcomes.isEmpty else {
            XCTFail("不应出现未配置的系统通知授权请求")
            throw URLError(.unknown)
        }
        switch outcomes.removeFirst() {
        case .granted:
            status = .authorized
            return true
        case .denied:
            status = .denied
            return false
        case .interrupted:
            throw URLError(.cancelled)
        }
    }

    func resumeRequest() {
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TestPushNotificationAccount: PushNotificationAccount {
    struct BindingAttempt: Equatable {
        let userID: String?
        let generation: UInt64
        let deviceToken: String
    }

    var pushEligibleUserID: String?
    var pushSessionGeneration: UInt64 = 1
    var hasPushEligibleSession: Bool { pushEligibleUserID != nil }
    var hasPushUnbindingSession = true
    var bindingFailuresRemaining = 0
    var bindingRequiresSignIn = false
    var pauseNextUnbind = false
    var unbindStarted: (() -> Void)?
    private(set) var bindingAttempts: [BindingAttempt] = []
    private(set) var unbindCount = 0
    private var unbindContinuation: CheckedContinuation<Void, Never>?

    init(userID: String? = nil) {
        pushEligibleUserID = userID
    }

    func bindPushDevice(deviceToken: String) async throws {
        bindingAttempts.append(BindingAttempt(
            userID: pushEligibleUserID,
            generation: pushSessionGeneration,
            deviceToken: deviceToken
        ))
        if bindingRequiresSignIn { throw FanAccountError.sessionExpired }
        if bindingFailuresRemaining > 0 {
            bindingFailuresRemaining -= 1
            throw URLError(.notConnectedToInternet)
        }
    }

    func unbindPushDevice() async throws {
        unbindCount += 1
        if pauseNextUnbind {
            pauseNextUnbind = false
            await withCheckedContinuation { continuation in
                unbindContinuation = continuation
                unbindStarted?()
            }
        }
    }

    func resumeUnbind() {
        let continuation = unbindContinuation
        unbindContinuation = nil
        continuation?.resume()
    }
}

final class ContentAndAccessTests: XCTestCase {
    func testScreenProtectionDoesNotCoverColdLaunchBeforeFirstActiveState() {
        var state = ScreenProtectionPresentationState()

        state.updateScene(isActive: false)

        XCTAssertFalse(state.hasEnteredActiveState)
        XCTAssertFalse(state.isPrivacyCoverVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testScreenProtectionCoversInactiveSceneAfterProtectedContentWasVisible() {
        var state = ScreenProtectionPresentationState()

        state.updateScene(isActive: true)
        state.updateScene(isActive: false)

        XCTAssertTrue(state.hasEnteredActiveState)
        XCTAssertTrue(state.isPrivacyCoverVisible)
        XCTAssertTrue(state.shouldShowProtectionCover)

        state.updateScene(isActive: true)

        XCTAssertFalse(state.isPrivacyCoverVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testScreenshotWarningExpiresWhileLifecycleCoverRemainsActive() {
        var state = ScreenProtectionPresentationState()
        state.updateScene(isActive: true)
        let generation = state.beginScreenshotWarning()

        state.updateScene(isActive: false)
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertTrue(state.isPrivacyCoverVisible)
        XCTAssertTrue(state.shouldShowProtectionCover)
    }

    func testScreenshotWarningExpiresWhileCaptureCoverRemainsActive() {
        var state = ScreenProtectionPresentationState()
        let generation = state.beginScreenshotWarning()

        XCTAssertTrue(state.updateCapture(active: true))
        XCTAssertFalse(state.updateCapture(active: true), "重复状态不应重复触发开始录屏副作用")
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertTrue(state.isCaptureActive)
        XCTAssertTrue(state.shouldShowProtectionCover)

        XCTAssertFalse(state.updateCapture(active: false))
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testOlderScreenshotWarningCannotExpireNewerWarning() {
        var state = ScreenProtectionPresentationState()
        let firstGeneration = state.beginScreenshotWarning()
        let secondGeneration = state.beginScreenshotWarning()

        state.expireScreenshotWarning(generation: firstGeneration)
        XCTAssertTrue(state.isScreenshotWarningVisible)

        state.expireScreenshotWarning(generation: secondGeneration)
        XCTAssertFalse(state.isScreenshotWarningVisible)
    }

    func testCancellingScreenshotWarningInvalidatesPendingGeneration() {
        var state = ScreenProtectionPresentationState()
        let generation = state.beginScreenshotWarning()

        state.cancelScreenshotWarning()
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testWindowLifecycleShieldOnlyAppearsAfterFirstActiveState() {
        var state = WindowLifecycleShieldState()

        state.sceneWillDeactivate()
        state.sceneDidEnterBackground()
        XCTAssertFalse(state.isVisible)

        state.sceneDidActivate()
        XCTAssertTrue(state.hasEnteredActiveState)
        XCTAssertFalse(state.isVisible)

        state.sceneWillDeactivate()
        XCTAssertTrue(state.isVisible)

        state.sceneDidActivate()
        XCTAssertFalse(state.isVisible)
    }

    func testSecureCanvasFallbackPolicyRetriesThenFailsClosed() {
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 1,
                maximumAttempts: 3,
                failure: .canvasMissing
            ),
            .retry
        )
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 3,
                maximumAttempts: 3,
                failure: .canvasMissing
            ),
            .showPrivacyFallback(.canvasMissing)
        )
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 1,
                maximumAttempts: 3,
                failure: nil
            ),
            .attachSecureCanvas
        )
    }

    @MainActor
    func testSecureContainerHostsProtectedContentOnlyInsideAttachedCanvas() {
        var observedStates: [SecureCanvasInstallationState] = []
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { textField in
                let canvas = UIView(frame: textField.bounds)
                textField.addSubview(canvas)
                return canvas
            },
            stateObserver: { observedStates.append($0) }
        )

        XCTAssertEqual(container.installationState, .secured)
        XCTAssertTrue(container.hostsProtectedContent)
        XCTAssertFalse(container.hostsVisiblePrivacyFallback)
        XCTAssertEqual(observedStates.last, .secured)
        XCTAssertFalse(container.isOpaque)
        XCTAssertEqual(container.backgroundColor, .clear)
    }

    @MainActor
    func testSecureContainerShowsVisiblePrivacyFallbackWhenCanvasIsMissing() {
        var observedStates: [SecureCanvasInstallationState] = []
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { _ in nil },
            stateObserver: { observedStates.append($0) }
        )

        XCTAssertEqual(container.installationState, .privacyFallback(.canvasMissing))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
        XCTAssertEqual(observedStates.last, .privacyFallback(.canvasMissing))

        container.update(rootView: AnyView(Text("updated-protected-content")))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
    }

    @MainActor
    func testSecureContainerRejectsDetachedCanvas() {
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { _ in UIView() }
        )

        XCTAssertEqual(container.installationState, .privacyFallback(.canvasNotAttached))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
    }

    func testAboutSocialBrandIconsAreBundledAtDisplayResolution() throws {
        let requiredPixelEdge = Int(ceil(24 * UIScreen.main.scale))
        for assetName in [
            "XiaohongshuBrandIcon",
            "DouyinBrandIcon",
            "HongguoBrandIcon",
        ] {
            let image = try XCTUnwrap(
                UIImage(named: assetName),
                "关于页缺少官方社交平台图标资产 \(assetName)"
            )
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertGreaterThanOrEqual(
                min(cgImage.width, cgImage.height),
                requiredPixelEdge,
                "\(assetName) 不足以在当前屏幕的 24pt 展示中保持清晰"
            )
        }
    }

    func testSafeIdentifiedBindingFallsBackAfterRowRemoval() {
        let fallback = ContentCatalog.launchPosters[0]
        var posters = [fallback]
        let collection = Binding(
            get: { posters },
            set: { posters = $0 }
        )
        let row = SafeIdentifiedBinding.element(for: fallback, in: collection)

        posters.removeAll()

        XCTAssertEqual(row.wrappedValue, fallback)
        var staleUpdate = fallback
        staleUpdate.isEnabled.toggle()
        row.wrappedValue = staleUpdate
        XCTAssertTrue(posters.isEmpty)
    }

    func testSafeIdentifiedBindingResolvesTheCurrentRowByID() {
        let fallback = ContentCatalog.launchPosters[0]
        var current = fallback
        current.title = "服务器新标题"
        var posters = [current]
        let collection = Binding(
            get: { posters },
            set: { posters = $0 }
        )
        let row = SafeIdentifiedBinding.element(for: fallback, in: collection)

        XCTAssertEqual(row.wrappedValue.title, "服务器新标题")
        var edited = row.wrappedValue
        edited.subtitle = "安全写回"
        row.wrappedValue = edited
        XCTAssertEqual(posters.first?.subtitle, "安全写回")
    }

    func testWeatherLocationAlwaysKeepsAConcisePlaceName() {
        XCTAssertEqual(WeatherPresentation.conciseLocationText("杭州市"), "杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("香港特别行政区"), "香港")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("浙江·杭州"), "浙江·杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("  "), "当前位置")
    }

    func testCompactWeatherSummaryOnlyContainsLocationAndCurrentWeather() {
        XCTAssertEqual(
            WeatherPresentation.compactSummary(location: "杭州市", weather: "晴 24°"),
            "杭州 · 晴 24°"
        )
        XCTAssertFalse(
            WeatherPresentation.compactSummary(location: "杭州市", weather: "晴 24°")
                .localizedCaseInsensitiveContains("Apple Weather")
        )
    }

    func testWeatherAttributionAlwaysHasAnOfficialLegalFallback() {
        XCTAssertEqual(
            WeatherAttributionPresentation.officialLegalURL.absoluteString,
            "https://developer.apple.com/weatherkit/data-source-attribution/"
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(from: nil),
            WeatherAttributionPresentation.officialLegalURL
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(
                from: URL(string: "http://weatherkit.apple.com/legal-attribution.html")
            ),
            WeatherAttributionPresentation.officialLegalURL
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(
                from: URL(string: "https://weatherkit.apple.com/legal-attribution.html")
            ).host,
            "weatherkit.apple.com"
        )
    }

    func testWeatherAttributionProviderNameNeverDisappears() {
        XCTAssertEqual(WeatherAttributionPresentation.providerName(nil), "Apple Weather")
        XCTAssertEqual(WeatherAttributionPresentation.providerName("  \n"), "Apple Weather")
        XCTAssertEqual(
            WeatherAttributionPresentation.providerName("Apple Weather"),
            "Apple Weather"
        )
    }

    func testPrivacyManifestCoversAdminMediaAndSecurityDiagnostics() throws {
        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let declarations = try XCTUnwrap(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        var declarationsByType: [String: [String: Any]] = [:]
        for declaration in declarations {
            guard let type = declaration["NSPrivacyCollectedDataType"] as? String else {
                XCTFail("PrivacyInfo.xcprivacy 包含缺少类型的数据声明")
                continue
            }
            XCTAssertNil(declarationsByType[type], "PrivacyInfo.xcprivacy 重复声明 \(type)")
            declarationsByType[type] = declaration
        }

        let expectedLinkedFunctionalTypes = [
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeOtherDataTypes",
        ]
        for type in expectedLinkedFunctionalTypes {
            let declaration = try XCTUnwrap(
                declarationsByType[type],
                "PrivacyInfo.xcprivacy 缺少 \(type)"
            )
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(
                declaration["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }
    }

    func testLoadedPortfolioExposesEveryImage() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(portfolio.images.map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(portfolio.displayImageCount, 6)
    }

    func testServerCountNeverHidesLoadedImages() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(portfolio.images.count, 6)
        XCTAssertGreaterThanOrEqual(portfolio.displayImageCount, portfolio.images.count)
    }

    func testEveryHomeHeroUsesOnlyTrustedRemoteMedia() {
        XCTAssertEqual(ContentCatalog.heroImages.count, 5)
        for url in ContentCatalog.heroImages {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(url))
        }
    }

    func testProtectedPortraitPhotosAreNotBundledInTheApp() {
        let forbiddenAssetNames = [
            "HeroOne", "HeroTwo", "HeroThree", "HeroFour", "HeroFive",
            "AboutPortrait", "ShowreelPoster", "LaunchPosterFallback",
            "LaunchPosterLanternOne", "LaunchPosterLanternTwo", "LaunchPosterLanternThree",
        ]

        for assetName in forbiddenAssetNames {
            XCTAssertNil(UIImage(named: assetName), "受保护人物照片不得打包进 App：\(assetName)")
        }
    }

    func testHomeHeroShowsTheFullPhotoOnlyForLandscapeIPadWindows() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 1_366, height: 1_024),
                idiom: .pad
            ),
            .fit
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 1_024, height: 1_366),
                idiom: .pad
            ),
            .fill
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 932, height: 430),
                idiom: .phone
            ),
            .fill
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 430, height: 932),
                idiom: .phone
            ),
            .fill
        )
    }

    func testLandscapeIPadHeroFitPreservesThePortraitAspectRatio() {
        let source = CGSize(width: 959, height: 1_440)
        let viewport = CGSize(width: 1_376, height: 1_032)
        let fitted = HomeHeroRenderPolicy.fittedSize(
            sourceSize: source,
            in: viewport
        )

        XCTAssertEqual(fitted.height, viewport.height, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fitted.width, viewport.width)
        XCTAssertEqual(
            fitted.width / fitted.height,
            source.width / source.height,
            accuracy: 0.0001
        )
    }

    func testHomeHeroTreatsTheFirstAndLastSlidesAsCircularNeighbours() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.prefetchIndices(selection: 0, count: 5),
            [0, 1, 4]
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 4,
                selection: 0,
                count: 5
            )
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 0,
                selection: 4,
                count: 5
            )
        )
        XCTAssertFalse(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 3,
                selection: 0,
                count: 5
            )
        )
        XCTAssertFalse(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 4, to: 0, count: 5),
            "末张回到首张时不能让非循环 TabView 跨页动画"
        )
        XCTAssertFalse(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 0, to: 4, count: 5),
            "首张回到末张时不能让非循环 TabView 跨页动画"
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 3, to: 4, count: 5)
        )
    }

    func testLandscapeIPadWarmsEveryHeroBeforePaging() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.prefetchIndices(
                selection: 0,
                count: 5,
                presentation: .fit
            ),
            [0, 1, 2, 3, 4]
        )
        for index in 0..<5 {
            XCTAssertTrue(
                HomeHeroRenderPolicy.shouldLoadRemoteImage(
                    at: index,
                    selection: 0,
                    count: 5,
                    presentation: .fit
                ),
                "iPad 横屏第 \(index + 1) 张首页图片没有在切页前加载"
            )
        }
    }

    func testRemoteLaunchPostersDoNotReuseAHomeHero() {
        let homeHeroes = Set(ContentCatalog.heroImages)

        XCTAssertEqual(ContentCatalog.launchPosters.count, 3)
        for poster in ContentCatalog.launchPosters {
            XCTAssertFalse(homeHeroes.contains(poster.imageURL))
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(poster.imageURL))
        }
        XCTAssertEqual(Set(ContentCatalog.launchPosters.map(\.id)).count, 3)
    }

    func testColdLaunchPosterSelectionIsClearedBetweenAccounts() {
        let firstAccountPoster = ContentCatalog.launchPosters[0]
        let secondAccountPoster = ContentCatalog.launchPosters[1]
        var state = ColdLaunchPosterSelectionState()

        state.record(firstAccountPoster)
        XCTAssertTrue(state.hasSelected)
        XCTAssertEqual(state.snapshot, firstAccountPoster)

        state.reset()
        XCTAssertFalse(state.hasSelected)
        XCTAssertNil(state.snapshot)

        state.record(secondAccountPoster)
        XCTAssertEqual(state.snapshot, secondAccountPoster)
        XCTAssertNotEqual(state.snapshot, firstAccountPoster)
    }

    func testLaunchPosterSelectionRotatesDeterministicallyWithoutRepeating() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let posters = [
            makeLaunchPoster(id: "third", startsAt: now.addingTimeInterval(-100)),
            makeLaunchPoster(id: "first", startsAt: now.addingTimeInterval(-300)),
            makeLaunchPoster(id: "second", startsAt: now.addingTimeInterval(-200)),
            makeLaunchPoster(
                id: "future",
                startsAt: now.addingTimeInterval(100),
                endsAt: now.addingTimeInterval(500)
            ),
        ]

        XCTAssertEqual(
            LaunchPosterSelectionPolicy.activeCandidates(in: posters, at: now).map(\.id),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: nil
            )?.id,
            "first"
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: "first"
            )?.id,
            "second"
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: "third"
            )?.id,
            "first",
            "轮换回首张时也必须避免连续重复末张"
        )
    }

    func testLaunchPosterIgnoresLegacyFallbackMetadata() throws {
        let poster = makeLaunchPoster(
            id: "bundled-original",
            startsAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try JSONEncoder().encode(poster)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject["fallbackAssetName"] = "LaunchPosterOriginalOne"
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(LaunchPosterContent.self, from: legacyData)
        XCTAssertEqual(decoded, poster)
    }

    func testAboutPortraitAcceptsOnlyTrustedHTTPSMedia() {
        let trusted = makeManifest(
            aboutPortraitURL: URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/about.jpg")
        )
        let untrusted = makeManifest(
            aboutPortraitURL: URL(string: "https://example.com/about.jpg")
        )

        XCTAssertTrue(ContentSecurityPolicy.isTrusted(trusted))
        XCTAssertFalse(ContentSecurityPolicy.isTrusted(untrusted))
    }

    func testAboutPortraitSelectionUsesConfiguredURLBeforeEveryFallback() {
        let configured = URL(
            string: "https://www.shuzijun.com.cn/wp-content/uploads/about-configured.jpg"
        )!
        let hero = URL(string: "https://img.shuzijun.com.cn/test/about-hero.jpg")!
        let portfolio = makePortfolio(imageCount: 1)

        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: configured,
                heroImages: [hero],
                portfolios: [portfolio]
            ),
            configured
        )
    }

    func testAboutPortraitSelectionFallsBackToHeroThenPortfolioCover() {
        let hero = URL(string: "https://img.shuzijun.com.cn/test/about-hero.jpg")!
        let portfolio = makePortfolio(imageCount: 1)
        let portfolioWithoutCover = Portfolio(
            id: 2,
            title: "无封面相册",
            subtitle: "回归测试",
            eyebrow: "TEST",
            slug: "no-cover",
            websiteURL: URL(
                string: "https://www.shuzijun.com.cn/portfolio/no-cover/"
            )!,
            coverURL: nil,
            images: []
        )

        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [hero],
                portfolios: [portfolio]
            ),
            hero
        )
        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [],
                portfolios: [portfolioWithoutCover, portfolio]
            ),
            portfolio.coverURL
        )
        XCTAssertNil(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [],
                portfolios: []
            )
        )
    }

    @MainActor
    func testAboutPortraitFallbackNeverBecomesAnImplicitAdministratorDraft() throws {
        let manifest = makeManifest(aboutPortraitURL: nil)
        let store = PortfolioStore()

        store.applyPublishedManifest(manifest)

        XCTAssertNil(store.configuredAboutPortraitURL)
        XCTAssertEqual(store.aboutPortraitURL, manifest.heroImages.first)

        let update = AppContentUpdate(
            heroImages: manifest.heroImages,
            aboutPortraitURL: store.configuredAboutPortraitURL,
            launchPosters: try XCTUnwrap(manifest.launchPosters),
            showreel: try XCTUnwrap(manifest.showreel),
            dramas: manifest.dramas
        )
        let data = try JSONEncoder().encode(update)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(
            object["aboutPortraitURL"],
            "保存其他字段时必须省略未配置的关于页照片，不得写入展示用备用图"
        )
    }

    func testAboutPortraitPartialUpdateEncodesNoUnrelatedContent() throws {
        let portraitURL = URL(
            string: "https://www.shuzijun.com.cn/wp-content/uploads/about-published.jpg"
        )!
        let data = try JSONEncoder().encode(
            AboutPortraitUpdate(aboutPortraitURL: portraitURL)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["aboutPortraitURL"])
        XCTAssertEqual(object["aboutPortraitURL"] as? String, portraitURL.absoluteString)
    }

    func testMissingAboutPortraitKeepsOlderManifestsCompatible() throws {
        let original = makeManifest(aboutPortraitURL: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppContentManifest.self, from: data)

        XCTAssertNil(decoded.aboutPortraitURL)
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(decoded))
    }

    func testManifestPolicyRejectsOversizedAndDuplicateCollections() {
        let base = makeManifest(aboutPortraitURL: nil)
        XCTAssertTrue(ContentManifestPolicy.isValid(base))

        let tooManyHeroes = (0..<6).map { index in
            URL(string: "https://img.shuzijun.com.cn/test/hero-\(index).jpg")!
        }
        let oversized = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: tooManyHeroes,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: base.launchPosters,
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: base.portfolios
        )
        XCTAssertFalse(ContentManifestPolicy.isValid(oversized))
        XCTAssertFalse(ContentSecurityPolicy.isTrusted(oversized))

        let duplicatePortfolios = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: base.heroImages,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: base.launchPosters,
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: [base.portfolios[0], base.portfolios[0]]
        )
        XCTAssertFalse(ContentManifestPolicy.isValid(duplicatePortfolios))
    }

    func testManifestPolicyRejectsUnsafeTimingAndUnknownCacheVersions() {
        let base = makeManifest(aboutPortraitURL: nil)
        var invalidPoster = ContentCatalog.launchPosters[0]
        invalidPoster.displaySeconds = .infinity
        let invalidTiming = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: base.heroImages,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: [invalidPoster],
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: base.portfolios
        )

        XCTAssertFalse(ContentManifestPolicy.isValid(invalidTiming))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(nil))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(1))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(2))
        XCTAssertFalse(
            ContentManifestPolicy.isSupportedCacheSchemaVersion(3),
            "Build 41 必须拒绝可能保留旧开屏 URL 的缓存"
        )
        XCTAssertTrue(ContentManifestPolicy.isSupportedCacheSchemaVersion(4))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(5))
    }

    func testInsecureOrUnknownMediaHostsAreRejected() {
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "http://www.shuzijun.com.cn/photo.jpg")!
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "https://example.com/photo.jpg")!
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(
                    string: "https://img.shuzijun.com.cn/\(String(repeating: "a", count: 2_100)).jpg"
                )!
            )
        )
    }

    func testAppURLPreservesValidValuesAndFailsClosedForInvalidValues() {
        let rawValue = "https://www.shuzijun.com.cn/path/image.jpg?size=large"

        XCTAssertEqual(AppURL.make(rawValue).absoluteString, rawValue)

        let invalidURL = AppURL.make("")
        XCTAssertTrue(invalidURL.isFileURL)
        XCTAssertFalse(AppNetworkSecurityPolicy.isTrustedHTTPSOrigin(invalidURL))
        XCTAssertFalse(AppNetworkSecurityPolicy.isTrustedAdminRequestURL(invalidURL))
    }

    func testPublishedManifestUsesAStableTrustedHTTPSEndpoint() {
        let endpoint = ContentCatalog.publishedManifestURL

        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "shuzijun.com.cn")
        XCTAssertNil(endpoint.user)
        XCTAssertNil(endpoint.password)
    }

    func testPrivacyPolicyUsesTheOfficialHTTPSOrigin() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isTrustedHTTPSOrigin(ContentCatalog.privacyPolicyURL))
        XCTAssertEqual(ContentCatalog.privacyPolicyURL.path, "/app-privacy")
    }

    func testBusinessAndPrivacyMailboxesAreExplicitlySeparated() {
        XCTAssertEqual(ContentCatalog.collaborationEmailAddress, "369476120@qq.com")
        XCTAssertEqual(ContentCatalog.emailURL.absoluteString, "mailto:369476120@qq.com")
        XCTAssertEqual(ContentCatalog.privacyContactEmailAddress, "sariki@me.com")
        XCTAssertEqual(ContentCatalog.privacyEmailURL.absoluteString, "mailto:sariki@me.com")
        XCTAssertNotEqual(
            ContentCatalog.collaborationEmailAddress,
            ContentCatalog.privacyContactEmailAddress
        )
    }

    func testPublishedManifestResponseMustMatchTheExactConfiguredEndpoint() {
        let expected = ContentCatalog.publishedManifestURL

        XCTAssertTrue(AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(expected, expected: expected))
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "http://shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://shuzijun.com.cn.evil.example\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://shuzijun.com.cn:444\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://user:password@shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
    }

    func testAdministratorRequestsStayInsideTheWordPressAPINamespace() {
        XCTAssertTrue(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://shuzijun.com.cn/wp-json-evil/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://img.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )

        XCTAssertTrue(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2/media")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2/users")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://shuzijun.com.cn/wp-json/wp/v2/media")
            )
        )
    }

    func testAdministratorUnlockAlwaysExpiresAndMissingExpiryIsLocked() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(AdminSessionSecurityPolicy.isFresh(expiresAt: nil, now: now))
        XCTAssertFalse(
            AdminSessionSecurityPolicy.isFresh(
                expiresAt: Date(timeIntervalSince1970: 999),
                now: now
            )
        )
        XCTAssertTrue(
            AdminSessionSecurityPolicy.isFresh(
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
        XCTAssertFalse(
            AdminSessionSecurityPolicy.canAcceptResponse(
                requestGeneration: 7,
                currentGeneration: 8,
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
        XCTAssertTrue(
            AdminSessionSecurityPolicy.canAcceptResponse(
                requestGeneration: 8,
                currentGeneration: 8,
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
    }

    func testPermissionScopedManifestCanOmitAllVideoMetadata() {
        let full = makeManifest(aboutPortraitURL: nil)
        let scoped = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: nil,
            dramas: [],
            portfolios: full.portfolios
        )

        XCTAssertTrue(ContentManifestPolicy.isValid(scoped))
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(scoped))
    }

    @MainActor
    func testPermissionDowngradeFailsClosedInMemoryAndCannotExpandLocally() {
        let store = PortfolioStore()
        let full = makeManifest(aboutPortraitURL: nil, imageCount: 6)
        defer { store.discardProtectedContent() }

        store.applyPublishedManifest(full)
        XCTAssertEqual(store.portfolios.first?.images.count, 6)
        XCTAssertNotNil(store.showreel)
        XCTAssertFalse(store.dramas.isEmpty)

        store.enforcePermissionScope(canViewFullGallery: false, canViewVideo: false)
        XCTAssertEqual(store.portfolios.first?.images.count, 3)
        XCTAssertEqual(store.portfolios.first?.displayImageCount, 6)
        XCTAssertNil(store.showreel)
        XCTAssertTrue(store.dramas.isEmpty)

        // A local permission flag change must not resurrect removed URLs. Only a
        // new server-authorized manifest can expand the in-memory catalog again.
        store.enforcePermissionScope(canViewFullGallery: true, canViewVideo: true)
        XCTAssertEqual(store.portfolios.first?.images.count, 3)
        XCTAssertNil(store.showreel)
        XCTAssertTrue(store.dramas.isEmpty)

        store.applyPublishedManifest(full)
        XCTAssertEqual(store.portfolios.first?.images.count, 6)
        XCTAssertNotNil(store.showreel)
        XCTAssertFalse(store.dramas.isEmpty)
    }

    func testAdministratorEditorRequiresAuthenticationAndFullManifest() {
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: false,
                hasLoadedFullManifest: false
            )
        )
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: true,
                hasLoadedFullManifest: false
            )
        )
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: false,
                hasLoadedFullManifest: true
            )
        )
        XCTAssertTrue(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: true,
                hasLoadedFullManifest: true
            )
        )

        let full = makeManifest(aboutPortraitURL: nil, imageCount: 6)
        let fanScoped = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: nil,
            dramas: [],
            portfolios: full.portfolios
        )
        let fullPortfolio = full.portfolios[0]
        let galleryPreview = Portfolio(
            id: fullPortfolio.id,
            title: fullPortfolio.title,
            subtitle: fullPortfolio.subtitle,
            eyebrow: fullPortfolio.eyebrow,
            slug: fullPortfolio.slug,
            websiteURL: fullPortfolio.websiteURL,
            coverURL: fullPortfolio.coverURL,
            images: Array(fullPortfolio.images.prefix(3)),
            totalImageCount: fullPortfolio.images.count
        )
        let videoEnabledFanScope = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: full.showreel,
            dramas: full.dramas,
            portfolios: [galleryPreview]
        )
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(full))
        XCTAssertFalse(AdminContentEditingPolicy.isFullAdministratorManifest(fanScoped))
        XCTAssertFalse(
            AdminContentEditingPolicy.isFullAdministratorManifest(videoEnabledFanScope)
        )
    }

    func testAdministratorMediaPreviewsAlwaysPreserveTheCompleteAsset() {
        switch AdminMediaPreviewPolicy.contentMode {
        case .fit:
            break
        case .fill:
            XCTFail("Administrator previews must not crop the source asset")
        @unknown default:
            XCTFail("Administrator previews use an unsupported content mode")
        }
    }

    func testFanIdentityCodesAreNormalizedWithoutAmbiguousCharacters() {
        XCTAssertEqual(
            FanAccountValidation.normalizedIdentityCode("hs-abcd-2345"),
            "HS-ABCD-2345"
        )
        XCTAssertEqual(
            FanAccountValidation.normalizedIdentityCode(" ABCD 2345 "),
            "HS-ABCD-2345"
        )
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCI-2345"))
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCD-1234"))
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCD-234"))
    }

    func testNewFanAcknowledgementsUseTheCurrentPrivacyPolicyVersion() {
        XCTAssertEqual(
            FanAccountConsentPolicy.currentVersion,
            "2026-09-04-approval-v4"
        )
    }

    func testFanRegistrationRequiresAndNormalizesASafeDouyinID() {
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID(" @YiShu_2026 "), "yishu_2026")
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID("一只梳子君"), "一只梳子君")
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("https://v.douyin.com/example"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("a b"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("@"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("   "))
        XCTAssertTrue(FanAccountValidation.isCompleteDouyinID("yishu_2026"))
        XCTAssertFalse(FanAccountValidation.isCompleteDouyinID(""))
        XCTAssertFalse(FanAccountValidation.isCompleteDouyinID(
            "invite_0123456789abcdef01234567"
        ))
    }

    func testFanPasswordPolicyRequiresLengthAndTwoCharacterCategories() {
        XCTAssertTrue(FanAccountValidation.isValidPassword("fansafety2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("乖乖影像安全2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("long-password"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("onlyletters"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("short1"))
        XCTAssertFalse(FanAccountValidation.isValidPassword(" fansafety2026"))
    }

    func testPasswordRecoveryProfileFailsClosedUntilPasswordRotation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000001",
            identityCode: "HS-ABCD-2345",
            displayName: "恢复中粉丝",
            douyinID: "recovery_fan",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600),
            requiresPasswordChange: true,
            passwordRecoveryExpiresAt: now.addingTimeInterval(900)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertTrue(FanAccountValidation.isValidProfile(profile, now: now))
        XCTAssertFalse(profile.isApproved(at: now))
        XCTAssertFalse(profile.hasPermission(.galleryFull, at: now))

        let missingExpiry = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: profile.permissions,
            status: profile.status,
            sessionExpiresAt: profile.sessionExpiresAt,
            requiresPasswordChange: true,
            passwordRecoveryExpiresAt: nil
        )
        XCTAssertFalse(missingExpiry.hasConsistentAccountSetupState)
        XCTAssertFalse(FanAccountValidation.isValidProfile(missingExpiry, now: now))
    }

    func testPasswordChangeValidationRequiresCurrentDifferentStrongPassword() throws {
        XCTAssertEqual(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue
            ),
            FanPasswordChangeInput(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.replacementValue
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.unchangedValue,
                newPassword: TestCredentialFixture.unchangedValue,
                newPasswordConfirmation: TestCredentialFixture.unchangedValue
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.weakValue,
                newPasswordConfirmation: TestCredentialFixture.weakValue
            )
        )
    }

    func testFanAccountOperationGuardRejectsStaleOrTokenChangedResponses() {
        XCTAssertTrue(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 7,
                expectedToken: "token-a",
                currentToken: "token-a"
            )
        )
        XCTAssertTrue(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 1,
                currentGeneration: 1,
                expectedToken: nil,
                currentToken: nil
            )
        )
        XCTAssertFalse(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 8,
                expectedToken: "token-a",
                currentToken: "token-a"
            )
        )
        XCTAssertFalse(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 7,
                expectedToken: "token-a",
                currentToken: "token-b"
            )
        )
    }

    func testAppleDouyinMigrationAcceptsEveryPreservedAccountStatus() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for status in FanAccountStatus.allCases {
            let profile = FanProfile(
                userID: UUID().uuidString.lowercased(),
                identityCode: "HS-ABCD-2345",
                displayName: "旧 Apple 粉丝",
                douyinID: "apple_migrated_fan",
                installationCode: "IN-ABC-234",
                permissions: FanPermission.allCases.map(\.rawValue),
                status: status.rawValue,
                sessionExpiresAt: now.addingTimeInterval(600),
                accountSource: FanAccountSource.apple.rawValue
            )

            XCTAssertTrue(
                FanAppleRegistrationCompletionPolicy.accepts(profile),
                "Apple 旧账号补全抖音 ID 时必须保留并接受 \(status.rawValue) 状态"
            )
            XCTAssertFalse(FanAppleRegistrationCompletionPolicy.notice(for: status).isEmpty)
        }

        let incomplete = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "未完成账号",
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: "IN-ABC-234",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600),
            requiresAccountSetup: true,
            invitationExpiresAt: now.addingTimeInterval(600),
            accountSource: FanAccountSource.apple.rawValue
        )
        XCTAssertFalse(FanAppleRegistrationCompletionPolicy.accepts(incomplete))
    }

    func testUncertainDeletionResultsFailClosedButExplicitClientErrorsDoNot() {
        XCTAssertTrue(FanDeletionFailurePolicy.shouldFailClosed(after: .unavailable))
        XCTAssertTrue(FanDeletionFailurePolicy.shouldFailClosed(after: .invalidResponse))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .invalidCredentials))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .rateLimited))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .server("当前密码不正确。")))
    }

    func testAppleNonceHashAndConstantTimeStateValidation() {
        XCTAssertEqual(
            AppleSignInSecurity.sha256Hex("test-nonce"),
            "ed04c4e9ea6c49cf9ceb39098787c5b9842524f96b07ef45305476a11caec9b4"
        )
        XCTAssertTrue(AppleSignInSecurity.statesMatch("same-state", "same-state"))
        XCTAssertFalse(AppleSignInSecurity.statesMatch("same-state-x", "same-state"))
        XCTAssertFalse(AppleSignInSecurity.statesMatch(nil, "same-state"))
    }

    func testAppleChallengeRejectsExpiredAndOverlongTTL() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = FanAppleChallenge(
            challengeID: String(repeating: "c", count: 24),
            nonce: String(repeating: "n", count: 43),
            state: String(repeating: "s", count: 43),
            expiresAt: now.addingTimeInterval(300)
        )
        XCTAssertTrue(valid.isValid(now: now))
        XCTAssertFalse(FanAppleChallenge(
            challengeID: valid.challengeID,
            nonce: valid.nonce,
            state: valid.state,
            expiresAt: now
        ).isValid(now: now))
        XCTAssertFalse(FanAppleChallenge(
            challengeID: valid.challengeID,
            nonce: valid.nonce,
            state: valid.state,
            expiresAt: now.addingTimeInterval(601)
        ).isValid(now: now))
    }

    func testAppleAuthRequestSendsOnlyServerChallengeProof() throws {
        let request = FanAppleAuthRequest(
            identityToken: "header.payload.signature",
            authorizationCode: "authorization-code",
            challengeID: String(repeating: "c", count: 24),
            state: String(repeating: "s", count: 43),
            installID: "00000000-0000-4000-8000-000000000001"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["identityToken", "authorizationCode", "challengeID", "state", "installID"]
        )
        XCTAssertNil(object["user"])
        XCTAssertNil(object["nonce"])
    }

    func testAppleRegistrationRequiresNameDouyinIDAndConsent() throws {
        XCTAssertEqual(
            try FanAccountValidation.validatedAppleRegistration(
                displayName: " 梳子粉丝 ",
                douyinID: " @fan_2026 ",
                acceptedDataUse: true
            ),
            FanAppleRegistrationInput(displayName: "梳子粉丝", douyinID: "fan_2026")
        )
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "梳子粉丝",
            douyinID: "fan_2026",
            acceptedDataUse: false
        ))
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "",
            douyinID: "fan_2026",
            acceptedDataUse: true
        ))
        XCTAssertThrowsError(
            try FanAccountValidation.validatedAppleRegistration(
                displayName: "梳子粉丝",
                douyinID: "  ",
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "梳子粉丝",
            douyinID: "https://v.douyin.com/example",
            acceptedDataUse: true
        ))
    }

    func testAppleOnboardingResponseDistinguishesNewApplicationAndMigration() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"expiresAt":"2026-09-04T12:20:00Z"}"#.utf8)
        let legacyState = try decoder.decode(FanAppleRegistrationState.self, from: legacy)
        XCTAssertFalse(legacyState.isDouyinMigration)
        XCTAssertEqual(legacyState.displayName, "")
        XCTAssertNil(legacyState.preservedStatus)

        let migration = Data(
            #"{"expiresAt":"2026-09-04T12:20:00Z","isDouyinMigration":true,"displayName":"旧 Apple 粉丝","preservedStatus":"suspended"}"#.utf8
        )
        let migrationState = try decoder.decode(FanAppleRegistrationState.self, from: migration)
        XCTAssertTrue(migrationState.isDouyinMigration)
        XCTAssertEqual(migrationState.displayName, "旧 Apple 粉丝")
        XCTAssertEqual(migrationState.preservedStatus, .suspended)
    }

    func testAppleCredentialRevocationPolicyFailsClosed() {
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .authorized), .authorize)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .revoked), .revoke)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .notFound), .revoke)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .transferred), .transfer)
        XCTAssertEqual(
            FanAppleCredentialStatePolicy.queryDisposition(hasError: true),
            .retryKeepingSession
        )
        XCTAssertEqual(
            FanAppleCredentialStatePolicy.queryDisposition(hasError: false),
            .evaluateCredential
        )
        XCTAssertFalse(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .checking
        ))
        XCTAssertTrue(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .retryRequired
        ))
        XCTAssertTrue(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .verified
        ))
    }

    func testAppleRegistrationDraftClearsAcrossAccountTransition() {
        var draft = FanAppleRegistrationDraft(
            displayName: "上一位用户",
            douyinID: "previous_fan",
            acceptedDataUse: true
        )

        draft.clear()

        XCTAssertEqual(draft, FanAppleRegistrationDraft())
    }

    func testAppleOnlyAccountDoesNotOfferPasswordChange() {
        XCTAssertFalse(
            FanAccountSecurityCapabilities.supportsPasswordChange(usesAppleSignIn: true)
        )
        XCTAssertTrue(
            FanAccountSecurityCapabilities.supportsPasswordChange(usesAppleSignIn: false)
        )
    }

    func testAppleOnboardingSessionCanSelfDeleteBeforeApproval() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let onboarding = FanAppleRegistrationState(expiresAt: now.addingTimeInterval(600))

        XCTAssertTrue(FanAppleDeletionEligibility.canBegin(
            hasToken: true,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now
        ))
        XCTAssertFalse(FanAppleDeletionEligibility.canBegin(
            hasToken: true,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now.addingTimeInterval(601)
        ))
        XCTAssertFalse(FanAppleDeletionEligibility.canBegin(
            hasToken: false,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now
        ))
    }

    func testFanSessionDirectoryRejectsForeignCurrentOrDuplicateSession() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = FanSessionRecord(
            sessionID: "0123456789abcdef0123456789abcdef",
            installationCode: "IN-ABC-234",
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            isCurrent: true
        )
        let other = FanSessionRecord(
            sessionID: "abcdef0123456789abcdef0123456789",
            installationCode: "IN-BCD-345",
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            isCurrent: false
        )
        XCTAssertTrue(
            FanAccountValidation.isValidSessionDirectory(
                [current, other],
                currentInstallationCode: "IN-ABC-234",
                now: now
            )
        )
        XCTAssertFalse(
            FanAccountValidation.isValidSessionDirectory(
                [current, current],
                currentInstallationCode: "IN-ABC-234",
                now: now
            )
        )
        XCTAssertFalse(
            FanAccountValidation.isValidSessionDirectory(
                [current, other],
                currentInstallationCode: "IN-XYZ-999",
                now: now
            )
        )
    }

    func testActiveInvitationAccountStillFailsClosed() {
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "待完成设置",
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: Date().addingTimeInterval(600),
            requiresAccountSetup: true,
            invitationExpiresAt: Date().addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertFalse(profile.isApproved)
        XCTAssertFalse(profile.hasPermission(.galleryFull))
        XCTAssertFalse(profile.hasPermission(.videoView))
        XCTAssertFalse(profile.hasPermission(.earlyAccess))

        let contradictoryProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: profile.permissions,
            status: profile.status,
            sessionExpiresAt: profile.sessionExpiresAt,
            requiresAccountSetup: false,
            invitationExpiresAt: nil
        )
        XCTAssertFalse(contradictoryProfile.hasConsistentAccountSetupState)
        XCTAssertFalse(contradictoryProfile.isApproved)
    }

    func testSessionExpiryFailsClosedAfterTimeAdvanceEvenWhenRefreshIsUnavailable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "已批准粉丝",
            douyinID: "approved_fan",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(60)
        )

        XCTAssertTrue(profile.isApproved(at: now))
        XCTAssertTrue(profile.hasPermission(.galleryFull, at: now))

        // A failed refresh leaves the last decoded value in memory. Access is
        // still decided from the local expiry, not from the stale active flag.
        let retainedAfterNetworkFailure = profile
        let afterExpiry = now.addingTimeInterval(61)
        XCTAssertFalse(retainedAfterNetworkFailure.isApproved(at: afterExpiry))
        XCTAssertFalse(retainedAfterNetworkFailure.hasPermission(.galleryFull, at: afterExpiry))
        XCTAssertFalse(retainedAfterNetworkFailure.hasPermission(.videoView, at: afterExpiry))
    }

    func testAdminAccessPatchEncodesOnlyTheFieldBeingChanged() throws {
        let statusData = try JSONEncoder().encode(
            AdminFanAccessUpdate(permissions: nil, status: FanAccountStatus.suspended.rawValue)
        )
        let statusObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        )
        XCTAssertEqual(Set(statusObject.keys), ["status"])
        XCTAssertEqual(statusObject["status"] as? String, FanAccountStatus.suspended.rawValue)

        let permissionData = try JSONEncoder().encode(
            AdminFanAccessUpdate(permissions: [FanPermission.galleryFull.rawValue], status: nil)
        )
        let permissionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: permissionData) as? [String: Any]
        )
        XCTAssertEqual(Set(permissionObject.keys), ["permissions"])
        XCTAssertEqual(
            permissionObject["permissions"] as? [String],
            [FanPermission.galleryFull.rawValue]
        )
    }

    func testLegacyFanModelsDecodeAsConfiguredAccounts() throws {
        let profileJSON = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000001",
              "identityCode":"HS-ABCD-2345",
              "displayName":"旧版粉丝",
              "douyinID":"legacy_fan",
              "installationCode":"IN-ABC-234",
              "permissions":["gallery_full"],
              "status":"active",
              "sessionExpiresAt":"2099-01-01T00:00:00Z"
            }
            """.utf8
        )
        let adminJSON = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000001",
              "identityCode":"HS-ABCD-2345",
              "displayName":"旧版粉丝",
              "douyinID":"legacy_fan",
              "permissions":["gallery_full"],
              "status":"active",
              "registeredAt":"2026-08-31T00:00:00Z",
              "reviewedAt":null
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let profile = try decoder.decode(FanProfile.self, from: profileJSON)
        let admin = try decoder.decode(AdminFanUser.self, from: adminJSON)

        XCTAssertFalse(profile.requiresAccountSetup)
        XCTAssertNil(profile.invitationExpiresAt)
        XCTAssertFalse(profile.requiresPasswordChange)
        XCTAssertNil(profile.passwordRecoveryExpiresAt)
        XCTAssertEqual(profile.accountSource, FanAccountSource.password.rawValue)
        XCTAssertFalse(profile.requiresAppleRegistration)
        XCTAssertTrue(profile.isApproved)
        XCTAssertFalse(admin.requiresAccountSetup)
        XCTAssertNil(admin.invitationExpiresAt)
        XCTAssertFalse(admin.requiresPasswordChange)
        XCTAssertNil(admin.passwordRecoveryExpiresAt)
        XCTAssertEqual(admin.accountSource, FanAccountSource.password.rawValue)
        XCTAssertFalse(admin.requiresAppleRegistration)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(admin))

        let invitedAdmin = AdminFanUser(
            userID: "00000000-0000-4000-8000-000000000002",
            identityCode: "HS-BCDE-3456",
            displayName: "待完成设置",
            douyinID: "invite_0123456789abcdef01234567",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            registeredAt: Date(),
            reviewedAt: nil,
            requiresAccountSetup: true,
            invitationExpiresAt: Date().addingTimeInterval(3_600)
        )
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(invitedAdmin))

        let unmarkedPlaceholder = AdminFanUser(
            userID: invitedAdmin.userID,
            identityCode: invitedAdmin.identityCode,
            displayName: invitedAdmin.displayName,
            douyinID: invitedAdmin.douyinID,
            permissions: invitedAdmin.permissions,
            status: invitedAdmin.status,
            registeredAt: invitedAdmin.registeredAt,
            reviewedAt: nil
        )
        XCTAssertFalse(FanAccountValidation.isValidAdminFanUser(unmarkedPlaceholder))
    }

    func testAdminDirectoryMarksIncompleteAndLegacyBlankDouyinProfiles() throws {
        let data = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000003",
              "identityCode":"HS-CDEF-4567",
              "displayName":"Apple 新用户",
              "douyinID":"",
              "permissions":[],
              "status":"pending",
              "registeredAt":"2026-08-31T00:00:00Z",
              "reviewedAt":null,
              "accountSource":"apple",
              "requiresAppleRegistration":true
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let user = try decoder.decode(AdminFanUser.self, from: data)

        XCTAssertTrue(user.requiresIdentityCompletion)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(user))

        let completedWithoutDouyin = AdminFanUser(
            userID: user.userID,
            identityCode: user.identityCode,
            displayName: user.displayName,
            douyinID: "",
            permissions: [],
            status: user.status,
            registeredAt: user.registeredAt,
            reviewedAt: nil,
            accountSource: FanAccountSource.apple.rawValue,
            requiresAppleRegistration: false
        )
        XCTAssertTrue(completedWithoutDouyin.requiresIdentityCompletion)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(completedWithoutDouyin))

        let wrongSource = AdminFanUser(
            userID: user.userID,
            identityCode: user.identityCode,
            displayName: user.displayName,
            douyinID: "",
            permissions: [],
            status: user.status,
            registeredAt: user.registeredAt,
            reviewedAt: nil,
            accountSource: FanAccountSource.password.rawValue,
            requiresAppleRegistration: true
        )
        XCTAssertFalse(FanAccountValidation.isValidAdminFanUser(wrongSource))
    }

    func testLegacyApprovedProfileWithoutDouyinRemainsManageableButCannotAccessContent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000005",
            identityCode: "HS-EFGH-6789",
            displayName: "未填抖音的粉丝",
            douyinID: "",
            installationCode: "IN-ABC-234",
            permissions: [FanPermission.galleryFull.rawValue],
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertTrue(FanAccountValidation.isValidProfile(profile, now: now))
        XCTAssertFalse(profile.hasRequiredDouyinID)
        XCTAssertFalse(profile.isApproved(at: now))
        XCTAssertFalse(profile.hasPermission(.galleryFull, at: now))
    }

    func testNormalProfileRejectsIncompleteAppleRegistrationMarker() {
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000004",
            identityCode: "HS-DEFG-5678",
            displayName: "Apple 粉丝",
            douyinID: "apple_fan",
            installationCode: "IN-ABC-234",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: Date().addingTimeInterval(3_600),
            accountSource: FanAccountSource.apple.rawValue,
            requiresAppleRegistration: true
        )

        XCTAssertFalse(FanAccountValidation.isValidProfile(profile))
    }

    func testInvitationResponseValidationRejectsMalformedOrReplayedBatchShapes() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(
            """
            {
              "invitations":[{
                "userID":"00000000-0000-4000-8000-000000000001",
                "identityCode":"HS-ABCD-2345",
                "temporaryPassword":"\(TestCredentialFixture.temporaryValue)",
                "expiresAt":"2099-01-01T00:00:00Z",
                "requiresAccountSetup":true
              }]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AdminFanInvitationResponse.self, from: data)
        let invitation = try XCTUnwrap(response.invitations.first)

        XCTAssertTrue(
            AdminFanInvitationValidation.isValid(
                response,
                requestedCount: 1,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                response,
                requestedCount: 2,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                AdminFanInvitationResponse(
                    invitations: [invitation, invitation]
                ),
                requestedCount: 2,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                AdminFanInvitationResponse(
                    invitations: [
                        AdminFanInvitation(
                            userID: invitation.userID,
                            identityCode: invitation.identityCode,
                            temporaryPassword: invitation.temporaryPassword,
                            expiresAt: now,
                            requiresAccountSetup: true
                        ),
                    ]
                ),
                requestedCount: 1,
                now: now
            )
        )
    }

    func testAdminPasswordRecoveryCredentialIsShortLivedAndOneTimeShaped() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recovery = AdminFanPasswordRecovery(
            userID: "00000000-0000-4000-8000-000000000001",
            identityCode: "HS-ABCD-2345",
            temporaryPassword: TestCredentialFixture.temporaryValue,
            expiresAt: now.addingTimeInterval(900),
            requiresPasswordChange: true
        )
        XCTAssertTrue(
            AdminFanPasswordRecoveryValidation.isValid(
                recovery,
                expectedUserID: recovery.userID,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanPasswordRecoveryValidation.isValid(
                recovery,
                expectedUserID: "00000000-0000-4000-8000-000000000002",
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanPasswordRecoveryValidation.isValid(
                AdminFanPasswordRecovery(
                    userID: recovery.userID,
                    identityCode: recovery.identityCode,
                    temporaryPassword: recovery.temporaryPassword,
                    expiresAt: now.addingTimeInterval(3_600),
                    requiresPasswordChange: true
                ),
                expectedUserID: recovery.userID,
                now: now
            )
        )
    }

    func testRequiredSetupValidationRequiresDouyinAndPasswordRotation() throws {
        let temporaryPassword = TestCredentialFixture.temporaryValue
        let valid = try FanAccountValidation.validatedRequiredSetup(
            displayName: "  测试粉丝  ",
            douyinID: " @Real_Fan ",
            currentPassword: temporaryPassword,
            newPassword: TestCredentialFixture.replacementValue,
            newPasswordConfirmation: TestCredentialFixture.replacementValue,
            acceptedDataUse: true
        )
        XCTAssertEqual(valid.displayName, "测试粉丝")
        XCTAssertEqual(valid.douyinID, "real_fan")

        XCTAssertThrowsError(try FanAccountValidation.validatedRequiredSetup(
            displayName: "测试粉丝",
            douyinID: "   ",
            currentPassword: temporaryPassword,
            newPassword: TestCredentialFixture.replacementValue,
            newPasswordConfirmation: TestCredentialFixture.replacementValue,
            acceptedDataUse: true
        ))

        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "invite_0123456789abcdef01234567",
                currentPassword: temporaryPassword,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue,
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "real_fan",
                currentPassword: temporaryPassword,
                newPassword: temporaryPassword,
                newPasswordConfirmation: temporaryPassword,
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "real_fan",
                currentPassword: temporaryPassword,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue,
                acceptedDataUse: false
            )
        )
    }

    func testFanPermissionsAreExplicitAndUnknownValuesStayInactive() {
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "测试粉丝",
            douyinID: "test_fan",
            installationCode: "IN-ABC-234",
            permissions: [FanPermission.galleryFull.rawValue, "future_permission"],
            status: "active",
            sessionExpiresAt: Date().addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasPermission(.galleryFull))
        XCTAssertFalse(profile.hasPermission(.videoView))
        XCTAssertFalse(profile.hasPermission(.earlyAccess))

        let suspendedProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: FanPermission.allCases.map(\.rawValue),
            status: "suspended",
            sessionExpiresAt: profile.sessionExpiresAt
        )
        XCTAssertFalse(suspendedProfile.hasPermission(.galleryFull))
        XCTAssertFalse(suspendedProfile.hasPermission(.videoView))
        XCTAssertFalse(suspendedProfile.hasPermission(.earlyAccess))

        let pendingProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: profile.sessionExpiresAt
        )
        XCTAssertFalse(pendingProfile.isApproved)
        XCTAssertFalse(pendingProfile.hasPermission(.galleryFull))
        XCTAssertTrue(profile.isApproved)
    }

    func testOnlyJSONResponseTypesAreAccepted() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isJSONMIMEType("application/json; charset=UTF-8"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isJSONMIMEType("application/problem+json"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isJSONMIMEType("text/html"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isJSONMIMEType(nil))
    }

    func testImageResponsesRequireSafeMIMEAndBoundedLength() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("image/jpeg; charset=binary"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("IMAGE/WEBP"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("image/heic"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType("image/svg+xml"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType("text/html"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType(nil))

        let limit: Int64 = 20 * 1024 * 1024
        XCTAssertTrue(AppNetworkSecurityPolicy.permitsResponseLength(limit, maximumBytes: limit))
        XCTAssertTrue(
            AppNetworkSecurityPolicy.permitsResponseLength(
                NSURLSessionTransferSizeUnknown,
                maximumBytes: limit
            )
        )
        XCTAssertFalse(AppNetworkSecurityPolicy.permitsResponseLength(0, maximumBytes: limit))
        XCTAssertFalse(AppNetworkSecurityPolicy.permitsResponseLength(limit + 1, maximumBytes: limit))
    }

    func testMediaResponseCannotChangeURLOrAddFragment() {
        let requested = URL(string: "https://img.shuzijun.com.cn/images/portrait.webp?v=2")!

        XCTAssertTrue(
            ContentSecurityPolicy.matchesRequestedMediaURL(requested, requestedURL: requested)
        )
        XCTAssertFalse(
            ContentSecurityPolicy.matchesRequestedMediaURL(
                URL(string: "https://www.shuzijun.com.cn/images/portrait.webp?v=2"),
                requestedURL: requested
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.matchesRequestedMediaURL(
                URL(string: "https://img.shuzijun.com.cn/images/portrait.webp?v=3"),
                requestedURL: requested
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "https://img.shuzijun.com.cn/images/portrait.webp#hidden")!
            )
        )
    }

    func testDiagnosticsReduceErrorsToNonSensitiveNumericCategories() {
        let sensitiveURL = URL(string: "https://user:password@example.com/private.jpg")!
        let networkError = URLError(
            .timedOut,
            userInfo: [NSURLErrorFailingURLErrorKey: sensitiveURL]
        )
        let applicationError = NSError(
            domain: "private.account.name",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret content"]
        )

        XCTAssertEqual(
            DiagnosticsSanitizer.networkErrorCode(networkError),
            URLError.Code.timedOut.rawValue
        )
        XCTAssertEqual(DiagnosticsSanitizer.networkErrorCode(applicationError), 0)
    }

    func testArtworkImageRetryPolicyOnlyRetriesTransientFailures() {
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(URLError(.secureConnectionFailed)))
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.httpStatus(503)))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.httpStatus(404)))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.invalidResponse))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.decodeFailed))
    }

    func testAPNsDeviceTokenEncodingIsCanonicalAndStrict() {
        let bytes = Data((0..<32).map(UInt8.init))
        let encoded = PushDeviceTokenPolicy.encodedToken(from: bytes)

        XCTAssertEqual(encoded, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        XCTAssertTrue(PushDeviceTokenPolicy.isValid(encoded ?? ""))
        XCTAssertNotNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 1)))
        XCTAssertNotNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 256)))
        XCTAssertNil(PushDeviceTokenPolicy.encodedToken(from: Data()))
        XCTAssertNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 257)))
        XCTAssertFalse(PushDeviceTokenPolicy.isValid(String(repeating: "A", count: 64)))
        XCTAssertFalse(PushDeviceTokenPolicy.isValid(String(repeating: "a", count: 33)))
    }

    func testPushRegistrationRequiresCompletedDouyinProfileAndLiveSession() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pendingProfile = FanProfile(
            userID: "11111111-2222-4333-8444-555555555555",
            identityCode: "HS-ABCD-2345",
            displayName: "测试用户",
            douyinID: "douyin-user",
            installationCode: "HSI-1234-5678-ABCD",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600)
        )

        XCTAssertEqual(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: true,
                now: now
            ),
            pendingProfile.userID
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: false,
                now: now
            )
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: true,
                credentialAccessAllowed: false,
                now: now
            ),
            "Apple 凭据尚未验证时不得继续绑定推送"
        )

        let incompleteProfile = FanProfile(
            userID: pendingProfile.userID,
            identityCode: pendingProfile.identityCode,
            displayName: pendingProfile.displayName,
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: pendingProfile.installationCode,
            permissions: [],
            status: pendingProfile.status,
            sessionExpiresAt: pendingProfile.sessionExpiresAt,
            requiresAccountSetup: true,
            invitationExpiresAt: now.addingTimeInterval(300),
            accountSource: FanAccountSource.invitation.rawValue
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: incompleteProfile,
                hasSessionToken: true,
                now: now
            )
        )

        for status in [FanAccountStatus.rejected, .suspended] {
            let blockedProfile = FanProfile(
                userID: pendingProfile.userID,
                identityCode: pendingProfile.identityCode,
                displayName: pendingProfile.displayName,
                douyinID: pendingProfile.douyinID,
                installationCode: pendingProfile.installationCode,
                permissions: [],
                status: status.rawValue,
                sessionExpiresAt: pendingProfile.sessionExpiresAt
            )
            XCTAssertNil(
                PushSessionEligibility.userID(
                    profile: blockedProfile,
                    hasSessionToken: true,
                    now: now
                )
            )
        }
    }

    func testPushSynchronizationRebindsAfterSameUserSessionRotation() {
        let before = PushSynchronizationTaskID(
            userID: "11111111-2222-4333-8444-555555555555",
            fanSessionGeneration: 7,
            deviceRegistrationGeneration: 3
        )
        let afterPasswordChange = PushSynchronizationTaskID(
            userID: before.userID,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3
        )

        XCTAssertNotEqual(before, afterPasswordChange)
        XCTAssertEqual(before, before)

        let appleCredentialChecking = PushSynchronizationTaskID(
            userID: nil,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3,
            canUnbindPushDevice: true,
            appleCredentialAccessState: .checking
        )
        let appleCredentialVerified = PushSynchronizationTaskID(
            userID: before.userID,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3,
            canUnbindPushDevice: true,
            appleCredentialAccessState: .verified
        )
        XCTAssertNotEqual(appleCredentialChecking, appleCredentialVerified)
    }

    func testPushBindingGenerationIsStrictlyMonotonicAndBounded() {
        XCTAssertEqual(PushBindingGenerationPolicy.next(after: 0), 1)
        XCTAssertEqual(
            PushBindingGenerationPolicy.next(after: PushBindingGenerationPolicy.maximum - 1),
            PushBindingGenerationPolicy.maximum
        )
        XCTAssertNil(
            PushBindingGenerationPolicy.next(after: PushBindingGenerationPolicy.maximum)
        )

        let state = FanInstallationState(
            installID: UUID(),
            bindingGeneration: PushBindingGenerationPolicy.maximum
        )
        let encoded = try? JSONEncoder().encode(state)
        let decoded = encoded.flatMap {
            try? JSONDecoder().decode(FanInstallationState.self, from: $0)
        }
        XCTAssertEqual(decoded, state)
    }

    func testPushBindingRefreshesAtFixedTwentyFourHourAge() {
        let boundAt = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(
            PushBindingRefreshPolicy.needsRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(24 * 60 * 60 - 1)
            )
        )
        XCTAssertTrue(
            PushBindingRefreshPolicy.needsRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(24 * 60 * 60)
            )
        )
        XCTAssertEqual(
            PushBindingRefreshPolicy.delayUntilRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(23 * 60 * 60)
            ),
            60 * 60
        )
    }

    func testPushAccountTransitionsResetDeviceRegistration() {
        let first = "11111111-2222-4333-8444-555555555555"
        let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

        XCTAssertTrue(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: nil
            )
        )
        XCTAssertTrue(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: second
            )
        )
        XCTAssertFalse(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: first
            )
        )
    }

    func testPushNotificationsStayOffUntilTheUserExplicitlyOptsIn() {
        let suiteName = "PushNotificationPreferenceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferenceKey = "push-opt-in"
        let associationKey = "push-opt-in-user"
        let firstUserID = "11111111-2222-4333-8444-555555555555"
        let secondUserID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            ),
            "首次安装不能在用户操作前隐式开启通知"
        )
        PushNotificationPreferencePolicy.setEnabled(
            true,
            for: firstUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertTrue(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            )
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            ),
            "B 账号不能继承 A 账号主动开启的通知偏好"
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: nil
            ),
            "退出登录后必须立即关闭本地通知绑定状态"
        )
        PushNotificationPreferencePolicy.setEnabled(
            true,
            for: secondUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            ),
            "一台安装只恢复最近一次明确开启通知的账号"
        )
        XCTAssertTrue(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            )
        )
        PushNotificationPreferencePolicy.setEnabled(
            false,
            for: secondUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            )
        )
    }

    @MainActor
    func testStartupPushPermissionRequestsOnceAndKeepsDeliveryOffBeforeLogin() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.requestStartupAuthorizationIfNeeded()

        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertFalse(coordinator.notificationsEnabled, "系统授权不能在未登录时开启账号推送")
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
        let generationBeforeToken = coordinator.registrationGeneration
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        XCTAssertEqual(coordinator.registrationGeneration, generationBeforeToken,
                       "未登录时必须忽略设备令牌，不能触发绑定")
    }

    @MainActor
    func testStartupPushPermissionDoesNotRepeatAfterDenialOrEnableAnAccount() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.denied])
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.requestStartupAuthorizationIfNeeded()
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )

        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .denied)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
    }

    @MainActor
    func testExistingSystemPushPermissionDoesNotImplyNewAccountConsent() async throws {
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            let defaults = try makePushStartupDefaults()
            let client = TestPushAuthorizationClient(status: status)
            let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)

            await coordinator.requestStartupAuthorizationIfNeeded()
            PushStartupConsentPolicy.consume(
                for: "new-account", in: defaults,
                preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
            )

            XCTAssertEqual(client.requestCount, 0)
            XCTAssertEqual(coordinator.authorizationStatus, status)
            XCTAssertFalse(coordinator.notificationsEnabled)
            XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"),
                         "设备已有系统权限不能被当成新账号主动同意接收推送")
        }
    }

    @MainActor
    func testStartupPushConsentSurvivesRelaunchAndIsConsumedByOnlyOneAccount() async throws {
        let defaults = try makePushStartupDefaults()
        let firstClient = TestPushAuthorizationClient(outcomes: [.granted])
        let firstCoordinator = PushNotificationCoordinator(authorizationClient: firstClient, defaults: defaults)
        await firstCoordinator.requestStartupAuthorizationIfNeeded()

        let relaunchClient = TestPushAuthorizationClient(status: .authorized)
        let relaunchedCoordinator = PushNotificationCoordinator(authorizationClient: relaunchClient, defaults: defaults)
        await relaunchedCoordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(relaunchClient.requestCount, 0)
        XCTAssertFalse(relaunchedCoordinator.notificationsEnabled)

        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
        PushStartupConsentPolicy.consume(
            for: "second-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertFalse(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "second-account"
        ), "B 账号不能继承 A 账号已经使用的启动授权")
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
    }

    @MainActor
    func testStartupPushPermissionPreservesBuild45LegacyOptOut() async throws {
        let defaults = try makePushStartupDefaults()
        defaults.set(false, forKey: "push-notifications-enabled")
        let client = TestPushAuthorizationClient()
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)

        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "legacy-account"
        ))
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "legacy-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertFalse(defaults.bool(forKey: "push-notifications-enabled"))
        XCTAssertNil(defaults.string(forKey: "push-notifications-enabled-user"))
    }

    func testStartupPushConsentRespectsAccountOptOutAndCannotLeakToNextAccount() throws {
        let defaults = try makePushStartupDefaults()
        PushNotificationPreferencePolicy.setEnabled(
            false, for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        PushStartupConsentPolicy.consume(
            for: "second-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )

        for userID in ["first-account", "second-account"] {
            XCTAssertFalse(PushNotificationPreferencePolicy.isEnabled(
                in: defaults, preferenceKey: "push-notifications-enabled",
                associationKey: "push-notifications-enabled-user", userID: userID
            ))
        }
        XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
        XCTAssertFalse(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "second-account"
        ))
    }

    func testClearingStartupPushConsentPreventsLaterImplicitOptIn() throws {
        let defaults = try makePushStartupDefaults()
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.clear(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
    }

    @MainActor
    func testInterruptedStartupPushPermissionCanRetryWithoutPrematureOptIn() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.interrupted, .granted])
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)

        await coordinator.requestStartupAuthorizationIfNeeded()
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .notDetermined)
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))

        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertFalse(coordinator.notificationsEnabled)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
    }

    @MainActor
    func testConcurrentStartupPushPermissionAttemptsShareOneSystemRequest() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let requestStarted = expectation(description: "第一条系统授权请求已经挂起")
        client.pauseRequest = true
        client.requestStarted = { requestStarted.fulfill() }
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)
        let firstRequest = Task { await coordinator.requestStartupAuthorizationIfNeeded() }

        await fulfillment(of: [requestStarted], timeout: 2)
        guard client.requestCount == 1 else {
            firstRequest.cancel()
            client.resumeRequest()
            return XCTFail("第一条授权请求应进入受控等待")
        }
        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 1, "多次前台生命周期事件只能产生一个系统授权弹窗")
        XCTAssertFalse(coordinator.notificationsEnabled)
        client.resumeRequest()
        await firstRequest.value

        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertEqual(client.requestCount, 1)
    }

    @MainActor
    func testPushCoordinatorBindsStartupConsentOnlyAfterEligibleLoginAndDeviceToken() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)
        let account = TestPushNotificationAccount()
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertTrue(account.bindingAttempts.isEmpty, "未登录不得向服务器绑定设备")

        account.pushEligibleUserID = "first-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        XCTAssertTrue(account.bindingAttempts.isEmpty, "系统授权不等于已获得 APNs 设备令牌")

        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts, [
            TestPushNotificationAccount.BindingAttempt(
                userID: "first-account", generation: 2, deviceToken: "1234"
            ),
        ])
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)

        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 1, "正常的前台同步不能重复提交有效绑定")
        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled, "切换账号不得继承已经消费的启动授权")
        XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 1, "未主动开启的新账号不得绑定迟到的设备令牌")
    }

    @MainActor
    func testDelayedIneligiblePushUnbindCannotEraseNewAccountReadyState() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)

        let unbindStarted = expectation(description: "旧的不合格会话解除绑定正在等待网络响应")
        account.pushEligibleUserID = nil
        account.pushSessionGeneration += 1
        account.pauseNextUnbind = true
        account.unbindStarted = { unbindStarted.fulfill() }
        let oldSynchronization = Task { await coordinator.synchronize(with: account) }
        await fulfillment(of: [unbindStarted], timeout: 2)
        defer {
            oldSynchronization.cancel()
            account.resumeUnbind()
        }
        XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)

        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.last?.userID, "second-account")

        account.resumeUnbind()
        await oldSynchronization.value
        XCTAssertTrue(coordinator.notificationsEnabled, "旧解除绑定响应不能关闭新账号通知")
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready,
                      "旧解除绑定响应不能清除新账号已经完成的设备连接")
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 2,
                       "旧响应不能清掉新绑定缓存并造成重复绑定")
    }

    @MainActor
    func testPushCoordinatorCanRetryBothAPNsRegistrationAndServerBindingFailures() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.registrationFailed()
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        account.bindingFailuresRemaining = 1
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed,
                      "服务器绑定失败不能显示设备已经连接")
        XCTAssertEqual(account.bindingAttempts.count, 1)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts[0], account.bindingAttempts[1],
                       "手动重试应使用同一账号与设备令牌")
    }

    @MainActor
    func testExpiredPushBindingSessionRequiresSignInWithoutLoggingOutOrShowingNetworkFailure() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(20)
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        account.bindingRequiresSignIn = true
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .requiresSignIn,
                      "旧登录会话缺少推送绑定资料时必须提示重新登录")
        XCTAssertTrue(coordinator.notificationsEnabled, "需要重新登录不等于用户关闭了通知")
        XCTAssertTrue(account.hasPushEligibleSession, "推送绑定失败不得强制退出仍可浏览的账号")
        XCTAssertEqual(account.bindingAttempts.count, 1)
        XCTAssertEqual(account.unbindCount, 0)

        let noNetworkFailure = expectation(description: "重新登录提示不能被旧连接超时覆盖")
        noNetworkFailure.isInverted = true
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .sink { _ in noNetworkFailure.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [noNetworkFailure], timeout: 0.08)
        XCTAssertTrue(coordinator.deviceRegistrationState == .requiresSignIn)

        account.bindingRequiresSignIn = false
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready,
                      "用户重新登录取得完整会话后应可以完成通知绑定")
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts.last?.generation, 2)
    }

    @MainActor
    func testPushRegistrationWithoutCallbackTimesOutAndCanBeRetried() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(20)
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let timedOut = expectation(description: "没有 APNs 回调时连接状态应结束等待")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .prefix(1)
            .sink { _ in timedOut.fulfill() }
        defer { observation.cancel() }

        await coordinator.setNotificationsEnabled(true, for: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting,
                      "超时后手动重试必须重新进入连接状态")
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.count, 1)
    }

    @MainActor
    func testPushRegistrationTimeoutSurvivesSameAccountSessionRotation() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(100)
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let timedOut = expectation(description: "同账号会话更新后仍应有有效的连接超时检测")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .prefix(1)
            .sink { _ in timedOut.fulfill() }
        defer { observation.cancel() }

        await coordinator.setNotificationsEnabled(true, for: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed,
                      "旧会话的超时任务不得阻止新会话离开无限等待状态")

        await coordinator.synchronize(with: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.last?.generation, 2)
    }

    @MainActor
    func testExplicitPushOptOutDuringStartupRequestCannotBeOverwrittenByItsReply() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults)
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let requestStarted = expectation(description: "系统授权等待期间可以记录账号关闭偏好")
        client.pauseRequest = true
        client.requestStarted = { requestStarted.fulfill() }
        let startupRequest = Task { await coordinator.requestStartupAuthorizationIfNeeded() }
        await fulfillment(of: [requestStarted], timeout: 2)
        defer {
            startupRequest.cancel()
            client.resumeRequest()
        }

        await coordinator.setNotificationsEnabled(false, for: account)
        client.resumeRequest()
        await startupRequest.value
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled,
                       "被明确关闭作废的迟到授权也不能再用于另一个账号")
        XCTAssertTrue(account.bindingAttempts.isEmpty)
    }

    func testAdminFanDirectoryQueryNormalizesRemoteSearchAndBoundsPagination() throws {
        let query = try AdminFanDirectoryQuery(
            search: "  易姝 HS-ABCD-1234  ",
            page: 101,
            perPage: 50
        )

        XCTAssertEqual(query.search, "易姝 HS-ABCD-1234")
        XCTAssertEqual(query.page, 101)
        XCTAssertEqual(query.perPage, 50)
        XCTAssertTrue(AdminQueryItemPolicy.areValid(query.queryItems))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: query.queryItems.compactMap { item in
                item.value.map { (item.name, $0) }
            })["search"],
            "易姝 HS-ABCD-1234"
        )

        XCTAssertNil(try AdminFanDirectoryQuery(search: "   ").search)
        XCTAssertThrowsError(
            try AdminFanDirectoryQuery(
                search: String(repeating: "字", count: 81)
            )
        )
        XCTAssertThrowsError(try AdminFanDirectoryQuery(search: "用户\n身份码"))
        XCTAssertThrowsError(try AdminFanDirectoryQuery(page: 10_001))
        XCTAssertThrowsError(try AdminFanDirectoryQuery(perPage: 101))
        XCTAssertFalse(
            AdminQueryItemPolicy.areValid([
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "page", value: "2"),
            ])
        )
    }

    func testAdminFanDirectoryPaginationAppendsWithoutDuplicateUsers() {
        let firstUser = AdminFanUser(
            userID: "11111111-2222-4333-8444-555555555555",
            identityCode: "HS-ABCD-2345",
            displayName: "第一页用户",
            douyinID: "douyin-first",
            permissions: [],
            status: FanAccountStatus.active.rawValue,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000),
            reviewedAt: nil
        )
        let secondUser = AdminFanUser(
            userID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            identityCode: "HS-BCDE-3456",
            displayName: "第 101 名用户",
            douyinID: "douyin-101",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_100),
            reviewedAt: nil
        )
        let catalog = [
            AdminFanPermissionDefinition(
                code: "gallery_full",
                title: "全部相册",
                description: "允许查看全部作品"
            ),
        ]
        let firstPage = AdminFanDirectory(
            users: [firstUser],
            permissionCatalog: catalog,
            page: 1,
            perPage: 100,
            hasMore: true
        )
        let secondPage = AdminFanDirectory(
            users: [firstUser, secondUser],
            permissionCatalog: catalog,
            page: 2,
            perPage: 100,
            hasMore: false
        )

        XCTAssertTrue(
            AdminFanDirectoryValidation.isValid(
                secondPage,
                requestedPage: 2,
                requestedPerPage: 100
            )
        )
        let merged = AdminFanDirectoryValidation.appending(secondPage, to: firstPage)
        XCTAssertEqual(merged?.users.map(\.userID), [firstUser.userID, secondUser.userID])
        XCTAssertEqual(merged?.page, 2)
        XCTAssertEqual(merged?.hasMore, false)

        let stalePage = AdminFanDirectory(
            users: [secondUser],
            permissionCatalog: catalog,
            page: 3,
            perPage: 100,
            hasMore: false
        )
        XCTAssertNil(AdminFanDirectoryValidation.appending(stalePage, to: firstPage))
    }

    func testAdminFanDirectoryDecodesLegacyResponseAsSinglePage() throws {
        let directory = try JSONDecoder().decode(
            AdminFanDirectory.self,
            from: Data(#"{"users":[],"permissionCatalog":[]}"#.utf8)
        )

        XCTAssertEqual(directory.page, 1)
        XCTAssertEqual(directory.perPage, 100)
        XCTAssertFalse(directory.hasMore)
    }

    func testAdminPushContentIsBoundedNormalizedAndPrivateByDefault() {
        let content = AdminPushNotificationValidation.normalized(
            title: "不应离开设备的标题",
            body: "不应离开设备的敏感内容",
            sensitive: true
        )

        XCTAssertEqual(content?.title, AdminPushNotificationValidation.privateTitle)
        XCTAssertEqual(content?.body, AdminPushNotificationValidation.privateBody)
        XCTAssertEqual(content?.sensitive, true)
        XCTAssertNotNil(
            AdminPushNotificationValidation.normalized(
                title: String(repeating: "标", count: 60),
                body: String(repeating: "文", count: 240),
                sensitive: false
            )
        )
        XCTAssertNil(
            AdminPushNotificationValidation.normalized(
                title: String(repeating: "标", count: 61),
                body: "正文",
                sensitive: false
            )
        )
        XCTAssertNil(
            AdminPushNotificationValidation.normalized(
                title: "标题",
                body: "不可见\u{0000}内容",
                sensitive: false
            )
        )
    }

    func testCustomTargetedPushRequiresExplicitSecondConfirmation() throws {
        let privateContent = try XCTUnwrap(
            AdminPushNotificationValidation.normalized(
                title: "不会发送",
                body: "不会发送",
                sensitive: true
            )
        )
        let customContent = try XCTUnwrap(
            AdminPushNotificationValidation.normalized(
                title: "作品更新",
                body: "今晚八点发布新作品。",
                sensitive: false
            )
        )

        XCTAssertFalse(
            AdminPushConfirmationPolicy.requiresSecondConfirmation(for: privateContent)
        )
        XCTAssertTrue(
            AdminPushConfirmationPolicy.requiresSecondConfirmation(for: customContent)
        )
        XCTAssertEqual(
            AdminPushConfirmationPolicy.summary(
                recipient: "测试用户",
                content: customContent
            ),
            "收件人：测试用户\n标题：作品更新\n正文：今晚八点发布新作品。"
        )
    }

    func testTargetedPushRecipientMustRemainPendingOrActive() {
        XCTAssertTrue(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.pending.rawValue,
                requiresIdentityCompletion: false
            )
        )
        XCTAssertTrue(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.active.rawValue,
                requiresIdentityCompletion: false
            )
        )
        for status in [FanAccountStatus.rejected, .suspended] {
            XCTAssertFalse(
                AdminTargetedPushRecipientPolicy.isEligible(
                    status: status.rawValue,
                    requiresIdentityCompletion: false
                )
            )
        }
        XCTAssertFalse(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.pending.rawValue,
                requiresIdentityCompletion: true
            )
        )
        XCTAssertFalse(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: "unknown",
                requiresIdentityCompletion: false
            )
        )
    }

    func testAdminPushResponseMustMatchQueuedSingleRecipientContract() {
        let response = AdminPushNotificationResponse(
            notificationID: "11111111-2222-4333-8444-555555555555",
            status: "queued",
            recipientCount: 1,
            deviceCount: 16
        )
        XCTAssertTrue(
            AdminPushNotificationValidation.isValidResponse(
                response,
                expectedRecipientCount: 1
            )
        )
        XCTAssertFalse(
            AdminPushNotificationValidation.isValidResponse(
                AdminPushNotificationResponse(
                    notificationID: response.notificationID,
                    status: "sent",
                    recipientCount: 1,
                    deviceCount: 1
                ),
                expectedRecipientCount: 1
            )
        )
        XCTAssertFalse(
            AdminPushNotificationValidation.isValidResponse(
                AdminPushNotificationResponse(
                    notificationID: response.notificationID.uppercased(),
                    status: "queued",
                    recipientCount: 1,
                    deviceCount: 1_601
                ),
                expectedRecipientCount: 1
            )
        )
    }

    func testPushCapabilityDenialDoesNotLockAdministratorSession() {
        XCTAssertFalse(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 403,
                serverErrorCode: "push_capability_required"
            )
        )
        XCTAssertTrue(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 403,
                serverErrorCode: "rest_forbidden"
            )
        )
        XCTAssertTrue(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 401,
                serverErrorCode: nil
            )
        )
    }

    func testPurgedImageReloadsWhenTheAppBecomesActive() {
        let url = URL(string: "https://img.shuzijun.com.cn/images/test.jpg")

        XCTAssertTrue(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: url, hasImage: false),
            "后台安全清理取消下载后，回到前台必须重新请求空白图片"
        )
        XCTAssertFalse(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: url, hasImage: true)
        )
        XCTAssertFalse(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: nil, hasImage: false)
        )
    }

    func testArtworkImageDiagnosticsUseStableNonSensitiveCategories() {
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: URLError(.timedOut)),
            10_000 + abs(URLError.Code.timedOut.rawValue)
        )
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: ArtworkImageLoadError.httpStatus(503)),
            20_503
        )
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: ArtworkImageLoadError.decodeFailed),
            30_002
        )
    }

    func testUploadFilenameMustMatchItsMIMEType() throws {
        XCTAssertTrue(AdminUploadPolicy.isAllowed(filename: "portrait.JPG", mimeType: "image/jpeg"))
        XCTAssertTrue(AdminUploadPolicy.isAllowed(filename: "showreel.mov", mimeType: "video/quicktime"))
        XCTAssertFalse(AdminUploadPolicy.isAllowed(filename: "portrait.php", mimeType: "image/jpeg"))
        XCTAssertFalse(AdminUploadPolicy.isAllowed(filename: "portrait.jpg", mimeType: "video/mp4"))

        let sanitized = try AdminUploadPolicy.sanitizedFilename(
            "../portrait\r\nInjected.php.jpg",
            mimeType: "image/jpeg"
        )
        XCTAssertEqual(sanitized, "portrait__Injected_php.jpg")
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertFalse(sanitized.contains("\n"))
    }

    func testCollaborationSubmissionNormalizesFieldsAndUsesStableIdempotencyID() throws {
        let submissionID = UUID(uuidString: "7d8cb55b-7358-4d25-8e4c-af657a122d44")!
        let date = Date(timeIntervalSince1970: 1_788_192_000)
        let draft = try CollaborationSubmissionDraft(
            submissionID: submissionID,
            contactName: "  林女士  ",
            contactMethod: "  13800000000  ",
            organization: "  梧桐影业  ",
            projectType: "drama",
            city: "  杭州  ",
            preferredDate: date,
            budget: "  5 万元  ",
            details: "  短剧女主角\r\n拍摄 7 天  "
        )

        XCTAssertEqual(draft.submissionID, submissionID.uuidString.lowercased())
        XCTAssertEqual(draft.contactName, "林女士")
        XCTAssertEqual(draft.contactMethod, "13800000000")
        XCTAssertEqual(draft.organization, "梧桐影业")
        XCTAssertEqual(draft.city, "杭州")
        XCTAssertEqual(draft.budget, "5 万元")
        XCTAssertEqual(draft.details, "短剧女主角\n拍摄 7 天")

        let payload = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(draft)
        ) as? [String: Any]
        XCTAssertEqual(payload?["submissionID"] as? String, draft.submissionID)
        XCTAssertEqual(payload?["projectType"] as? String, "drama")
        XCTAssertNotNil(payload?["preferredDate"] as? String)
    }

    func testCollaborationSubmissionRejectsMissingOrMultilineRequiredFields() {
        let submissionID = UUID(uuidString: "e4af5d2e-b6b2-42fa-a2ee-3b8777379d27")!
        XCTAssertThrowsError(
            try CollaborationSubmissionDraft(
                submissionID: submissionID,
                contactName: "   ",
                contactMethod: "13800000000",
                organization: "",
                projectType: "drama",
                city: "",
                preferredDate: .now,
                budget: "",
                details: ""
            )
        )
        XCTAssertThrowsError(
            try CollaborationSubmissionDraft(
                submissionID: submissionID,
                contactName: "林女士\n伪造字段",
                contactMethod: "13800000000",
                organization: "",
                projectType: "drama",
                city: "",
                preferredDate: .now,
                budget: "",
                details: ""
            )
        )
    }

    func testCollaborationReceiptRequiresCanonicalV4Identifier() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let valid = Data(
            #"{"requestID":"7d8cb55b-7358-4d25-8e4c-af657a122d44","status":"received","receivedAt":"2026-09-04T12:00:00Z","duplicate":false}"#.utf8
        )
        let receipt = try decoder.decode(CollaborationSubmissionReceipt.self, from: valid)
        XCTAssertEqual(receipt.status, .received)
        XCTAssertFalse(receipt.duplicate)

        let invalidVersion = Data(
            #"{"requestID":"7d8cb55b-7358-1d25-8e4c-af657a122d44","status":"received","receivedAt":"2026-09-04T12:00:00Z","duplicate":false}"#.utf8
        )
        XCTAssertThrowsError(
            try decoder.decode(CollaborationSubmissionReceipt.self, from: invalidVersion)
        )
    }

    func testCollaborationRetryAcceptsReceiptAfterAdminAdvancedStatus() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let advanced = Data(
            #"{"requestID":"7d8cb55b-7358-4d25-8e4c-af657a122d44","status":"reviewing","receivedAt":"2026-09-04T12:00:00Z","duplicate":true}"#.utf8
        )
        let receipt = try decoder.decode(CollaborationSubmissionReceipt.self, from: advanced)
        XCTAssertTrue(receipt.duplicate)
        XCTAssertEqual(receipt.status, .reviewing)
        XCTAssertTrue(
            CollaborationReceiptValidation.isAccepted(
                receipt,
                now: Date(timeIntervalSince1970: 1_788_544_100)
            )
        )
    }

    func testCollaborationCapabilitiesRequireExactPair() {
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true
            ).isConsistent
        )
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: false,
                collaborationInboxEnabled: false
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: false
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: false,
                collaborationInboxEnabled: true
            ).isConsistent
        )
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true,
                pushNotificationsEnabled: true,
                canSendPushNotifications: true
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true,
                pushNotificationsEnabled: false,
                canSendPushNotifications: true
            ).isConsistent
        )
    }

    func testLegacyCapabilitiesDecodeWithPushDisabled() throws {
        let legacy = Data(
            #"{"collaborationSubmissionEnabled":true,"collaborationInboxEnabled":true}"#.utf8
        )
        let capabilities = try JSONDecoder().decode(
            AppFeatureCapabilities.self,
            from: legacy
        )

        XCTAssertFalse(capabilities.pushNotificationsEnabled)
        XCTAssertFalse(capabilities.canSendPushNotifications)
        XCTAssertTrue(capabilities.isConsistent)
    }

    func testAdminCollaborationDirectoryValidatesMailAndStatusContracts() {
        let now = Date(timeIntervalSince1970: 1_788_544_000)
        let request = AdminCollaborationRequest(
            requestID: "7d8cb55b-7358-4d25-8e4c-af657a122d44",
            fanUserID: "e4af5d2e-b6b2-42fa-a2ee-3b8777379d27",
            contactName: "林女士",
            contactMethod: "13800000000",
            organization: "梧桐影业",
            projectType: "drama",
            city: "杭州",
            preferredDate: "2026-10-01",
            budget: "5 万元",
            details: "短剧女主角",
            status: CollaborationRequestStatus.received.rawValue,
            version: 1,
            receivedAt: now.addingTimeInterval(-60),
            updatedAt: now,
            delivery: AdminCollaborationDelivery(
                status: "pending",
                attempts: 0,
                errorCode: ""
            )
        )
        let directory = AdminCollaborationDirectory(
            requests: [request],
            page: 1,
            perPage: 100,
            total: 1,
            statuses: CollaborationRequestStatus.allCases.map(\.rawValue)
        )
        XCTAssertTrue(
            AdminCollaborationValidation.isValid(
                directory,
                filteredBy: .received,
                now: now
            )
        )

        let invalidDelivery = AdminCollaborationRequest(
            requestID: request.requestID,
            fanUserID: request.fanUserID,
            contactName: request.contactName,
            contactMethod: request.contactMethod,
            organization: request.organization,
            projectType: request.projectType,
            city: request.city,
            preferredDate: request.preferredDate,
            budget: request.budget,
            details: request.details,
            status: request.status,
            version: request.version,
            receivedAt: request.receivedAt,
            updatedAt: request.updatedAt,
            delivery: AdminCollaborationDelivery(
                status: "retrying-forever",
                attempts: 99,
                errorCode: "raw error with spaces"
            )
        )
        XCTAssertFalse(AdminCollaborationValidation.isValid(invalidDelivery, now: now))
    }

    func testWeatherKitConditionsHaveChinesePresentation() {
        XCTAssertEqual(WeatherPresentation.conditionText(for: .clear), "晴")
        XCTAssertEqual(WeatherPresentation.conditionText(for: .heavyRain), "大雨")
        XCTAssertEqual(WeatherPresentation.conditionText(for: .wintryMix), "雨雪混合")

        for condition in WeatherCondition.allCases {
            XCTAssertFalse(WeatherPresentation.conditionText(for: condition).isEmpty)
        }
    }

    func testWeatherFailuresHaveStableNonSensitiveCategories() {
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: WeatherError.permissionDenied),
            WeatherFailureCategory.permissionDenied.rawValue
        )
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: WeatherError.unknown),
            WeatherFailureCategory.weatherUnknown.rawValue
        )
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: URLError(.timedOut)),
            WeatherFailureCategory.urlLoadingBase.rawValue + abs(URLError.Code.timedOut.rawValue)
        )
        XCTAssertEqual(
            WeatherFailurePresentation.message(for: WeatherError.permissionDenied),
            "天气服务未授权"
        )
        XCTAssertEqual(
            WeatherFailurePresentation.message(for: URLError(.notConnectedToInternet)),
            "网络未连接"
        )
    }

    private func makePushStartupDefaults() throws -> UserDefaults {
        let suiteName = "PushStartupAuthorizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makePortfolio(imageCount: Int) -> Portfolio {
        let images = (1...imageCount).map { id in
            PortfolioImage(
                id: id,
                url: URL(string: "https://img.shuzijun.com.cn/test/\(id)-display.jpg")!,
                fullSizeURL: URL(string: "https://img.shuzijun.com.cn/test/\(id)-full.jpg")!,
                altText: "第 \(id) 张"
            )
        }
        return Portfolio(
            id: 1,
            title: "测试相册",
            subtitle: "回归测试",
            eyebrow: "TEST",
            slug: "test",
            websiteURL: URL(string: "https://www.shuzijun.com.cn/portfolio/test/")!,
            coverURL: images.first?.url,
            images: images
        )
    }

    private func makeLaunchPoster(
        id: String,
        startsAt: Date,
        endsAt: Date? = nil
    ) -> LaunchPosterContent {
        LaunchPosterContent(
            id: id,
            isEnabled: true,
            imageURL: URL(string: "https://img.shuzijun.com.cn/launch/\(id).jpg")!,
            eyebrow: "YI SHU",
            title: "易姝",
            subtitle: "镜头之内，自有叙事。",
            startsAt: startsAt,
            endsAt: endsAt ?? Date(timeIntervalSince1970: 4_102_444_800),
            displaySeconds: 2.5
        )
    }

    private func makeManifest(aboutPortraitURL: URL?, imageCount: Int = 3) -> AppContentManifest {
        AppContentManifest(
            schemaVersion: 1,
            updatedAt: .now,
            heroImages: [ContentCatalog.heroImages[0]],
            aboutPortraitURL: aboutPortraitURL,
            launchPosters: ContentCatalog.launchPosters,
            showreel: ContentCatalog.showreel,
            dramas: ContentCatalog.dramas,
            portfolios: [makePortfolio(imageCount: imageCount)]
        )
    }
}
