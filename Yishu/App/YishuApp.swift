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

        // Let current systems render the native adaptive tab-bar material.
        // Older releases keep the branded opaque fallback for equivalent
        // contrast and predictable readability.
        if #unavailable(iOS 26.0) {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(AppTheme.ink)
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.62)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.62)
            ]
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(AppTheme.gold)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(AppTheme.gold)
            ]
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    var body: some Scene {
        WindowGroup {
            SecureCaptureSurface(owner: .appRoot) {
                appContent
            }
            .preferredColorScheme(.dark)
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
