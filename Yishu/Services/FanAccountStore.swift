import Foundation
import Security

enum FanPermission: String, CaseIterable, Identifiable {
    case galleryFull = "gallery_full"
    case videoView = "video_view"
    case earlyAccess = "early_access"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .galleryFull: "完整相册"
        case .videoView: "影视内容"
        case .earlyAccess: "提前观看"
        }
    }

    var detail: String {
        switch self {
        case .galleryFull: "查看完整照片作品"
        case .videoView: "查看 Showreel 与影视内容"
        case .earlyAccess: "提前体验新作品和新功能"
        }
    }
}

enum FanAccountStatus: String, CaseIterable {
    case pending
    case active
    case rejected
    case suspended
}

struct FanProfile: Codable, Equatable {
    let userID: String
    let identityCode: String
    let displayName: String
    let douyinID: String
    let installationCode: String
    let permissions: [String]
    let status: String
    let sessionExpiresAt: Date
    let requiresAccountSetup: Bool
    let invitationExpiresAt: Date?
    let requiresPasswordChange: Bool
    let passwordRecoveryExpiresAt: Date?

    init(
        userID: String,
        identityCode: String,
        displayName: String,
        douyinID: String,
        installationCode: String,
        permissions: [String],
        status: String,
        sessionExpiresAt: Date,
        requiresAccountSetup: Bool = false,
        invitationExpiresAt: Date? = nil,
        requiresPasswordChange: Bool = false,
        passwordRecoveryExpiresAt: Date? = nil
    ) {
        self.userID = userID
        self.identityCode = identityCode
        self.displayName = displayName
        self.douyinID = douyinID
        self.installationCode = installationCode
        self.permissions = permissions
        self.status = status
        self.sessionExpiresAt = sessionExpiresAt
        self.requiresAccountSetup = requiresAccountSetup
        self.invitationExpiresAt = invitationExpiresAt
        self.requiresPasswordChange = requiresPasswordChange
        self.passwordRecoveryExpiresAt = passwordRecoveryExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case userID
        case identityCode
        case displayName
        case douyinID
        case installationCode
        case permissions
        case status
        case sessionExpiresAt
        case requiresAccountSetup
        case invitationExpiresAt
        case requiresPasswordChange
        case passwordRecoveryExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        identityCode = try container.decode(String.self, forKey: .identityCode)
        displayName = try container.decode(String.self, forKey: .displayName)
        douyinID = try container.decode(String.self, forKey: .douyinID)
        installationCode = try container.decode(String.self, forKey: .installationCode)
        permissions = try container.decode([String].self, forKey: .permissions)
        status = try container.decode(String.self, forKey: .status)
        sessionExpiresAt = try container.decode(Date.self, forKey: .sessionExpiresAt)
        // Responses from builds before invitation onboarding omit both fields.
        // Treat those established accounts as fully configured, while the
        // consistency checks below fail closed for partial or contradictory data.
        requiresAccountSetup = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresAccountSetup
        ) ?? false
        invitationExpiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .invitationExpiresAt
        )
        requiresPasswordChange = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresPasswordChange
        ) ?? false
        passwordRecoveryExpiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .passwordRecoveryExpiresAt
        )
    }

    var accountStatus: FanAccountStatus? { FanAccountStatus(rawValue: status) }
    var hasConsistentAccountSetupState: Bool {
        FanAccountValidation.hasConsistentSecuritySetupState(
            douyinID: douyinID,
            requiresAccountSetup: requiresAccountSetup,
            invitationExpiresAt: invitationExpiresAt,
            requiresPasswordChange: requiresPasswordChange,
            passwordRecoveryExpiresAt: passwordRecoveryExpiresAt
        )
    }
    func isApproved(at date: Date) -> Bool {
        accountStatus == .active
            && !requiresAccountSetup
            && !requiresPasswordChange
            && hasConsistentAccountSetupState
            && sessionExpiresAt > date
    }

    var isApproved: Bool {
        isApproved(at: Date())
    }

    func hasPermission(_ permission: FanPermission, at date: Date = Date()) -> Bool {
        isApproved(at: date) && permissions.contains(permission.rawValue)
    }
}

struct FanRequiredSetupInput: Equatable {
    let displayName: String
    let douyinID: String
    let currentPassword: String
    let newPassword: String
}

struct FanPasswordChangeInput: Equatable {
    let currentPassword: String
    let newPassword: String
}

struct FanSessionRecord: Codable, Identifiable, Equatable {
    let sessionID: String
    let installationCode: String
    let createdAt: Date
    let expiresAt: Date
    let isCurrent: Bool

    var id: String { sessionID }
}

enum FanAccountValidation {
    private static let invitationPlaceholderPattern = #"^invite_[a-f0-9]{24}$"#
    private static let temporaryPasswordPattern = #"^Tmp-[A-Za-z0-9_-]{24}-9!$"#

