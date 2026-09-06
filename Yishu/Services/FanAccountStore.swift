import AuthenticationServices
import Combine
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

enum FanAccountStatus: String, CaseIterable, Codable {
    case pending
    case active
    case rejected
    case suspended
}

enum FanAccountSource: String {
    case password
    case invitation
    case apple
}

enum FanAccountConsentPolicy {
    /// Every new acknowledgement is tied to the currently published policy.
    /// The server alone owns the compatibility allowlist for already stored
    /// acknowledgements so an old App cannot opt itself into legacy consent.
    static let currentVersion = "2026-09-04-approval-v4"
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
    let accountSource: String
    let requiresAppleRegistration: Bool
    /// Presentation hint only. The management endpoint independently verifies the role.
    let administratorBound: Bool

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
        passwordRecoveryExpiresAt: Date? = nil,
        accountSource: String = FanAccountSource.password.rawValue,
        requiresAppleRegistration: Bool = false,
        administratorBound: Bool = false
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
        self.accountSource = accountSource
        self.requiresAppleRegistration = requiresAppleRegistration
        self.administratorBound = administratorBound
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
        case accountSource
        case requiresAppleRegistration
        case administratorBound
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
        accountSource = try container.decodeIfPresent(
            String.self,
            forKey: .accountSource
        ) ?? FanAccountSource.password.rawValue
        requiresAppleRegistration = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresAppleRegistration
        ) ?? false
        administratorBound = try container.decodeIfPresent(Bool.self, forKey: .administratorBound) ?? false
    }

    var accountStatus: FanAccountStatus? { FanAccountStatus(rawValue: status) }
    var hasRequiredDouyinID: Bool {
        FanAccountValidation.isCompleteDouyinID(douyinID)
    }
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
            && hasRequiredDouyinID
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

struct FanAppleRegistrationState: Codable, Equatable {
    let expiresAt: Date
    let isDouyinMigration: Bool
    let displayName: String
    let preservedStatus: FanAccountStatus?

    init(
        expiresAt: Date,
        isDouyinMigration: Bool = false,
        displayName: String = "",
        preservedStatus: FanAccountStatus? = nil
    ) {
        self.expiresAt = expiresAt
        self.isDouyinMigration = isDouyinMigration
        self.displayName = displayName
        self.preservedStatus = preservedStatus
    }

    private enum CodingKeys: String, CodingKey {
        case expiresAt
        case isDouyinMigration
        case displayName
        case preservedStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        // During a staged rollout the previous server omits these fields; its
        // onboarding response can only represent a new application.
        isDouyinMigration = try container.decodeIfPresent(
            Bool.self,
            forKey: .isDouyinMigration
        ) ?? false
        displayName = try container.decodeIfPresent(
            String.self,
            forKey: .displayName
        ) ?? ""
        preservedStatus = try container.decodeIfPresent(
            FanAccountStatus.self,
            forKey: .preservedStatus
        )
    }

    func isValid(now: Date = Date()) -> Bool {
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 30 * 60 else {
            return false
        }
        if isDouyinMigration {
            return preservedStatus != nil
                && FanAccountValidation.isValidDisplayName(displayName)
        }
        return preservedStatus == nil
    }
}

enum FanAppleChallengePurpose: String, Encodable {
    case signIn = "sign_in"
    case deleteAccount = "delete_account"
}

struct FanAppleRegistrationInput: Equatable {
    let displayName: String
    let douyinID: String
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

    /// A completed fan profile must carry a real, normalized Douyin ID.
    /// Invitation placeholders are server-only onboarding state and never
    /// satisfy the member identity requirement.
    static func isCompleteDouyinID(_ value: String) -> Bool {
        normalizedDouyinID(value) == value && !isInvitationPlaceholderDouyinID(value)
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
            // Keep legacy blank profiles decodable so their owners can still
            // view account state, sign out and delete data. `isApproved`
            // separately fails closed until a required Douyin ID is present.
            && (profile.douyinID.isEmpty
                || normalizedDouyinID(profile.douyinID) == profile.douyinID)
            && FanAccountSource(rawValue: profile.accountSource) != nil
            && !profile.requiresAppleRegistration
            && FanAccountStatus(rawValue: profile.status) != nil
            && profile.sessionExpiresAt > now
            && (!profile.requiresPasswordChange
                || profile.passwordRecoveryExpiresAt.map { $0 > now } == true)
            && profile.hasConsistentAccountSetupState
    }

