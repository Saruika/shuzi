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
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @EnvironmentObject private var adminSession: AdminSessionStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab
    @State private var portfolioPath: [Portfolio] = []
    @State private var launchPosterSnapshot: LaunchPosterContent?
    @State private var hasPreparedLaunchPoster = false
    @State private var isLaunchPosterVisible = false
    @State private var hasResolvedAccess = false
    @State private var hasPreparedAuthorizedContent = false
    @State private var isPreparingAuthorizedContent = false
    @State private var approvedContentRefreshID = UUID()
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
        Group {
            if !hasResolvedAccess {
                accessResolutionView
            } else if canAccessAppContent {
                authorizedAppContent
            } else {
                AppAccessGateView()
            }
        }
        .tint(AppTheme.gold)
        .protectedFromScreenCapture()
        .task { await restoreAccess() }
        .task(id: "\(fanAccount.profile?.status ?? "none"):\(fanAccount.profile?.requiresAccountSetup == true)") {
            await monitorApprovedAccess()
        }
        .onChange(of: portfolioStore.portfolios) { _, portfolios in
            recentlyViewed.retainAvailablePortfolios(in: portfolios)
        }
        .onChange(of: fanAccount.profile?.userID, initial: true) { _, userID in
            switchLocalLibrary(to: userID)
        }
        .onChange(of: fanAccount.removedAccountUserID, initial: true) { _, userID in
            guard let userID else { return }
            favorites.removeData(for: userID)
            recentlyViewed.removeData(for: userID)
        }
        .onChange(of: fanAccount.profile?.status) { _, status in
            if fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            } else if !adminSession.isAuthenticated {
                resetProtectedPresentation()
            }
        }
        .onChange(of: fanAccount.profile?.requiresAccountSetup) { _, requiresSetup in
            if requiresSetup == true, !adminSession.isAuthenticated {
                resetProtectedPresentation()
            } else if fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            }
        }
        .onChange(of: adminSession.isAuthenticated) { _, authenticated in
            invalidateApprovedContentRefresh()
            // AdminView owns its full-manifest load. Keeping that request out of
            // the fan root prevents role-specific responses racing here.
            guard !authenticated else { return }

            // Administrator manifests are unrestricted. Always remove them on
            // logout, including when no approved fan session exists.
            portfolioStore.discardProtectedContent()
            if fanAccount.isApproved {
                // The local scope is authoritative even when the replacement
                // fan request fails.
                enforceCurrentFanPermissionScope()
                if hasPreparedAuthorizedContent {
                    Task { await refreshApprovedContent() }
                } else {
                    Task { await prepareAuthorizedContentIfNeeded() }
                }
            } else {
                portfolioStore.enforcePermissionScope(
                    canViewFullGallery: false,
                    canViewVideo: false
                )
            }
        }
        .onChange(of: fanAccount.profile?.permissions) { _, _ in
            if !canViewVideo, selectedTab == .credits { selectedTab = .home }
            if !canViewFullGallery { portfolioPath = [] }
            invalidateApprovedContentRefresh()
            guard fanAccount.isApproved, !adminSession.isAuthenticated else { return }
            enforceCurrentFanPermissionScope()
            Task { await refreshApprovedContent() }
        }
        .onChange(of: portfolioStore.launchPosters) { _, _ in
            refreshVisibleLaunchPosterSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                adminSession.lock()
                return
            }
            if fanAccount.clearExpiredSessionIfNeeded() {
                resetProtectedPresentation()
                return
            }
            Task {
                await fanAccount.refreshIfNeeded(minimumInterval: 0)
                if fanAccount.isApproved { await refreshApprovedContent() }
            }
        }
    }

    private var authorizedAppContent: some View {
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

                if canViewVideo {
                    NavigationStack {
                        CreditsView()
                    }
                    .tag(AppTab.credits)
                    .tabItem { Label("影视", systemImage: "film.stack") }
                }

                NavigationStack {
                    FavoritesView(showPortfolio: { selectedTab = .portfolio })
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
    }

    private var accessResolutionView: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(AppTheme.gold)
                ProgressView().tint(AppTheme.gold)
                Text("正在验证访问授权")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .accessibilityIdentifier("access-checking")
    }

    private var canAccessAppContent: Bool {
        fanAccount.isApproved || shouldBypassAccessGate
    }

    private var canViewVideo: Bool {
        shouldBypassAccessGate || fanAccount.hasPermission(.videoView)
    }

    private var canViewFullGallery: Bool {
        shouldBypassAccessGate || fanAccount.hasPermission(.galleryFull)
    }

    private var shouldBypassAccessGate: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-bypass-access-gate-for-visual-testing")
