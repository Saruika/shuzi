import SwiftUI

private enum AppTab: Hashable {
    case home
    case portfolio
    case credits
    case favorites
    case about
}

private enum VisualTestingDestination {
    case admin
    case collaboration
}

struct RootView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @EnvironmentObject private var adminSession: AdminSessionStore
    @State private var selectedTab: AppTab
    @State private var portfolioPath: [Portfolio] = []
    @State private var launchPosterSnapshot: LaunchPosterContent?
    @State private var hasPreparedLaunchPoster = false
    @State private var isLaunchPosterVisible = true
    private let visualPortfolioTitle: String?
    private let visualTestingDestination: VisualTestingDestination?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let prefix = "-visual-portfolio-title="
        let title = arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        visualPortfolioTitle = title
        let destination: VisualTestingDestination?
#if DEBUG
        if arguments.contains("-open-admin-for-visual-testing") {
            destination = .admin
        } else if arguments.contains("-open-collaboration-for-visual-testing") {
            destination = .collaboration
        } else {
            destination = nil
        }
#else
        destination = nil
#endif
        visualTestingDestination = destination
        let initialTab: AppTab
#if DEBUG
        if title != nil || arguments.contains("-open-portfolio-for-visual-testing") {
            initialTab = .portfolio
        } else if arguments.contains("-open-about-for-visual-testing") || destination != nil {
            initialTab = .about
        } else if arguments.contains("-open-credits-for-visual-testing") {
            initialTab = .credits
        } else if arguments.contains("-open-favorites-for-visual-testing") {
            initialTab = .favorites
        } else {
            initialTab = .home
        }
#else
        initialTab = title == nil ? .home : .portfolio
#endif
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView(showPortfolio: { selectedTab = .portfolio })
                .ignoresSafeArea(.container, edges: .top)
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
                    visualAboutContent
                }
                .ignoresSafeArea(.container, edges: .top)
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
        .task {
            await portfolioStore.restoreCachedContent()
            prepareLaunchPosterIfNeeded()
            await adminSession.restoreSession()
            await refreshAdministratorContentIfAllowed()
            recentlyViewed.retainAvailablePortfolios(in: portfolioStore.portfolios)
            if let visualPortfolioTitle,
               let portfolio = portfolioStore.portfolios.first(where: { $0.title == visualPortfolioTitle }) {
                portfolioPath = [portfolio]
            }
        }
        .onChange(of: portfolioStore.portfolios) { _, portfolios in
            recentlyViewed.retainAvailablePortfolios(in: portfolios)
        }
        .onChange(of: adminSession.isAuthenticated) { _, _ in
            Task { await refreshAdministratorContentIfAllowed() }
        }
    }

    @ViewBuilder
    private var visualAboutContent: some View {
#if DEBUG
        switch visualTestingDestination {
        case .admin:
            AdminView()
        case .collaboration:
            CollaborationInquiryView()
        case nil:
            AboutView()
        }
#else
        AboutView()
#endif
    }

    private var displayedLaunchPoster: LaunchPosterContent? {
        if hasPreparedLaunchPoster { return launchPosterSnapshot }
        return portfolioStore.activeLaunchPoster
    }

    private func prepareLaunchPosterIfNeeded() {
        guard !hasPreparedLaunchPoster else { return }
        let skipsPosterForTesting: Bool
#if DEBUG
        skipsPosterForTesting = ProcessInfo.processInfo.arguments.contains(
            "-skip-launch-poster-for-visual-testing"
        )
#else
        skipsPosterForTesting = false
#endif
        if skipsPosterForTesting || visualPortfolioTitle != nil || selectedTab != .home {
            launchPosterSnapshot = nil
            isLaunchPosterVisible = false
            hasPreparedLaunchPoster = true
            return
        }
        launchPosterSnapshot = portfolioStore.activeLaunchPoster
        isLaunchPosterVisible = launchPosterSnapshot != nil
        hasPreparedLaunchPoster = true
    }

    private func refreshAdministratorContentIfAllowed() async {
        if adminSession.isAuthenticated {
            if let manifest = try? await adminSession.fetchContent() {
                portfolioStore.applyPublishedManifest(manifest)
            }
        } else {
            await portfolioStore.refresh()
        }
    }
}
