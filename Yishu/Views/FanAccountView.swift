import AuthenticationServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FanAppleRegistrationDraft: Equatable {
    var displayName = ""
    var douyinID = ""
    var acceptedDataUse = false

    mutating func clear() {
        self = FanAppleRegistrationDraft()
    }
}

struct AppAccessGateView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var store: PortfolioStore
    @State private var presentsAdminAccess = false

    var body: some View {
        NavigationStack {
            FanAccountView(
                isAccessGate: true,
                externalAdminAccessPresented: presentsAdminAccess
            )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentsAdminAccess = true
                        } label: {
                            Label("管理员", systemImage: "person.badge.key.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .accessibilityIdentifier("access-gate-admin-entry")
                    }
                }
        }
        .fullScreenCover(isPresented: $presentsAdminAccess) {
            protectedAdminAccess
        }
    }

    private var protectedAdminAccess: some View {
        SecureCaptureSurface(
            owner: .fullScreenPresentation,
            onExit: { presentsAdminAccess = false }
        ) {
            AdminAccessView(onClose: { presentsAdminAccess = false })
                .environmentObject(admin)
                .environmentObject(store)
        }
    }
}

struct FanAccountView: View {
    @EnvironmentObject private var account: FanAccountStore
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var pushNotifications: PushNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    let isAccessGate: Bool
    let externalAdminAccessPresented: Bool
    @State private var mode: AuthenticationMode = .register
    @State private var displayName = ""
    @State private var douyinID = ""
    @State private var registrationPassword = ""
    @State private var passwordConfirmation = ""
    @State private var acceptedDataUse = false
    @State private var identityCode = ""
    @State private var loginPassword = ""
    @State private var invitedDisplayName = ""
    @State private var invitedDouyinID = ""
    @State private var currentTemporaryPassword = ""
    @State private var invitedNewPassword = ""
    @State private var invitedPasswordConfirmation = ""
    @State private var acceptedInvitationDataUse = false
    @State private var profileUpgradeDouyinID = ""
    @State private var profileUpgradeCurrentPassword = ""
    @State private var acceptedProfileUpgradeDataUse = false
    @State private var recoveryTemporaryPassword = ""
    @State private var recoveryNewPassword = ""
    @State private var recoveryPasswordConfirmation = ""
    @State private var copiedLabel: String?
    @State private var showDeleteConfirmation = false
    @State private var deleteCurrentPassword = ""
    @State private var presentsAdminAccess = false
    @StateObject private var appleSignIn = AppleSignInCoordinator()
    @State private var appleRegistrationDraft = FanAppleRegistrationDraft()
    @State private var needsAppleRegistrationRestore = false
    @State private var showAppleDeleteConfirmation = false

