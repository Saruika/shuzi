import XCTest
import WeatherKit
@testable import Yishu

final class ContentAndAccessTests: XCTestCase {
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
