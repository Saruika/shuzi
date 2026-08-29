import SwiftUI

private enum AppTab: Hashable {
    case home
    case portfolio
    case credits
    case favorites
    case about
}

struct RootView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @EnvironmentObject private var adminSession: AdminSessionStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @State private var selectedTab: AppTab
    @State private var portfolioPath: [Portfolio] = []
    @State private var launchPosterSnapshot: LaunchPosterContent?
    @State private var hasPreparedLaunchPoster = false
    @State private var isLaunchPosterVisible = true
    private let visualPortfolioTitle: String?

    init() {
        let prefix = "-visual-portfolio-title="
        let title = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        visualPortfolioTitle = title
        let startsOnPortfolio = title != nil || ProcessInfo.processInfo.arguments.contains(
            "-open-portfolio-for-visual-testing"
        )
        _selectedTab = State(initialValue: startsOnPortfolio ? .portfolio : .home)
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView(showPortfolio: { selectedTab = .portfolio })
                }
                .tag(AppTab.home)
                .tabItem { Label("首页", systemImage: "play.rectangle") }

                NavigationStack(path: $portfolioPath) {
                    PortfolioGridView()
                }
                .tag(AppTab.portfolio)
                .tabItem { Label("作品", systemImage: "square.grid.2x2") }

                NavigationStack {
                    CreditsView()
                }
                .tag(AppTab.credits)
                .tabItem { Label("影视", systemImage: "film.stack") }

                NavigationStack {
                    FavoritesView()
                }
                .tag(AppTab.favorites)
                .tabItem { Label("收藏", systemImage: "heart") }

                NavigationStack {
                    AboutView()
                }
                .tag(AppTab.about)
                .tabItem { Label("关于", systemImage: "person.crop.rectangle") }
            }

            if isLaunchPosterVisible, let poster = displayedLaunchPoster {
                LaunchPosterView(poster: poster) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        isLaunchPosterVisible = false
                    }
                }
                .transition(.opacity)
                .zIndex(20_000)
            }
        }
        .tint(AppTheme.gold)
        .protectedFromScreenCapture()
        .onAppear { prepareLaunchPosterIfNeeded() }
        .task {
            async let contentRefresh: Void = portfolioStore.refresh()
            async let sessionRestore: Void = adminSession.restoreSession()
            async let subscriptionRefresh: Void = subscription.refresh()
            _ = await (contentRefresh, sessionRestore, subscriptionRefresh)
            favorites.retainAvailableImages(in: portfolioStore.portfolios)
            recentlyViewed.retainAvailablePortfolios(in: portfolioStore.portfolios)
            if let visualPortfolioTitle,
               let portfolio = portfolioStore.portfolios.first(where: { $0.title == visualPortfolioTitle }) {
                portfolioPath = [portfolio]
            }
        }
        .onChange(of: portfolioStore.portfolios) { _, portfolios in
            favorites.retainAvailableImages(in: portfolios)
            recentlyViewed.retainAvailablePortfolios(in: portfolios)
        }
    }

    private var displayedLaunchPoster: LaunchPosterContent? {
        if hasPreparedLaunchPoster { return launchPosterSnapshot }
        return portfolioStore.activeLaunchPoster
    }

    private func prepareLaunchPosterIfNeeded() {
        guard !hasPreparedLaunchPoster else { return }
        if visualPortfolioTitle != nil || selectedTab == .portfolio {
            launchPosterSnapshot = nil
            isLaunchPosterVisible = false
            hasPreparedLaunchPoster = true
            return
        }
        launchPosterSnapshot = portfolioStore.activeLaunchPoster
        isLaunchPosterVisible = launchPosterSnapshot != nil
        hasPreparedLaunchPoster = true
    }
}
