import Foundation

@MainActor
final class RecentlyViewedStore: ObservableObject {
    @Published private(set) var portfolioIDs: [Int]

    private let defaultsKey = "recentlyViewedPortfolioIDs"
    private let maximumCount = 6

    init() {
        portfolioIDs = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? []
    }

    func record(_ portfolio: Portfolio) {
        portfolioIDs.removeAll { $0 == portfolio.id }
        portfolioIDs.insert(portfolio.id, at: 0)
        portfolioIDs = Array(portfolioIDs.prefix(maximumCount))
        UserDefaults.standard.set(portfolioIDs, forKey: defaultsKey)
    }

    func retainAvailablePortfolios(in portfolios: [Portfolio]) {
        let availableIDs = Set(portfolios.map(\.id))
        let retained = portfolioIDs.filter(availableIDs.contains)
        guard retained != portfolioIDs else { return }
        portfolioIDs = retained
        UserDefaults.standard.set(portfolioIDs, forKey: defaultsKey)
    }

    func clear() {
        portfolioIDs = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
