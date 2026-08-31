import Foundation

@MainActor
final class RecentlyViewedStore: ObservableObject {
    @Published private(set) var portfolioIDs: [Int]

    private static let legacyDefaultsKey = "recentlyViewedPortfolioIDs"
    private static let accountKeyPrefix = "recentlyViewedPortfolioIDs.v2"
    private let defaults: UserDefaults
    private var activeAccountID: String?
    private let maximumCount = 6

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        portfolioIDs = []
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    func activate(accountID: String) {
        guard let normalizedID = Self.normalizedAccountID(accountID) else {
            deactivate()
            return
        }
        guard normalizedID != activeAccountID else { return }
        activeAccountID = normalizedID
        portfolioIDs = defaults.array(forKey: defaultsKey(for: normalizedID)) as? [Int] ?? []
    }

    func deactivate() {
        activeAccountID = nil
        portfolioIDs = []
    }

    func removeData(for accountID: String) {
        guard let normalizedID = Self.normalizedAccountID(accountID) else { return }
        defaults.removeObject(forKey: defaultsKey(for: normalizedID))
        if activeAccountID == normalizedID {
            portfolioIDs = []
        }
    }

    func record(_ portfolio: Portfolio) {
        guard activeAccountID != nil else { return }
        portfolioIDs.removeAll { $0 == portfolio.id }
        portfolioIDs.insert(portfolio.id, at: 0)
        portfolioIDs = Array(portfolioIDs.prefix(maximumCount))
        persist()
    }

    func retainAvailablePortfolios(in portfolios: [Portfolio]) {
        let availableIDs = Set(portfolios.map(\.id))
        let retained = portfolioIDs.filter(availableIDs.contains)
        guard retained != portfolioIDs else { return }
        portfolioIDs = retained
        persist()
    }

    func clear() {
        portfolioIDs = []
        guard let activeAccountID else { return }
        defaults.removeObject(forKey: defaultsKey(for: activeAccountID))
    }

    private func persist() {
        guard let activeAccountID else { return }
        defaults.set(portfolioIDs, forKey: defaultsKey(for: activeAccountID))
    }

    private func defaultsKey(for accountID: String) -> String {
        "\(Self.accountKeyPrefix).\(accountID)"
    }

    private static func normalizedAccountID(_ accountID: String) -> String? {
        guard let uuid = UUID(uuidString: accountID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }
}
