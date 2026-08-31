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
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab
    @State private var portfolioPath: [Portfolio] = []
    @State private var launchPosterSnapshot: LaunchPosterContent?
    @State private var hasPreparedLaunchPoster = false
    @State private var isLaunchPosterVisible = false
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
            if !hasPreparedLaunchPoster {
                AppTheme.ink
                    .ignoresSafeArea()
                    .zIndex(19_999)
            } else if isLaunchPosterVisible, let poster = displayedLaunchPoster {
                LaunchPosterView(poster: poster) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        isLaunchPosterVisible = false
                    }
                }
                .id(poster)
                .transition(.opacity)
                .zIndex(20_000)
            }
        }
        .tint(AppTheme.gold)
        .protectedFromScreenCapture()
        .task {
            await portfolioStore.restoreCachedContent()
            let refreshedForLaunch = shouldSkipLaunchPoster
                ? false
                : await portfolioStore.refreshLaunchContent()
            prepareLaunchPosterIfNeeded(
                allowBundledFallback: refreshedForLaunch || portfolioStore.contentOrigin != .bundled
            )
            await adminSession.restoreSession()
            await fanAccount.restoreSession()
            await refreshAdministratorContentIfAllowed(publicContentIsFresh: refreshedForLaunch)
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
        .onChange(of: portfolioStore.launchPosters) { _, _ in
            refreshVisibleLaunchPosterSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await fanAccount.refreshIfNeeded() }
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
        launchPosterSnapshot
    }

    private var shouldSkipLaunchPoster: Bool {
        let skipsPosterForTesting: Bool
#if DEBUG
        skipsPosterForTesting = ProcessInfo.processInfo.arguments.contains(
            "-skip-launch-poster-for-visual-testing"
        )
#else
        skipsPosterForTesting = false
#endif
        return skipsPosterForTesting || visualPortfolioTitle != nil || selectedTab != .home
    }

    private func prepareLaunchPosterIfNeeded(allowBundledFallback: Bool) {
        guard !hasPreparedLaunchPoster else { return }
        if shouldSkipLaunchPoster || !allowBundledFallback {
            launchPosterSnapshot = nil
            isLaunchPosterVisible = false
            hasPreparedLaunchPoster = true
            return
        }
        launchPosterSnapshot = portfolioStore.activeLaunchPoster
        isLaunchPosterVisible = launchPosterSnapshot != nil
        hasPreparedLaunchPoster = true
    }

    private func refreshVisibleLaunchPosterSnapshot() {
        guard hasPreparedLaunchPoster, isLaunchPosterVisible else { return }
        let latest = portfolioStore.activeLaunchPoster
        guard latest != launchPosterSnapshot else { return }
        launchPosterSnapshot = latest
        isLaunchPosterVisible = latest != nil
    }

    private func refreshAdministratorContentIfAllowed(publicContentIsFresh: Bool = false) async {
        if adminSession.isAuthenticated {
            if let manifest = try? await adminSession.fetchContent() {
                portfolioStore.applyPublishedManifest(manifest)
            }
        } else if !publicContentIsFresh {
            await portfolioStore.refresh()
        }
    }
}