    static func normalizedIdentityCode(_ value: String) -> String? {
        var compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: #"[\s-]+"#, with: "", options: .regularExpression)
        if compact.hasPrefix("HS") { compact.removeFirst(2) }
        guard compact.range(
            of: #"^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return "HS-\(compact.prefix(4))-\(compact.suffix(4))"
    }

    static func normalizedDouyinID(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasPrefix("@") { candidate.removeFirst() }
        candidate = candidate.lowercased()
        guard (2...50).contains(candidate.count),
              candidate.range(
                of: #"^[\p{L}\p{N}._-]+$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return candidate
    }

    static func isValidDisplayName(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...30).contains(clean.count)
    }

    static func isValidPassword(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              (10...128).contains(value.count) else { return false }
        let containsLetter = value.range(of: #"\p{L}"#, options: .regularExpression) != nil
        let containsNumber = value.range(of: #"[0-9]"#, options: .regularExpression) != nil
        let containsSymbol = value.range(
            of: #"[^\p{L}0-9\s]"#,
            options: .regularExpression
        ) != nil
        return [containsLetter, containsNumber, containsSymbol].filter { $0 }.count >= 2
    }

    static func isInvitationPlaceholderDouyinID(_ value: String) -> Bool {
        value.range(of: invitationPlaceholderPattern, options: .regularExpression) != nil
    }

    static func isValidInvitationTemporaryPassword(_ value: String) -> Bool {
        value.range(of: temporaryPasswordPattern, options: .regularExpression) != nil
    }

    static func hasConsistentAccountSetupState(
        douyinID: String,
        requiresAccountSetup: Bool,
        invitationExpiresAt: Date?
    ) -> Bool {
        if requiresAccountSetup {
            return invitationExpiresAt != nil && isInvitationPlaceholderDouyinID(douyinID)
        }
        return invitationExpiresAt == nil && !isInvitationPlaceholderDouyinID(douyinID)
    }

    static func hasConsistentSecuritySetupState(
        douyinID: String,
        requiresAccountSetup: Bool,
        invitationExpiresAt: Date?,
        requiresPasswordChange: Bool,
        passwordRecoveryExpiresAt: Date?
    ) -> Bool {
        guard !(requiresAccountSetup && requiresPasswordChange) else { return false }
        guard hasConsistentAccountSetupState(
            douyinID: douyinID,
            requiresAccountSetup: requiresAccountSetup,
            invitationExpiresAt: invitationExpiresAt
        ) else { return false }
        if requiresPasswordChange {
            return !isInvitationPlaceholderDouyinID(douyinID)
                && passwordRecoveryExpiresAt != nil
        }
        return passwordRecoveryExpiresAt == nil
    }

    static func validatedPasswordChange(
        currentPassword: String,
        newPassword: String,
        newPasswordConfirmation: String
    ) throws -> FanPasswordChangeInput {
        guard !currentPassword.isEmpty, currentPassword.count <= 512 else {
            throw FanAccountError.invalidCredentials
        }
        guard isValidPassword(newPassword) else { throw FanAccountError.weakPassword }
        guard newPassword != currentPassword else { throw FanAccountError.passwordMustChange }
        guard newPassword == newPasswordConfirmation else {
            throw FanAccountError.passwordMismatch
        }
        return FanPasswordChangeInput(
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }

    static func isValidSessionDirectory(
        _ sessions: [FanSessionRecord],
        currentInstallationCode: String,
        now: Date = Date()
    ) -> Bool {
        guard (1...8).contains(sessions.count),
              Set(sessions.map(\.sessionID)).count == sessions.count,
              sessions.filter(\.isCurrent).count == 1 else { return false }
        return sessions.allSatisfy { session in
            session.sessionID.range(
                of: #"^[a-f0-9]{32}$"#,
                options: .regularExpression
            ) != nil
                && session.installationCode.range(
                    of: #"^IN-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{3}$"#,
                    options: .regularExpression
                ) != nil
                && session.createdAt <= session.expiresAt
                && session.expiresAt > now
                && (!session.isCurrent || session.installationCode == currentInstallationCode)
        }
    }

    static func isValidProfile(_ profile: FanProfile, now: Date = Date()) -> Bool {
        UUID(uuidString: profile.userID) != nil
            && normalizedIdentityCode(profile.identityCode) == profile.identityCode
            && normalizedDouyinID(profile.douyinID) == profile.douyinID
            && FanAccountStatus(rawValue: profile.status) != nil
            && profile.sessionExpiresAt > now
            && (!profile.requiresPasswordChange
                || profile.passwordRecoveryExpiresAt.map { $0 > now } == true)
            && profile.hasConsistentAccountSetupState
    }

    static func isValidAdminFanUser(_ user: AdminFanUser) -> Bool {
        UUID(uuidString: user.userID) != nil
            && normalizedIdentityCode(user.identityCode) == user.identityCode
            && normalizedDouyinID(user.douyinID) == user.douyinID
            && FanAccountStatus(rawValue: user.status) != nil
            && hasConsistentSecuritySetupState(
                douyinID: user.douyinID,
                requiresAccountSetup: user.requiresAccountSetup,
                invitationExpiresAt: user.invitationExpiresAt,
                requiresPasswordChange: user.requiresPasswordChange,
                passwordRecoveryExpiresAt: user.passwordRecoveryExpiresAt
            )
    }

    static func validatedRequiredSetup(
        displayName: String,
        douyinID: String,
        currentPassword: String,
        newPassword: String,
        newPasswordConfirmation: String,
        acceptedDataUse: Bool
    ) throws -> FanRequiredSetupInput {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDisplayName(cleanName) else { throw FanAccountError.invalidDisplayName }
        guard let cleanDouyinID = normalizedDouyinID(douyinID),
              !isInvitationPlaceholderDouyinID(cleanDouyinID) else {
            throw FanAccountError.invalidDouyinID
        }
        guard isValidInvitationTemporaryPassword(currentPassword) else {
            throw FanAccountError.invalidCredentials
        }
        guard acceptedDataUse else { throw FanAccountError.consentRequired }
        guard isValidPassword(newPassword) else { throw FanAccountError.weakPassword }
        guard newPassword != currentPassword else { throw FanAccountError.passwordMustChange }
        guard newPassword == newPasswordConfirmation else {
            throw FanAccountError.passwordMismatch
        }
        return FanRequiredSetupInput(
            displayName: cleanName,
            douyinID: cleanDouyinID,
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }
}

enum FanAccountError: LocalizedError {
    case invalidDisplayName
    case invalidDouyinID
    case consentRequired
    case weakPassword
    case passwordMismatch
    case passwordMustChange
    case invalidIdentityCode
    case invalidCredentials
    case accountSetupRequired
    case accountSetupNotRequired
    case invitationExpired
    case passwordRecoveryRequired
    case passwordRecoveryExpired
    case currentSessionCannotBeRevoked
    case sessionExpired
    case approvalPending
    case approvalRejected
    case accountSuspended
    case rateLimited
    case invalidResponse
    case unavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidDisplayName: "请填写 1–30 个字符的昵称。"
        case .invalidDouyinID: "请填写 2–50 位的抖音 ID，不要填链接。"
        case .consentRequired: "请先阅读并确认账号资料的使用说明。"
        case .weakPassword: "密码至少 10 位，并包含文字或字母、数字、符号中的至少两类。"
        case .passwordMismatch: "两次输入的密码不一致。"
        case .passwordMustChange: "新密码不能与临时密码相同。"
        case .invalidIdentityCode: "请输入完整的粉丝身份码。"
        case .invalidCredentials: "身份码或密码不正确。"
        case .accountSetupRequired: "请先完成账号资料和新密码设置。"
        case .accountSetupNotRequired: "当前账号不需要完成临时账号设置。"
        case .invitationExpired: "临时账号已过期，请联系管理员重新生成。"
        case .passwordRecoveryRequired: "请使用临时恢复凭据设置一个新密码。"
        case .passwordRecoveryExpired: "密码恢复凭据已过期，请联系管理员重新生成。"
        case .currentSessionCannotBeRevoked: "当前设备请使用退出登录。"
        case .sessionExpired: "登录已失效，请重新登录。"
        case .approvalPending: "注册申请正在等待管理员审批。"
        case .approvalRejected: "注册申请未通过审批。"
        case .accountSuspended: "账号访问已暂停，请联系管理员。"
        case .rateLimited: "尝试次数过多，请稍后再试。"
        case .invalidResponse: "服务器返回了无法识别的账号数据。"
        case .unavailable: "暂时无法连接账号服务，请检查网络后重试。"
        case .server(let message): message
        }
    }
}

enum FanAccountOperationGuard {
    static func canAccept(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        expectedToken: String?,
        currentToken: String?
    ) -> Bool {
        requestGeneration == currentGeneration && expectedToken == currentToken
    }
}

enum FanDeletionFailurePolicy {
    static func shouldFailClosed(after error: FanAccountError) -> Bool {
        switch error {
        case .unavailable, .invalidResponse: true
        default: false
        }
    }
}

@MainActor
final class FanAccountStore: ObservableObject {
    @Published private(set) var profile: FanProfile?
    @Published private(set) var sessions: [FanSessionRecord] = []
    @Published private(set) var removedAccountUserID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedSession = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let apiRoot = URL(string: "https://shuzijun.com.cn/wp-json")!
    private let session: URLSession
    private let installID: UUID
    private var token: String?
    private var lastSuccessfulRefresh: Date?
    private var sessionExpiryTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    var isAuthenticated: Bool {
        token != nil && profile.map { $0.sessionExpiresAt > Date() } == true
    }
    var isApproved: Bool {
        token != nil && profile?.isApproved(at: Date()) == true
    }

    init() {
        session = SecureURLSessionFactory.make(requestTimeout: 30, resourceTimeout: 45)
        installID = FanAccountKeychain.loadOrCreateInstallID()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset-fan-session-for-visual-testing") {
            FanAccountKeychain.deleteToken()
        }
#endif
        token = FanAccountKeychain.loadToken()
        hasSavedSession = token != nil
    }

    func hasPermission(_ permission: FanPermission) -> Bool {
        token != nil && profile?.hasPermission(permission, at: Date()) == true
    }

    /// Clears an expired session without waiting for a network round trip. This
    /// is called on foreground entry as well as by the scheduled expiry task so
    /// an unavailable server can never extend access from stale memory.
    @discardableResult
    func clearExpiredSessionIfNeeded(now: Date = Date()) -> Bool {
        guard let profile, profile.sessionExpiresAt <= now else { return false }
        clearLocalSession()
        errorMessage = FanAccountError.sessionExpired.errorDescription
        noticeMessage = nil
        return true
    }

    func restoreSession() async {
        guard token != nil, profile == nil else { return }
        await refreshSession(showError: false)
    }

    func refreshIfNeeded(minimumInterval: TimeInterval = 300) async {
        guard !clearExpiredSessionIfNeeded() else { return }
        guard token != nil else { return }
        if let lastSuccessfulRefresh,
           Date().timeIntervalSince(lastSuccessfulRefresh) < minimumInterval { return }
        await refreshSession(showError: false)
    }

    func refreshSession(showError: Bool = true) async {
        guard !clearExpiredSessionIfNeeded() else {
            if !showError { errorMessage = nil }
            return
        }
        guard let refreshToken = token else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isWorking = true
        defer { isWorking = false }
        do {
            let response: FanSessionResponse = try await perform(
                path: "shuzijun/v1/fan/session",
                method: "GET",
                authorized: true
            )
            guard FanAccountValidation.isValidProfile(response.profile) else {
                throw FanAccountError.invalidResponse
            }
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            profile = response.profile
            lastSuccessfulRefresh = Date()
            scheduleSessionExpiration()
            errorMessage = nil
        } catch FanAccountError.sessionExpired {
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            clearLocalSession()
            if showError { errorMessage = FanAccountError.sessionExpired.errorDescription }
        } catch FanAccountError.accountSuspended {
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            clearLocalSession()
            if showError { errorMessage = FanAccountError.accountSuspended.errorDescription }
        } catch FanAccountError.invalidResponse {
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            // A contradictory setup state must never leave an older approved
            // profile usable in memory.
            clearLocalSession()
            if showError { errorMessage = FanAccountError.invalidResponse.errorDescription }
        } catch {
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            if showError {
                errorMessage = (error as? FanAccountError)?.errorDescription
                    ?? FanAccountError.unavailable.errorDescription
            }
        }
    }

    func register(
        displayName: String,
        douyinID: String,
        password: String,
        passwordConfirmation: String,
        acceptedDataUse: Bool
    ) async {
        noticeMessage = nil
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FanAccountValidation.isValidDisplayName(cleanName) else {
            errorMessage = FanAccountError.invalidDisplayName.errorDescription
            return
        }
        guard let cleanDouyinID = FanAccountValidation.normalizedDouyinID(douyinID) else {
            errorMessage = FanAccountError.invalidDouyinID.errorDescription
            return
        }
        guard acceptedDataUse else {
            errorMessage = FanAccountError.consentRequired.errorDescription
            return
        }
        guard FanAccountValidation.isValidPassword(password) else {
            errorMessage = FanAccountError.weakPassword.errorDescription
            return
        }
        guard password == passwordConfirmation else {
            errorMessage = FanAccountError.passwordMismatch.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanRegistrationRequest(
                    displayName: cleanName,
                    douyinID: cleanDouyinID,
                    password: password,
                    installID: installID.uuidString.lowercased(),
                    consentVersion: "2026-08-31-approval-v2"
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/register",
                method: "POST",
                body: body,
                authorized: false
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            try accept(response)
            noticeMessage = "注册申请已提交，请等待管理员审批。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func signIn(identityCode: String, password: String) async {
        noticeMessage = nil
        guard let cleanCode = FanAccountValidation.normalizedIdentityCode(identityCode) else {
            errorMessage = FanAccountError.invalidIdentityCode.errorDescription
            return
        }
        guard !password.isEmpty, password.count <= 128 else {
            errorMessage = FanAccountError.invalidCredentials.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanLoginRequest(
                    identityCode: cleanCode,
                    password: password,
                    installID: installID.uuidString.lowercased()
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/login",
                method: "POST",
                body: body,
                authorized: false
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            try accept(response)
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func completeRequiredSetup(
        displayName: String,
        douyinID: String,
        currentPassword: String,
        newPassword: String,
        passwordConfirmation: String,
        acceptedDataUse: Bool
    ) async {
        noticeMessage = nil
        let input: FanRequiredSetupInput
        do {
            input = try FanAccountValidation.validatedRequiredSetup(
                displayName: displayName,
                douyinID: douyinID,
                currentPassword: currentPassword,
                newPassword: newPassword,
                newPasswordConfirmation: passwordConfirmation,
                acceptedDataUse: acceptedDataUse
            )
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.invalidResponse.errorDescription
            return
        }

        guard token != nil, let existingProfile = profile else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }
        guard existingProfile.requiresAccountSetup else {
            errorMessage = FanAccountError.accountSetupNotRequired.errorDescription
            return
        }
        guard existingProfile.hasConsistentAccountSetupState else {
            errorMessage = FanAccountError.invalidResponse.errorDescription
            return
        }
        guard let invitationExpiresAt = existingProfile.invitationExpiresAt,
              invitationExpiresAt > Date() else {
            errorMessage = FanAccountError.invitationExpired.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token

        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanInvitationCompletionRequest(
                    displayName: input.displayName,
                    douyinID: input.douyinID,
                    currentPassword: input.currentPassword,
                    newPassword: input.newPassword,
                    installID: installID.uuidString.lowercased(),
                    consentVersion: "2026-08-31-approval-v2"
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/complete-invitation",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            guard response.profile.userID == existingProfile.userID,
                  !response.profile.requiresAccountSetup else {
                throw FanAccountError.invalidResponse
            }
            try accept(response, requiringTokenRotation: true)
            noticeMessage = response.profile.isApproved
                ? "账号设置已完成。"
                : "账号设置已完成，请等待管理员审批。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func completePasswordRecovery(
        currentPassword: String,
        newPassword: String,
        passwordConfirmation: String
    ) async {
        noticeMessage = nil
        let input: FanPasswordChangeInput
        do {
            input = try FanAccountValidation.validatedPasswordChange(
                currentPassword: currentPassword,
                newPassword: newPassword,
                newPasswordConfirmation: passwordConfirmation
            )
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.invalidResponse.errorDescription
            return
        }
        guard token != nil, let existingProfile = profile,
              existingProfile.requiresPasswordChange,
              let recoveryExpiry = existingProfile.passwordRecoveryExpiresAt,
              recoveryExpiry > Date() else {
            errorMessage = FanAccountError.passwordRecoveryExpired.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token

        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanPasswordChangeRequest(
                    currentPassword: input.currentPassword,
                    newPassword: input.newPassword,
                    installID: installID.uuidString.lowercased()
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/complete-password-recovery",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            guard response.profile.userID == existingProfile.userID,
                  !response.profile.requiresPasswordChange else {
                throw FanAccountError.invalidResponse
            }
            try accept(response, requiringTokenRotation: true)
            sessions.removeAll()
            noticeMessage = "新密码已设置，其他设备已退出登录。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func changePassword(
        currentPassword: String,
        newPassword: String,
        passwordConfirmation: String
    ) async {
        noticeMessage = nil
        let input: FanPasswordChangeInput
        do {
            input = try FanAccountValidation.validatedPasswordChange(
                currentPassword: currentPassword,
                newPassword: newPassword,
                newPasswordConfirmation: passwordConfirmation
            )
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.invalidResponse.errorDescription
            return
        }
        guard token != nil, let existingProfile = profile,
              !existingProfile.requiresAccountSetup,
              !existingProfile.requiresPasswordChange else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token

        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanPasswordChangeRequest(
                    currentPassword: input.currentPassword,
                    newPassword: input.newPassword,
                    installID: installID.uuidString.lowercased()
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/change-password",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            guard response.profile.userID == existingProfile.userID,
                  !response.profile.requiresPasswordChange else {
                throw FanAccountError.invalidResponse
            }
            try accept(response, requiringTokenRotation: true)
            sessions.removeAll()
            noticeMessage = "密码已更新，其他设备已退出登录。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func fetchSessions() async {
        guard let expectedToken = token, let profile,
              !profile.requiresAccountSetup,
              !profile.requiresPasswordChange else {
            sessions.removeAll()
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }
        let operationGeneration = refreshGeneration
        let expectedUserID = profile.userID
        isWorking = true
        defer { isWorking = false }
        do {
            let response: FanSessionDirectoryResponse = try await perform(
                path: "shuzijun/v1/fan/sessions",
                method: "GET",
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), self.profile?.userID == expectedUserID else { return }
            guard FanAccountValidation.isValidSessionDirectory(
                response.sessions,
                currentInstallationCode: profile.installationCode
            ) else { throw FanAccountError.invalidResponse }
            sessions = response.sessions
            errorMessage = nil
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), self.profile?.userID == expectedUserID else { return }
            sessions.removeAll()
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func revokeSession(_ sessionID: String) async {
        guard let expectedToken = token, let profile,
              sessionID.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
              sessions.first(where: { $0.sessionID == sessionID })?.isCurrent == false else {
            errorMessage = FanAccountError.currentSessionCannotBeRevoked.errorDescription
            return
        }
        let operationGeneration = refreshGeneration
        let expectedUserID = profile.userID
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(FanSessionRevokeRequest(sessionID: sessionID))
            let response: FanSessionRevokeResponse = try await perform(
                path: "shuzijun/v1/fan/sessions/revoke",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), self.profile?.userID == expectedUserID else { return }
            guard response.ok,
                  FanAccountValidation.isValidSessionDirectory(
                    response.sessions,
                    currentInstallationCode: profile.installationCode
                  ),
                  !response.sessions.contains(where: { $0.sessionID == sessionID }) else {
                throw FanAccountError.invalidResponse
            }
            sessions = response.sessions
            errorMessage = nil
            noticeMessage = "已撤销所选设备的会话。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), self.profile?.userID == expectedUserID else { return }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func signOut() async {
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        if expectedToken != nil {
            let _: FanLogoutResponse? = try? await perform(
                path: "shuzijun/v1/fan/logout",
                method: "POST",
                authorized: true
            )
        }
        guard FanAccountOperationGuard.canAccept(
            requestGeneration: operationGeneration,
            currentGeneration: refreshGeneration,
            expectedToken: expectedToken,
            currentToken: token
        ) else { return }
        clearLocalSession()
        errorMessage = nil
        noticeMessage = nil
    }

    func deleteAccount(currentPassword: String) async {
        guard let expectedToken = token, let existingProfile = profile else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }
        guard !currentPassword.isEmpty, currentPassword.count <= 512 else {
            errorMessage = FanAccountError.invalidCredentials.errorDescription
            return
        }
        let deletingUserID = existingProfile.userID
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanDeletionRequest(
                    confirmation: "DELETE_ACCOUNT",
                    currentPassword: currentPassword,
                    installID: installID.uuidString.lowercased()
                )
            )
            let response: FanLogoutResponse = try await perform(
                path: "shuzijun/v1/fan/delete",
                method: "POST",
                body: body,
                authorized: true
            )
            guard response.ok else { throw FanAccountError.invalidResponse }
            // The server deletion is authoritative. Publish the deleted user
            // namespace even if the user switched accounts while awaiting the
            // response, but never clear a newer account's token.
            removedAccountUserID = deletingUserID
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), profile?.userID == deletingUserID else { return }
            clearLocalSession()
            errorMessage = nil
            noticeMessage = "账号与关联个人资料已永久删除。"
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), profile?.userID == deletingUserID else { return }
            let accountError = error as? FanAccountError ?? .unavailable
            if FanDeletionFailurePolicy.shouldFailClosed(after: accountError) {
                clearLocalSession()
                removedAccountUserID = deletingUserID
                errorMessage = "删除请求的远端结果未能确认。为保护你的资料，本机已退出并清除该账号内容；请重新登录确认账号状态。"
                noticeMessage = nil
                return
            }
            errorMessage = accountError.errorDescription
        }
    }

    func fetchApprovedContent() async throws -> AppContentManifest {
        guard isApproved else {
            if profile?.requiresAccountSetup == true {
                throw FanAccountError.accountSetupRequired
            }
            if profile?.requiresPasswordChange == true {
                throw FanAccountError.passwordRecoveryRequired
            }
            switch profile?.accountStatus {
            case .some(.pending): throw FanAccountError.approvalPending
            case .some(.rejected): throw FanAccountError.approvalRejected
            case .some(.suspended): throw FanAccountError.accountSuspended
            default: throw FanAccountError.sessionExpired
            }
        }
        let manifest: AppContentManifest = try await perform(
            path: "shuzijun/v1/app-content",
            method: "GET",
            authorized: true
        )
        guard ContentSecurityPolicy.isTrusted(manifest) else {
            throw FanAccountError.invalidResponse
        }
        return manifest
    }

    private func accept(
        _ response: FanAuthResponse,
        requiringTokenRotation: Bool = false
    ) throws {
        guard response.token.range(
            of: #"^[A-Za-z0-9_-]{43,128}$"#,
            options: .regularExpression
        ) != nil,
              (!requiringTokenRotation || response.token != token),
              FanAccountValidation.isValidProfile(response.profile) else {
            throw FanAccountError.invalidResponse
        }
        let previousUserID = profile?.userID
        try FanAccountKeychain.saveToken(response.token)
        refreshGeneration &+= 1
        token = response.token
        hasSavedSession = true
        profile = response.profile
        if previousUserID != nil, previousUserID != response.profile.userID {
            sessions.removeAll()
        }
        lastSuccessfulRefresh = Date()
        scheduleSessionExpiration()
        errorMessage = nil
        noticeMessage = nil
    }

    private func clearLocalSession() {
        refreshGeneration &+= 1
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        FanAccountKeychain.deleteToken()
        token = nil
        profile = nil
        sessions.removeAll()
        hasSavedSession = false
        lastSuccessfulRefresh = nil
    }

    private func scheduleSessionExpiration() {
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        guard let expiresAt = profile?.sessionExpiresAt else { return }
        let delay = expiresAt.timeIntervalSinceNow
        guard delay > 0 else {
            _ = clearExpiredSessionIfNeeded()
            return
        }
        sessionExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = self.clearExpiredSessionIfNeeded()
        }
    }

    private func perform<T: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        authorized: Bool
    ) async throws -> T {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."),
              !path.contains("?"), !path.contains("#"),
              ["GET", "POST"].contains(method) else { throw FanAccountError.invalidResponse }
        let endpoint = apiRoot.appending(path: path)
        guard AppNetworkSecurityPolicy.isTrustedAdminAPIURL(endpoint) else {
            throw FanAccountError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Yishu-iOS-Fan/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(installID.uuidString.lowercased(), forHTTPHeaderField: "X-Yishu-Install-ID")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let token else { throw FanAccountError.sessionExpired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FanAccountError.unavailable
        }
        let maximumResponseBytes = path == "shuzijun/v1/app-content"
            ? 5 * 1024 * 1024
            : 1024 * 1024
        guard data.count <= maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              AppNetworkSecurityPolicy.isTrustedAdminAPIURL(http.url) else {
            throw FanAccountError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data: data, response: http)
        }
        guard !data.isEmpty,
              AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
              ) else { throw FanAccountError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FanAccountError.invalidResponse
        }
    }

    private func decodeError(data: Data, response: HTTPURLResponse) -> FanAccountError {
        let payload: FanServerError?
        if AppNetworkSecurityPolicy.isJSONMIMEType(
            response.value(forHTTPHeaderField: "Content-Type")
        ) {
            payload = try? JSONDecoder().decode(FanServerError.self, from: data)
        } else {
            payload = nil
        }
        switch (response.statusCode, payload?.code) {
        case (401, "fan_login_invalid"): return .invalidCredentials
        case (401, _): return .sessionExpired
        case (_, "fan_account_setup_required"): return .accountSetupRequired
        case (_, "fan_invitation_expired"): return .invitationExpired
        case (_, "fan_password_recovery_expired"): return .passwordRecoveryExpired
        case (_, "fan_password_recovery_session_required"): return .passwordRecoveryRequired
        case (_, "fan_normal_session_required"): return .passwordRecoveryRequired
        case (_, "fan_current_session_cannot_be_revoked"): return .currentSessionCannotBeRevoked
        case (_, "fan_new_password_must_differ"): return .passwordMustChange
        case (_, "fan_new_password_required"): return .passwordMustChange
        case (403, "fan_approval_pending"): return .approvalPending
        case (403, "fan_approval_rejected"): return .approvalRejected
        case (403, "fan_account_suspended"): return .accountSuspended
        case (429, _): return .rateLimited
        default:
            return .server(safeMessage(payload?.message, statusCode: response.statusCode))
        }
    }

    private func safeMessage(_ raw: String?, statusCode: Int) -> String {
        guard (400..<500).contains(statusCode), let raw else {
            return "账号服务暂时不可用（HTTP \(statusCode)）。"
        }
        let withoutHTML = String(raw.prefix(300)).replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let printable = withoutHTML.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let clean = String(String.UnicodeScalarView(printable))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return clean.isEmpty ? "请检查输入后重试。" : String(clean.prefix(160))
    }
}

struct AdminFanUser: Codable, Identifiable, Equatable {
    let userID: String
    let identityCode: String
    let displayName: String
    let douyinID: String
    let permissions: [String]
    let status: String
    let registeredAt: Date
    let reviewedAt: Date?
    let requiresAccountSetup: Bool
    let invitationExpiresAt: Date?
    let requiresPasswordChange: Bool
    let passwordRecoveryExpiresAt: Date?

    init(
        userID: String,
        identityCode: String,
        displayName: String,
        douyinID: String,
        permissions: [String],
        status: String,
        registeredAt: Date,
        reviewedAt: Date?,
        requiresAccountSetup: Bool = false,
        invitationExpiresAt: Date? = nil,
        requiresPasswordChange: Bool = false,
        passwordRecoveryExpiresAt: Date? = nil
    ) {
        self.userID = userID
        self.identityCode = identityCode
        self.displayName = displayName
        self.douyinID = douyinID
        self.permissions = permissions
        self.status = status
        self.registeredAt = registeredAt
        self.reviewedAt = reviewedAt
        self.requiresAccountSetup = requiresAccountSetup
        self.invitationExpiresAt = invitationExpiresAt
        self.requiresPasswordChange = requiresPasswordChange
        self.passwordRecoveryExpiresAt = passwordRecoveryExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case userID
        case identityCode
        case displayName
        case douyinID
        case permissions
        case status
        case registeredAt
        case reviewedAt
        case requiresAccountSetup
        case invitationExpiresAt
        case requiresPasswordChange
        case passwordRecoveryExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        identityCode = try container.decode(String.self, forKey: .identityCode)
        displayName = try container.decode(String.self, forKey: .displayName)
        douyinID = try container.decode(String.self, forKey: .douyinID)
        permissions = try container.decode([String].self, forKey: .permissions)
        status = try container.decode(String.self, forKey: .status)
        registeredAt = try container.decode(Date.self, forKey: .registeredAt)
        reviewedAt = try container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        requiresAccountSetup = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresAccountSetup
        ) ?? false
        invitationExpiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .invitationExpiresAt
        )
        requiresPasswordChange = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresPasswordChange
        ) ?? false
        passwordRecoveryExpiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .passwordRecoveryExpiresAt
        )
    }