    static func isValidAdminFanUser(_ user: AdminFanUser) -> Bool {
        guard UUID(uuidString: user.userID) != nil,
              user.hasConsistentAdministratorBinding,
              normalizedIdentityCode(user.identityCode) == user.identityCode,
              let source = FanAccountSource(rawValue: user.accountSource),
              FanAccountStatus(rawValue: user.status) != nil else { return false }
        if user.requiresAppleRegistration {
            return source == .apple
                && user.douyinID.isEmpty
                && !user.requiresAccountSetup
                && user.invitationExpiresAt == nil
                && !user.requiresPasswordChange
                && user.passwordRecoveryExpiresAt == nil
        }
        return (user.douyinID.isEmpty
                || normalizedDouyinID(user.douyinID) == user.douyinID)
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

    static func validatedAppleRegistration(
        displayName: String,
        douyinID: String,
        acceptedDataUse: Bool
    ) throws -> FanAppleRegistrationInput {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDisplayName(cleanName) else { throw FanAccountError.invalidDisplayName }
        guard let cleanDouyinID = normalizedDouyinID(douyinID),
              !isInvitationPlaceholderDouyinID(cleanDouyinID) else {
            throw FanAccountError.invalidDouyinID
        }
        guard acceptedDataUse else { throw FanAccountError.consentRequired }
        return FanAppleRegistrationInput(displayName: cleanName, douyinID: cleanDouyinID)
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
    case appleRegistrationRequired
    case appleCredentialRevoked
    case appleCredentialTransferred
    case appleCredentialUnavailable
    case appleCredentialCheckFailed
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
        case .invalidDouyinID: "请填写 2–50 位抖音 ID，不要填链接。未绑定的旧账号请在账号页完成资料升级。"
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
        case .appleRegistrationRequired: "请先填写昵称并完成账号申请。"
        case .appleCredentialRevoked: "Apple 登录授权已撤销，请重新登录。"
        case .appleCredentialTransferred: "Apple 登录关系已转移，请重新通过 Apple 登录确认账号。"
        case .appleCredentialUnavailable: "无法确认当前 Apple 登录凭据，请重新通过 Apple 登录。"
        case .appleCredentialCheckFailed: "Apple 凭据状态检查暂时失败；当前有效的服务器会话会继续使用，并将在稍后重试检查。"
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

@MainActor
struct FanSignOutOperation {
    struct Request {
        let path: String
        let method: String
        let body: Data?
        let authorizationToken: String
    }

    private let requests: [Request]

    /// Freeze the old session requests and clear access synchronously, before
    /// even the first network suspension. Remote completion owns no local state.
    static func begin(
        authorizationToken: String?,
        unbindingBody: Data?,
        clearLocalState: () -> Void
    ) -> FanSignOutOperation {
        var requests: [Request] = []
        if let authorizationToken {
            if let unbindingBody {
                requests.append(Request(
                    path: "shuzijun/v1/fan/push-device", method: "DELETE",
                    body: unbindingBody, authorizationToken: authorizationToken
                ))
            }
            requests.append(Request(
                path: "shuzijun/v1/fan/logout", method: "POST",
                body: nil, authorizationToken: authorizationToken
            ))
        }
        clearLocalState()
        return FanSignOutOperation(requests: requests)
    }

    func complete(using send: (Request) async throws -> Void) async {
        for request in requests {
            // A failed unbind must not prevent best-effort old-session logout.
            // Neither success nor failure may clear a newly signed-in account.
            try? await send(request)
        }
    }
}

enum FanAppleRegistrationCompletionPolicy {
    static func accepts(_ profile: FanProfile) -> Bool {
        profile.accountStatus != nil
            && !profile.requiresAccountSetup
            && !profile.requiresPasswordChange
            && profile.hasRequiredDouyinID
    }

    static func notice(for status: FanAccountStatus) -> String {
        switch status {
        case .active:
            "抖音 ID 已补全，账号可继续使用。"
        case .pending:
            "账号申请已提交，请等待管理员审批。"
        case .rejected:
            "抖音 ID 已补全，账号申请仍未通过。"
        case .suspended:
            "抖音 ID 已补全，账号访问仍处于暂停状态。"
        }
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

enum FanAppleCredentialAccessState: Equatable, Hashable {
    case notRequired
    case checking
    case verified
    case retryRequired
}

enum FanAppleCredentialAccessPolicy {
    static func canUseValidServerSession(
        usesAppleSignIn: Bool,
        state: FanAppleCredentialAccessState
    ) -> Bool {
        guard usesAppleSignIn else { return true }
        return state == .verified || state == .retryRequired
    }
}

struct FanInstallationState: Codable, Equatable {
    let installID: UUID
    let bindingGeneration: UInt64
}

enum PushBindingGenerationPolicy {
    static let maximum = UInt64(Int64.max)

    static func next(after current: UInt64) -> UInt64? {
        guard current < maximum else { return nil }
        return current + 1
    }
}

enum FanAccountSecurityCapabilities {
    static func supportsPasswordChange(usesAppleSignIn: Bool) -> Bool {
        !usesAppleSignIn
    }
}

enum FanAppleDeletionEligibility {
    static func canBegin(
        hasToken: Bool,
        usesAppleSignIn: Bool,
        hasProfile: Bool,
        registration: FanAppleRegistrationState?,
        now: Date = Date()
    ) -> Bool {
        hasToken
            && usesAppleSignIn
            && (hasProfile || registration?.isValid(now: now) == true)
    }
}

struct FanAdministratorContext: Equatable {
    let userID: String
    let sessionGeneration: UInt64
    let environment: AppServiceEnvironment

    init(userID: String, sessionGeneration: UInt64, environment: AppServiceEnvironment = .production) {
        self.userID = userID
        self.sessionGeneration = sessionGeneration
        self.environment = environment
    }
}

enum FanAdministratorEligibility {
    static func context(
        profile: FanProfile?, hasSessionToken: Bool, credentialAccessAllowed: Bool,
        hasPendingAppleRegistration: Bool, sessionGeneration: UInt64, now: Date = .now,
        environment: AppServiceEnvironment = .production
    ) -> FanAdministratorContext? {
        guard hasSessionToken, credentialAccessAllowed, !hasPendingAppleRegistration,
              let profile, profile.administratorBound, profile.isApproved(at: now),
              !profile.requiresAppleRegistration else { return nil }
        return FanAdministratorContext(userID: profile.userID, sessionGeneration: sessionGeneration, environment: environment)
    }
}

@MainActor
protocol FanAdministratorAccount: AnyObject {
    var administratorContext: FanAdministratorContext? { get }
    var administratorChanges: AnyPublisher<Void, Never> { get }
    func authorizeAdministratorRequest(_ request: inout URLRequest, context: FanAdministratorContext) throws
}

@MainActor
final class FanAccountStore: ObservableObject, FanNotificationAccount, FanAdministratorAccount {
    @Published private(set) var profile: FanProfile? {
        didSet { notificationStore.updateContext(notificationContext) }
    }
    let notificationStore = FanNotificationStore()
    @Published private(set) var appleRegistration: FanAppleRegistrationState?
    @Published private(set) var usesAppleSignIn = false
    @Published private(set) var appleCredentialAccessState: FanAppleCredentialAccessState = .notRequired
    @Published private(set) var sessions: [FanSessionRecord] = []
    @Published private(set) var removedAccountUserID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedSession = false
    @Published private(set) var pushSessionGeneration: UInt64 = 0
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    let serviceEnvironment: AppServiceEnvironment
    private let apiRoot: URL
    private let keychain: FanAccountKeychain
    private let session: URLSession
    private let installID: UUID
    private var pushBindingGeneration: UInt64
    private var token: String?
    private var lastSuccessfulRefresh: Date?
    private var sessionExpiryTask: Task<Void, Never>?
    private var appleCredentialRetryTask: Task<Void, Never>?
    private var appleCredentialRetryAttempt = 0
    private var refreshGeneration: UInt64 = 0

    var isAuthenticated: Bool {
        token != nil && profile.map { $0.sessionExpiresAt > Date() } == true
    }
    var isApproved: Bool {
        token != nil
            && profile?.isApproved(at: Date()) == true
            && FanAppleCredentialAccessPolicy.canUseValidServerSession(
                usesAppleSignIn: usesAppleSignIn,
                state: appleCredentialAccessState
            )
    }
    var pushEligibleUserID: String? {
        return PushSessionEligibility.userID(
            profile: profile,
            hasSessionToken: token != nil,
            credentialAccessAllowed: FanAppleCredentialAccessPolicy.canUseValidServerSession(
                usesAppleSignIn: usesAppleSignIn,
                state: appleCredentialAccessState
            )
        )
    }
    var hasPushEligibleSession: Bool { pushEligibleUserID != nil }
    var administratorContext: FanAdministratorContext? {
        FanAdministratorEligibility.context(
            profile: profile, hasSessionToken: token != nil,
            credentialAccessAllowed: FanAppleCredentialAccessPolicy.canUseValidServerSession(
                usesAppleSignIn: usesAppleSignIn, state: appleCredentialAccessState
            ),
            hasPendingAppleRegistration: appleRegistration != nil,
            sessionGeneration: pushSessionGeneration,
            environment: serviceEnvironment
        )
    }
    var administratorChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
    func authorizeAdministratorRequest(_ request: inout URLRequest, context: FanAdministratorContext) throws {
        guard administratorContext == context, let token,
              (serviceEnvironment.allowsAPIURL(request.url)
                || serviceEnvironment.allowsMediaUploadURL(request.url)) else {
            throw AdminAPIError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(installID.uuidString.lowercased(), forHTTPHeaderField: "X-Yishu-Install-ID")
    }
    var notificationContext: FanNotificationContext? {
#if DEBUG
        if FanNotificationUITestFixture.isEnabled {
            return FanNotificationContext(userID: "11111111-2222-4333-8444-666666666666", sessionGeneration: 1, environment: serviceEnvironment)
        }
#endif
        guard let userID = pushEligibleUserID else { return nil }
        return FanNotificationContext(userID: userID, sessionGeneration: pushSessionGeneration, environment: serviceEnvironment)
    }
    var hasPushUnbindingSession: Bool {
        token != nil && profile.map { $0.sessionExpiresAt > Date() } == true
    }

    init(environment: AppServiceEnvironment = .production) {
        serviceEnvironment = environment
        apiRoot = environment.apiRoot
        keychain = FanAccountKeychain(environment: environment)
        session = SecureURLSessionFactory.make(requestTimeout: 30, resourceTimeout: 45)
        let installationState = keychain.loadOrCreateInstallationState()
        installID = installationState.installID
        pushBindingGeneration = installationState.bindingGeneration
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset-fan-session-for-visual-testing") {
            keychain.deleteToken()
            keychain.deleteAppleUserID()
        }
#endif
        token = keychain.loadToken()
        if token != nil { pushSessionGeneration = 1 }
        usesAppleSignIn = keychain.loadAppleUserID() != nil
        appleCredentialAccessState = usesAppleSignIn ? .checking : .notRequired
        hasSavedSession = token != nil
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-simulate-apple-registration-for-visual-testing") {
            appleRegistration = FanAppleRegistrationState(
                expiresAt: Date().addingTimeInterval(20 * 60)
            )
            hasSavedSession = true
        }
#endif
    }

    func hasPermission(_ permission: FanPermission) -> Bool {
        isApproved && profile?.hasPermission(permission, at: Date()) == true
    }

    func bindPushDevice(deviceToken: String) async throws {
        guard hasPushEligibleSession,
              PushDeviceTokenPolicy.isValid(deviceToken) else {
            throw FanAccountError.invalidResponse
        }
        let bindingGeneration = try nextPushBindingGeneration()
        let body = try JSONEncoder().encode(
            FanPushDeviceBindingRequest(
                installID: installID.uuidString.lowercased(),
                deviceToken: deviceToken,
                bindingGeneration: bindingGeneration
            )
        )
        let response: FanLogoutResponse = try await perform(
            path: "shuzijun/v1/fan/push-device",
            method: "POST",
            body: body,
            authorized: true
        )
        guard response.ok else { throw FanAccountError.invalidResponse }
    }

    func fetchNotificationPage(cursor: String?) async throws -> FanNotificationPage {
#if DEBUG
        if FanNotificationUITestFixture.isEnabled {
            return FanNotificationPage(notifications: [FanNotificationUITestFixture.message], nextCursor: nil, unreadCount: 0)
        }
#endif
        guard notificationContext != nil else { throw FanNotificationError.signInRequired }
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let cursor {
            guard FanNotificationValidation.isValidCursor(cursor) else { throw FanAccountError.invalidResponse }
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await perform(
            path: "shuzijun/v1/fan/notifications", method: "GET", authorized: true,
            queryItems: query
        )
    }

    func fetchNotification(id: String) async throws -> FanNotification {
        try await performNotificationRequest(id: id, markRead: false)
    }

    func markNotificationRead(id: String) async throws -> FanNotification {
        try await performNotificationRequest(id: id, markRead: true)
    }

    private func performNotificationRequest(id: String, markRead: Bool) async throws -> FanNotification {
#if DEBUG
        if FanNotificationUITestFixture.isEnabled {
            guard id == FanNotificationUITestFixture.message.id else { throw FanNotificationError.notFound }
            return FanNotificationUITestFixture.message
        }
#endif
        guard notificationContext != nil else { throw FanNotificationError.signInRequired }
        guard FanNotificationValidation.canonicalID(id) != nil else { throw FanAccountError.invalidResponse }
        let response: FanNotificationResponse = try await perform(
            path: "shuzijun/v1/fan/notifications/\(id)" + (markRead ? "/read" : ""),
            method: markRead ? "POST" : "GET", authorized: true
        )
        return response.notification
    }

    func unbindPushDevice() async throws {
        guard hasPushUnbindingSession else { throw FanAccountError.sessionExpired }
        let bindingGeneration = try nextPushBindingGeneration()
        let body = try JSONEncoder().encode(
            FanPushDeviceUnbindingRequest(
                installID: installID.uuidString.lowercased(),
                bindingGeneration: bindingGeneration
            )
        )
        let response: FanLogoutResponse = try await perform(
            path: "shuzijun/v1/fan/push-device",
            method: "DELETE",
            body: body,
            authorized: true
        )
        guard response.ok else { throw FanAccountError.invalidResponse }
    }

    private func nextPushBindingGeneration() throws -> String {
        guard let next = PushBindingGenerationPolicy.next(after: pushBindingGeneration) else {
            throw FanAccountError.unavailable
        }
        let state = FanInstallationState(
            installID: installID,
            bindingGeneration: next
        )
        // Persist before starting the request. A terminated or reordered request
        // can therefore never reuse an older operation number for this install.
        try keychain.saveInstallationState(state)
        pushBindingGeneration = next
        return String(next)
    }

    /// Clears an expired session without waiting for a network round trip. This
    /// is called on foreground entry as well as by the scheduled expiry task so
    /// an unavailable server can never extend access from stale memory.
    @discardableResult
    func clearExpiredSessionIfNeeded(now: Date = Date()) -> Bool {
        let isExpired = profile.map { $0.sessionExpiresAt <= now }
            ?? appleRegistration.map { $0.expiresAt <= now }
            ?? false
        guard isExpired else { return false }
        clearLocalSession()
        errorMessage = FanAccountError.sessionExpired.errorDescription
        noticeMessage = nil
        return true
    }

    func restoreSession() async {
        guard token != nil, profile == nil, appleRegistration == nil else { return }
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
            guard generation == refreshGeneration,
                  token == refreshToken else { return }
            switch (response.profile, response.appleRegistration) {
            case let (.some(profile), .none):
                guard FanAccountValidation.isValidProfile(profile) else {
                    throw FanAccountError.invalidResponse
                }
                self.profile = profile
                appleRegistration = nil
            case let (.none, .some(registration)):
                guard registration.isValid() else { throw FanAccountError.invalidResponse }
                profile = nil
                appleRegistration = registration
            default:
                throw FanAccountError.invalidResponse
            }
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
        guard let cleanDouyinID = FanAccountValidation.normalizedDouyinID(douyinID),
              !FanAccountValidation.isInvitationPlaceholderDouyinID(cleanDouyinID) else {
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
                    consentVersion: FanAccountConsentPolicy.currentVersion
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
            clearAppleCredentialReference()
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
            clearAppleCredentialReference()
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

    func requestAppleChallenge(
        purpose: FanAppleChallengePurpose = .signIn
    ) async -> FanAppleChallenge? {
        noticeMessage = nil
        errorMessage = nil
        if purpose == .deleteAccount, (token == nil || !usesAppleSignIn) {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return nil
        }
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(FanAppleChallengeRequest(
                installID: installID.uuidString.lowercased(),
                purpose: purpose
            ))
            let response: FanAppleChallenge = try await perform(
                path: "shuzijun/v1/fan/apple-challenge",
                method: "POST",
                body: body,
                authorized: purpose == .deleteAccount
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return nil }
            guard response.isValid() else { throw FanAccountError.invalidResponse }
            return response
        } catch {
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ) else { return nil }
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
            return nil
        }
    }

    func signInWithApple(_ submission: FanAppleCredentialSubmission) async {
        noticeMessage = nil
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(FanAppleAuthRequest(
                identityToken: submission.identityToken,
                authorizationCode: submission.authorizationCode,
                challengeID: submission.challengeID,
                state: submission.state,
                installID: installID.uuidString.lowercased()
            ))
            let response: FanAppleAuthResponse = try await perform(
                path: "shuzijun/v1/fan/apple-auth",
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
            try acceptApple(response, localAppleUserID: submission.localAppleUserID)
            if let registration = appleRegistration {
                noticeMessage = registration.isDouyinMigration
                    ? "Apple 身份已验证，请补全必填的抖音 ID。原账号状态和权限会保留。"
                    : "Apple 身份已验证，请完成账号申请。"
            } else {
                noticeMessage = nil
            }
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

    func completeAppleRegistration(
        displayName: String,
        douyinID: String,
        acceptedDataUse: Bool
    ) async {
        noticeMessage = nil
        let input: FanAppleRegistrationInput
        do {
            input = try FanAccountValidation.validatedAppleRegistration(
                displayName: displayName,
                douyinID: douyinID,
                acceptedDataUse: acceptedDataUse
            )
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.invalidResponse.errorDescription
            return
        }
        guard let expectedToken = token,
              let registration = appleRegistration,
              registration.isValid() else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(FanAppleRegistrationRequest(
                displayName: input.displayName,
                douyinID: input.douyinID,
                installID: installID.uuidString.lowercased(),
                consentVersion: FanAccountConsentPolicy.currentVersion
            ))
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/complete-apple-registration",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), FanAppleRegistrationCompletionPolicy.accepts(response.profile),
               let completedStatus = response.profile.accountStatus else {
                throw FanAccountError.invalidResponse
            }
            try accept(response, requiringTokenRotation: true)
            appleRegistration = nil
            noticeMessage = FanAppleRegistrationCompletionPolicy.notice(for: completedStatus)
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

    func completeRequiredDouyinID(
        displayName: String,
        douyinID: String,
        currentPassword: String,
        acceptedDataUse: Bool
    ) async {
        noticeMessage = nil
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FanAccountValidation.isValidDisplayName(cleanName) else {
            errorMessage = FanAccountError.invalidDisplayName.errorDescription
            return
        }
        guard let cleanDouyinID = FanAccountValidation.normalizedDouyinID(douyinID),
              !FanAccountValidation.isInvitationPlaceholderDouyinID(cleanDouyinID) else {
            errorMessage = FanAccountError.invalidDouyinID.errorDescription
            return
        }
        guard acceptedDataUse else {
            errorMessage = FanAccountError.consentRequired.errorDescription
            return
        }
        guard let existingProfile = profile,
              token != nil,
              !existingProfile.requiresAccountSetup,
              !existingProfile.requiresPasswordChange,
              !existingProfile.hasRequiredDouyinID else {
            errorMessage = FanAccountError.accountSetupNotRequired.errorDescription
            return
        }
        if existingProfile.accountSource != FanAccountSource.apple.rawValue {
            guard !currentPassword.isEmpty, currentPassword.count <= 512 else {
                errorMessage = FanAccountError.invalidCredentials.errorDescription
                return
            }
        }

        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        let expectedToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(FanDouyinProfileUpgradeRequest(
                displayName: cleanName,
                douyinID: cleanDouyinID,
                currentPassword: existingProfile.accountSource == FanAccountSource.apple.rawValue
                    ? nil : currentPassword,
                installID: installID.uuidString.lowercased(),
                consentVersion: FanAccountConsentPolicy.currentVersion
            ))
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/complete-apple-registration",
                method: "POST",
                body: body,
                authorized: true
            )
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), response.profile.userID == existingProfile.userID,
               response.profile.hasRequiredDouyinID,
               !response.profile.requiresAccountSetup,
               !response.profile.requiresPasswordChange else {
                throw FanAccountError.invalidResponse
            }
            try accept(response, requiringTokenRotation: true)
            noticeMessage = "抖音 ID 已补全，账号可继续使用。"
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

    func handleAppleCredentialRevoked() {
        guard usesAppleSignIn else { return }
        scheduleBestEffortPushUnbindBeforeClearingSession()
        clearLocalSession()
        errorMessage = FanAccountError.appleCredentialRevoked.errorDescription
        noticeMessage = nil
    }

    func revalidateAppleCredentialIfNeeded(resetRetrySchedule: Bool = false) async {
        if resetRetrySchedule { appleCredentialRetryAttempt = 0 }
        guard usesAppleSignIn else {
            appleCredentialAccessState = .notRequired
            return
        }
        guard let localUserID = keychain.loadAppleUserID() else {
            scheduleBestEffortPushUnbindBeforeClearingSession()
            clearLocalSession()
            errorMessage = FanAccountError.appleCredentialUnavailable.errorDescription
            noticeMessage = nil
            return
        }
        appleCredentialRetryTask?.cancel()
        appleCredentialRetryTask = nil
        // Cold launch begins in `.checking` and stays fail-closed until the
        // first query finishes. Later foreground/retry checks keep an already
        // usable server session visible while Apple's asynchronous query runs.
        if !FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: appleCredentialAccessState
        ) {
            appleCredentialAccessState = .checking
        }
        let generation = refreshGeneration
        let expectedToken = token
        let result = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: localUserID) {
                state, error in continuation.resume(returning: (state, error))
            }
        }
        guard FanAccountOperationGuard.canAccept(
            requestGeneration: generation,
            currentGeneration: refreshGeneration,
            expectedToken: expectedToken,
            currentToken: token
        ) else { return }
        guard FanAppleCredentialStatePolicy.queryDisposition(
            hasError: result.1 != nil
        ) == .evaluateCredential else {
            appleCredentialAccessState = .retryRequired
            errorMessage = FanAccountError.appleCredentialCheckFailed.errorDescription
            noticeMessage = nil
            scheduleAppleCredentialRetry()
            return
        }
        switch FanAppleCredentialStatePolicy.decision(for: result.0) {
        case .authorize:
            appleCredentialRetryAttempt = 0
            appleCredentialAccessState = .verified
            if errorMessage == FanAccountError.appleCredentialCheckFailed.errorDescription {
                errorMessage = nil
            }
        case .revoke:
            handleAppleCredentialRevoked()
        case .transfer:
            scheduleBestEffortPushUnbindBeforeClearingSession()
            clearLocalSession()
            errorMessage = FanAccountError.appleCredentialTransferred.errorDescription
            noticeMessage = nil
        case .unknown:
            scheduleBestEffortPushUnbindBeforeClearingSession()
            clearLocalSession()
            errorMessage = FanAccountError.appleCredentialUnavailable.errorDescription
            noticeMessage = nil
        }
    }

    func pauseAppleCredentialRetry() {
        appleCredentialRetryTask?.cancel()
        appleCredentialRetryTask = nil
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
                    consentVersion: FanAccountConsentPolicy.currentVersion
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
        let authorizationToken = token
        let unbindingBody: Data?
        if hasPushUnbindingSession, let bindingGeneration = try? nextPushBindingGeneration() {
            unbindingBody = try? JSONEncoder().encode(FanPushDeviceUnbindingRequest(
                installID: installID.uuidString.lowercased(),
                bindingGeneration: bindingGeneration
            ))
        } else {
            unbindingBody = nil
        }
        let operation = FanSignOutOperation.begin(
            authorizationToken: authorizationToken,
            unbindingBody: unbindingBody
        ) {
            clearLocalSession()
            errorMessage = nil
            noticeMessage = nil
        }
        await operation.complete { request in
            let _: FanLogoutResponse = try await perform(
                path: request.path,
                method: request.method,
                body: request.body,
                authorized: true,
                authorizationToken: request.authorizationToken
            )
        }
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
            try? await unbindPushDevice()
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

    func deleteAppleAccount(_ submission: FanAppleCredentialSubmission) async {
        guard let expectedToken = token,
              FanAppleDeletionEligibility.canBegin(
                hasToken: true,
                usesAppleSignIn: usesAppleSignIn,
                hasProfile: profile != nil,
                registration: appleRegistration
              ) else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }
        let deletingUserID = profile?.userID
        refreshGeneration &+= 1
        let operationGeneration = refreshGeneration
        isWorking = true
        defer { isWorking = false }
        do {
            try? await unbindPushDevice()
            let body = try JSONEncoder().encode(FanAppleDeletionRequest(
                identityToken: submission.identityToken,
                authorizationCode: submission.authorizationCode,
                challengeID: submission.challengeID,
                state: submission.state,
                installID: installID.uuidString.lowercased(),
                confirmation: "DELETE_ACCOUNT"
            ))
            let response: FanLogoutResponse = try await perform(
                path: "shuzijun/v1/fan/apple-delete",
                method: "POST",
                body: body,
                authorized: true
            )
            guard response.ok else { throw FanAccountError.invalidResponse }
            if let deletingUserID { removedAccountUserID = deletingUserID }
            let isSameAccountContext: Bool
            if let deletingUserID {
                isSameAccountContext = profile?.userID == deletingUserID
            } else {
                isSameAccountContext = profile == nil && appleRegistration != nil
            }
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), isSameAccountContext else { return }
            clearLocalSession()
            errorMessage = nil
            noticeMessage = "账号与关联个人资料已永久删除。"
        } catch {
            let isSameAccountContext: Bool
            if let deletingUserID {
                isSameAccountContext = profile?.userID == deletingUserID
            } else {
                isSameAccountContext = profile == nil && appleRegistration != nil
            }
            guard FanAccountOperationGuard.canAccept(
                requestGeneration: operationGeneration,
                currentGeneration: refreshGeneration,
                expectedToken: expectedToken,
                currentToken: token
            ), isSameAccountContext else { return }
            let accountError = error as? FanAccountError ?? .unavailable
            if FanDeletionFailurePolicy.shouldFailClosed(after: accountError) {
                clearLocalSession()
                if let deletingUserID { removedAccountUserID = deletingUserID }
                errorMessage = "删除请求的远端结果未能确认。为保护你的资料，本机已退出并清除该账号内容；请重新登录确认账号状态。"
                noticeMessage = nil
                return
            }
            errorMessage = accountError.errorDescription
        }
    }

    func fetchApprovedContent() async throws -> AppContentManifest {
        guard isApproved else {
            if appleRegistration != nil {
                throw FanAccountError.appleRegistrationRequired
            }
            if profile?.requiresAccountSetup == true {
                throw FanAccountError.accountSetupRequired
            }
            if profile?.requiresPasswordChange == true {
                throw FanAccountError.passwordRecoveryRequired
            }
            if profile != nil, profile?.hasRequiredDouyinID == false {
                throw FanAccountError.invalidDouyinID
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
        guard ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment) else {
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
        try keychain.saveToken(response.token)
        refreshGeneration &+= 1
        pushSessionGeneration &+= 1
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

    private func acceptApple(
        _ response: FanAppleAuthResponse,
        localAppleUserID: String
    ) throws {
        guard response.token.range(
            of: #"^[A-Za-z0-9_-]{43,128}$"#,
            options: .regularExpression
        ) != nil,
              !localAppleUserID.isEmpty,
              localAppleUserID.count <= 1_024 else {
            throw FanAccountError.invalidResponse
        }
        switch (response.profile, response.appleRegistration) {
        case let (.some(profile), .none):
            guard FanAccountValidation.isValidProfile(profile) else {
                throw FanAccountError.invalidResponse
            }
        case let (.none, .some(registration)):
            guard registration.isValid() else { throw FanAccountError.invalidResponse }
        default:
            throw FanAccountError.invalidResponse
        }

        try keychain.saveToken(response.token)
        do {
            try keychain.saveAppleUserID(localAppleUserID)
        } catch {
            keychain.deleteToken()
            throw error
        }
        refreshGeneration &+= 1
        pushSessionGeneration &+= 1
        token = response.token
        hasSavedSession = true
        usesAppleSignIn = true
        appleCredentialAccessState = .verified
        profile = response.profile
        appleRegistration = response.appleRegistration
        sessions.removeAll()
        lastSuccessfulRefresh = Date()
        scheduleSessionExpiration()
        errorMessage = nil
        noticeMessage = nil
    }

    private func clearAppleCredentialReference() {
        appleCredentialRetryTask?.cancel()
        appleCredentialRetryTask = nil
        appleCredentialRetryAttempt = 0
        keychain.deleteAppleUserID()
        usesAppleSignIn = false
        appleCredentialAccessState = .notRequired
    }

    private func scheduleBestEffortPushUnbindBeforeClearingSession() {
        guard let authorizationToken = token,
              hasPushUnbindingSession,
              let bindingGeneration = try? nextPushBindingGeneration(),
              let body = try? JSONEncoder().encode(
                FanPushDeviceUnbindingRequest(
                    installID: installID.uuidString.lowercased(),
                    bindingGeneration: bindingGeneration
                )
              ) else { return }

        Task { [weak self] in
            guard let self else { return }
            let _: FanLogoutResponse? = try? await self.perform(
                path: "shuzijun/v1/fan/push-device",
                method: "DELETE",
                body: body,
                authorized: true,
                authorizationToken: authorizationToken
            )
        }
    }

    private func clearLocalSession() {
        refreshGeneration &+= 1
        pushSessionGeneration &+= 1
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        keychain.deleteToken()
        clearAppleCredentialReference()
        token = nil
        profile = nil
        appleRegistration = nil
        sessions.removeAll()
        hasSavedSession = false
        lastSuccessfulRefresh = nil
    }

    private func scheduleAppleCredentialRetry() {
        appleCredentialRetryTask?.cancel()
        let delays: [Duration] = [.seconds(15), .seconds(60), .seconds(300)]
        guard appleCredentialRetryAttempt < delays.count else {
            appleCredentialRetryTask = nil
            return
        }
        let delay = delays[appleCredentialRetryAttempt]
        appleCredentialRetryAttempt += 1
        appleCredentialRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.usesAppleSignIn,
                  self.appleCredentialAccessState == .retryRequired else { return }
            await self.revalidateAppleCredentialIfNeeded(resetRetrySchedule: false)
        }
    }

    private func scheduleSessionExpiration() {
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        guard let expiresAt = profile?.sessionExpiresAt ?? appleRegistration?.expiresAt else { return }
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
        authorized: Bool,
        authorizationToken: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."),
              !path.contains("?"), !path.contains("#"),
              ["DELETE", "GET", "POST"].contains(method) else {
            throw FanAccountError.invalidResponse
        }
        // Only the receive-only inbox accepts query parameters. Keep every
        // existing account/auth path's original no-query contract unchanged.
        guard queryItems.isEmpty || (
            path == "shuzijun/v1/fan/notifications" && method == "GET"
                && queryItems.count <= 2
                && Set(queryItems.map(\.name)).count == queryItems.count
                && queryItems.allSatisfy {
                    ($0.name == "limit" && $0.value == "20")
                        || ($0.name == "cursor" && $0.value.map(FanNotificationValidation.isValidCursor) == true)
                }
        ) else { throw FanAccountError.invalidResponse }
        let endpoint = apiRoot.appending(path: path).appending(queryItems: queryItems)
        guard serviceEnvironment.allowsAPIURL(endpoint) else {
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
            guard let authorizationToken = authorizationToken ?? token else {
                throw FanAccountError.sessionExpired
            }
            request.setValue(
                "Bearer \(authorizationToken)",
                forHTTPHeaderField: "Authorization"
            )
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
              serviceEnvironment.allowsAPIURL(http.url) else {
            throw FanAccountError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if path == "shuzijun/v1/fan/notifications" || path.hasPrefix("shuzijun/v1/fan/notifications/") {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw FanNotificationError.signInRequired
                }
            }
            if path.hasPrefix("shuzijun/v1/fan/notifications/"), http.statusCode == 404 {
                throw FanNotificationError.notFound
            }
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
        case (_, "fan_douyin_id_required"): return .invalidDouyinID
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
    let accountSource: String
    let requiresAppleRegistration: Bool
    let administratorBound: Bool?
    let administratorRevision: Int?

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
        passwordRecoveryExpiresAt: Date? = nil,
        accountSource: String = FanAccountSource.password.rawValue,
        requiresAppleRegistration: Bool = false,
        administratorBound: Bool? = nil,
        administratorRevision: Int? = nil
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
        self.accountSource = accountSource
        self.requiresAppleRegistration = requiresAppleRegistration
        self.administratorBound = administratorBound
        self.administratorRevision = administratorRevision
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
        case accountSource
        case requiresAppleRegistration
        case administratorBound
        case administratorRevision
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
        accountSource = try container.decodeIfPresent(
            String.self,
            forKey: .accountSource
        ) ?? FanAccountSource.password.rawValue
        requiresAppleRegistration = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresAppleRegistration
        ) ?? false
        administratorBound = try container.decodeIfPresent(Bool.self, forKey: .administratorBound)
        administratorRevision = try container.decodeIfPresent(Int.self, forKey: .administratorRevision)
    }

    var id: String { userID }
    var hasConsistentAdministratorBinding: Bool {
        switch (administratorBound, administratorRevision) {
        case (nil, nil): true // Legacy server: no grant/revoke control.
        case (.some, .some(let revision)): revision >= 0
        default: false
        }
    }
    var requiresIdentityCompletion: Bool {
        requiresAccountSetup || requiresAppleRegistration || douyinID.isEmpty
    }
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

struct AdminFanDirectory: Codable, Equatable {
    let users: [AdminFanUser]
    let permissionCatalog: [AdminFanPermissionDefinition]
    let page: Int
    let perPage: Int
    let hasMore: Bool

    init(
        users: [AdminFanUser],
        permissionCatalog: [AdminFanPermissionDefinition],
        page: Int = 1,
        perPage: Int = 100,
        hasMore: Bool = false
    ) {
        self.users = users
        self.permissionCatalog = permissionCatalog
        self.page = page
        self.perPage = perPage
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case users
        case permissionCatalog
        case page
        case perPage
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        users = try container.decode([AdminFanUser].self, forKey: .users)
        permissionCatalog = try container.decode(
            [AdminFanPermissionDefinition].self,
            forKey: .permissionCatalog
        )
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        perPage = try container.decodeIfPresent(Int.self, forKey: .perPage) ?? 100
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

enum AdminFanDirectoryValidation {
    static func isValid(
        _ directory: AdminFanDirectory,
        requestedPage: Int,
        requestedPerPage: Int
    ) -> Bool {
        directory.page == requestedPage
            && directory.perPage == requestedPerPage
            && directory.users.count <= requestedPerPage
            && directory.permissionCatalog.count <= 20
            && Set(directory.users.map(\.userID)).count == directory.users.count
            && Set(directory.permissionCatalog.map(\.code)).count
                == directory.permissionCatalog.count
            && directory.users.allSatisfy(FanAccountValidation.isValidAdminFanUser)
            && (!directory.hasMore
                || (!directory.users.isEmpty
                    && directory.page < AdminFanDirectoryQuery.maximumPage))
    }

    static func appending(
        _ nextPage: AdminFanDirectory,
        to current: AdminFanDirectory
    ) -> AdminFanDirectory? {
        guard current.page >= 1,
              current.page < AdminFanDirectoryQuery.maximumPage,
              nextPage.page == current.page + 1,
              nextPage.perPage == current.perPage,
              nextPage.permissionCatalog == current.permissionCatalog,
              Set(current.users.map(\.userID)).count == current.users.count else {
            return nil
        }
        var userIDs = Set(current.users.map(\.userID))
        let uniqueAdditionalUsers = nextPage.users.filter {
            userIDs.insert($0.userID).inserted
        }
        return AdminFanDirectory(
            users: current.users + uniqueAdditionalUsers,
            permissionCatalog: current.permissionCatalog,
            page: nextPage.page,
            perPage: nextPage.perPage,
            hasMore: nextPage.hasMore
        )
    }
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

private struct FanAppleChallengeRequest: Encodable {
    let installID: String
    let purpose: FanAppleChallengePurpose
}

struct FanAppleAuthRequest: Encodable, Equatable {
    let identityToken: String
    let authorizationCode: String
    let challengeID: String
    let state: String
    let installID: String
}

private struct FanAppleRegistrationRequest: Encodable {
    let displayName: String
    let douyinID: String
    let installID: String
    let consentVersion: String
}

private struct FanDouyinProfileUpgradeRequest: Encodable {
    let displayName: String
    let douyinID: String
    let currentPassword: String?
    let installID: String
    let consentVersion: String
}

private struct FanAppleDeletionRequest: Encodable {
    let identityToken: String
    let authorizationCode: String
    let challengeID: String
    let state: String
    let installID: String
    let confirmation: String
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

private struct FanPushDeviceBindingRequest: Encodable {
    let installID: String
    let deviceToken: String
    let bindingGeneration: String
}

private struct FanPushDeviceUnbindingRequest: Encodable {
    let installID: String
    let bindingGeneration: String
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

struct FanAppleAuthResponse: Decodable {
    let token: String
    let profile: FanProfile?
    let appleRegistration: FanAppleRegistrationState?
}

struct FanSessionResponse: Decodable {
    let profile: FanProfile?
    let appleRegistration: FanAppleRegistrationState?
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

private struct FanAccountKeychain {
    private let service: String
    private let installAccount = "installation-id"
    private let installationStateAccount = "installation-state-v2"
    private let tokenAccount = "session-token"
    private let appleUserAccount = "apple-user-id"

    init(environment: AppServiceEnvironment) {
        service = environment.storageKey("cn.com.shuzijun.yishu.fan-account")
    }

    func loadOrCreateInstallationState() -> FanInstallationState {
        if let data = load(account: installationStateAccount) {
            if let state = try? JSONDecoder().decode(FanInstallationState.self, from: data),
               state.bindingGeneration <= PushBindingGenerationPolicy.maximum {
                return state
            }
            let replacement = FanInstallationState(
                installID: UUID(),
                bindingGeneration: 0
            )
            try? saveInstallationState(replacement)
            return replacement
        }

        // Preserve existing installs while migrating from the former UUID-only
        // record. A corrupt combined record starts a new install lifetime rather
        // than ever resetting the operation counter on the old UUID.
        let installID: UUID
        if let data = load(account: installAccount),
           let raw = String(data: data, encoding: .utf8),
           let value = UUID(uuidString: raw) {
            installID = value
        } else {
            installID = UUID()
        }
        let state = FanInstallationState(installID: installID, bindingGeneration: 0)
        try? saveInstallationState(state)
        return state
    }

    func saveInstallationState(_ state: FanInstallationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try save(try encoder.encode(state), account: installationStateAccount)
    }

    func loadToken() -> String? {
        guard let data = load(account: tokenAccount),
              let token = String(data: data, encoding: .utf8),
              token.range(
                of: #"^[A-Za-z0-9_-]{43,128}$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return token
    }

    func saveToken(_ token: String) throws {
        try save(Data(token.utf8), account: tokenAccount)
    }

    func deleteToken() {
        delete(account: tokenAccount)
    }

    func loadAppleUserID() -> String? {
        guard let data = load(account: appleUserAccount),
              data.count <= 4_096,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty,
              value.count <= 1_024 else { return nil }
        return value
    }

    func saveAppleUserID(_ value: String) throws {
        guard !value.isEmpty, value.count <= 1_024 else {
            throw FanAccountError.invalidResponse
        }
        try save(Data(value.utf8), account: appleUserAccount)
    }

    func deleteAppleUserID() {
        delete(account: appleUserAccount)
    }

    private func load(account: String) -> Data? {
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

    private func save(_ data: Data, account: String) throws {
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

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
