import AuthenticationServices
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case portfolio
    case credits
    case favorites
    case about

    func resolved(canViewVideo: Bool) -> Self {
        self == .credits && !canViewVideo ? .home : self
    }
}

private enum VisualTestingDestination {
    case fanAdministrator
    case admin
    case collaboration
}

struct ColdLaunchPosterSelectionState: Equatable {
    private(set) var snapshot: LaunchPosterContent?
    private(set) var hasSelected = false

    mutating func record(_ poster: LaunchPosterContent?) {
        snapshot = poster
        hasSelected = true
    }

    mutating func reset() {
        snapshot = nil
        hasSelected = false
    }
}

struct RootView: View {
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore
    @EnvironmentObject private var adminSession: AdminSessionStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @EnvironmentObject private var pushNotifications: PushNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: AppTab
    @State private var portfolioPath: [Portfolio] = []
    @State private var launchPosterSnapshot: LaunchPosterContent?
    @State private var coldLaunchPosterSelection = ColdLaunchPosterSelectionState()
    @State private var hasPreparedLaunchPoster = false
    @State private var isLaunchPosterVisible = false
    @State private var hasResolvedAccess = false
    @State private var presentsMemberAccess = false
    @State private var presentsStartupNotificationIntro = false
    @State private var hasPreparedAuthorizedContent = false
    @State private var authorizedContentPreparationID: UUID?
    @State private var approvedContentRefreshID = UUID()
    private let visualPortfolioTitle: String?
    private let visualTestingDestination: VisualTestingDestination?

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let prefix = "-visual-portfolio-title="
        let title = arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        visualPortfolioTitle = title
#else
        visualPortfolioTitle = nil
#endif
        let destination: VisualTestingDestination?
#if DEBUG
        if arguments.contains("-open-fan-administrator-for-testing") {
            destination = .fanAdministrator
        } else if arguments.contains("-open-admin-for-visual-testing") {
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
        initialTab = .home
#endif
        _selectedTab = State(initialValue: initialTab)
    }

    private var themedAccessContent: some View {
        Group {
            if !hasResolvedAccess {
                accessResolutionView
            } else if canAccessAppContent {
                authorizedAppContent
            } else {
                PublicExperienceView(onMemberAccess: { presentsMemberAccess = true })
            }
        }
        .tint(usesDarkMediaCanvas ? MediaTheme.gold : AppTheme.gold)
        .onChange(of: usesDarkMediaCanvas, initial: true) { _, visible in
            AppearanceStore.shared.setDarkMediaCanvasVisible(visible)
        }
    }