    var id: String { userID }
    var hasConsistentAccountSetupState: Bool {
        FanAccountValidation.hasConsistentSecuritySetupState(
            douyinID: douyinID,
            requiresAccountSetup: requiresAccountSetup,
            invitationExpiresAt: invitationExpiresAt,
            requiresPasswordChange: requiresPasswordChange,
            passwordRecoveryExpiresAt: passwordRecoveryExpiresAt
        )
    }
}

struct AdminFanPermissionDefinition: Codable, Identifiable, Equatable {
    let code: String
    let title: String
    let description: String

    var id: String { code }
}

struct AdminFanDirectory: Codable {
    let users: [AdminFanUser]
    let permissionCatalog: [AdminFanPermissionDefinition]
}

private struct FanRegistrationRequest: Encodable {
    let displayName: String
    let douyinID: String
    let password: String
    let installID: String
    let consentVersion: String
}

private struct FanLoginRequest: Encodable {
    let identityCode: String
    let password: String
    let installID: String
}

private struct FanInvitationCompletionRequest: Encodable {
    let displayName: String
    let douyinID: String
    let currentPassword: String
    let newPassword: String
    let installID: String
    let consentVersion: String
}

private struct FanPasswordChangeRequest: Encodable {
    let currentPassword: String
    let newPassword: String
    let installID: String
}

