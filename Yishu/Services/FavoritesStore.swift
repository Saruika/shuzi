import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var imageIDs: Set<Int>

    private let defaultsKey = "favoritePortfolioImageIDs"

    init() {
        imageIDs = Set(UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? [])
    }

    func contains(_ image: PortfolioImage) -> Bool {
        imageIDs.contains(image.id)
    }

    func toggle(_ image: PortfolioImage) {
        if imageIDs.contains(image.id) {
            imageIDs.remove(image.id)
        } else {
            imageIDs.insert(image.id)
        }
        UserDefaults.standard.set(Array(imageIDs).sorted(), forKey: defaultsKey)
    }

    func retainAvailableImages(in portfolios: [Portfolio]) {
        let availableIDs = Set(portfolios.flatMap { $0.images.map(\.id) })
        let retained = imageIDs.intersection(availableIDs)
        guard retained != imageIDs else { return }
        imageIDs = retained
        UserDefaults.standard.set(Array(imageIDs).sorted(), forKey: defaultsKey)
    }
}
