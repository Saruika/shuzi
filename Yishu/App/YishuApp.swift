import SwiftUI

@main
struct YishuApp: App {
    @StateObject private var portfolioStore = PortfolioStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var recentlyViewed = RecentlyViewedStore()
    @StateObject private var adminSession = AdminSessionStore()
    @StateObject private var localWeather = LocalWeatherStore()

    init() {
        let cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            // Keep gallery artwork out of persistent URL caches. Images may
            // remain in memory while the app is running, but are discarded on
            // termination instead of being written to the app container.
            diskCapacity: 0
        )
        URLCache.shared = cache

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppTheme.ink)
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.45)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.white.withAlphaComponent(0.45)
        ]
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(AppTheme.gold)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(AppTheme.gold)
        ]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                CaptureProtectionCover()
                    .accessibilityHidden(true)

                if ScreenProtectionTesting.isDisabled {
                    appContent
                } else {
                    ScreenshotProtectedContent {
                        appContent
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var appContent: some View {
        RootView()
            .environmentObject(portfolioStore)
            .environmentObject(favorites)
            .environmentObject(recentlyViewed)
            .environmentObject(adminSession)
            .environmentObject(localWeather)
    }
}
