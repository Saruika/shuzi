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

struct FanProfile: Codable, Equatable {
    let userID: String
    let identityCode: String
    let displayName: String
    let douyinID: String
    let installationCode: String
    let permissions: [String]
    let status: String
    let sessionExpiresAt: Date

    func hasPermission(_ permission: FanPermission) -> Bool {
        status == "active" && permissions.contains(permission.rawValue)
    }
}

enum FanAccountValidation {
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
}

enum FanAccountError: LocalizedError {
    case invalidDisplayName
    case invalidDouyinID
    case consentRequired
    case weakPassword
    case passwordMismatch
    case invalidIdentityCode
    case invalidCredentials
    case sessionExpired
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
        case .invalidIdentityCode: "请输入完整的粉丝身份码。"
        case .invalidCredentials: "身份码或密码不正确。"
        case .sessionExpired: "登录已失效，请重新登录。"
        case .accountSuspended: "账号已暂停，请联系管理员。"
        case .rateLimited: "尝试次数过多，请稍后再试。"
        case .invalidResponse: "服务器返回了无法识别的账号数据。"
        case .unavailable: "暂时无法连接账号服务，请检查网络后重试。"
        case .server(let message): message
        }
    }
}

@MainActor
final class FanAccountStore: ObservableObject {
    @Published private(set) var profile: FanProfile?
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedSession = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let apiRoot = URL(string: "https://www.shuzijun.com.cn/wp-json")!
    private let session: URLSession
    private let installID: UUID
    private var token: String?
    private var lastSuccessfulRefresh: Date?

    var isAuthenticated: Bool { profile != nil && token != nil }

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
        profile?.hasPermission(permission) == true
    }

    func restoreSession() async {
        guard token != nil, profile == nil else { return }
        await refreshSession(showError: false)
    }

    func refreshIfNeeded(minimumInterval: TimeInterval = 300) async {
        guard token != nil else { return }
        if let lastSuccessfulRefresh,
           Date().timeIntervalSince(lastSuccessfulRefresh) < minimumInterval { return }
        await refreshSession(showError: false)
    }

    func refreshSession(showError: Bool = true) async {
        guard token != nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response: FanSessionResponse = try await perform(
                path: "shuzijun/v1/fan/session",
                method: "GET",
                authorized: true
            )
            profile = response.profile
            lastSuccessfulRefresh = Date()
            errorMessage = nil
        } catch FanAccountError.sessionExpired {
            clearLocalSession()
            if showError { errorMessage = FanAccountError.sessionExpired.errorDescription }
        } catch FanAccountError.accountSuspended {
            clearLocalSession()
            if showError { errorMessage = FanAccountError.accountSuspended.errorDescription }
        } catch {
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

        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanRegistrationRequest(
                    displayName: cleanName,
                    douyinID: cleanDouyinID,
                    password: password,
                    installID: installID.uuidString.lowercased(),
                    consentVersion: "2026-08-31"
                )
            )
            let response: FanAuthResponse = try await perform(
                path: "shuzijun/v1/fan/register",
                method: "POST",
                body: body,
                authorized: false
            )
            try accept(response)
        } catch {
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
            try accept(response)
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    func signOut() async {
        if token != nil {
            let _: FanLogoutResponse? = try? await perform(
                path: "shuzijun/v1/fan/logout",
                method: "POST",
                authorized: true
            )
        }
        clearLocalSession()
        errorMessage = nil
        noticeMessage = nil
    }

    func deleteAccount() async {
        guard token != nil else {
            errorMessage = FanAccountError.sessionExpired.errorDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try JSONEncoder().encode(
                FanDeletionRequest(confirmation: "DELETE_ACCOUNT")
            )
            let response: FanLogoutResponse = try await perform(
                path: "shuzijun/v1/fan/delete",
                method: "POST",
                body: body,
                authorized: true
            )
            guard response.ok else { throw FanAccountError.invalidResponse }
            clearLocalSession()
            errorMessage = nil
            noticeMessage = "账号与关联个人资料已永久删除。"
        } catch {
            errorMessage = (error as? FanAccountError)?.errorDescription
                ?? FanAccountError.unavailable.errorDescription
        }
    }

    private func accept(_ response: FanAuthResponse) throws {
        guard response.token.range(
            of: #"^[A-Za-z0-9_-]{43,128}$"#,
            options: .regularExpression
        ) != nil,
              FanAccountValidation.normalizedIdentityCode(response.profile.identityCode)
                == response.profile.identityCode,
              FanAccountValidation.normalizedDouyinID(response.profile.douyinID)
                == response.profile.douyinID,
              UUID(uuidString: response.profile.userID) != nil,
              response.profile.sessionExpiresAt > Date() else {
            throw FanAccountError.invalidResponse
        }
        try FanAccountKeychain.saveToken(response.token)
        token = response.token
        hasSavedSession = true
        profile = response.profile
        lastSuccessfulRefresh = Date()
        errorMessage = nil
        noticeMessage = nil
    }

    private func clearLocalSession() {
        FanAccountKeychain.deleteToken()
        token = nil
        profile = nil
        hasSavedSession = false
        lastSuccessfulRefresh = nil
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
        guard data.count <= 1024 * 1024,
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

    var id: String { userID }
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

private struct FanDeletionRequest: Encodable {
    let confirmation: String
}

private struct FanAuthResponse: Decodable {
    let token: String
    let profile: FanProfile
}

private struct FanSessionResponse: Decodable {
    let profile: FanProfile
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
