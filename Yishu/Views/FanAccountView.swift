import SwiftUI
import UIKit

struct FanAccountView: View {
    @EnvironmentObject private var account: FanAccountStore
    @State private var mode: AuthenticationMode = .register
    @State private var displayName = ""
    @State private var douyinID = ""
    @State private var registrationPassword = ""
    @State private var passwordConfirmation = ""
    @State private var acceptedDataUse = false
    @State private var identityCode = ""
    @State private var loginPassword = ""
    @State private var copiedLabel: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                if let profile = account.profile {
                    profileContent(profile)
                } else {
                    authenticationContent
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("粉丝账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await account.restoreSession() }
        .confirmationDialog(
            "永久删除粉丝账号？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除账号与全部个人资料", role: .destructive) {
                Task { await account.deleteAccount() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("身份码、抖音 ID、权限和服务器账号记录都会被删除，且无法恢复。")
        }
    }

    private var authenticationContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("FAN IDENTITY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text("粉丝身份")
                    .font(.editorial(38))
                    .accessibilityIdentifier("fan-account-heading")
                Text("注册后会生成独立身份码和本机安装记录码，管理员可按账号远程分配权限。")
                    .font(.subheadline)
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.muted)
            }

            Picker("账号操作", selection: $mode) {
                ForEach(AuthenticationMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .register: registrationForm
                case .login: loginForm
                }
            }
            .textFieldStyle(AccountTextFieldStyle())

            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = account.noticeMessage {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-account-notice")
            }

            Label(
                "App 不读取手机硬件 UDID。随机身份 UUID、会话令牌和安装记录均由服务器或本机安全生成，令牌只保存于 Keychain。",
                systemImage: "lock.shield"
            )
            .font(.caption2)
            .lineSpacing(4)
            .foregroundStyle(AppTheme.muted)
        }
        .padding(22)
        .padding(.bottom, 54)
    }

    private var registrationForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("昵称", text: $displayName)
                .textContentType(.nickname)
            TextField("抖音 ID（必填，不要填链接）", text: $douyinID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("fan-register-douyin-id")
            SecureField("设置密码（至少 10 位）", text: $registrationPassword)
                .textContentType(.newPassword)
            SecureField("再输入一次密码", text: $passwordConfirmation)
                .textContentType(.newPassword)

            Text("抖音 ID 只用于管理员核验身份和分配权限，不会在粉丝之间公开。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)

            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("注册前查看隐私政策与删除规则", systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
            }
            .accessibilityIdentifier("fan-register-privacy-policy")

            Toggle(isOn: $acceptedDataUse) {
                Text("我已阅读隐私政策：昵称、抖音 ID、随机身份码和安装记录用于账号识别、安全登录与权限分配，不用于广告跟踪。")
                    .font(.caption)
                    .lineSpacing(4)
            }
            .tint(AppTheme.gold)
            .accessibilityIdentifier("fan-register-consent")

            Button {
                Task {
                    await account.register(
                        displayName: displayName,
                        douyinID: douyinID,
                        password: registrationPassword,
                        passwordConfirmation: passwordConfirmation,
                        acceptedDataUse: acceptedDataUse
                    )
                    if account.isAuthenticated {
                        registrationPassword = ""
                        passwordConfirmation = ""
                    }
                }
            } label: {
                accountButtonLabel(account.isWorking ? "正在创建身份" : "注册并生成身份码")
            }
            .disabled(account.isWorking || !acceptedDataUse)
            .accessibilityIdentifier("fan-register-submit")
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("身份码，例如 HS-ABCD-2345", text: $identityCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField("密码", text: $loginPassword)
                .textContentType(.password)

            Button {
                Task {
                    await account.signIn(identityCode: identityCode, password: loginPassword)
                    if account.isAuthenticated { loginPassword = "" }
                }
            } label: {
                accountButtonLabel(account.isWorking ? "正在验证" : "登录粉丝账号")
            }
            .disabled(account.isWorking)
            .accessibilityIdentifier("fan-login-submit")
        }
    }

    private func profileContent(_ profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 9) {
                Text("VERIFIED FAN")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text("你好，\(profile.displayName)")
                    .font(.editorial(38))
                    .accessibilityIdentifier("fan-account-heading")
                Label(
                    profile.status == "active" ? "账号身份已建立" : "账号功能已暂停，仍可管理或删除资料",
                    systemImage: profile.status == "active"
                        ? "checkmark.seal.fill" : "exclamationmark.shield.fill"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(profile.status == "active" ? AppTheme.gold : .orange)
            }

            VStack(spacing: 0) {
                identityRow("粉丝身份码", value: profile.identityCode, copyable: true)
                Divider().overlay(.white.opacity(0.08))
                identityRow("抖音 ID", value: profile.douyinID, copyable: false)
                Divider().overlay(.white.opacity(0.08))
                identityRow("本机安装码", value: profile.installationCode, copyable: true)
                Divider().overlay(.white.opacity(0.08))
                identityRow("身份记录 UUID", value: profile.userID, copyable: true)
            }
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("已授予权限")
                        .font(.editorial(26))
                    Spacer()
                    Text("\(profile.permissions.count) 项")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                ForEach(FanPermission.allCases) { permission in
                    HStack(spacing: 12) {
                        Image(systemName: profile.hasPermission(permission)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.hasPermission(permission)
                                             ? AppTheme.gold : AppTheme.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.subheadline.weight(.semibold))
                            Text(permission.detail).font(.caption2).foregroundStyle(AppTheme.muted)
                        }
                        Spacer()
                    }
                }
            }

            if let copiedLabel {
                Label("已复制\(copiedLabel)", systemImage: "doc.on.doc.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.gold)
            }

            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await account.refreshSession() }
                } label: {
                    Label("刷新权限", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                }
                .disabled(account.isWorking)

                Button {
                    Task { await account.signOut() }
                } label: {
                    Text("退出登录")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(AppTheme.ink)
                }
                .disabled(account.isWorking)
            }

            Text("请妥善保存身份码。管理员只能看到昵称、抖音 ID、身份码和权限，无法查看你的密码。")
                .font(.caption2)
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)

            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("隐私政策与数据删除说明", systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("永久删除账号与个人资料", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .disabled(account.isWorking)
            .accessibilityIdentifier("fan-delete-account")
        }
        .padding(22)
        .padding(.bottom, 54)
    }

    private func identityRow(_ title: String, value: String, copyable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(AppTheme.muted)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if copyable {
                Button {
                    UIPasteboard.general.string = value
                    copiedLabel = title
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("复制\(title)")
            }
        }
        .padding(15)
    }

    private func accountButtonLabel(_ title: String) -> some View {
        HStack(spacing: 9) {
            if account.isWorking { ProgressView().tint(AppTheme.ink) }
            Text(title)
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(AppTheme.ink)
    }
}

