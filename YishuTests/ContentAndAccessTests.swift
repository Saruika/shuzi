import XCTest
import WeatherKit
@testable import Yishu

final class ContentAndAccessTests: XCTestCase {
    func testWeatherLocationAlwaysKeepsAConcisePlaceName() {
        XCTAssertEqual(WeatherPresentation.conciseLocationText("杭州市"), "杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("香港特别行政区"), "香港")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("浙江·杭州"), "浙江·杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("  "), "当前位置")
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

    func testEveryBundledHeroHasAStableMatchingFallback() {
        XCTAssertEqual(ContentCatalog.heroImages.count, 5)
        for (index, url) in ContentCatalog.heroImages.enumerated() {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNotNil(ContentCatalog.heroAssetName(at: index))
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(url))
        }
        XCTAssertNil(ContentCatalog.heroAssetName(at: ContentCatalog.heroImages.count))
    }

    func testBundledLaunchPosterDoesNotReuseAHomeHero() {
        let homeHeroes = Set(ContentCatalog.heroImages)

        XCTAssertFalse(ContentCatalog.launchPosters.isEmpty)
        for poster in ContentCatalog.launchPosters {
            XCTAssertFalse(homeHeroes.contains(poster.imageURL))
        }
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
    }

    func testPublishedManifestUsesAStableTrustedHTTPSEndpoint() {
        let endpoint = ContentCatalog.publishedManifestURL

        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "www.shuzijun.com.cn")
        XCTAssertNil(endpoint.user)
        XCTAssertNil(endpoint.password)
    }

    func testPublishedManifestResponseMustMatchTheExactConfiguredEndpoint() {
        let expected = ContentCatalog.publishedManifestURL

        XCTAssertTrue(AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(expected, expected: expected))
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "http://www.shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://www.shuzijun.com.cn.evil.example\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://www.shuzijun.com.cn:444\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://user:password@www.shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
    }

    func testAdministratorRequestsStayInsideTheWordPressAPINamespace() {
        XCTAssertTrue(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json-evil/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://img.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
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

    private func makeManifest(aboutPortraitURL: URL?) -> AppContentManifest {
        AppContentManifest(
            schemaVersion: 1,
            updatedAt: .now,
            heroImages: [ContentCatalog.heroImages[0]],
            aboutPortraitURL: aboutPortraitURL,
            launchPosters: ContentCatalog.launchPosters,
            showreel: ContentCatalog.showreel,
            dramas: ContentCatalog.dramas,
            portfolios: [makePortfolio(imageCount: 3)]
        )
    }
}
