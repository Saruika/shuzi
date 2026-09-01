import XCTest
import AuthenticationServices
import SwiftUI
import UIKit
import WeatherKit
@testable import Yishu

final class ContentAndAccessTests: XCTestCase {
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
            "2026-09-02-approval-v3"
        )
    }

    func testFanRegistrationAcceptsBlankOrNormalizesASafeOptionalDouyinID() {
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID(" @YiShu_2026 "), "yishu_2026")
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID("一只梳子君"), "一只梳子君")
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("https://v.douyin.com/example"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("a b"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("@"))
        XCTAssertEqual(FanAccountValidation.normalizedOptionalDouyinID("   "), "")
        XCTAssertEqual(
            FanAccountValidation.normalizedOptionalDouyinID(" @YiShu_2026 "),
            "yishu_2026"
        )
        XCTAssertNil(FanAccountValidation.normalizedOptionalDouyinID("https://v.douyin.com/example"))
        XCTAssertNil(FanAccountValidation.normalizedOptionalDouyinID("@"))
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
                currentPassword: "OldPassword2026!",
                newPassword: "NewPassword2026!",
                newPasswordConfirmation: "NewPassword2026!"
            ),
            FanPasswordChangeInput(
                currentPassword: "OldPassword2026!",
                newPassword: "NewPassword2026!"
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: "SamePassword2026!",
                newPassword: "SamePassword2026!",
                newPasswordConfirmation: "SamePassword2026!"
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: "OldPassword2026!",
                newPassword: "weak",
                newPasswordConfirmation: "weak"
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

    func testAppleRegistrationRequiresNameAndConsentButKeepsDouyinOptional() throws {
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
        XCTAssertEqual(
            try FanAccountValidation.validatedAppleRegistration(
                displayName: "梳子粉丝",
                douyinID: "  ",
                acceptedDataUse: true
            ),
            FanAppleRegistrationInput(displayName: "梳子粉丝", douyinID: "")
        )
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "梳子粉丝",
            douyinID: "https://v.douyin.com/example",
            acceptedDataUse: true
        ))
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

    func testAdminDirectorySeparatesIncompleteAppleRegistrationFromCompletedOptionalDouyin() throws {
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
        XCTAssertFalse(completedWithoutDouyin.requiresIdentityCompletion)
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

    func testApprovedProfileWithoutOptionalDouyinRemainsCompleteAndUsable() {
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
        XCTAssertTrue(profile.isApproved(at: now))
        XCTAssertTrue(profile.hasPermission(.galleryFull, at: now))
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
                "temporaryPassword":"Tmp-abcdefghijklmnopqrstuvwx-9!",
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
            temporaryPassword: "Tmp-abcdefghijklmnopqrstuvwx-9!",
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

    func testRequiredSetupValidationAllowsBlankOptionalDouyinAndRequiresPasswordRotation() throws {
        let temporaryPassword = "Tmp-abcdefghijklmnopqrstuvwx-9!"
        let valid = try FanAccountValidation.validatedRequiredSetup(
            displayName: "  测试粉丝  ",
            douyinID: " @Real_Fan ",
            currentPassword: temporaryPassword,
            newPassword: "new-password-2026",
            newPasswordConfirmation: "new-password-2026",
            acceptedDataUse: true
        )
        XCTAssertEqual(valid.displayName, "测试粉丝")
        XCTAssertEqual(valid.douyinID, "real_fan")

        let withoutDouyin = try FanAccountValidation.validatedRequiredSetup(
            displayName: "测试粉丝",
            douyinID: "   ",
            currentPassword: temporaryPassword,
            newPassword: "new-password-2026",
            newPasswordConfirmation: "new-password-2026",
            acceptedDataUse: true
        )
        XCTAssertEqual(withoutDouyin.douyinID, "")

        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "invite_0123456789abcdef01234567",
                currentPassword: temporaryPassword,
                newPassword: "new-password-2026",
                newPasswordConfirmation: "new-password-2026",
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
                newPassword: "new-password-2026",
                newPasswordConfirmation: "new-password-2026",
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