struct FanAccessAdminView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @State private var directory: AdminFanDirectory?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredUsers: [AdminFanUser] {
        guard let users = directory?.users else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return users }
        return users.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.identityCode.localizedCaseInsensitiveContains(query)
                || $0.douyinID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("只可分配 App 粉丝权限或暂停已授予功能；粉丝密码不会在后台显示。")
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)
                        .padding(.bottom, 4)

                    if isLoading, directory == nil {
                        ProgressView("正在读取用户")
                            .tint(AppTheme.gold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                    } else if filteredUsers.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "还没有注册用户" : "没有匹配的用户",
                            systemImage: "person.2.slash"
                        )
                        .foregroundStyle(AppTheme.warmWhite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        ForEach(filteredUsers) { user in
                            NavigationLink {
                                FanAccessDetailView(
                                    user: user,
                                    catalog: directory?.permissionCatalog ?? []
                                ) { updated in
                                    replace(updated)
                                }
                            } label: {
                                FanAdminUserRow(user: user)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(18)
                .padding(.bottom, 40)
            }
            .refreshable { await load() }
        }
        .navigationTitle("用户权限")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .searchable(text: $searchText, prompt: "昵称、抖音 ID 或身份码")
        .task { await load() }
    }

    private func load() async {
        guard admin.isAuthenticated else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            directory = try await admin.fetchFanDirectory()
            errorMessage = nil
        } catch {
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "暂时无法读取用户。"
        }
    }

    private func replace(_ updated: AdminFanUser) {
        guard let current = directory,
              let index = current.users.firstIndex(where: { $0.id == updated.id }) else { return }
        var users = current.users
        users[index] = updated
        directory = AdminFanDirectory(users: users, permissionCatalog: current.permissionCatalog)
    }
}

