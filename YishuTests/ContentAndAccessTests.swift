import XCTest
@testable import Yishu

final class ContentAndAccessTests: XCTestCase {
    func testVisitorCanAccessOnlyFirstThreeImages() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(
            PhotoAccessPolicy.accessibleImages(
                in: portfolio,
                hasSubscription: false,
                isAdministrator: false
            ).map(\.id),
            [1, 2, 3]
        )
        XCTAssertFalse(
            PhotoAccessPolicy.canAccess(
                portfolio.images[3],
                in: portfolio,
                hasSubscription: false,
                isAdministrator: false
            )
        )
    }

    func testSubscriberAndAdministratorCanAccessEveryImage() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(
            PhotoAccessPolicy.accessibleImages(
                in: portfolio,
                hasSubscription: true,
                isAdministrator: false
            ).count,
            6
        )
        XCTAssertTrue(
            PhotoAccessPolicy.canAccess(
                portfolio.images[5],
                in: portfolio,
                hasSubscription: false,
                isAdministrator: true
            )
        )
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
}
