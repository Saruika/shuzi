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
    private let didSelect: (AppServiceEnvironment) -> Void

    init(environment: AppServiceEnvironment = .production,
         didSelect: @escaping (AppServiceEnvironment) -> Void = { _ in },
         makeWorkspace: @escaping (AppServiceEnvironment) -> Workspace) {
        self.makeWorkspace = makeWorkspace
        self.didSelect = didSelect
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
        didSelect(environment)
        isSwitching = false
        return true
    }
}

/// Only an explicit local selection is persisted. Invalid values fail back to
/// production; a remote payload or an account's identity never selects a backend.
enum AppWorkspaceSelection {
    static let key = "app-service-environment"

    static func restore(from defaults: UserDefaults = .standard) -> AppServiceEnvironment {
        AppServiceEnvironment(rawValue: defaults.string(forKey: key) ?? "") ?? .production
    }

    static func save(_ environment: AppServiceEnvironment, to defaults: UserDefaults = .standard) {
        defaults.set(environment.rawValue, forKey: key)
    }
}

struct AppWorkspaceSelectionView: View {
    @EnvironmentObject private var workspaces: AppWorkspaceCoordinator<AppServiceWorkspace>
    @State private var pendingSelection: AppServiceEnvironment?

    var body: some View {
        Form {
            Section {
                ForEach(AppServiceEnvironment.allCases, id: \.self) { environment in
                    Button {
                        guard environment != workspaces.current.serviceEnvironment else { return }
                        pendingSelection = environment
                    } label: {
                        HStack {
                            Text(environment.displayName)
                            Spacer()
                            if environment == workspaces.current.serviceEnvironment {
                                Image(systemName: "checkmark")
                            }
                        }
                        .foregroundStyle(AppTheme.warmWhite)
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("workspace-select-\(environment.rawValue)")
                    .accessibilityValue(environment == workspaces.current.serviceEnvironment ? "当前环境" : "未选择")
                }
            } header: {
                Text("服务环境")
            } footer: {
                Text("正式环境用于日常使用。演示环境使用独立账号与演示资料，不会修改正式用户或作品；两边均需注册、审批和正常登录。")
            }
            .listRowBackground(AppTheme.elevatedInk)
            Section {
                Text("切换会退出当前环境的账号、关闭正在编辑的页面，并清除内存中的图片。未保存的修改不会保留，请先完成编辑。此选择会保存在本机，可随时在登录页或设置页切换回来。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.muted)
            }
            .listRowBackground(AppTheme.elevatedInk)
        }
        .disabled(workspaces.isSwitching)
        .scrollContentBackground(.hidden)
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("服务环境")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .stableDetailTabBar()
        .accessibilityIdentifier("workspace-selection")
        .alert("退出当前账号并切换环境？", isPresented: Binding(
            get: { pendingSelection != nil },
            set: { if !$0 { pendingSelection = nil } }
        )) {
            if let selection = pendingSelection {
                Button("切换至\(selection.displayName)") {
                    pendingSelection = nil
                    Task { await workspaces.switchEnvironment(to: selection) }
                }
            }
            Button("取消", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("未保存的编辑将丢失。切换不会删除账号，也不会转移身份码、权限或个人资料。")
        }
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