private struct FanAccessDetailView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @State private var user: AdminFanUser
    @State private var isSaving = false
    @State private var errorMessage: String?
    let catalog: [AdminFanPermissionDefinition]
    let onUpdate: (AdminFanUser) -> Void

    init(
        user: AdminFanUser,
        catalog: [AdminFanPermissionDefinition],
        onUpdate: @escaping (AdminFanUser) -> Void
    ) {
        _user = State(initialValue: user)
        self.catalog = catalog
        self.onUpdate = onUpdate
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(user.displayName).font(.editorial(36))
                        Text("@\(user.douyinID)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.gold)
                        Text(user.identityCode)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(AppTheme.muted)
                        Text("注册于 \(user.registeredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("账号状态").font(.editorial(25))
                        Toggle("允许使用已授予功能", isOn: Binding(
                            get: { user.status == "active" },
                            set: { enabled in
                                Task { await save(status: enabled ? "active" : "suspended") }
                            }
                        ))
                        .tint(AppTheme.gold)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        Text("功能权限").font(.editorial(25))
                        ForEach(catalog) { permission in
                            Toggle(isOn: permissionBinding(permission.code)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(permission.title).font(.subheadline.weight(.semibold))
                                    Text(permission.description)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                            }
                            .tint(AppTheme.gold)
                        }
                    }

                    if isSaving {
                        Label("正在远程更新", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(AppTheme.gold)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("权限保存后立即在服务器生效。用户下次启动 App，或在粉丝账号页点击“刷新权限”后获取新状态。")
                        .font(.caption2)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)

                    Text("暂停会立即撤销现有会话并停用所有功能权限，但用户仍可用身份码与密码进入账号管理并主动删除个人资料。")
                        .font(.caption2)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)
                }
                .padding(20)
                .padding(.bottom, 44)
            }
        }
        .navigationTitle("分配权限")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .disabled(isSaving)
    }

    private func permissionBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { user.permissions.contains(code) },
            set: { enabled in
                var permissions = Set(user.permissions)
                if enabled { permissions.insert(code) } else { permissions.remove(code) }
                Task { await save(permissions: Array(permissions).sorted()) }
            }
        )
    }

    private func save(permissions: [String]? = nil, status: String? = nil) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await admin.updateFanAccess(
                userID: user.userID,
                permissions: permissions ?? user.permissions,
                status: status ?? user.status
            )
            user = updated
            onUpdate(updated)
            errorMessage = nil
        } catch {
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "权限更新失败。"
        }
    }
}

private struct FanAdminUserRow: View {
    let user: AdminFanUser

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: user.status == "active" ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                .font(.system(size: 27))
                .foregroundStyle(user.status == "active" ? AppTheme.gold : .orange)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(user.displayName).font(.subheadline.weight(.semibold))
                    Text("\(user.permissions.count) 项权限")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.gold)
                }
                Text("@\(user.douyinID) · \(user.identityCode)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(14)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 7))
    }
}

private enum AuthenticationMode: String, CaseIterable, Identifiable {
    case register
    case login

    var id: String { rawValue }
    var title: String { self == .register ? "注册" : "登录" }
}

private struct AccountTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            }
    }
}
