import SwiftUI

@MainActor
protocol AppWorkspaceLifecycle: AnyObject {
    var serviceEnvironment: AppServiceEnvironment { get }
    func activate()
    func retire() async
}

/// A single transition owns teardown and replacement. The view removes the
/// old root while switching, so sheets, navigation paths and admin drafts are
/// destroyed instead of being reattached to services from another workspace.
@MainActor
final class AppWorkspaceCoordinator<Workspace: AppWorkspaceLifecycle>: ObservableObject {
    @Published private(set) var current: Workspace
    @Published private(set) var isSwitching = false
    private let makeWorkspace: (AppServiceEnvironment) -> Workspace

    init(environment: AppServiceEnvironment = .production,
         makeWorkspace: @escaping (AppServiceEnvironment) -> Workspace) {
        self.makeWorkspace = makeWorkspace
        current = makeWorkspace(environment)
        current.activate()
    }

    @discardableResult
    func switchEnvironment(to environment: AppServiceEnvironment) async -> Bool {
        guard !isSwitching, current.serviceEnvironment != environment else { return false }
        isSwitching = true
        // Once teardown starts, finish replacement even if the initiating view
        // disappears/cancels; never leave a retired workspace mounted again.
        await current.retire()
        let replacement = makeWorkspace(environment)
        current = replacement
        replacement.activate()
        isSwitching = false
        return true
    }
}

@MainActor
final class AppServiceWorkspace: AppWorkspaceLifecycle {
    let serviceEnvironment: AppServiceEnvironment
    let portfolioStore: PortfolioStore
    let favorites: FavoritesStore
    let recentlyViewed: RecentlyViewedStore
    let adminSession: AdminSessionStore
    let fanAccount: FanAccountStore
    let pushNotifications: PushNotificationCoordinator
    private let notificationRouter: PushNotificationRouter
    private var isRetired = false

    init(environment: AppServiceEnvironment, notificationRouter: PushNotificationRouter? = nil) {
        serviceEnvironment = environment
        self.notificationRouter = notificationRouter ?? .shared
        portfolioStore = PortfolioStore(environment: environment)
        favorites = FavoritesStore(environment: environment)
        recentlyViewed = RecentlyViewedStore(environment: environment)
        adminSession = AdminSessionStore(environment: environment)
        fanAccount = FanAccountStore(environment: environment)
        pushNotifications = PushNotificationCoordinator(environment: environment)
    }

    func activate() {
        guard !isRetired else { return }
        notificationRouter.activate(pushNotifications)
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        notificationRouter.deactivate(pushNotifications)
        pushNotifications.retire()
        adminSession.retireForEnvironmentSwitch()
        favorites.deactivate()
        recentlyViewed.deactivate()
        portfolioStore.retireForEnvironmentSwitch()
        // signOut clears access synchronously, then attempts remote cleanup
        // through its old immutable endpoint. The new workspace is not active yet.
        await fanAccount.retireForEnvironmentSwitch()
        await ArtworkImagePrefetcher.purgeMemory()
    }
}