private struct FanSessionRevokeRequest: Encodable {
    let sessionID: String
}

private struct FanDeletionRequest: Encodable {
    let confirmation: String
    let currentPassword: String
    let installID: String
}

private struct FanAuthResponse: Decodable {
    let token: String
    let profile: FanProfile
}

private struct FanSessionResponse: Decodable {
    let profile: FanProfile
}

private struct FanSessionDirectoryResponse: Decodable {
    let sessions: [FanSessionRecord]
}

private struct FanSessionRevokeResponse: Decodable {
    let ok: Bool
    let sessions: [FanSessionRecord]
}

private struct FanLogoutResponse: Decodable {
    let ok: Bool
}

private struct FanServerError: Decodable {
    let code: String?
    let message: String?
}

private enum FanAccountKeychain {
    private static let service = "cn.com.shuzijun.yishu.fan-account"
    private static let installAccount = "installation-id"
    private static let tokenAccount = "session-token"

    static func loadOrCreateInstallID() -> UUID {
        if let data = load(account: installAccount),
           let raw = String(data: data, encoding: .utf8),
           let value = UUID(uuidString: raw) {
            return value
        }
        let value = UUID()
        try? save(Data(value.uuidString.lowercased().utf8), account: installAccount)
        return value
    }

    static func loadToken() -> String? {
        guard let data = load(account: tokenAccount),
              let token = String(data: data, encoding: .utf8),
              token.range(
                of: #"^[A-Za-z0-9_-]{43,128}$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return token
    }

    static func saveToken(_ token: String) throws {
        try save(Data(token.utf8), account: tokenAccount)
    }

    static func deleteToken() {
        delete(account: tokenAccount)
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FanAccountError.unavailable }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
