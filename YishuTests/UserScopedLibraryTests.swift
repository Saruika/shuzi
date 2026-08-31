import Foundation
import XCTest
@testable import Yishu

@MainActor
final class UserScopedLibraryTests: XCTestCase {
    func testFavoritesRemainIsolatedAcrossAccountsAndLogout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([999], forKey: "favoritePortfolioImageIDs")

        let store = FavoritesStore(defaults: defaults)
        let accountA = UUID().uuidString
        let accountB = UUID().uuidString
        let imageA = makeImage(id: 11)
        let imageB = makeImage(id: 22)

        XCTAssertNil(defaults.object(forKey: "favoritePortfolioImageIDs"))

        store.activate(accountID: accountA)
        store.toggle(imageA)
        XCTAssertTrue(store.contains(imageA))

        store.activate(accountID: accountB)
        XCTAssertFalse(store.contains(imageA))
        store.toggle(imageB)
        XCTAssertTrue(store.contains(imageB))

        store.deactivate()
        XCTAssertTrue(store.imageIDs.isEmpty)
        store.toggle(imageA)
        XCTAssertTrue(store.imageIDs.isEmpty)

        store.activate(accountID: accountA)
        XCTAssertTrue(store.contains(imageA))
        XCTAssertFalse(store.contains(imageB))

        store.removeData(for: accountA)
        XCTAssertTrue(store.imageIDs.isEmpty)
        store.activate(accountID: accountB)
        XCTAssertTrue(store.contains(imageB))
    }

    func testRecentlyViewedHistoryIsScopedAndDeletionTargetsOneAccount() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([999], forKey: "recentlyViewedPortfolioIDs")

        let store = RecentlyViewedStore(defaults: defaults)
        let accountA = UUID().uuidString
        let accountB = UUID().uuidString
        let portfolioA = makePortfolio(id: 101)
        let portfolioB = makePortfolio(id: 202)

        XCTAssertNil(defaults.object(forKey: "recentlyViewedPortfolioIDs"))

        store.activate(accountID: accountA)
        store.record(portfolioA)
        store.activate(accountID: accountB)
        XCTAssertTrue(store.portfolioIDs.isEmpty)
        store.record(portfolioB)

        store.removeData(for: accountA)
        XCTAssertEqual(store.portfolioIDs, [portfolioB.id])
        store.activate(accountID: accountA)
        XCTAssertTrue(store.portfolioIDs.isEmpty)
        store.activate(accountID: accountB)
        XCTAssertEqual(store.portfolioIDs, [portfolioB.id])
    }

    func testInvalidAccountIdentifiersFailClosed() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let image = makeImage(id: 7)
        let portfolio = makePortfolio(id: 8)
        let favorites = FavoritesStore(defaults: defaults)
        let recentlyViewed = RecentlyViewedStore(defaults: defaults)

        favorites.activate(accountID: "not-a-server-uuid")
        recentlyViewed.activate(accountID: "not-a-server-uuid")
        favorites.toggle(image)
        recentlyViewed.record(portfolio)

        XCTAssertTrue(favorites.imageIDs.isEmpty)
        XCTAssertTrue(recentlyViewed.portfolioIDs.isEmpty)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "cn.com.shuzijun.yishu.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeImage(id: Int) -> PortfolioImage {
        PortfolioImage(
            id: id,
            url: URL(string: "https://img.shuzijun.com.cn/tests/\(id).jpg")!,
            fullSizeURL: URL(string: "https://img.shuzijun.com.cn/tests/\(id)-full.jpg")!,
            altText: "测试照片 \(id)"
        )
    }

    private func makePortfolio(id: Int) -> Portfolio {
        let image = makeImage(id: id)
        return Portfolio(
            id: id,
            title: "测试相册 \(id)",
            subtitle: "测试",
            eyebrow: "TEST",
            slug: "test-\(id)",
            websiteURL: URL(string: "https://www.shuzijun.com.cn/portfolio/test-\(id)/")!,
            coverURL: image.url,
            images: [image]
        )
    }
}
