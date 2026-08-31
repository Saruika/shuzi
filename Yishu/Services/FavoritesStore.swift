import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var imageIDs: Set<Int>

    private static let legacyDefaultsKey = "favoritePortfolioImageIDs"
    private static let accountKeyPrefix = "favoritePortfolioImageIDs.v2"
    private let defaults: UserDefaults
    private var activeAccountID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        imageIDs = []

        // The old key mixed every signed-in user on a shared device. There is
        // no trustworthy way to assign that data to one server UUID, so fail
        // closed instead of leaking one fan's library to the next account.
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    func activate(accountID: String) {
        guard let normalizedID = Self.normalizedAccountID(accountID) else {
            deactivate()
            return
        }
        guard normalizedID != activeAccountID else { return }
        activeAccountID = normalizedID
        imageIDs = Set(defaults.array(forKey: defaultsKey(for: normalizedID)) as? [Int] ?? [])
    }

    func deactivate() {
        activeAccountID = nil
        imageIDs = []
    }

    func removeData(for accountID: String) {
        guard let normalizedID = Self.normalizedAccountID(accountID) else { return }
        defaults.removeObject(forKey: defaultsKey(for: normalizedID))
        if activeAccountID == normalizedID {
            imageIDs = []
        }
    }

    func contains(_ image: PortfolioImage) -> Bool {
        imageIDs.contains(image.id)
    }

    func toggle(_ image: PortfolioImage) {
        guard activeAccountID != nil else { return }
        if imageIDs.contains(image.id) {
            imageIDs.remove(image.id)
        } else {
            imageIDs.insert(image.id)
        }
        persist()
    }

    func retainAvailableImages(in portfolios: [Portfolio]) {
        let availableIDs = Set(portfolios.flatMap { $0.images.map(\.id) })
        let retained = imageIDs.intersection(availableIDs)
        guard retained != imageIDs else { return }
        imageIDs = retained
        persist()
    }

    private func persist() {
        guard let activeAccountID else { return }
        defaults.set(Array(imageIDs).sorted(), forKey: defaultsKey(for: activeAccountID))
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