    init(
        isAccessGate: Bool = false,
        externalAdminAccessPresented: Bool = false
    ) {
        self.isAccessGate = isAccessGate
        self.externalAdminAccessPresented = externalAdminAccessPresented
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                Group {
                    if let profile = account.profile {
                        profileContent(profile)
                    } else if account.appleRegistration != nil {
                        appleRegistrationContent
                    } else {
                        authenticationContent
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("fan-account-scroll")
        }
        .navigationTitle(isAccessGate ? "访问申请" : "粉丝账号")
        .navigationBarTitleDisplayMode(.inline)
        .themeNavigationChrome()
        .toolbar(.hidden, for: .tabBar)
        .task { await account.restoreSession() }
        .onAppear {
            if account.appleRegistration != nil {
                prepareAppleRegistrationFields(for: account.appleRegistration)
            }
        }
        .task(id: "\(account.profile?.status ?? "none"):\(account.profile?.requiresAccountSetup == true)") {
            await monitorPendingApproval()
        }
        .onChange(of: account.profile?.userID) { oldUserID, newUserID in
            guard oldUserID != newUserID else { return }
            clearAuthenticationPasswords()
            clearInvitationSetupFields()
            clearDouyinProfileUpgradeFields()
            clearAppleRegistrationFields()
            deleteCurrentPassword = ""
            copiedLabel = nil
        }
        .onChange(of: account.appleRegistration) { _, registration in
            prepareAppleRegistrationFields(for: registration)
        }
        .onChange(of: account.profile?.requiresAccountSetup) { _, requiresSetup in
            if requiresSetup != true { clearInvitationSetupFields() }
        }
        .onChange(of: account.profile?.requiresPasswordChange) { _, requiresChange in
            if requiresChange != true { clearRecoveryPasswords() }
        }
        .onChange(of: mode) { _, _ in
            clearAuthenticationPasswords()
        }
        .onChange(of: scenePhase) { _, phase in
            appleSignIn.scenePhaseDidChange(to: phase)
            if phase != .active {
                clearAllPasswords()
                profileUpgradeCurrentPassword = ""
            }
            if phase == .background {
                clearAppleRegistrationFields()
                needsAppleRegistrationRestore = true
            } else if phase == .active, needsAppleRegistrationRestore {
                needsAppleRegistrationRestore = false
                prepareAppleRegistrationFields(for: account.appleRegistration)
            }
        }
        .onChange(of: account.isAuthenticated) { _, authenticated in
            if !authenticated {
                clearAllPasswords()
                clearAppleRegistrationFields()
            }
        }
        .onChange(of: presentsAdminAccess) { _, presented in
            if presented { clearAllPasswords() }
        }
        .onChange(of: externalAdminAccessPresented) { _, presented in
            if presented { clearAllPasswords() }
        }
        .alert(
            "永久删除粉丝账号？",
            isPresented: $showDeleteConfirmation
        ) {
            SecureField("当前密码", text: $deleteCurrentPassword)
                .textContentType(.password)
            Button("删除账号与全部个人资料", role: .destructive) {
                let password = deleteCurrentPassword
                deleteCurrentPassword = ""
                pushNotifications.accountContextDidChange(to: nil)
                Task {
                    await account.deleteAccount(currentPassword: password)
                    if account.isAuthenticated {
                        await pushNotifications.synchronize(with: account)
                    }
                }
            }
            .disabled(deleteCurrentPassword.isEmpty)
            Button("取消", role: .cancel) { deleteCurrentPassword = "" }
        } message: {
            Text("请重新输入当前密码。身份码、已填写的抖音 ID、权限和服务器账号记录都会被删除，且无法恢复。")
        }
        .alert("通过 Apple 重新验证并删除账号？", isPresented: $showAppleDeleteConfirmation) {
            Button("继续 Apple 验证", role: .destructive) {
                beginAppleAuthorization(
                    purpose: .deleteAccount,
                    presentationAnchor: currentPresentationWindow
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("验证通过后，身份码、已填写的抖音 ID、权限和服务器账号记录都会被永久删除。")
        }
        .fullScreenCover(isPresented: $presentsAdminAccess) {
            SecureCaptureSurface(
                owner: .fullScreenPresentation,
                onExit: { presentsAdminAccess = false }
            ) {
                AdminAccessView(onClose: { presentsAdminAccess = false })
                    .environmentObject(admin)
                    .environmentObject(store)
            }
        }
    }

    private var authenticationContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text(isAccessGate ? "MEMBER ACCESS" : "FAN IDENTITY")
                    .font(.caption2.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text(isAccessGate ? "申请访问" : "粉丝身份")
                    .font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("fan-account-heading")
                    .accessibilityAddTraits(.isHeader)
                Text(isAccessGate
                     ? "请先注册并提交申请。管理员审批通过后，才能进入首页、作品、影视、收藏和关于页面。"
                     : "注册后会生成独立身份码和本机安装记录码，管理员可按账号远程分配权限。")
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

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Rectangle().fill(AppTheme.line).frame(height: 1)
                    Text("或").font(.caption).foregroundStyle(AppTheme.muted)
                    Rectangle().fill(AppTheme.line).frame(height: 1)
                }

                NativeAppleSignInButton { window in
                    beginAppleAuthorization(purpose: .signIn, presentationAnchor: window)
                }
                .frame(height: 50)
                .disabled(account.isWorking || appleSignIn.isWorking)
                .opacity(account.isWorking || appleSignIn.isWorking ? 0.55 : 1)

                Text("首次通过 Apple 验证后，仍需填写昵称和抖音 ID 并提交申请。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)

                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Text("使用 Apple 登录前查看隐私政策")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.gold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fan-apple-prelogin-privacy")
            }

            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
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

            if account.hasSavedSession, account.profile == nil {
                Button {
                    Task { await account.restoreSession() }
                } label: {
                    Label("重新验证已保存的登录", systemImage: "arrow.clockwise.shield")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(account.isWorking)
            }

            if isAccessGate {
                Button {
                    presentsAdminAccess = true
                } label: {
                    Label("管理员审批入口", systemImage: "person.badge.key")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("access-gate-admin-link")
            }
        }
        .padding(22)
        .padding(.bottom, 54)
    }

    private var appleRegistrationContent: some View {
        let registration = account.appleRegistration
        let isMigration = registration?.isDouyinMigration == true
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("APPLE ID VERIFIED")
                    .font(.caption2.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text(isMigration ? "补全抖音 ID" : "完成账号申请")
                    .font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("fan-apple-registration-required")
                    .accessibilityAddTraits(.isHeader)
                Text(appleRegistrationExplanation(registration))
                    .font(.subheadline)
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.muted)
            }

            VStack(alignment: .leading, spacing: 13) {
                TextField("昵称", text: $appleRegistrationDraft.displayName)
                    .textContentType(.nickname)
                    .accessibilityLabel("昵称")
                    .accessibilityIdentifier("fan-apple-display-name")
                TextField("抖音 ID（必填，不要填链接）", text: $appleRegistrationDraft.douyinID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("抖音 ID，必填，请不要填写链接")
                    .accessibilityIdentifier("fan-apple-douyin-id")

                Text("抖音 ID 是账号申请的必填资料，仅用于管理员核验身份，不会向其他粉丝公开。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)

                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("申请前查看隐私政策与删除规则", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.gold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fan-apple-privacy-policy")

                ThemePreferenceRow()

                Toggle(isOn: $appleRegistrationDraft.acceptedDataUse) {
                    Text("我已阅读隐私政策：昵称、抖音 ID、随机身份码和安装记录用于账号识别、管理员核验、安全登录与权限分配。")
                        .font(.caption)
                        .lineSpacing(4)
                }
                .tint(AppTheme.gold)
                .accessibilityIdentifier("fan-apple-consent")

                Button {
                    Task {
                        await account.completeAppleRegistration(
                            displayName: appleRegistrationDraft.displayName,
                            douyinID: appleRegistrationDraft.douyinID,
                            acceptedDataUse: appleRegistrationDraft.acceptedDataUse
                        )
                        if account.appleRegistration == nil {
                            clearAppleRegistrationFields()
                        }
                    }
                } label: {
                    accountButtonLabel(
                        account.isWorking
                            ? "正在提交"
                            : (isMigration ? "同意并补全资料" : "同意并提交审批")
                    )
                }
                .disabled(account.isWorking || !appleRegistrationDraft.acceptedDataUse)
                .accessibilityIdentifier("fan-apple-registration-submit")
            }
            .textFieldStyle(AccountTextFieldStyle())

            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Button {
                clearAppleRegistrationFields()
                pushNotifications.accountContextDidChange(to: nil)
                Task { await account.signOut() }
            } label: {
                Text("退出登录")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
            }
            .disabled(account.isWorking)

            Button(role: .destructive) {
                showAppleDeleteConfirmation = true
            } label: {
                Label(isMigration ? "永久删除账号" : "永久删除账号申请", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .disabled(account.isWorking || appleSignIn.isWorking)
            .accessibilityIdentifier("fan-apple-delete-onboarding")
        }
        .padding(22)
        .padding(.bottom, 54)
    }

    private var registrationForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("昵称", text: $displayName)
                .textContentType(.nickname)
                .accessibilityLabel("昵称")
                .accessibilityIdentifier("fan-register-display-name")
            TextField("抖音 ID（必填，不要填链接）", text: $douyinID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("抖音 ID，必填，请不要填写链接")
                .accessibilityIdentifier("fan-register-douyin-id")
            SecureField("设置密码（至少 10 位）", text: $registrationPassword)
                .textContentType(.newPassword)
                .accessibilityLabel("设置密码，至少 10 位")
            SecureField("再输入一次密码", text: $passwordConfirmation)
                .textContentType(.newPassword)
                .accessibilityLabel("确认密码")

            Text("抖音 ID 必须填写，仅用于管理员核验身份，不会向其他粉丝公开。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)

            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("注册前查看隐私政策与删除规则", systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fan-register-privacy-policy")

            ThemePreferenceRow()

            Toggle(isOn: $acceptedDataUse) {
                Text("我已阅读隐私政策：昵称、抖音 ID、随机身份码和安装记录用于账号识别、管理员核验、安全登录与权限分配。上述资料不用于广告跟踪。")
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
                accountButtonLabel(account.isWorking ? "正在提交申请" : "注册并提交审批")
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
                .accessibilityLabel("粉丝身份码")
                .accessibilityHint("格式示例，HS-ABCD-2345")
            SecureField("密码", text: $loginPassword)
                .textContentType(.password)
                .accessibilityLabel("密码")

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
        let requiresDouyinCompletion = !profile.requiresAccountSetup
            && !profile.hasRequiredDouyinID
        return VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 9) {
                Text(profile.requiresAccountSetup
                     ? "SECURE ACCOUNT SETUP"
                     : (profile.requiresPasswordChange
                        ? "PASSWORD RECOVERY"
                        : (requiresDouyinCompletion
                            ? "IDENTITY UPDATE REQUIRED"
                            : (profile.status == FanAccountStatus.active.rawValue
                                ? "APPROVED MEMBER" : "ACCESS REVIEW"))))
                    .font(.caption2.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(AppTheme.gold)
                Text(profileHeading(profile))
                    .font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("fan-account-heading")
                    .accessibilityAddTraits(.isHeader)
                Label(
                    profile.requiresAccountSetup
                        ? "完成本人设置前不会开放 App 内容"
                        : (profile.requiresPasswordChange
                            ? "请先设置一个只有你知道的新密码"
                            : (requiresDouyinCompletion
                                ? "请先补全抖音 ID，内容访问已暂停"
                                : statusTitle(profile.status))),
                    systemImage: profile.requiresAccountSetup || profile.requiresPasswordChange
                        || requiresDouyinCompletion
                        ? "key.horizontal.fill" : statusIcon(profile.status)
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        !profile.requiresAccountSetup && !profile.requiresPasswordChange
                            && !requiresDouyinCompletion
                            && profile.status == FanAccountStatus.active.rawValue
                            ? AppTheme.gold : AppTheme.warning
                    )
                    .accessibilityIdentifier(
                        profile.requiresAccountSetup
                            ? "fan-account-setup-required"
                            : (profile.requiresPasswordChange
                                ? "fan-password-recovery-required"
                                : "fan-access-status-\(profile.status)")
                    )
            }

            if profile.requiresAccountSetup {
                requiredAccountSetupForm(profile)
            } else if profile.requiresPasswordChange {
                passwordRecoveryForm(profile)
            } else {
                if profile.status != FanAccountStatus.active.rawValue {
                    approvalStatusCard(profile.status)
                }

                VStack(spacing: 0) {
                    identityRow("粉丝身份码", value: profile.identityCode, copyable: true)
                    Divider().overlay(AppTheme.line)
                    identityRow(
                        "抖音 ID",
                        value: profile.douyinID.isEmpty ? "未填写（必须补全）" : profile.douyinID,
                        copyable: false
                    )
                    Divider().overlay(AppTheme.line)
                    identityRow("本机安装码", value: profile.installationCode, copyable: true)
                    Divider().overlay(AppTheme.line)
                    identityRow("身份记录 UUID", value: profile.userID, copyable: true)
                }
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))

                if requiresDouyinCompletion {
                    Label(
                        "这是旧版未绑定抖音 ID 的账号。为了保护账号身份，暂时不能访问影像内容。请在下方完成资料升级；你仍可退出或主动删除账号。",
                        systemImage: "person.text.rectangle"
                    )
                    .font(.subheadline)
                    .lineSpacing(5)
                    .foregroundStyle(AppTheme.warning)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("fan-douyin-id-required")

                    requiredDouyinUpgradeForm(profile)
                }

                if profile.status == FanAccountStatus.active.rawValue
                    || profile.status == FanAccountStatus.suspended.rawValue {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("已授予权限")
                                .font(.system(.title2, design: .serif))
                                .accessibilityAddTraits(.isHeader)
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
                }

                if !requiresDouyinCompletion {
                    FanNotificationAccountEntry(account: account)

                    NavigationLink {
                        FanAccountSecurityView()
                    } label: {
                        Label(
                            account.usesAppleSignIn ? "登录设备与会话" : "密码与登录设备",
                            systemImage: "lock.shield"
                        )
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fan-account-security")

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            isOn: Binding(
                                get: { pushNotifications.notificationsEnabled },
                                set: { enabled in
                                    Task {
                                        await pushNotifications.setNotificationsEnabled(
                                            enabled,
                                            for: account
                                        )
                                    }
                                }
                            )
                        ) {
                            Label("消息通知", systemImage: "bell.badge")
                                .font(.subheadline.weight(.semibold))
                        }
                        .tint(AppTheme.gold)
                        .disabled(pushNotifications.isUpdatingPreference || !account.hasPushEligibleSession)
                        .accessibilityIdentifier("fan-push-notification-toggle")

                        Text(
                            !account.hasPushEligibleSession
                                ? "完成账号资料并处于待审批或已通过状态后，可开启消息通知。"
                                : pushNotifications.notificationsEnabled
                                ? "用于接收账号审批、合作进度和作品动态。可随时关闭；关闭后会从账号解绑此设备。"
                                : "已关闭，此设备不再接收账号推送。"
                        )
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)

                        if pushNotifications.notificationsEnabled,
                           pushNotifications.authorizationStatus == .authorized {
                            switch pushNotifications.deviceRegistrationState {
                            case .ready:
                                Label("此设备已连接，可以接收账号通知。", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            case .connecting:
                                Label("正在连接通知服务…", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            case .failed:
                                Text("通知连接尚未完成，此设备暂时无法接收推送。")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                                Button("重新连接通知服务") {
                                    Task { await pushNotifications.synchronize(with: account) }
                                }
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("fan-push-notification-retry")
                            case .requiresSignIn:
                                Text("通知绑定需要更新登录凭据。请退出当前粉丝账号后重新登录，再开启消息通知。")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                                    .accessibilityIdentifier("fan-push-notification-sign-in-required")
                            case .inactive:
                                EmptyView()
                            }
                        }

                        if pushNotifications.notificationsEnabled,
                           pushNotifications.authorizationStatus == .denied {
                            Button {
                                guard let settingsURL = URL(
                                    string: UIApplication.openSettingsURLString
                                ) else { return }
                                UIApplication.shared.open(settingsURL)
                            } label: {
                                Label("到系统设置开启通知", systemImage: "gearshape")
                                    .font(.caption.weight(.semibold))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.gold)
                        }
                    }
                    .padding(14)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
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
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    profileRefreshButton(profile)
                    profileSignOutButton
                }
                VStack(spacing: 10) {
                    profileRefreshButton(profile)
                    profileSignOutButton
                }
            }

            Text(profile.requiresAccountSetup
                 ? "管理员只会看到这次生成的临时凭据一次，无法读取你设置的新密码。完成后临时密码和旧会话会立即失效。"
                 : (profile.requiresPasswordChange
                    ? "恢复凭据只会向管理员显示一次。完成后临时密码和所有旧会话都会失效。"
                    : "请妥善保存身份码。管理员只能看到昵称、身份码、审批状态、权限和用于身份核验的抖音 ID，无法查看你的密码。"))
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
                if account.usesAppleSignIn {
                    showAppleDeleteConfirmation = true
                } else {
                    showDeleteConfirmation = true
                }
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

    private func requiredAccountSetupForm(_ profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "这是管理员生成的一次性临时账号。请由账号本人完成以下设置。",
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.gold)

            if let expiresAt = profile.invitationExpiresAt {
                Text("临时凭据有效至 \(expiresAt.formatted(date: .abbreviated, time: .shortened))。过期后服务器会删除未完善的临时记录。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }

            identityRow("粉丝身份码", value: profile.identityCode, copyable: true)
                .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))

            TextField("本人昵称", text: $invitedDisplayName)
                .textContentType(.nickname)
                .accessibilityLabel("本人昵称")
            TextField("本人抖音 ID（必填，不要填链接）", text: $invitedDouyinID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("本人抖音 ID，必填，请不要填写链接")
                .accessibilityIdentifier("fan-setup-douyin-id")
            SecureField("重新输入管理员给你的临时密码", text: $currentTemporaryPassword)
                .textContentType(.password)
                .accessibilityLabel("管理员提供的临时密码")
            SecureField("设置仅本人知道的新密码（至少 10 位）", text: $invitedNewPassword)
                .textContentType(.newPassword)
                .accessibilityLabel("设置新密码，至少 10 位")
            SecureField("再输入一次新密码", text: $invitedPasswordConfirmation)
                .textContentType(.newPassword)
                .accessibilityLabel("确认新密码")

            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("设置前查看隐私政策与删除规则", systemImage: "hand.raised")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fan-setup-privacy-policy")

            ThemePreferenceRow()

            Toggle(isOn: $acceptedInvitationDataUse) {
                Text("我本人已阅读隐私政策，同意昵称、抖音 ID、随机身份码和安装记录用于账号识别、管理员核验、安全登录与权限分配。")
                    .font(.caption)
                    .lineSpacing(4)
            }
            .tint(AppTheme.gold)
            .accessibilityIdentifier("fan-setup-consent")

            Button {
                Task {
                    await account.completeRequiredSetup(
                        displayName: invitedDisplayName,
                        douyinID: invitedDouyinID,
                        currentPassword: currentTemporaryPassword,
                        newPassword: invitedNewPassword,
                        passwordConfirmation: invitedPasswordConfirmation,
                        acceptedDataUse: acceptedInvitationDataUse
                    )
                    if account.profile?.requiresAccountSetup == false {
                        currentTemporaryPassword = ""
                        invitedNewPassword = ""
                        invitedPasswordConfirmation = ""
                    }
                }
            } label: {
                accountButtonLabel(account.isWorking ? "正在安全设置" : "同意并设置我的账号")
            }
            .disabled(account.isWorking || !acceptedInvitationDataUse)
            .accessibilityIdentifier("fan-setup-submit")
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        .textFieldStyle(AccountTextFieldStyle())
    }

    @ViewBuilder
    private func requiredDouyinUpgradeForm(_ profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if profile.accountSource == FanAccountSource.apple.rawValue {
                Text("请重新使用 Apple ID 验证。验证成功后会进入资料补全页，填写抖音 ID 后即可继续。")
                    .font(.caption)
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.muted)

                NativeAppleSignInButton { window in
                    beginAppleAuthorization(purpose: .signIn, presentationAnchor: window)
                }
                .frame(height: 50)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppTheme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .disabled(account.isWorking || appleSignIn.isWorking)
                .opacity(account.isWorking || appleSignIn.isWorking ? 0.55 : 1)
                .accessibilityIdentifier("fan-douyin-upgrade-apple")
            } else {
                TextField("抖音 ID（必填，不要填链接）", text: $profileUpgradeDouyinID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("补全抖音 ID，必填，请不要填写链接")
                    .accessibilityIdentifier("fan-douyin-upgrade-id")
                SecureField("当前密码", text: $profileUpgradeCurrentPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("fan-douyin-upgrade-password")

                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("补全前查看隐私政策", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.gold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }

                Toggle(isOn: $acceptedProfileUpgradeDataUse) {
                    Text("我已阅读当前隐私政策，同意将抖音 ID 用于管理员核验账号身份。")
                        .font(.caption)
                        .lineSpacing(4)
                }
                .tint(AppTheme.gold)
                .accessibilityIdentifier("fan-douyin-upgrade-consent")

                Button {
                    Task {
                        await account.completeRequiredDouyinID(
                            displayName: profile.displayName,
                            douyinID: profileUpgradeDouyinID,
                            currentPassword: profileUpgradeCurrentPassword,
                            acceptedDataUse: acceptedProfileUpgradeDataUse
                        )
                        if account.profile?.hasRequiredDouyinID == true {
                            clearDouyinProfileUpgradeFields()
                        } else {
                            profileUpgradeCurrentPassword = ""
                        }
                    }
                } label: {
                    accountButtonLabel(account.isWorking ? "正在安全补全" : "同意并补全抖音 ID")
                }
                .disabled(account.isWorking || !acceptedProfileUpgradeDataUse)
                .accessibilityIdentifier("fan-douyin-upgrade-submit")
            }
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        .textFieldStyle(AccountTextFieldStyle())
    }

    private func passwordRecoveryForm(_ profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "管理员已生成一次性恢复凭据。在这里设置新密码后才能继续使用 App。",
                systemImage: "key.horizontal.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.gold)

            if let expiresAt = profile.passwordRecoveryExpiresAt {
                Text("恢复凭据有效至 \(expiresAt.formatted(date: .abbreviated, time: .shortened))。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }

            identityRow("粉丝身份码", value: profile.identityCode, copyable: true)
                .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
            SecureField("重新输入管理员给你的临时密码", text: $recoveryTemporaryPassword)
                .textContentType(.password)
                .accessibilityLabel("管理员提供的临时恢复密码")
            SecureField("设置仅本人知道的新密码（至少 10 位）", text: $recoveryNewPassword)
                .textContentType(.newPassword)
                .accessibilityLabel("设置新密码，至少 10 位")
            SecureField("再输入一次新密码", text: $recoveryPasswordConfirmation)
                .textContentType(.newPassword)
                .accessibilityLabel("确认新密码")

            Button {
                Task {
                    await account.completePasswordRecovery(
                        currentPassword: recoveryTemporaryPassword,
                        newPassword: recoveryNewPassword,
                        passwordConfirmation: recoveryPasswordConfirmation
                    )
                    if account.profile?.requiresPasswordChange == false {
                        clearRecoveryPasswords()
                    }
                }
            } label: {
                accountButtonLabel(account.isWorking ? "正在安全更新" : "设置新密码并继续")
            }
            .disabled(account.isWorking)
            .accessibilityIdentifier("fan-password-recovery-submit")
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        .textFieldStyle(AccountTextFieldStyle())
    }

    private func profileHeading(_ profile: FanProfile) -> String {
        if profile.requiresAccountSetup { return "完成首次设置" }
        if profile.requiresPasswordChange { return "重新设置密码" }
        if !profile.hasRequiredDouyinID { return "需要补全资料" }
        switch profile.accountStatus {
        case .some(.active): return "你好，\(profile.displayName)"
        case .some(.pending): return "申请已提交"
        case .some(.rejected): return "申请未通过"
        case .some(.suspended): return "访问已暂停"
        case .none: return "账号状态异常"
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch FanAccountStatus(rawValue: status) {
        case .some(.active): return "管理员已批准，可按已授予权限访问 App"
        case .some(.pending): return "正在等待管理员审批"
        case .some(.rejected): return "管理员未批准本次访问申请"
        case .some(.suspended): return "管理员已暂停 App 访问"
        case .none: return "账号状态异常，请联系管理员"
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch FanAccountStatus(rawValue: status) {
        case .some(.active): return "checkmark.seal.fill"
        case .some(.pending): return "clock.badge.questionmark.fill"
        case .some(.rejected): return "xmark.seal.fill"
        case .some(.suspended), .none: return "exclamationmark.shield.fill"
        }
    }

    private func approvalStatusCard(_ status: String) -> some View {
        let message: String
        switch FanAccountStatus(rawValue: status) {
        case .some(.pending):
            message = "管理员审批通过前，首页、作品、影视、收藏和关于页面不会开放。本页会自动检查审批结果，你也可以手动刷新。"
        case .some(.rejected):
            message = "本次申请未获批准。你仍可查看和复制身份码、退出登录，或永久删除账号后重新申请。"
        case .some(.suspended):
            message = "现有 App 内容访问已经停用。你仍可重新登录管理资料，并随时永久删除账号。"
        case .some(.active):
            message = "访问已批准，可按已授予权限使用相应内容。"
        case .none:
            message = "服务器返回了未知状态，请联系管理员。"
        }
        return Label(message, systemImage: statusIcon(status))
            .font(.subheadline)
            .lineSpacing(5)
            .foregroundStyle(AppTheme.warmWhite)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func monitorPendingApproval() async {
        guard isAccessGate,
              account.profile?.requiresAccountSetup == false,
              account.profile?.accountStatus == .pending else { return }
        while !Task.isCancelled, account.profile?.accountStatus == .pending {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await account.refreshSession(showError: false)
        }
    }

    private func clearInvitationSetupFields() {
        invitedDisplayName = ""
        invitedDouyinID = ""
        currentTemporaryPassword = ""
        invitedNewPassword = ""
        invitedPasswordConfirmation = ""
        acceptedInvitationDataUse = false
    }

    private func clearDouyinProfileUpgradeFields() {
        profileUpgradeDouyinID = ""
        profileUpgradeCurrentPassword = ""
        acceptedProfileUpgradeDataUse = false
    }

    private func clearAuthenticationPasswords() {
        registrationPassword = ""
        passwordConfirmation = ""
        loginPassword = ""
    }

    private func clearInvitationPasswords() {
        currentTemporaryPassword = ""
        invitedNewPassword = ""
        invitedPasswordConfirmation = ""
    }

    private func clearRecoveryPasswords() {
        recoveryTemporaryPassword = ""
        recoveryNewPassword = ""
        recoveryPasswordConfirmation = ""
    }

    private func clearAllPasswords() {
        clearAuthenticationPasswords()
        clearInvitationPasswords()
        clearRecoveryPasswords()
        profileUpgradeCurrentPassword = ""
        deleteCurrentPassword = ""
    }

    private func clearAppleRegistrationFields() {
        appleRegistrationDraft.clear()
    }

    private func prepareAppleRegistrationFields(for registration: FanAppleRegistrationState?) {
        clearAppleRegistrationFields()
        guard let registration, registration.isDouyinMigration,
              FanAccountValidation.isValidDisplayName(registration.displayName) else { return }
        appleRegistrationDraft.displayName = registration.displayName
    }

    private func appleRegistrationExplanation(
        _ registration: FanAppleRegistrationState?
    ) -> String {
        guard let registration, registration.isDouyinMigration,
              let status = registration.preservedStatus else {
            return "你的 Apple 身份已通过服务器验证。请主动填写以下资料；管理员批准前不会开放主页和媒体内容。"
        }
        switch status {
        case .active:
            return "这是已获批准的 Apple 账号。补填必填的抖音 ID 后会恢复原有权限，无需重新审批。"
        case .pending:
            return "这是已有的 Apple 账号。补填必填的抖音 ID 后，原有待审批状态会继续保留。"
        case .rejected:
            return "这是已有的 Apple 账号。补填必填的抖音 ID 后，原有未通过状态会继续保留。"
        case .suspended:
            return "这是已有的 Apple 账号。补填必填的抖音 ID 后，原有暂停状态会继续保留。"
        }
    }

    private func profileRefreshButton(_ profile: FanProfile) -> some View {
        Button {
            Task { await account.refreshSession() }
        } label: {
            Label(
                profile.requiresAccountSetup
                    ? "刷新临时账号状态"
                    : profile.status == FanAccountStatus.pending.rawValue
                    ? "刷新审批状态" : "刷新账号状态",
                systemImage: "arrow.clockwise"
            )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(account.isWorking)
    }

    private var profileSignOutButton: some View {
        Button {
            clearAllPasswords()
            pushNotifications.accountContextDidChange(to: nil)
            Task { await account.signOut() }
        } label: {
            Text("退出登录")
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(AppTheme.ink)
        }
        .disabled(account.isWorking)
    }

    private func identityRow(_ title: String, value: String, copyable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(AppTheme.muted)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if copyable {
                Button {
                    UIPasteboard.general.string = value
                    copiedLabel = title
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 44, height: 44)
                        .background(AppTheme.subtleFill, in: Circle())
                }
                .accessibilityLabel("复制\(title)")
            }
        }
        .padding(15)
    }

    private var currentPresentationWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func beginAppleAuthorization(
        purpose: FanAppleChallengePurpose,
        presentationAnchor: UIWindow?
    ) {
        Task {
            guard let challenge = await account.requestAppleChallenge(purpose: purpose) else {
                return
            }
            guard scenePhase == .active else { return }
            appleSignIn.start(
                challenge: challenge,
                presentationAnchor: presentationAnchor ?? currentPresentationWindow
            ) { result in
                switch result {
                case .success(let submission):
                    Task {
                        if purpose == .deleteAccount {
                            pushNotifications.accountContextDidChange(to: nil)
                            await account.deleteAppleAccount(submission)
                            if account.isAuthenticated {
                                await pushNotifications.synchronize(with: account)
                            }
                            if account.appleRegistration == nil {
                                clearAppleRegistrationFields()
                            }
                        } else {
                            await account.signInWithApple(submission)
                            clearAppleRegistrationFields()
                        }
                    }
                case .failure(let error):
                    account.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Apple 登录未完成，请重试。"
                }
            }
        }
    }

    private func accountButtonLabel(_ title: String) -> some View {
        HStack(spacing: 9) {
            if account.isWorking { ProgressView().tint(AppTheme.ink) }
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(AppTheme.ink)
    }
}

private struct NativeAppleSignInButton: UIViewRepresentable {
    let action: (UIWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .white)
        button.cornerRadius = 6
        button.accessibilityIdentifier = "fan-sign-in-with-apple"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.activate(_:)),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (UIWindow?) -> Void

        init(action: @escaping (UIWindow?) -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: ASAuthorizationAppleIDButton) {
            action(sender.window)
        }
    }
}

private struct FanAccountSecurityView: View {
    @EnvironmentObject private var account: FanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var passwordConfirmation = ""

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if FanAccountSecurityCapabilities.supportsPasswordChange(
                        usesAppleSignIn: account.usesAppleSignIn
                    ) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("修改密码")
                                .font(.system(.title2, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text("修改成功后会撤销所有旧会话，并为当前设备立即换发新会话。")
                                .font(.caption)
                                .lineSpacing(4)
                                .foregroundStyle(AppTheme.muted)
                            SecureField("当前密码", text: $currentPassword)
                                .textContentType(.password)
                                .accessibilityLabel("当前密码")
                            SecureField("新密码（至少 10 位）", text: $newPassword)
                                .textContentType(.newPassword)
                                .accessibilityLabel("新密码，至少 10 位")
                            SecureField("再输入一次新密码", text: $passwordConfirmation)
                                .textContentType(.newPassword)
                                .accessibilityLabel("确认新密码")
                            Button {
                                Task {
                                    await account.changePassword(
                                        currentPassword: currentPassword,
                                        newPassword: newPassword,
                                        passwordConfirmation: passwordConfirmation
                                    )
                                    if account.errorMessage == nil {
                                        clearPasswords()
                                        await account.fetchSessions()
                                    }
                                }
                            } label: {
                                Label("更新密码", systemImage: "key.horizontal")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(AppTheme.ink)
                            }
                            .buttonStyle(.plain)
                            .disabled(account.isWorking)
                        }
                        .padding(16)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
                        .textFieldStyle(AccountTextFieldStyle())
                    } else {
                        Label(
                            "此账号通过 Apple 登录，不在本 App 内设置密码。你仍可查看并撤销其他设备会话。",
                            systemImage: "apple.logo"
                        )
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("登录设备与会话")
                                .font(.system(.title2, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button {
                                Task { await account.fetchSessions() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(account.isWorking)
                            .accessibilityLabel("刷新登录会话")
                        }

                        if account.sessions.isEmpty, account.isWorking {
                            ProgressView("正在读取安全会话")
                                .tint(AppTheme.gold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 22)
                        } else {
                            ForEach(account.sessions) { session in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(
                                            session.isCurrent ? "当前设备" : "其他登录设备",
                                            systemImage: session.isCurrent
                                                ? "iphone.gen3.circle.fill" : "iphone.gen3.circle"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(session.isCurrent ? AppTheme.gold : .white)
                                        Spacer()
                                        Text(session.installationCode)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(AppTheme.muted)
                                    }
                                    Text("登录于 \(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · 有效至 \(session.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                    if !session.isCurrent {
                                        Button(role: .destructive) {
                                            Task { await account.revokeSession(session.sessionID) }
                                        } label: {
                                            Label("撤销这个会话", systemImage: "rectangle.portrait.and.arrow.right")
                                                .font(.caption.weight(.semibold))
                                                .frame(minHeight: 44)
                                        }
                                        .disabled(account.isWorking)
                                    }
                                }
                                .padding(13)
                                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(16)
                    .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))

                    if let notice = account.noticeMessage {
                        Label(notice, systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.gold)
                    }
                    if let error = account.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(20)
                .padding(.bottom, 44)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(account.usesAppleSignIn ? "登录设备" : "账号安全")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .task { await account.fetchSessions() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearPasswords() }
        }
        .onDisappear { clearPasswords() }
    }

    private func clearPasswords() {
        currentPassword = ""
        newPassword = ""
        passwordConfirmation = ""
    }
}

private struct FanDirectorySearchTaskID: Hashable {
    let searchText: String
    let isAuthenticated: Bool
}

struct FanAccessAdminView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var directory: AdminFanDirectory?
    @State private var searchText = ""
    @State private var appliedSearch = ""
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var isCreatingInvitations = false
    @State private var invitationCount = 3
    @State private var invitations: [AdminFanInvitation] = []
    @State private var copiedInvitationID: String?
    @State private var temporaryPasteboardValue: String?
    @State private var pasteboardClearTask: Task<Void, Never>?
    @State private var directoryLoadGeneration: UInt64 = 0
    @State private var canSendPushNotifications = false
    @State private var hasResolvedPushCapability = false
    @State private var errorMessage: String?

    private var visibleUsers: [AdminFanUser] {
        directory?.users ?? []
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pendingUsers: [AdminFanUser] {
        visibleUsers.filter { $0.status == FanAccountStatus.pending.rawValue }
    }

    private var reviewedUsers: [AdminFanUser] {
        visibleUsers.filter { $0.status != FanAccountStatus.pending.rawValue }
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("新注册用户会先进入待审批列表。只有管理员批准后，用户才能进入首页、作品、影视、收藏和关于页面。粉丝密码不会在后台显示。")
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)
                        .padding(.bottom, 4)

                    invitationCreator

                    if isLoading, directory == nil {
                        ProgressView("正在读取用户")
                            .tint(AppTheme.gold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                    } else if visibleUsers.isEmpty {
                        ContentUnavailableView(
                            errorMessage == nil
                                ? (hasSearchQuery ? "没有匹配的用户" : "还没有注册用户")
                                : "暂时无法读取用户",
                            systemImage: errorMessage == nil
                                ? "person.2.slash"
                                : "wifi.exclamationmark"
                        )
                        .foregroundStyle(AppTheme.warmWhite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        if !pendingUsers.isEmpty {
                            HStack {
                                Label("待审批申请", systemImage: "bell.badge.fill")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.gold)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                Text("\(pendingUsers.count)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.gold, in: Capsule())
                                    .foregroundStyle(AppTheme.ink)
                            }
                            .accessibilityIdentifier("fan-pending-applications")

                            ForEach(pendingUsers) { user in
                                userLink(user)
                            }
                        }

                        if !reviewedUsers.isEmpty {
                            Text(pendingUsers.isEmpty ? "全部用户" : "已处理用户")
                                .font(.headline)
                                .padding(.top, pendingUsers.isEmpty ? 0 : 14)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(reviewedUsers) { user in
                                userLink(user)
                            }
                        }

                        if directory?.hasMore == true {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                HStack(spacing: 9) {
                                    if isLoadingMore {
                                        ProgressView()
                                            .tint(AppTheme.ink)
                                    }
                                    Text(isLoadingMore ? "正在加载更多用户" : "加载更多用户")
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(AppTheme.ink)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading || isLoadingMore)
                            .accessibilityIdentifier("admin-fan-load-more")
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(18)
                .padding(.bottom, 40)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await loadFirstPage(
                    search: searchText,
                    debounce: false
                )
            }

            if !admin.isAuthenticated {
                AdministratorLockedView()
            }
        }
        .navigationTitle("注册审批")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .searchable(text: $searchText, prompt: "昵称、抖音 ID 或身份码")
        .task(
            id: FanDirectorySearchTaskID(
                searchText: searchText,
                isAuthenticated: admin.isAuthenticated
            )
        ) {
            await loadFirstPage(search: searchText, debounce: true)
        }
        .task(id: admin.isAuthenticated) { await monitorApplications() }
        .onChange(of: searchText) { _, value in
            let capped = String(value.prefix(AdminFanDirectoryQuery.maximumSearchLength))
            if capped != value { searchText = capped }
        }
        .onChange(of: admin.isAuthenticated) { _, authenticated in
            if !authenticated {
                invalidateDirectoryLoad()
                invitations.removeAll()
                clearTemporaryPasteboardIfOwned()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearTemporaryPasteboardIfOwned() }
        }
        .onDisappear {
            invalidateDirectoryLoad()
            invitations.removeAll()
            clearTemporaryPasteboardIfOwned()
        }
    }

    private var invitationCreator: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("生成一次性临时账号", systemImage: "person.badge.key.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.gold)

            Text("临时凭据仅显示这一次，有效期 24 小时。对方首次登录后必须本人填写昵称和抖音 ID、确认隐私政策并设置新密码。在完成设置前无法访问任何作品内容。")
                .font(.caption)
                .lineSpacing(4)
                .foregroundStyle(AppTheme.muted)

            Stepper("本次生成 \(invitationCount) 个", value: $invitationCount, in: 1...5)
                .font(.subheadline)

            Button {
                Task { await createInvitations() }
            } label: {
                HStack(spacing: 9) {
                    if isCreatingInvitations { ProgressView().tint(AppTheme.ink) }
                    Label(
                        isCreatingInvitations ? "正在安全生成" : "生成临时身份码与密码",
                        systemImage: "key.viewfinder"
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(AppTheme.ink)
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(isCreatingInvitations || !admin.isAuthenticated)

            if !invitations.isEmpty {
                Label(
                    "请现在复制并分别交给本人。离开此页后这些临时密码无法再次查询。",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.warning)

                ForEach(invitations) { invitation in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(invitation.identityCode)
                            .font(.system(.headline, design: .monospaced))
                            .textSelection(.enabled)
                        Text(invitation.temporaryPassword)
                            .font(.system(.subheadline, design: .monospaced))
                            .privacySensitive()
                        Text("有效至 \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                        Button {
                            copyInvitation(invitation)
                        } label: {
                            Label(
                                copiedInvitationID == invitation.id ? "已复制（2 分钟后清除）" : "复制这一组",
                                systemImage: copiedInvitationID == invitation.id ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.gold)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                }

                if invitations.count > 1 {
                    Button {
                        copyAllInvitations()
                    } label: {
                        Label("复制全部临时账号", systemImage: "doc.on.doc.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(15)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("admin-fan-invitation-creator")
    }

    private func userLink(_ user: AdminFanUser) -> some View {
        NavigationLink {
            FanAccessDetailView(
                user: user,
                catalog: directory?.permissionCatalog ?? [],
                canSendPushNotifications: canSendPushNotifications
            ) { updated in
                replace(updated)
            }
        } label: {
            FanAdminUserRow(user: user)
        }
        .buttonStyle(.plain)
    }

    private func loadFirstPage(search: String, debounce: Bool) async {
        guard admin.isAuthenticated else {
            invalidateDirectoryLoad()
            return
        }
        let query: AdminFanDirectoryQuery
        do {
            query = try AdminFanDirectoryQuery(search: search)
        } catch {
            directoryLoadGeneration &+= 1
            directory = nil
            isLoading = false
            isLoadingMore = false
            errorMessage = "搜索内容不能超过 80 个字符。"
            return
        }
        directoryLoadGeneration &+= 1
        let generation = directoryLoadGeneration
        if (query.search ?? "") != appliedSearch {
            directory = nil
        }
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        defer {
            if generation == directoryLoadGeneration { isLoading = false }
        }
        do {
            if debounce {
                try await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let response = try await admin.fetchFanDirectory(
                search: query.search ?? "",
                page: query.page,
                perPage: query.perPage
            )
            let capabilities = hasResolvedPushCapability
                ? nil
                : try? await admin.fetchFeatureCapabilities()
            guard isCurrentDirectoryRequest(query, generation: generation) else { return }
            directory = response
            appliedSearch = query.search ?? ""
            if let capabilities {
                hasResolvedPushCapability = true
                canSendPushNotifications = capabilities.canSendPushNotifications
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentDirectoryRequest(query, generation: generation) else { return }
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "暂时无法读取用户。"
        }
    }

    private func loadMore() async {
        guard admin.isAuthenticated,
              !isLoading,
              !isLoadingMore,
              let current = directory,
              current.hasMore,
              current.page < AdminFanDirectoryQuery.maximumPage else { return }
        let query: AdminFanDirectoryQuery
        do {
            query = try AdminFanDirectoryQuery(
                search: appliedSearch,
                page: current.page + 1,
                perPage: current.perPage
            )
        } catch {
            errorMessage = "无法继续读取下一页用户。"
            return
        }
        directoryLoadGeneration &+= 1
        let generation = directoryLoadGeneration
        isLoadingMore = true
        errorMessage = nil
        defer {
            if generation == directoryLoadGeneration { isLoadingMore = false }
        }
        do {
            let response = try await admin.fetchFanDirectory(
                search: query.search ?? "",
                page: query.page,
                perPage: query.perPage
            )
            guard isCurrentDirectoryRequest(query, generation: generation),
                  appliedSearch == (query.search ?? ""),
                  let latest = directory else { return }
            guard let merged = AdminFanDirectoryValidation.appending(
                response,
                to: latest
            ) else {
                errorMessage = "用户列表已更新，请下拉刷新后重试。"
                return
            }
            directory = merged
            errorMessage = nil
        } catch {
            guard isCurrentDirectoryRequest(query, generation: generation) else { return }
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "暂时无法加载更多用户。"
        }
    }

    private func invalidateDirectoryLoad() {
        directoryLoadGeneration &+= 1
        isLoading = false
        isLoadingMore = false
        directory = nil
        appliedSearch = ""
        canSendPushNotifications = false
        hasResolvedPushCapability = false
    }

    private func isCurrentDirectoryRequest(
        _ query: AdminFanDirectoryQuery,
        generation: UInt64
    ) -> Bool {
        guard generation == directoryLoadGeneration,
              !Task.isCancelled,
              admin.isAuthenticated,
              let currentQuery = try? AdminFanDirectoryQuery(search: searchText) else {
            return false
        }
        return currentQuery.search == query.search
    }

    private func createInvitations() async {
        guard admin.isAuthenticated, !isCreatingInvitations else {
            errorMessage = "管理员会话已锁定，请返回后重新登录。"
            return
        }
        isCreatingInvitations = true
        defer { isCreatingInvitations = false }
        do {
            let created = try await admin.createFanInvitations(count: invitationCount)
            guard admin.isAuthenticated else { return }
            clearTemporaryPasteboardIfOwned()
            invitations = created
            errorMessage = nil
            await loadFirstPage(search: searchText, debounce: false)
        } catch {
            clearTemporaryPasteboardIfOwned()
            invitations.removeAll()
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "临时账号生成失败。"
        }
    }

    private func copyInvitation(_ invitation: AdminFanInvitation) {
        setTemporaryPasteboard(
            "Hi，梳子临时账号\n身份码：\(invitation.identityCode)\n临时密码：\(invitation.temporaryPassword)\n有效至：\(invitation.expiresAt.formatted(date: .numeric, time: .shortened))"
        )
        copiedInvitationID = invitation.id
    }

    private func copyAllInvitations() {
        let value = invitations.map {
            "身份码：\($0.identityCode)\n临时密码：\($0.temporaryPassword)\n有效至：\($0.expiresAt.formatted(date: .numeric, time: .shortened))"
        }.joined(separator: "\n\n")
        setTemporaryPasteboard("Hi，梳子临时账号\n\n\(value)")
        copiedInvitationID = "all"
    }

    private func setTemporaryPasteboard(_ value: String) {
        clearTemporaryPasteboardIfOwned()
        let expirationDate = Date().addingTimeInterval(2 * 60)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: expirationDate,
            ]
        )
        temporaryPasteboardValue = value
        pasteboardClearTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            clearTemporaryPasteboardIfOwned()
        }
    }

    private func clearTemporaryPasteboardIfOwned() {
        pasteboardClearTask?.cancel()
        pasteboardClearTask = nil
        if let temporaryPasteboardValue,
           UIPasteboard.general.string == temporaryPasteboardValue {
            UIPasteboard.general.items = []
        }
        temporaryPasteboardValue = nil
        copiedInvitationID = nil
    }

    private func monitorApplications() async {
        while !Task.isCancelled, admin.isAuthenticated {
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  !isLoading,
                  !isLoadingMore,
                  directory?.page == 1,
                  let query = try? AdminFanDirectoryQuery(search: searchText),
                  (query.search ?? "") == appliedSearch else { continue }
            await loadFirstPage(search: searchText, debounce: false)
        }
    }

    private func replace(_ updated: AdminFanUser) {
        guard let current = directory,
              let index = current.users.firstIndex(where: { $0.id == updated.id }) else { return }
        var users = current.users
        users[index] = updated
        directory = AdminFanDirectory(
            users: users,
            permissionCatalog: current.permissionCatalog,
            page: current.page,
            perPage: current.perPage,
            hasMore: current.hasMore
        )
    }
}

private struct FanAccessDetailView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var user: AdminFanUser
    @State private var isSaving = false
    @State private var isGeneratingRecovery = false
    @State private var showRecoveryConfirmation = false
    @State private var showPushComposer = false
    @State private var passwordRecovery: AdminFanPasswordRecovery?
    @State private var recoveryPasteboardValue: String?
    @State private var errorMessage: String?
    let catalog: [AdminFanPermissionDefinition]
    let canSendPushNotifications: Bool
    let onUpdate: (AdminFanUser) -> Void

    init(
        user: AdminFanUser,
        catalog: [AdminFanPermissionDefinition],
        canSendPushNotifications: Bool,
        onUpdate: @escaping (AdminFanUser) -> Void
    ) {
        _user = State(initialValue: user)
        self.catalog = catalog
        self.canSendPushNotifications = canSendPushNotifications
        self.onUpdate = onUpdate
    }

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(user.displayName)
                            .font(.system(.largeTitle, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        Text(user.requiresAppleRegistration
                             ? "等待完成账号申请"
                             : user.requiresAccountSetup
                             ? "待本人完成首次设置"
                             : (user.douyinID.isEmpty ? "抖音 ID 待补全（不可开放内容）" : "@\(user.douyinID)"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.gold)
                        Text(user.identityCode)
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundStyle(AppTheme.muted)
                        Text("注册于 \(user.registeredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                        if let reviewedAt = user.reviewedAt {
                            Text("最近处理于 \(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("审批状态")
                            .font(.system(.title2, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        Label(adminStatusTitle(user.status), systemImage: adminStatusIcon(user.status))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(user.status == FanAccountStatus.active.rawValue ? AppTheme.gold : AppTheme.warning)

                        if user.requiresIdentityCompletion {
                            Label(
                                user.requiresAppleRegistration
                                    ? "对方已通过 Apple 验证，但尚未完成昵称和抖音 ID 资料；现在不能批准或开放内容。"
                                    : (user.requiresAccountSetup
                                        ? "对方尚未完成首次设置。即使账号为待审批状态，也不能提前批准或访问内容。"
                                        : "这是旧版未绑定抖音 ID 的账号；请先协助完成资料升级，在此之前不可开放内容。"),
                                systemImage: user.requiresAppleRegistration
                                    ? "apple.logo" : "key.horizontal.fill"
                            )
                            .font(.caption)
                            .lineSpacing(4)
                            .foregroundStyle(AppTheme.warning)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        } else if user.status == FanAccountStatus.pending.rawValue {
                            Button {
                                Task { await save(status: FanAccountStatus.active.rawValue) }
                            } label: {
                                Label("批准并开放 App", systemImage: "checkmark.shield.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(AppTheme.gold, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(AppTheme.ink)
                            }
                            .accessibilityIdentifier("fan-approve-application")

                            Button(role: .destructive) {
                                Task { await save(status: FanAccountStatus.rejected.rawValue) }
                            } label: {
                                Label("拒绝本次申请", systemImage: "xmark.shield")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else if user.status == FanAccountStatus.active.rawValue {
                            Button(role: .destructive) {
                                Task { await save(status: FanAccountStatus.suspended.rawValue) }
                            } label: {
                                Label("暂停 App 访问", systemImage: "pause.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Button {
                                Task { await save(status: FanAccountStatus.active.rawValue) }
                            } label: {
                                Label("改为批准并恢复访问", systemImage: "checkmark.shield.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(AppTheme.gold, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(AppTheme.ink)
                            }
                        }
                    }

                    if !user.requiresIdentityCompletion,
                       user.accountSource != FanAccountSource.apple.rawValue {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("密码恢复")
                                .font(.system(.title2, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text("生成后会立即撤销该账号所有旧会话和旧密码。临时恢复凭据仅显示一次，有效期 15 分钟。")
                                .font(.caption)
                                .lineSpacing(4)
                                .foregroundStyle(AppTheme.muted)

                            Button(role: .destructive) {
                                showRecoveryConfirmation = true
                            } label: {
                                HStack(spacing: 8) {
                                    if isGeneratingRecovery { ProgressView() }
                                    Label("生成一次性密码恢复凭据", systemImage: "key.viewfinder")
                                }
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .disabled(isSaving || isGeneratingRecovery || !admin.isAuthenticated)

                            if let passwordRecovery {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("请立即安全交给账号本人", systemImage: "exclamationmark.shield.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.warning)
                                    Text(passwordRecovery.identityCode)
                                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                        .textSelection(.enabled)
                                    Text(passwordRecovery.temporaryPassword)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .privacySensitive()
                                    Text("有效至 \(passwordRecovery.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                    Button {
                                        copyPasswordRecovery(passwordRecovery)
                                    } label: {
                                        Label("复制凭据（2 分钟后清除）", systemImage: "doc.on.doc")
                                            .font(.caption.weight(.semibold))
                                            .frame(minHeight: 44)
                                    }
                                }
                                .padding(13)
                                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        Text("功能权限")
                            .font(.system(.title2, design: .serif))
                            .accessibilityAddTraits(.isHeader)
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

                    if AdminTargetedPushRecipientPolicy.isEligible(user) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("定向通知")
                                .font(.system(.title2, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text(
                                canSendPushNotifications
                                    ? "只向这个账号已绑定的设备发送通知；默认使用隐私模式，不在锁屏显示具体内容。"
                                    : "推送服务尚未就绪，或当前管理员没有定向推送权限。"
                            )
                                .font(.caption)
                                .lineSpacing(4)
                                .foregroundStyle(AppTheme.muted)
                            if canSendPushNotifications {
                                Button {
                                    showPushComposer = true
                                } label: {
                                    Label("向该用户发送通知", systemImage: "paperplane.fill")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .disabled(!admin.isAuthenticated)
                                .accessibilityIdentifier("admin-send-user-push")
                            } else {
                                Label("定向通知不可用", systemImage: "bell.slash")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.muted)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
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
                            .foregroundStyle(AppTheme.warning)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    Text("审批或权限保存后立即在服务器生效。待审批用户的申请页会自动刷新；批准后会直接进入 App。")
                        .font(.caption2)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)

                    Text("拒绝不会删除用户资料；暂停会立即撤销现有内容会话。无论待审批、拒绝或暂停，用户都能主动永久删除账号与个人资料。")
                        .font(.caption2)
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.muted)
                }
                .padding(20)
                .padding(.bottom, 44)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            if !admin.isAuthenticated {
                AdministratorLockedView()
            }
        }
        .navigationTitle(
            user.requiresAccountSetup
                ? "临时账号"
                : (user.status == FanAccountStatus.pending.rawValue ? "审批申请" : "账号权限")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.ink, for: .navigationBar)
        .disabled(isSaving || isGeneratingRecovery)
        .confirmationDialog(
            "撤销该粉丝的旧密码和全部会话？",
            isPresented: $showRecoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("生成恢复凭据", role: .destructive) {
                Task { await generatePasswordRecovery() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("生成后不能查看原密码，已登录设备会立即失效。")
        }
        .sheet(isPresented: $showPushComposer) {
            FanPushComposerView(user: user)
                .environmentObject(admin)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearPasswordRecoverySecret() }
        }
        .onChange(of: admin.isAuthenticated) { _, authenticated in
            if !authenticated { clearPasswordRecoverySecret() }
        }
        .onDisappear { clearPasswordRecoverySecret() }
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

    private func adminStatusTitle(_ status: String) -> String {
        switch FanAccountStatus(rawValue: status) {
        case .some(.pending): return "等待管理员审批"
        case .some(.active): return "已批准访问"
        case .some(.rejected): return "申请已拒绝"
        case .some(.suspended): return "访问已暂停"
        case .none: return "未知状态"
        }
    }

    private func adminStatusIcon(_ status: String) -> String {
        switch FanAccountStatus(rawValue: status) {
        case .some(.pending): return "clock.badge.questionmark.fill"
        case .some(.active): return "checkmark.seal.fill"
        case .some(.rejected): return "xmark.seal.fill"
        case .some(.suspended), .none: return "pause.circle.fill"
        }
    }

    private func save(permissions: [String]? = nil, status: String? = nil) async {
        guard permissions != nil || status != nil,
              admin.isAuthenticated,
              !isSaving else {
            errorMessage = "管理员会话已锁定，请返回后重新登录。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await admin.updateFanAccess(
                userID: user.userID,
                permissions: permissions,
                status: status
            )
            user = updated
            onUpdate(updated)
            errorMessage = nil
        } catch {
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "权限更新失败。"
        }
    }

    private func generatePasswordRecovery() async {
        guard admin.isAuthenticated, !isGeneratingRecovery else {
            errorMessage = "管理员会话已锁定，请返回后重新登录。"
            return
        }
        clearPasswordRecoverySecret()
        isGeneratingRecovery = true
        defer { isGeneratingRecovery = false }
        do {
            passwordRecovery = try await admin.createFanPasswordRecovery(userID: user.userID)
            errorMessage = nil
        } catch {
            passwordRecovery = nil
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "暂时无法生成恢复凭据。"
        }
    }

    private func copyPasswordRecovery(_ recovery: AdminFanPasswordRecovery) {
        clearRecoveryPasteboardIfOwned()
        let value = "Hi，梳子密码恢复\n身份码：\(recovery.identityCode)\n临时密码：\(recovery.temporaryPassword)\n有效至：\(recovery.expiresAt.formatted(date: .numeric, time: .shortened))"
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        recoveryPasteboardValue = value
    }

    private func clearPasswordRecoverySecret() {
        passwordRecovery = nil
        clearRecoveryPasteboardIfOwned()
    }

    private func clearRecoveryPasteboardIfOwned() {
        if let recoveryPasteboardValue,
           UIPasteboard.general.string == recoveryPasteboardValue {
            UIPasteboard.general.items = []
        }
        recoveryPasteboardValue = nil
    }
}

private struct FanPushComposerView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(\.dismiss) private var dismiss
    let user: AdminFanUser

    @State private var title = "Hi，梳子"
    @State private var message = "你有一条新消息，请打开 App 查看。"
    @State private var privacyMode = true
    @State private var idempotencyKey = UUID()
    @State private var isSending = false
    @State private var customConfirmationContent: AdminPushNotificationContent?
    @State private var showCustomConfirmation = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private var normalizedContent: AdminPushNotificationContent? {
        AdminPushNotificationValidation.normalized(
            title: title,
            body: message,
            sensitive: privacyMode
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("收件人", value: user.displayName)
                    LabeledContent("身份码", value: user.identityCode)
                        .fontDesign(.monospaced)
                }

                Section("通知内容") {
                    if privacyMode {
                        Label(
                            "隐私模式仅在登录后的云端消息箱显示原文，锁屏只显示通用提醒。",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    }
                    TextField("标题", text: $title)
                        .disabled(isSending)
                        .onChange(of: title) { _, value in
                            if value.count > AdminPushNotificationValidation.titleLimit {
                                title = String(value.prefix(AdminPushNotificationValidation.titleLimit))
                            }
                            draftDidChange()
                        }
                    TextEditor(text: $message)
                        .frame(minHeight: 110)
                        .disabled(isSending)
                        .onChange(of: message) { _, value in
                            if value.count > AdminPushNotificationValidation.bodyLimit {
                                message = String(value.prefix(AdminPushNotificationValidation.bodyLimit))
                            }
                            draftDidChange()
                        }
                    HStack {
                        Spacer()
                        Text("\(message.count)/\(AdminPushNotificationValidation.bodyLimit)")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }
                }

                Section {
                    Toggle("隐私模式", isOn: $privacyMode)
                        .tint(AppTheme.gold)
                        .disabled(isSending)
                        .onChange(of: privacyMode) { _, _ in draftDidChange() }
                    Text(
                        privacyMode
                            ? "已开启：原文保存到收件人的云端消息箱，锁屏仅显示“有新消息，请登录查看”。"
                            : "已关闭：将按上方文本发送。请确保内容不含联系方式、账号、密码或其他敏感信息。"
                    )
                    .font(.caption)
                    .foregroundStyle(privacyMode ? AppTheme.muted : AppTheme.warning)
                } footer: {
                    Text("消息会保存在该用户的云端消息箱。通知权限只影响系统提醒，不影响登录后查看消息，也不会暴露设备令牌。")
                }

                if let resultMessage {
                    Section {
                        Label(resultMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.gold)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                    }
                }

                Section {
                    Button {
                        beginSend()
                    } label: {
                        HStack {
                            Spacer()
                            if isSending { ProgressView() }
                            Text(isSending ? "正在加入队列" : "发送给该用户")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isSending || normalizedContent == nil || !admin.isAuthenticated)
                    .accessibilityIdentifier("admin-confirm-user-push")
                }
            }
            .navigationTitle("定向通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSending)
        .alert("确认发送自定义通知？", isPresented: $showCustomConfirmation) {
            Button("确认发送", role: .destructive) {
                guard let content = customConfirmationContent else { return }
                Task { await send(content) }
            }
            Button("取消", role: .cancel) {
                customConfirmationContent = nil
            }
        } message: {
            if let content = customConfirmationContent {
                Text(
                    AdminPushConfirmationPolicy.summary(
                        recipient: "\(user.displayName)（\(user.identityCode)）",
                        content: content
                    )
                )
            }
        }
    }

    private func beginSend() {
        guard AdminTargetedPushRecipientPolicy.isEligible(user) else {
            errorMessage = "该账号当前状态不允许发送定向通知。"
            return
        }
        guard let content = normalizedContent, admin.isAuthenticated else {
            errorMessage = "请完整填写标题和正文。"
            return
        }
        if AdminPushConfirmationPolicy.requiresSecondConfirmation(for: content) {
            customConfirmationContent = content
            showCustomConfirmation = true
        } else {
            Task { await send(content) }
        }
    }

    private func send(_ content: AdminPushNotificationContent) async {
        guard AdminTargetedPushRecipientPolicy.isEligible(user) else {
            errorMessage = "该账号当前状态不允许发送定向通知。"
            return
        }
        guard admin.isAuthenticated,
              !isSending else {
            errorMessage = "请完整填写标题和正文。"
            return
        }
        customConfirmationContent = nil
        isSending = true
        resultMessage = nil
        errorMessage = nil
        defer { isSending = false }
        do {
            let response = try await admin.sendPushNotification(
                toUserID: user.userID,
                title: content.title,
                body: content.body,
                sensitive: content.sensitive,
                idempotencyKey: idempotencyKey
            )
            idempotencyKey = UUID()
            resultMessage = response.deviceCount > 0
                ? "已存入消息箱，系统提醒已加入 \(response.deviceCount) 台设备的发送队列。"
                : "已存入该用户的消息箱；暂无线上的推送设备，用户登录后仍可查看。"
        } catch {
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? "暂时无法发送通知。"
        }
    }

    private func draftDidChange() {
        guard !isSending else { return }
        idempotencyKey = UUID()
        resultMessage = nil
        errorMessage = nil
        customConfirmationContent = nil
        showCustomConfirmation = false
    }
}

private struct AdministratorLockedView: View {
    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ContentUnavailableView(
                "管理员会话已锁定",
                systemImage: "lock.shield.fill",
                description: Text("请返回管理员入口并重新输入访问码。")
            )
            .foregroundStyle(AppTheme.warmWhite)
        }
        .accessibilityIdentifier("admin-session-locked")
    }
}

private struct FanAdminUserRow: View {
    let user: AdminFanUser

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: rowIcon)
                .font(.title)
                .foregroundStyle(user.status == FanAccountStatus.active.rawValue ? AppTheme.gold : AppTheme.warning)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(user.displayName).font(.subheadline.weight(.semibold))
                    Text(rowStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(user.status == FanAccountStatus.active.rawValue ? AppTheme.gold : AppTheme.warning)
                }
                Text(user.requiresAppleRegistration
                     ? "等待完成账号申请 · \(user.identityCode)"
                     : user.requiresAccountSetup
                     ? "待本人完成首次设置 · \(user.identityCode)"
                     : (user.douyinID.isEmpty
                        ? "抖音 ID 待补全 · \(user.identityCode)"
                        : "@\(user.douyinID) · \(user.identityCode)"))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(14)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 7))
    }

    private var rowIcon: String {
        switch FanAccountStatus(rawValue: user.status) {
        case .some(.pending): return "person.crop.circle.badge.questionmark"
        case .some(.active): return "person.crop.circle.badge.checkmark"
        case .some(.rejected): return "person.crop.circle.badge.xmark"
        case .some(.suspended), .none: return "person.crop.circle.badge.minus"
        }
    }

    private var rowStatus: String {
        switch FanAccountStatus(rawValue: user.status) {
        case .some(.pending): return "待审批"
        case .some(.active): return "已批准 · \(user.permissions.count) 项权限"
        case .some(.rejected): return "已拒绝"
        case .some(.suspended): return "已暂停"
        case .none: return "状态异常"
        }
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
            .frame(minHeight: 48)
            .modifier(ThemeInputChrome())
    }
}
