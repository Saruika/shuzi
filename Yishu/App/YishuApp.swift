import SwiftUI

@main
struct YishuApp: App {
    @UIApplicationDelegateAdaptor(YishuApplicationDelegate.self) private var applicationDelegate
    @StateObject private var workspaces = AppWorkspaceCoordinator(
        environment: AppWorkspaceSelection.restore(),
        didSelect: { AppWorkspaceSelection.save($0) }
    ) {
        AppServiceWorkspace(environment: $0)
    }

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
    }

    var body: some Scene {
        WindowGroup {
            SecureCaptureSurface(owner: .appRoot) {
                appContent
#if DEBUG
                    .overlay(alignment: .bottom) {
                        if ProcessInfo.processInfo.arguments.contains("-workspace-switch-for-testing") {
                            workspaceTestControls
                        }
                    }
#endif
            }
            .environment(\.appServiceEnvironment, workspaces.current.serviceEnvironment)
            .preferredColorScheme(AppearanceStore.shared.systemColorScheme)
        }
    }

#if DEBUG
    private var workspaceTestControls: some View {
        HStack {
            Text(workspaces.current.serviceEnvironment.rawValue)
                .accessibilityIdentifier("workspace-test-environment")
            Button("测试切换演示") { Task { await workspaces.switchEnvironment(to: .review) } }
                .accessibilityIdentifier("workspace-test-review")
            Button("测试切换正式") { Task { await workspaces.switchEnvironment(to: .production) } }
                .accessibilityIdentifier("workspace-test-production")
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial)
        .disabled(workspaces.isSwitching)
    }
#endif

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

    @ViewBuilder
    private var configuredRoot: some View {
        if workspaces.isSwitching {
            ZStack {
                AppTheme.ink.ignoresSafeArea()
                ProgressView("正在切换环境…")
                    .foregroundStyle(AppTheme.warmWhite)
            }
        } else {
            let workspace = workspaces.current
            RootView()
                .id(ObjectIdentifier(workspace))
                .environment(\.appServiceEnvironment, workspace.serviceEnvironment)
                .environmentObject(workspace.portfolioStore)
                .environmentObject(workspace.favorites)
                .environmentObject(workspace.recentlyViewed)
                .environmentObject(workspace.adminSession)
                .environmentObject(workspace.fanAccount)
                .environmentObject(workspace.pushNotifications)
                .environmentObject(workspaces)
        }
    }
}