#else
        false
#endif
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

    private func restoreAccess() async {
        await fanAccount.restoreSession()
        hasResolvedAccess = true
        if canAccessAppContent {
            await prepareAuthorizedContentIfNeeded()
        } else {
            portfolioStore.discardProtectedContent()
            portfolioStore.enforcePermissionScope(
                canViewFullGallery: false,
                canViewVideo: false
            )
        }
    }

    private func prepareAuthorizedContentIfNeeded() async {
        guard canAccessAppContent,
              !adminSession.isAuthenticated,
              !hasPreparedAuthorizedContent,
              !isPreparingAuthorizedContent else { return }
        isPreparingAuthorizedContent = true
        defer { isPreparingAuthorizedContent = false }

        enforceCurrentFanPermissionScope()
        await portfolioStore.restoreCachedContent(allowVideo: canViewVideo)
        enforceCurrentFanPermissionScope()
        prepareLaunchPosterIfNeeded(allowBundledFallback: true)
        hasPreparedAuthorizedContent = true
        recentlyViewed.retainAvailablePortfolios(in: portfolioStore.portfolios)
        if let visualPortfolioTitle,
           let portfolio = portfolioStore.portfolios.first(where: { $0.title == visualPortfolioTitle }) {
            portfolioPath = [portfolio]
        }
        if fanAccount.isApproved { await refreshApprovedContent() }
    }

    private func refreshApprovedContent() async {
        let refreshID = UUID()
        approvedContentRefreshID = refreshID
        guard fanAccount.isApproved, !adminSession.isAuthenticated else { return }
        let storeRefreshID = portfolioStore.beginContentRefresh()
        do {
            let manifest = try await fanAccount.fetchApprovedContent()
            guard approvedContentRefreshID == refreshID,
                  fanAccount.isApproved,
                  !adminSession.isAuthenticated else {
                portfolioStore.cancelContentRefresh(storeRefreshID)
                return
            }
            portfolioStore.completeContentRefresh(storeRefreshID, with: manifest)
            enforceCurrentFanPermissionScope()
        } catch {
            guard approvedContentRefreshID == refreshID,
                  fanAccount.isApproved,
                  !adminSession.isAuthenticated else {
                portfolioStore.cancelContentRefresh(storeRefreshID)
                return
            }
            portfolioStore.failContentRefresh(storeRefreshID)
        }
    }

    private func invalidateApprovedContentRefresh() {
        approvedContentRefreshID = UUID()
    }

    private func enforceCurrentFanPermissionScope() {
        guard !shouldBypassAccessGate else { return }
        portfolioStore.enforcePermissionScope(
            canViewFullGallery: canViewFullGallery,
            canViewVideo: canViewVideo
        )
    }

    private func monitorApprovedAccess() async {
        guard fanAccount.isApproved, !shouldBypassAccessGate else { return }
        while !Task.isCancelled, fanAccount.isApproved {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await fanAccount.refreshSession(showError: false)
        }
    }

    private func resetProtectedPresentation() {
        invalidateApprovedContentRefresh()
        portfolioStore.discardProtectedContent()
        portfolioStore.enforcePermissionScope(
            canViewFullGallery: false,
            canViewVideo: false
        )
        hasPreparedAuthorizedContent = false
        hasPreparedLaunchPoster = false
        isLaunchPosterVisible = false
        launchPosterSnapshot = nil
        portfolioPath = []
    }

    private func switchLocalLibrary(to userID: String?) {
        guard let userID else {
            favorites.deactivate()
            recentlyViewed.deactivate()
            return
        }
        favorites.activate(accountID: userID)
        recentlyViewed.activate(accountID: userID)
        recentlyViewed.retainAvailablePortfolios(in: portfolioStore.portfolios)
    }
}
