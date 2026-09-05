import SwiftUI

@main
struct YishuApp: App {
    @UIApplicationDelegateAdaptor(YishuApplicationDelegate.self) private var applicationDelegate
    @StateObject private var portfolioStore = PortfolioStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var recentlyViewed = RecentlyViewedStore()
    @StateObject private var adminSession = AdminSessionStore()
    @StateObject private var fanAccount = FanAccountStore()
    @StateObject private var pushNotifications = PushNotificationCoordinator.shared
    @State private var localWeather = LocalWeatherStore()

    init() {
        AppDiagnostics.shared.start()

        let cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            // Keep gallery artwork out of persistent URL caches. Images may
            // remain in memory while the app is running, but are discarded on
            // termination instead of being written to the app container.
            diskCapacity: 0
        )
        URLCache.shared = cache

        AppAppearanceCoordinator.updateLegacyTabBars()
    }

    var body: some Scene {
        WindowGroup {
            SecureCaptureSurface(owner: .appRoot) {
                appContent
            }
            .preferredColorScheme(AppearanceStore.shared.systemColorScheme)
            .onChange(of: AppearanceStore.shared.theme) { _, _ in
                AppAppearanceCoordinator.updateLegacyTabBars()
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-preview-admin-launch-poster-for-testing") {
            LaunchPosterAdminPreviewFixture()
        } else {
            configuredRoot
        }
#else
        configuredRoot
#endif
    }

    private var configuredRoot: some View {
        RootView()
            .environmentObject(portfolioStore)
            .environmentObject(favorites)
            .environmentObject(recentlyViewed)
            .environmentObject(adminSession)
            .environmentObject(fanAccount)
            .environmentObject(pushNotifications)
            .environment(localWeather)
    }
}