    var body: some View {
        themedAccessContent
        .task { await restoreAccess() }
        .fullScreenCover(isPresented: $presentsMemberAccess) {
            SecureCaptureSurface(owner: .fullScreenPresentation, onExit: { presentsMemberAccess = false }) {
                AppAccessGateView(onClose: { presentsMemberAccess = false })
            }
        }
        .onChange(of: canAccessAppContent) { _, approved in
            if approved { presentsMemberAccess = false }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !presentsStartupNotificationIntro else { return }
            Task {
                if await pushNotifications.needsStartupAuthorization() {
                    presentsStartupNotificationIntro = true
                }
            }
        }
        // One action only: the explanation always leads to the system prompt,
        // which remains the user's real allow/deny choice.
        .alert("开启通知，福利不错过", isPresented: $presentsStartupNotificationIntro) {
            Button("继续") {
                // The system permission alert makes the scene inactive. This task
                // must survive that transition to retain the user's answer.
                Task { await pushNotifications.requestStartupAuthorizationIfNeeded() }
            }
        } message: {
            Text("开启后，我们会根据你的账号推送专属福利、活动预告、作品上新和审批结果。不想接收时，可随时在系统设置中关闭。")
        }
        .task(id: "\(fanAccount.profile?.status ?? "none"):\(fanAccount.profile?.requiresAccountSetup == true)") {
            await monitorApprovedAccess()
        }
        .task(id: pushSynchronizationTaskID) {
            await pushNotifications.synchronize(with: fanAccount)
        }
        .task(id: "\(fanAccount.notificationContext?.userID ?? "none"):\(fanAccount.pushSessionGeneration):\(pushNotifications.notificationReceiptGeneration)") {
            await fanAccount.notificationStore.refresh(using: fanAccount)
        }
        .fullScreenCover(item: Binding(
            get: { fanAccount.notificationContext == nil ? nil : pushNotifications.pendingNotification },
            set: { if $0 == nil { pushNotifications.clearPendingNotification() } }
        )) { pending in
            SecureCaptureSurface(owner: .fullScreenPresentation, onExit: {
                pushNotifications.clearPendingNotification()
            }) {
                AppNavigationStack {
                    FanNotificationInboxView(
                        inbox: fanAccount.notificationStore,
                        initialNotificationID: pending.id
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { pushNotifications.clearPendingNotification() }
                                .accessibilityIdentifier("fan-notification-presentation-close")
                        }
                    }
                }
                .environmentObject(fanAccount)
            }
        }
        .task {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-notification-inbox-ui-fixture") {
                pushNotifications.receiveNotification(
                    userInfo: ["notificationID": FanNotificationUITestFixture.message.id], opened: true
                )
            }
#endif
        }
        .confirmationDialog(
            "接收重要通知？",
            isPresented: Binding(
                get: {
                    hasResolvedAccess && !isLaunchPosterVisible
                        && !presentsStartupNotificationIntro
                        && pushNotifications.shouldPresentAuthorizationRationale
                },
                set: { presented in
                    if !presented { pushNotifications.dismissAuthorizationRationale() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("开启通知") {
                Task {
                    await pushNotifications.requestAuthorizationAfterRationale(for: fanAccount)
                }
            }
            Button("暂不启用", role: .cancel) {
                Task {
                    await pushNotifications.setNotificationsEnabled(false, for: fanAccount)
                }
            }
        } message: {
            Text("用于接收账号审批、合作进度和作品动态。通知是可选功能，不影响浏览；之后可在账号页随时关闭。")
        }
        .onChange(of: portfolioStore.portfolios) { _, portfolios in
            recentlyViewed.retainAvailablePortfolios(in: portfolios)
        }
        .onChange(of: fanAccount.profile?.userID, initial: true) { oldUserID, userID in
            if PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: oldUserID,
                currentUserID: userID
            ) {
                resetProtectedPresentation()
                pushNotifications.accountContextDidChange(to: fanAccount.pushEligibleUserID)
            }
            switchLocalLibrary(to: userID)
            if userID != nil, fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            }
        }
        .onChange(of: fanAccount.removedAccountUserID, initial: true) { _, userID in
            guard let userID else { return }
            favorites.removeData(for: userID)
            recentlyViewed.removeData(for: userID)
        }
        .onChange(of: fanAccount.confirmedDeletedAccountUserID, initial: true) { _, userID in
            guard let userID else { return }
            pushNotifications.removePreferenceForDeletedAccount(userID)
        }
        .onChange(of: fanAccount.profile?.status) { _, status in
            if fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            } else if !adminSession.isIndependentAdministrator {
                resetProtectedPresentation()
            }
        }
        .onChange(of: fanAccount.profile?.requiresAccountSetup) { _, requiresSetup in
            if requiresSetup == true, !adminSession.isIndependentAdministrator {
                resetProtectedPresentation()
            } else if fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            }
        }
        .onChange(of: fanAccount.appleCredentialAccessState) { _, state in
            if fanAccount.isApproved || shouldBypassAccessGate {
                Task { await prepareAuthorizedContentIfNeeded() }
            } else if state != .notRequired, !adminSession.isIndependentAdministrator {
                resetProtectedPresentation()
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                Task { await ArtworkImagePrefetcher.purgeMemory() }
                adminSession.lock()
                fanAccount.pauseAppleCredentialRetry()
                return
            }
            if fanAccount.clearExpiredSessionIfNeeded() {
                resetProtectedPresentation()
                return
            }
            Task { await fanAccount.notificationStore.refresh(using: fanAccount) }
            Task {
                await fanAccount.revalidateAppleCredentialIfNeeded(resetRetrySchedule: true)
                await pushNotifications.synchronize(with: fanAccount)
                guard fanAccount.isApproved || shouldBypassAccessGate else {
                    resetProtectedPresentation()
                    return
                }
                await fanAccount.refreshIfNeeded(minimumInterval: 0)
                if fanAccount.isApproved { await refreshApprovedContent() }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            )
        ) { _ in
            fanAccount.handleAppleCredentialRevoked()
            resetProtectedPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await ArtworkImagePrefetcher.purgeMemory() }
        }
    }

    private var pushSynchronizationTaskID: PushSynchronizationTaskID {
        PushSynchronizationTaskID(
            userID: fanAccount.pushEligibleUserID,
            fanSessionGeneration: fanAccount.pushSessionGeneration,
            deviceRegistrationGeneration: pushNotifications.registrationGeneration,
            canUnbindPushDevice: fanAccount.hasPushUnbindingSession,
            appleCredentialAccessState: fanAccount.appleCredentialAccessState,
            environment: fanAccount.serviceEnvironment
        )
    }

    private var usesDarkMediaCanvas: Bool {
        hasResolvedAccess && canAccessAppContent && (isLaunchPosterVisible || resolvedTab == .home)
    }

    private var resolvedTab: AppTab {
        selectedTab.resolved(canViewVideo: canViewVideo)
    }

    private var visibleTabSelection: Binding<AppTab> {
        // iOS 27 validates selection while reconciling TabView. An onChange
        // repair alone runs too late if permissions remove the selected tab.
        Binding(
            get: { resolvedTab },
            set: { selectedTab = $0.resolved(canViewVideo: canViewVideo) }
        )
    }

    private var authorizedAppContent: some View {
        ZStack {
            TabView(selection: visibleTabSelection) {
                HomeView(showPortfolio: { selectedTab = .portfolio })
                    .tag(AppTab.home)
                    .tabItem { Label("首页", systemImage: "house") }

                NavigationStack(path: $portfolioPath) {
                    PortfolioGridView()
                        .themeNavigationChrome()
                }
                .background { AppTheme.ink.ignoresSafeArea(.container) }
                .themeNavigationChrome()
                .tag(AppTab.portfolio)
                .tabItem { Label("作品", systemImage: "square.grid.2x2") }

                if canViewVideo {
                    AppNavigationStack {
                        CreditsView()
                    }
                    .tag(AppTab.credits)
                    .tabItem { Label("影视", systemImage: "film.stack") }
                }

                AppNavigationStack {
                    FavoritesView(showPortfolio: { selectedTab = .portfolio })
                }
                .tag(AppTab.favorites)
                .tabItem { Label("收藏", systemImage: "heart") }

                AppNavigationStack {
                    visualAboutContent
                }
                .tag(AppTab.about)
                .tabItem { Label("关于", systemImage: "person.crop.rectangle") }
            }
            .themeNavigationChrome()
            if !hasPreparedLaunchPoster {
                AppTheme.ink
                    .ignoresSafeArea()
                    .zIndex(19_999)
            } else if isLaunchPosterVisible, let poster = displayedLaunchPoster {
                LaunchPosterView(poster: poster) {
                    if reduceMotion {
                        isLaunchPosterVisible = false
                    } else {
                        withAnimation(.easeOut(duration: 0.35)) {
                            isLaunchPosterVisible = false
                        }
                    }
                }
                .id(poster)
                .transition(reduceMotion ? .identity : .opacity)
                .zIndex(20_000)
            }
        }
    }

    private var accessResolutionView: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.title.weight(.regular))
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
        case .fanAdministrator:
            FanAdministratorBindingTestScreen()
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

    private func prepareLaunchPosterIfNeeded(hasFreshContent: Bool) {
        guard !hasPreparedLaunchPoster else { return }
        if shouldSkipLaunchPoster || (!hasFreshContent && !shouldBypassAccessGate) {
            launchPosterSnapshot = nil
            isLaunchPosterVisible = false
            hasPreparedLaunchPoster = true
            return
        }
        if !coldLaunchPosterSelection.hasSelected {
            coldLaunchPosterSelection.record(
                portfolioStore.selectLaunchPosterForColdLaunch(
                    allowsBundledPreview: shouldBypassAccessGate
                )
            )
        }
        launchPosterSnapshot = coldLaunchPosterSelection.snapshot
        isLaunchPosterVisible = launchPosterSnapshot != nil
        hasPreparedLaunchPoster = true
    }

    private func restoreAccess() async {
        await fanAccount.restoreSession()
        await fanAccount.revalidateAppleCredentialIfNeeded(resetRetrySchedule: true)
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
              authorizedContentPreparationID == nil else { return }
        let preparationID = UUID()
        let userID = fanAccount.profile?.userID
        authorizedContentPreparationID = preparationID
        defer {
            if authorizedContentPreparationID == preparationID {
                authorizedContentPreparationID = nil
            }
        }

        enforceCurrentFanPermissionScope()
#if DEBUG
        if shouldBypassAccessGate {
            // UI tests must never inherit a permission-scoped cache written by
            // another test account. Start from the deterministic bundled
            // catalog; production sessions still restore their protected cache.
            portfolioStore.discardProtectedContent()
        } else {
            await portfolioStore.restoreCachedContent(allowVideo: canViewVideo)
        }
#else
        await portfolioStore.restoreCachedContent(allowVideo: canViewVideo)
#endif
        guard authorizedContentPreparationID == preparationID,
              fanAccount.profile?.userID == userID,
              canAccessAppContent, !adminSession.isAuthenticated,
              !Task.isCancelled else { return }
        enforceCurrentFanPermissionScope()
#if DEBUG
        portfolioStore.configureMultiImageGalleryForVisualTestingIfNeeded()
#endif
        // Select AFTER the authenticated refresh, never from the initial cache.
        // The bounded cold-launch request skips the poster on failure; normal
        // catalog retry continues without holding the user on a blank launch.
        let hasFreshContent = fanAccount.isApproved
            ? await refreshApprovedContent(forColdLaunch: true) : false
        guard authorizedContentPreparationID == preparationID,
              fanAccount.profile?.userID == userID,
              canAccessAppContent, !adminSession.isAuthenticated,
              !Task.isCancelled else { return }
        prepareLaunchPosterIfNeeded(hasFreshContent: hasFreshContent)
        hasPreparedAuthorizedContent = true
        recentlyViewed.retainAvailablePortfolios(in: portfolioStore.portfolios)
        if let visualPortfolioTitle,
           let portfolio = portfolioStore.portfolios.first(where: { $0.title == visualPortfolioTitle }) {
            portfolioPath = [portfolio]
        }
        if fanAccount.isApproved, !hasFreshContent { await refreshApprovedContent() }
    }

    @discardableResult
    private func refreshApprovedContent(forColdLaunch: Bool = false) async -> Bool {
        guard forColdLaunch || hasPreparedAuthorizedContent else { return false }
        let refreshID = UUID()
        approvedContentRefreshID = refreshID
        guard fanAccount.isApproved, !adminSession.isAuthenticated else { return false }
        let storeRefreshID = portfolioStore.beginContentRefresh()
        do {
            let manifest: AppContentManifest
            if forColdLaunch {
                manifest = try await LaunchPosterFreshContentLoader.load {
                    try await fanAccount.fetchApprovedContent()
                }
            } else {
                manifest = try await fanAccount.fetchApprovedContent()
            }
            guard approvedContentRefreshID == refreshID,
                  !Task.isCancelled,
                  fanAccount.isApproved,
                  !adminSession.isAuthenticated else {
                portfolioStore.cancelContentRefresh(storeRefreshID)
                return false
            }
            let applied = portfolioStore.completeContentRefresh(storeRefreshID, with: manifest)
            enforceCurrentFanPermissionScope()
            return applied
        } catch {
            guard approvedContentRefreshID == refreshID,
                  fanAccount.isApproved,
                  !adminSession.isAuthenticated else {
                portfolioStore.cancelContentRefresh(storeRefreshID)
                return false
            }
            portfolioStore.failContentRefresh(storeRefreshID)
            return false
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
        authorizedContentPreparationID = nil
        Task { await ArtworkImagePrefetcher.purgeMemory() }
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
        coldLaunchPosterSelection.reset()
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
