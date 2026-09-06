import Foundation
import Combine
import Security

enum AppUserRole: Equatable {
    case visitor
    case administrator(displayName: String)
}

struct UploadedMedia: Decodable {
    let id: Int
    let sourceURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
    }
}

enum AdminAPIError: LocalizedError {
    case invalidCredentials
    case insufficientPermission
    case pushPermissionRequired
    case invalidResponse
    case invalidFile
    case fileTooLarge
    case unsupportedFileType
    case networkUnavailable
    case administratorConflict
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "管理员账号或访问码不正确。"
        case .insufficientPermission:
            return "账号已验证，但没有内容管理权限。"
        case .pushPermissionRequired:
            return "当前管理员没有定向推送权限。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .invalidFile:
            return "文件为空、无法读取或不是普通文件。"
        case .fileTooLarge:
            return "文件不能超过 60 MB，请先压缩视频后再上传。"
        case .unsupportedFileType:
            return "仅支持 JPEG、PNG、HEIC、WebP 图片或 MP4、MOV 视频。"
        case .networkUnavailable:
            return "无法安全连接内容服务器，请检查网络后重试。"
        case .administratorConflict:
            return "管理员身份已被其他操作修改，请刷新后重新确认。"
        case .server(let message):
            return message
        }
    }
}

struct AdminFanDirectoryQuery: Equatable {
    static let maximumSearchLength = 80
    static let maximumPage = 10_000
    static let maximumPerPage = 100

    let search: String?
    let page: Int
    let perPage: Int

    init(search rawSearch: String = "", page: Int = 1, perPage: Int = 100) throws {
        let search = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maximumPage).contains(page),
              (1...Self.maximumPerPage).contains(perPage),
              search.count <= Self.maximumSearchLength,
              !search.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AdminAPIError.invalidResponse
        }
        self.search = search.isEmpty ? nil : search
        self.page = page
        self.perPage = perPage
    }

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perPage", value: String(perPage)),
        ]
        if let search {
            items.append(URLQueryItem(name: "search", value: search))
        }
        return items
    }
}

enum AdminQueryItemPolicy {
    static func areValid(_ items: [URLQueryItem]) -> Bool {
        guard items.count <= 3,
              Set(items.map(\.name)).count == items.count else { return false }
        return items.allSatisfy { item in
            guard let value = item.value else { return false }
            switch item.name {
            case "page":
                return value.allSatisfy(\.isNumber)
                    && (1...100_000).contains(Int(value) ?? 0)
            case "perPage":
                return value.allSatisfy(\.isNumber)
                    && (1...100).contains(Int(value) ?? 0)
            case "status":
                return value.range(
                    of: #"^[a-z0-9]{1,20}$"#,
                    options: .regularExpression
                ) != nil
            case "search":
                return !value.isEmpty
                    && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                    && value.count <= AdminFanDirectoryQuery.maximumSearchLength
                    && !value.unicodeScalars.contains(
                        where: CharacterSet.controlCharacters.contains
                    )
            default:
                return false
            }
        }
    }
}

enum AdminUploadPolicy {
    static let maximumByteCount = 60 * 1024 * 1024

    private static let extensionsByMIMEType: [String: Set<String>] = [
        "image/jpeg": ["jpg", "jpeg"],
        "image/png": ["png"],
        "image/heic": ["heic"],
        "image/heif": ["heif"],
        "image/webp": ["webp"],
        "video/mp4": ["mp4"],
        "video/quicktime": ["mov"],
    ]

    static func normalizedMIMEType(_ mimeType: String) -> String? {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return extensionsByMIMEType[normalized] == nil ? nil : normalized
    }

    static func isAllowed(filename: String, mimeType: String) -> Bool {
        guard let normalized = normalizedMIMEType(mimeType),
              let allowedExtensions = extensionsByMIMEType[normalized] else { return false }
        let basename = (filename as NSString).lastPathComponent
        let fileExtension = (basename as NSString).pathExtension.lowercased()
        return allowedExtensions.contains(fileExtension)
    }

    static func sanitizedFilename(_ filename: String, mimeType: String) throws -> String {
        guard let normalized = normalizedMIMEType(mimeType),
              isAllowed(filename: filename, mimeType: normalized) else {
            throw AdminAPIError.unsupportedFileType
        }

        let basename = (filename as NSString).lastPathComponent
        let fileExtension = (basename as NSString).pathExtension.lowercased()
        let stem = (basename as NSString).deletingPathExtension
        let allowedStem = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleanedScalars = stem.unicodeScalars.map { scalar in
            allowedStem.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let cleanedStem = String(cleanedScalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        let safeStem = cleanedStem.isEmpty ? "upload" : String(cleanedStem.prefix(96))
        return "\(safeStem).\(fileExtension)"
    }
}

struct AdminFanInvitation: Codable, Identifiable, Equatable {
    let userID: String
    let identityCode: String
    let temporaryPassword: String
    let expiresAt: Date
    let requiresAccountSetup: Bool

    var id: String { userID }
}

struct AdminFanInvitationResponse: Codable, Equatable {
    let invitations: [AdminFanInvitation]
}

struct AdminFanPasswordRecovery: Codable, Equatable {
    let userID: String
    let identityCode: String
    let temporaryPassword: String
    let expiresAt: Date
    let requiresPasswordChange: Bool
}

struct AdminFanPasswordRecoveryResponse: Codable, Equatable {
    let passwordRecovery: AdminFanPasswordRecovery
}

struct AdminCollaborationDelivery: Codable, Equatable {
    let status: String
    let attempts: Int
    let errorCode: String
}

struct AdminCollaborationRequest: Codable, Identifiable, Equatable {
    let requestID: String
    let fanUserID: String
    let contactName: String
    let contactMethod: String
    let organization: String
    let projectType: String
    let city: String
    let preferredDate: String
    let budget: String
    let details: String
    let status: String
    let version: Int
    let receivedAt: Date
    let updatedAt: Date
    let delivery: AdminCollaborationDelivery

    var id: String { requestID }
    var requestStatus: CollaborationRequestStatus? {
        CollaborationRequestStatus(rawValue: status)
    }
}

struct AdminCollaborationDirectory: Codable, Equatable {
    let requests: [AdminCollaborationRequest]
    let page: Int
    let perPage: Int
    let total: Int
    let statuses: [String]
}

enum AdminCollaborationValidation {
    private static let deliveryStatuses = Set(["pending", "processing", "sent", "dead"])

    static func isValid(
        _ directory: AdminCollaborationDirectory,
        filteredBy status: CollaborationRequestStatus? = nil,
        now: Date = Date()
    ) -> Bool {
        guard directory.page >= 1,
              (1...100).contains(directory.perPage),
              directory.total >= directory.requests.count,
              directory.requests.count <= directory.perPage,
              Set(directory.statuses) == Set(CollaborationRequestStatus.allCases.map(\.rawValue)),
              Set(directory.requests.map(\.requestID)).count == directory.requests.count,
              directory.requests.allSatisfy({ isValid($0, now: now) }) else {
            return false
        }
        return status.map { expected in
            directory.requests.allSatisfy { $0.requestStatus == expected }
        } ?? true
    }

    static func isValid(_ request: AdminCollaborationRequest, now: Date = Date()) -> Bool {
        let optionalSingleLines = [request.organization, request.city, request.budget]
        let optionalLimits = [120, 80, 80]
        return CollaborationSubmissionValidation.isCanonicalUUIDv4(request.requestID)
            && (request.fanUserID.isEmpty
                || CollaborationSubmissionValidation.isCanonicalUUIDv4(request.fanUserID))
            && CollaborationSubmissionValidation.isValidRequiredField(
                request.contactName,
                maximumLength: 80
            )
            && CollaborationSubmissionValidation.isValidRequiredField(
                request.contactMethod,
                maximumLength: 160
            )
            && zip(optionalSingleLines, optionalLimits).allSatisfy {
                (try? CollaborationSubmissionValidation.optionalSingleLine(
                    $0.0,
                    maximumLength: $0.1
                )) != nil
            }
            && ["drama", "commercial", "brand", "modeling", "event", "other"]
                .contains(request.projectType)
            && isValidDate(request.preferredDate)
            && (try? CollaborationSubmissionValidation.multilineDetails(request.details))
                == request.details
            && request.requestStatus != nil
            && request.version >= 1
            && request.receivedAt <= request.updatedAt
            && request.updatedAt <= now.addingTimeInterval(5 * 60)
            && deliveryStatuses.contains(request.delivery.status)
            && (0...5).contains(request.delivery.attempts)
            && request.delivery.errorCode.count <= 80
            && request.delivery.errorCode.range(
                of: #"^[a-z0-9_]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isValidDate(_ value: String) -> Bool {
        value.isEmpty || value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil
    }
}

enum AdminFanPasswordRecoveryValidation {
    static func isValid(
        _ recovery: AdminFanPasswordRecovery,
        expectedUserID: String,
        now: Date = Date()
    ) -> Bool {
        guard let uuid = UUID(uuidString: recovery.userID)?.uuidString.lowercased() else {
            return false
        }
        return uuid == expectedUserID.lowercased()
            && recovery.userID == recovery.userID.lowercased()
            && FanAccountValidation.normalizedIdentityCode(recovery.identityCode)
                == recovery.identityCode
            && FanAccountValidation.isValidInvitationTemporaryPassword(
                recovery.temporaryPassword
            )
            && recovery.expiresAt > now
            && recovery.expiresAt.timeIntervalSince(now) <= 16 * 60
            && recovery.requiresPasswordChange
    }
}

enum AdminFanInvitationValidation {
    static let allowedCount = 1...5

    static func isValid(_ invitation: AdminFanInvitation, now: Date = Date()) -> Bool {
        guard let uuid = UUID(uuidString: invitation.userID) else { return false }
        return uuid.uuidString.lowercased() == invitation.userID.lowercased()
            && invitation.userID == invitation.userID.lowercased()
            && FanAccountValidation.normalizedIdentityCode(invitation.identityCode)
                == invitation.identityCode
            && FanAccountValidation.isValidInvitationTemporaryPassword(
                invitation.temporaryPassword
            )
            && invitation.expiresAt > now
            && invitation.requiresAccountSetup
    }

    static func isValid(
        _ response: AdminFanInvitationResponse,
        requestedCount: Int,
        now: Date = Date()
    ) -> Bool {
        guard allowedCount.contains(requestedCount),
              response.invitations.count == requestedCount,
              response.invitations.allSatisfy({ isValid($0, now: now) }) else {
            return false
        }
        return Set(response.invitations.map(\.userID)).count == requestedCount
            && Set(response.invitations.map(\.identityCode)).count == requestedCount
            && Set(response.invitations.map(\.temporaryPassword)).count == requestedCount
    }
}

struct AdminPushNotificationContent: Equatable {
    let title: String
    let body: String
    let sensitive: Bool
}

enum AdminPushNotificationValidation {
    static let titleLimit = 60
    static let bodyLimit = 240
    static let privateTitle = "Hi，梳子"
    static let privateBody = "有新消息，请登录查看"

    static func normalized(
        title: String,
        body: String,
        sensitive: Bool
    ) -> AdminPushNotificationContent? {
        guard containsOnlySafeText(title), containsOnlySafeText(body) else { return nil }
        let cleanTitle = collapsedWhitespace(title)
        let cleanBody = collapsedWhitespace(body)
        guard (1...titleLimit).contains(cleanTitle.count),
              (1...bodyLimit).contains(cleanBody.count) else { return nil }
        return AdminPushNotificationContent(
            title: cleanTitle,
            body: cleanBody,
            sensitive: sensitive
        )
    }

    static func isValidResponse(
        _ response: AdminPushNotificationResponse,
        expectedRecipientCount: Int
    ) -> Bool {
        guard let uuid = UUID(uuidString: response.notificationID) else { return false }
        return uuid.uuidString.lowercased() == response.notificationID
            && response.status == "queued"
            && response.recipientCount == expectedRecipientCount
            && (0...1_600).contains(response.deviceCount)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsOnlySafeText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 10
                || scalar.value == 13
                || scalar.value == 9
        }
    }
}

enum AdminPushConfirmationPolicy {
    static func requiresSecondConfirmation(
        for content: AdminPushNotificationContent
    ) -> Bool {
        !content.sensitive
    }

    static func summary(
        recipient: String,
        content: AdminPushNotificationContent
    ) -> String {
        "收件人：\(recipient)\n标题：\(content.title)\n正文：\(content.body)"
    }
}

enum AdminTargetedPushRecipientPolicy {
    static func isEligible(
        status: String,
        requiresIdentityCompletion: Bool
    ) -> Bool {
        guard !requiresIdentityCompletion,
              let status = FanAccountStatus(rawValue: status) else { return false }
        return status == .pending || status == .active
    }

    static func isEligible(_ user: AdminFanUser) -> Bool {
        isEligible(
            status: user.status,
            requiresIdentityCompletion: user.requiresIdentityCompletion
        )
    }
}

struct AdminPushNotificationResponse: Decodable, Equatable {
    let notificationID: String
    let status: String
    let recipientCount: Int
    let deviceCount: Int
}

enum AdminTransportPolicy {
    static let jsonRequestTimeout: TimeInterval = 30
    static let uploadRequestTimeout: TimeInterval = 120

    static func makeJSONSession() -> URLSession {
        SecureURLSessionFactory.make(requestTimeout: jsonRequestTimeout, resourceTimeout: 45)
    }

    static func makeUploadSession() -> URLSession {
        SecureURLSessionFactory.make(requestTimeout: uploadRequestTimeout, resourceTimeout: 180)
    }

    static func requestTimeout(path: String) -> TimeInterval {
        path == "wp/v2/media" ? uploadRequestTimeout : jsonRequestTimeout
    }
}

@MainActor
final class AdminSessionStore: ObservableObject {
    private static let sessionLifetime: TimeInterval = 5 * 60

    @Published private(set) var role: AppUserRole = .visitor
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published private var serverCanManageFanAdministrators = false

    private var credential: AdminCredential?
    private weak var boundAccount: (any FanAdministratorAccount)?
    private var boundContext: FanAdministratorContext?
    private var boundAccountObservation: AnyCancellable?
    private let jsonLoader: ((URLRequest) async throws -> (Data, URLResponse))?
    private var authenticatedUntil: Date?
    private var expirationTask: Task<Void, Never>?
    private var authenticationGeneration: UInt64 = 0
    private var signInOperationID: UUID?
    let serviceEnvironment: AppServiceEnvironment
    private let apiRoot: URL
    private let mediaUploadRoot: URL
    private let session: URLSession
    private let uploadSession: URLSession

    var isAuthenticated: Bool {
        guard hasCurrentAuthenticationSource,
              AdminSessionSecurityPolicy.isFresh(expiresAt: authenticatedUntil),
              case .administrator = role else { return false }
        return true
    }

    var isIndependentAdministrator: Bool { isAuthenticated && boundContext == nil }
    var canManageFanAdministrators: Bool { isAuthenticated && serverCanManageFanAdministrators }
    var boundAdministratorUserID: String? { isAuthenticated ? boundContext?.userID : nil }

    private var hasCurrentAuthenticationSource: Bool {
        if let boundContext {
            return boundContext.environment == serviceEnvironment
                && boundAccount?.administratorContext == boundContext
        }
        return credential != nil
    }

    init(
        environment: AppServiceEnvironment = .production,
        jsonLoader: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        serviceEnvironment = environment
        apiRoot = environment.apiRoot
        mediaUploadRoot = environment.mediaUploadRoot
        self.jsonLoader = jsonLoader
        // Short account/permission JSON calls must not inherit large-media
        // upload deadlines. Both transports remain ephemeral and isolated.
        session = AdminTransportPolicy.makeJSONSession()
        uploadSession = AdminTransportPolicy.makeUploadSession()
        // Builds before 1.3.18 stored the complete WordPress Application
        // Password and restored it without user interaction. Delete that
        // legacy item during migration and keep new credentials in memory only.
        LegacyAdminKeychain.delete(environment: environment)
    }

    func signIn(username: String, applicationPassword: String) async {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = applicationPassword.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleanUsername.isEmpty,
              cleanUsername.count <= 128,
              !cleanUsername.contains(":"),
              !cleanUsername.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !cleanPassword.isEmpty,
              cleanPassword.count <= 512 else {
            errorMessage = "请输入管理员账号和访问码。"
            return
        }

        let candidate = AdminCredential(username: cleanUsername, applicationPassword: cleanPassword)
        lock()
        let attemptGeneration = authenticationGeneration
        let operationID = UUID()
        signInOperationID = operationID
        isWorking = true
        defer {
            if signInOperationID == operationID {
                signInOperationID = nil
                isWorking = false
            }
        }
        credential = candidate
        do {
            let session: AdminSessionResponse = try await authorizedJSON(
                path: "shuzijun/v1/app-admin/session",
                method: "GET",
                authenticationProbe: true
            )
            guard attemptGeneration == authenticationGeneration,
                  credential == candidate else { return }
            guard session.isVerifiedContentManager else {
                throw AdminAPIError.invalidResponse
            }
            establishSession(displayName: session.displayName,
                             canManageFanAdministrators: session.canManageFanAdministrators == true)
            errorMessage = nil
        } catch {
            guard attemptGeneration == authenticationGeneration else { return }
            lock()
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? AdminAPIError.networkUnavailable.errorDescription
        }
    }

    func signOut() {
        lock()
        errorMessage = nil
    }

    func retireForEnvironmentSwitch() {
        signOut()
        session.invalidateAndCancel()
        uploadSession.invalidateAndCancel()
    }

    /// Use the existing installation-bound session, never a second stored password.
    func signIn(using account: any FanAdministratorAccount) async {
        lock()
        guard let context = account.administratorContext, context.environment == serviceEnvironment else {
            errorMessage = "当前账号尚未获得管理员授权，或尚未完成资料与审批。"
            return
        }
        boundAccount = account
        boundContext = context
        let generation = authenticationGeneration
        let operationID = UUID()
        signInOperationID = operationID
        isWorking = true
        boundAccountObservation = account.administratorChanges.sink { [weak self] in
            // ObservableObject announces before mutation. Recheck after that mutation;
            // request construction and response validation also check synchronously.
            Task { @MainActor [weak self] in
                guard let self, self.authenticationGeneration == generation else { return }
                if !self.hasCurrentAuthenticationSource { self.lock() }
                else { self.objectWillChange.send() }
            }
        }
        defer {
            if signInOperationID == operationID {
                signInOperationID = nil
                isWorking = false
            }
        }
        do {
            let response: AdminSessionResponse = try await authorizedJSON(
                path: "shuzijun/v1/app-admin/session", method: "GET", authenticationProbe: true
            )
            guard generation == authenticationGeneration else { return }
            guard boundContext == context, account.administratorContext == context else {
                lock()
                return
            }
            guard response.isVerifiedContentManager else {
                throw AdminAPIError.invalidResponse
            }
            establishSession(displayName: response.displayName,
                             canManageFanAdministrators: response.canManageFanAdministrators == true)
            errorMessage = nil
        } catch {
            guard generation == authenticationGeneration else { return }
            lock()
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? AdminAPIError.networkUnavailable.errorDescription
        }
    }

    /// Immediately invalidates the local administrator unlock. The server still
    /// independently checks the Basic or installation-bound session and capability on every
    /// request; this prevents a previously unlocked phone from silently reusing it.
    func lock() {
        authenticationGeneration &+= 1
        signInOperationID = nil
        isWorking = false
        expirationTask?.cancel()
        expirationTask = nil
        credential = nil
        boundAccountObservation?.cancel()
        boundAccountObservation = nil
        boundAccount = nil
        boundContext = nil
        serverCanManageFanAdministrators = false
        authenticatedUntil = nil
        role = .visitor
    }

    func upload(data: Data, filename: String, mimeType: String) async throws -> UploadedMedia {
        guard !data.isEmpty else { throw AdminAPIError.invalidFile }
        guard data.count <= AdminUploadPolicy.maximumByteCount else { throw AdminAPIError.fileTooLarge }
        guard let safeMIMEType = AdminUploadPolicy.normalizedMIMEType(mimeType) else {
            throw AdminAPIError.unsupportedFileType
        }
        let safeFilename = try AdminUploadPolicy.sanitizedFilename(filename, mimeType: safeMIMEType)
        let requestGeneration = authenticationGeneration
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(safeFilename)\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await uploadSession.upload(for: request, from: data)
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        try validateActiveRequest(generation: requestGeneration)
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL, environment: serviceEnvironment) else {
            throw AdminAPIError.invalidResponse
        }
        return media
    }

    func upload(fileURL: URL, filename: String, mimeType: String) async throws -> UploadedMedia {
        guard fileURL.isFileURL, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw AdminAPIError.invalidFile
        }
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0 else { throw AdminAPIError.invalidFile }
        guard fileSize <= AdminUploadPolicy.maximumByteCount else { throw AdminAPIError.fileTooLarge }
        guard let safeMIMEType = AdminUploadPolicy.normalizedMIMEType(mimeType) else {
            throw AdminAPIError.unsupportedFileType
        }
        let safeFilename = try AdminUploadPolicy.sanitizedFilename(filename, mimeType: safeMIMEType)
        let requestGeneration = authenticationGeneration
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(safeFilename)\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await uploadSession.upload(for: request, fromFile: fileURL)
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        try validateActiveRequest(generation: requestGeneration)
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL, environment: serviceEnvironment) else {
            throw AdminAPIError.invalidResponse
        }
        return media
    }

    func publish(
        heroImages: [URL],
        aboutPortraitURL: URL?,
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork]
    ) async throws -> AppContentManifest {
        // Reject stale drafts from another workspace before any publishing request.
        let trustedMedia: (URL) -> Bool = { ContentSecurityPolicy.isTrustedMediaURL($0, environment: self.serviceEnvironment) }
        guard heroImages.allSatisfy(trustedMedia),
              (aboutPortraitURL.map(trustedMedia) ?? true),
              launchPosters.allSatisfy({ trustedMedia($0.imageURL) }),
              trustedMedia(showreel.videoURL), trustedMedia(showreel.posterURL),
              dramas.allSatisfy({ trustedMedia($0.imageURL) }) else { throw AdminAPIError.invalidResponse }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(
            AppContentUpdate(
                heroImages: heroImages,
                aboutPortraitURL: aboutPortraitURL,
                launchPosters: launchPosters,
                showreel: showreel,
                dramas: dramas
            )
        )
        let manifest: AppContentManifest = try await authorizedJSON(
            path: "shuzijun/v1/app-content",
            method: "POST",
            body: body
        )
        guard ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment) else { throw AdminAPIError.invalidResponse }
        return manifest
    }

    /// Publishes the uploaded About portrait without resubmitting unrelated
    /// administrator drafts. The server's existing content endpoint accepts a
    /// partial body and returns the complete authoritative manifest.
    func publishAboutPortrait(_ aboutPortraitURL: URL) async throws -> AppContentManifest {
        guard ContentSecurityPolicy.isTrustedMediaURL(aboutPortraitURL, environment: serviceEnvironment) else {
            throw AdminAPIError.invalidResponse
        }
        let body = try JSONEncoder().encode(
            AboutPortraitUpdate(aboutPortraitURL: aboutPortraitURL)
        )
        let manifest: AppContentManifest = try await authorizedJSON(
            path: "shuzijun/v1/app-content",
            method: "POST",
            body: body
        )
        guard ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment),
              manifest.aboutPortraitURL == aboutPortraitURL else {
            throw AdminAPIError.invalidResponse
        }
        return manifest
    }

    func fetchContent() async throws -> AppContentManifest {
        let manifest: AppContentManifest = try await authorizedJSON(
            path: "shuzijun/v1/app-content",
            method: "GET"
        )
        guard ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment) else { throw AdminAPIError.invalidResponse }
        return manifest
    }

    func updateGallery(portfolioID: Int, mediaIDs: [Int]) async throws -> AppContentManifest {
        let body = try JSONEncoder().encode(GalleryUpdate(mediaIDs: mediaIDs))
        let response: GalleryUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-content/portfolio/\(portfolioID)/gallery",
            method: "POST",
            body: body
        )
        guard ContentSecurityPolicy.isTrusted(response.content, environment: serviceEnvironment) else { throw AdminAPIError.invalidResponse }
        return response.content
    }

    func createPortfolio(
        title: String,
        subtitle: String,
        eyebrow: String
    ) async throws -> CreatedPortfolioResult {
        let body = try JSONEncoder().encode(
            CreatePortfolioRequest(title: title, subtitle: subtitle, eyebrow: eyebrow)
        )
        let result: CreatedPortfolioResult = try await authorizedJSON(
            path: "shuzijun/v1/app-content/portfolio",
            method: "POST",
            body: body
        )
        guard ContentSecurityPolicy.isTrusted(result.content, environment: serviceEnvironment) else { throw AdminAPIError.invalidResponse }
        return result
    }

    func fetchFanDirectory(
        search: String = "",
        page: Int = 1,
        perPage: Int = 100
    ) async throws -> AdminFanDirectory {
        let query = try AdminFanDirectoryQuery(
            search: search,
            page: page,
            perPage: perPage
        )
        let directory: AdminFanDirectory = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans",
            method: "GET",
            queryItems: query.queryItems
        )
        guard AdminFanDirectoryValidation.isValid(
            directory,
            requestedPage: query.page,
            requestedPerPage: query.perPage
        ) else {
            throw AdminAPIError.invalidResponse
        }
        return directory
    }

    func fetchFeatureCapabilities() async throws -> AppFeatureCapabilities {
        let capabilities: AppFeatureCapabilities = try await authorizedJSON(
            path: "shuzijun/v1/app-capabilities",
            method: "GET"
        )
        guard capabilities.isConsistent else { throw AdminAPIError.invalidResponse }
        return capabilities
    }

    func createFanInvitations(count: Int) async throws -> [AdminFanInvitation] {
        guard AdminFanInvitationValidation.allowedCount.contains(count) else {
            throw AdminAPIError.invalidResponse
        }
        let body = try JSONEncoder().encode(AdminFanInvitationRequest(count: count))
        let response: AdminFanInvitationResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans/invitations",
            method: "POST",
            body: body
        )
        guard AdminFanInvitationValidation.isValid(
            response,
            requestedCount: count
        ) else {
            throw AdminAPIError.invalidResponse
        }
        return response.invitations
    }

    func createFanPasswordRecovery(userID: String) async throws -> AdminFanPasswordRecovery {
        guard let uuid = UUID(uuidString: userID)?.uuidString.lowercased(),
              uuid == userID.lowercased() else {
            throw AdminAPIError.invalidResponse
        }
        let response: AdminFanPasswordRecoveryResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans/\(uuid)/password-recovery",
            method: "POST"
        )
        guard AdminFanPasswordRecoveryValidation.isValid(
            response.passwordRecovery,
            expectedUserID: uuid
        ) else {
            throw AdminAPIError.invalidResponse
        }
        return response.passwordRecovery
    }

    func fetchFanUser(userID: String) async throws -> AdminFanUser {
        let uuid = try AdminFanAdministratorUpdate.canonicalUserID(userID)
        let response: AdminFanAccessUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans/\(uuid)", method: "GET"
        )
        guard response.user.userID == uuid, FanAccountValidation.isValidAdminFanUser(response.user) else {
            throw AdminAPIError.invalidResponse
        }
        return response.user
    }

    func updateFanAdministrator(_ update: AdminFanAdministratorUpdate) async throws -> AdminFanUser {
        guard canManageFanAdministrators, boundAdministratorUserID != update.userID else {
            throw AdminAPIError.insufficientPermission
        }
        let response: AdminFanAccessUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans/\(update.userID)/administrator",
            method: "POST", body: try JSONEncoder().encode(update)
        )
        guard update.accepts(response.user) else { throw AdminAPIError.invalidResponse }
        return response.user
    }

    func updateFanAccess(
        userID: String,
        permissions: [String]? = nil,
        status: String? = nil
    ) async throws -> AdminFanUser {
        let permissionsAreValid = permissions.map { values in
            values.count <= 20
                && Set(values).count == values.count
                && values.allSatisfy { permission in
                    permission.range(
                        of: #"^[a-z][a-z0-9_]{0,63}$"#,
                        options: .regularExpression
                    ) != nil
                }
        } ?? true
        let statusIsValid = status.map { FanAccountStatus(rawValue: $0) != nil } ?? true
        guard let uuid = UUID(uuidString: userID)?.uuidString.lowercased(),
              uuid == userID.lowercased(),
              permissions != nil || status != nil,
              permissionsAreValid,
              statusIsValid else {
            throw AdminAPIError.invalidResponse
        }
        let body = try JSONEncoder().encode(
            AdminFanAccessUpdate(permissions: permissions, status: status)
        )
        let response: AdminFanAccessUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans/\(uuid)",
            method: "POST",
            body: body
        )
        guard response.user.userID.lowercased() == uuid,
              FanAccountValidation.isValidAdminFanUser(response.user) else {
            throw AdminAPIError.invalidResponse
        }
        return response.user
    }

    func sendPushNotification(
        toUserID userID: String,
        title: String,
        body: String,
        sensitive: Bool = true,
        idempotencyKey: UUID = UUID()
    ) async throws -> AdminPushNotificationResponse {
        guard let canonicalUserID = UUID(uuidString: userID)?.uuidString.lowercased(),
              canonicalUserID == userID.lowercased(),
        let content = AdminPushNotificationValidation.normalized(
                title: title,
                body: body,
                sensitive: sensitive
              ) else {
            throw AdminAPIError.invalidResponse
        }
        let request = AdminPushNotificationRequest(
            recipients: [AdminPushNotificationRecipient(userID: canonicalUserID)],
            title: content.title,
            body: content.body,
            sensitive: content.sensitive,
            idempotencyKey: idempotencyKey.uuidString.lowercased()
        )
        let response: AdminPushNotificationResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/push-notifications",
            method: "POST",
            body: try JSONEncoder().encode(request)
        )
        guard AdminPushNotificationValidation.isValidResponse(
            response,
            expectedRecipientCount: 1
        ) else {
            throw AdminAPIError.invalidResponse
        }
        return response
    }

    func fetchCollaborationRequests(
        status: CollaborationRequestStatus? = nil,
        page: Int = 1,
        perPage: Int = 100
    ) async throws -> AdminCollaborationDirectory {
        guard (1...100_000).contains(page), (1...100).contains(perPage) else {
            throw AdminAPIError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "perPage", value: String(perPage)),
        ]
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
        }
        let directory: AdminCollaborationDirectory = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/collaboration-requests",
            method: "GET",
            queryItems: queryItems
        )
        guard directory.page == page,
              directory.perPage == perPage,
              AdminCollaborationValidation.isValid(directory, filteredBy: status) else {
            throw AdminAPIError.invalidResponse
        }
        return directory
    }

    func updateCollaborationRequest(
        _ request: AdminCollaborationRequest,
        status: CollaborationRequestStatus
    ) async throws -> AdminCollaborationRequest {
        guard AdminCollaborationValidation.isValid(request),
              request.requestStatus != status else {
            if request.requestStatus == status { return request }
            throw AdminAPIError.invalidResponse
        }
        let body = try JSONEncoder().encode(
            AdminCollaborationStatusUpdate(status: status.rawValue, version: request.version)
        )
        let response: AdminCollaborationUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/collaboration-requests/\(request.requestID)",
            method: "POST",
            body: body
        )
        guard response.request.requestID == request.requestID,
              response.request.requestStatus == status,
              response.request.version == request.version + 1,
              AdminCollaborationValidation.isValid(response.request) else {
            throw AdminAPIError.invalidResponse
        }
        return response.request
    }

    private func authorizedJSON<T: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        queryItems: [URLQueryItem] = [],
        authenticationProbe: Bool = false
    ) async throws -> T {
        let requestGeneration = authenticationGeneration
        var request = try authorizedRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            authenticationProbe: authenticationProbe
        )
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            if let jsonLoader {
                (data, response) = try await jsonLoader(request)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        if !authenticationProbe {
            try validateActiveRequest(generation: requestGeneration)
        }
        return try decodeResponse(
            T.self,
            data: data,
            response: response,
            lockOnAuthorizationFailure: !authenticationProbe
        )
    }

    private func authorizedRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        authenticationProbe: Bool = false
    ) throws -> URLRequest {
        if !authenticationProbe,
           !AdminSessionSecurityPolicy.isFresh(expiresAt: authenticatedUntil) {
            lock()
            throw AdminAPIError.invalidCredentials
        }
        guard hasCurrentAuthenticationSource else {
            lock()
            throw AdminAPIError.invalidCredentials
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("?"),
              !path.contains("#"),
              AdminQueryItemPolicy.areValid(queryItems),
              ["GET", "POST"].contains(method) else {
            throw AdminAPIError.invalidResponse
        }
        let endpointRoot = path == "wp/v2/media" ? mediaUploadRoot : apiRoot
        let baseEndpoint = endpointRoot.appending(path: path)
        var components = URLComponents(
            url: baseEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let endpoint = components?.url else { throw AdminAPIError.invalidResponse }
        guard serviceEnvironment.allowsAPIURL(endpoint) || serviceEnvironment.allowsMediaUploadURL(endpoint) else {
            throw AdminAPIError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = AdminTransportPolicy.requestTimeout(path: path)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let boundContext, let boundAccount {
            try boundAccount.authorizeAdministratorRequest(&request, context: boundContext)
        } else if let credential {
            let token = Data("\(credential.username):\(credential.applicationPassword)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw AdminAPIError.invalidCredentials
        }
        request.setValue("Yishu-iOS-Admin/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func decodeResponse<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse,
        lockOnAuthorizationFailure: Bool = true
    ) throws -> T {
        guard data.count <= 8 * 1024 * 1024 else { throw AdminAPIError.invalidResponse }
        guard let http = response as? HTTPURLResponse,
              (serviceEnvironment.allowsAPIURL(http.url) || serviceEnvironment.allowsMediaUploadURL(http.url)) else {
            throw AdminAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let isJSON = AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
            )
            let serverError = isJSON
                ? try? JSONDecoder().decode(WordPressError.self, from: data)
                : nil
            if http.statusCode == 401 {
                if lockOnAuthorizationFailure { lock() }
                throw AdminAPIError.invalidCredentials
            }
            if http.statusCode == 403 {
                if lockOnAuthorizationFailure,
                   AdminAuthorizationFailurePolicy.shouldLock(
                    statusCode: http.statusCode,
                    serverErrorCode: serverError?.code
                   ) {
                    lock()
                }
                if serverError?.code == "push_capability_required" {
                    throw AdminAPIError.pushPermissionRequired
                }
                throw AdminAPIError.insufficientPermission
            }
            if http.statusCode == 409, serverError?.code == "fan_admin_conflict" {
                throw AdminAPIError.administratorConflict
            }
            throw AdminAPIError.server(
                safeServerMessage(serverError?.message, statusCode: http.statusCode)
            )
        }
        guard !data.isEmpty,
              AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
              ) else { throw AdminAPIError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AdminAPIError.invalidResponse
        }
    }

    private func safeServerMessage(_ rawMessage: String?, statusCode: Int) -> String {
        guard (400..<500).contains(statusCode), let rawMessage else {
            return "服务器暂时不可用（HTTP \(statusCode)）。"
        }
        let limited = String(rawMessage.prefix(500))
        let withoutHTML = limited.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let printable = withoutHTML.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let normalized = String(String.UnicodeScalarView(printable))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty
            ? "发布失败（HTTP \(statusCode)）。"
            : String(normalized.prefix(180))
    }

    private func establishSession(displayName: String, canManageFanAdministrators: Bool) {
        let expiry = Date().addingTimeInterval(Self.sessionLifetime)
        serverCanManageFanAdministrators = canManageFanAdministrators
        authenticatedUntil = expiry
        role = .administrator(displayName: displayName)
        expirationTask?.cancel()
        let expiryGeneration = authenticationGeneration
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.sessionLifetime))
            } catch {
                return
            }
            guard let self,
                  self.authenticationGeneration == expiryGeneration else { return }
            self.lock()
        }
    }

    private func validateActiveRequest(generation: UInt64) throws {
        if generation == authenticationGeneration, !hasCurrentAuthenticationSource {
            lock()
        }
        guard hasCurrentAuthenticationSource,
              AdminSessionSecurityPolicy.canAcceptResponse(
                requestGeneration: generation,
                currentGeneration: authenticationGeneration,
                expiresAt: authenticatedUntil
              ) else {
            throw AdminAPIError.invalidCredentials
        }
    }
}

enum AdminSessionSecurityPolicy {
    static func isFresh(expiresAt: Date?, now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return now < expiresAt
    }

    static func canAcceptResponse(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        expiresAt: Date?,
        now: Date = .now
    ) -> Bool {
        requestGeneration == currentGeneration && isFresh(expiresAt: expiresAt, now: now)
    }
}

enum AdminAuthorizationFailurePolicy {
    static func shouldLock(statusCode: Int, serverErrorCode: String?) -> Bool {
        statusCode == 401
            || (statusCode == 403 && serverErrorCode != "push_capability_required")
    }
}

private struct AdminCredential: Codable, Equatable {
    let username: String
    let applicationPassword: String
}

private struct AdminSessionResponse: Decodable {
    let displayName: String
    let authenticated: Bool?
    let role: String?
    let canManageFanAdministrators: Bool?

    var isVerifiedContentManager: Bool {
        authenticated == true && role == "yishu_content_manager"
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AdminFanAdministratorUpdate: Encodable, Equatable {
    let userID: String
    let administrator: Bool
    let expectedAdministrator: Bool
    let expectedRevision: Int

    private enum CodingKeys: String, CodingKey {
        case administrator, expectedAdministrator, expectedRevision
    }

    init(user: AdminFanUser, administrator: Bool) throws {
        userID = try Self.canonicalUserID(user.userID)
        guard FanAccountValidation.isValidAdminFanUser(user),
              let previous = user.administratorBound, let revision = user.administratorRevision,
              revision >= 0, revision < Int.max,
              !administrator || (user.status == FanAccountStatus.active.rawValue
                && !user.requiresIdentityCompletion && !user.requiresPasswordChange
                && FanAccountValidation.isCompleteDouyinID(user.douyinID)) else {
            throw AdminAPIError.invalidResponse
        }
        self.administrator = administrator
        expectedAdministrator = previous
        expectedRevision = revision
    }

    static func canonicalUserID(_ value: String) throws -> String {
        let uuid = value.lowercased()
        guard uuid.range(of: #"^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$"#,
                         options: .regularExpression) != nil else { throw AdminAPIError.invalidResponse }
        return uuid
    }

    func accepts(_ user: AdminFanUser) -> Bool {
        user.userID == userID && FanAccountValidation.isValidAdminFanUser(user)
            && user.administratorBound == administrator
            && user.administratorRevision == expectedRevision + (administrator == expectedAdministrator ? 0 : 1)
    }
}

struct AppContentUpdate: Encodable {
    let heroImages: [URL]
    let aboutPortraitURL: URL?
    let launchPosters: [LaunchPosterContent]
    let showreel: ShowreelContent
    let dramas: [DramaWork]
}

struct AboutPortraitUpdate: Encodable {
    let aboutPortraitURL: URL
}

private struct GalleryUpdate: Encodable {
    let mediaIDs: [Int]
}

private struct GalleryUpdateResponse: Decodable {
    let content: AppContentManifest
}

struct CreatedPortfolioResult: Decodable {
    let portfolioID: Int
    let content: AppContentManifest
}

private struct CreatePortfolioRequest: Encodable {
    let title: String
    let subtitle: String
    let eyebrow: String
}

struct AdminFanAccessUpdate: Encodable {
    let permissions: [String]?
    let status: String?
}

private struct AdminFanInvitationRequest: Encodable {
    let count: Int
}

private struct AdminFanAccessUpdateResponse: Decodable {
    let user: AdminFanUser
}

private struct AdminPushNotificationRecipient: Encodable {
    let userID: String
}

private struct AdminPushNotificationRequest: Encodable {
    let recipients: [AdminPushNotificationRecipient]
    let title: String
    let body: String
    let sensitive: Bool
    let idempotencyKey: String
}

private struct AdminCollaborationStatusUpdate: Encodable {
    let status: String
    let version: Int
}

private struct AdminCollaborationUpdateResponse: Decodable {
    let request: AdminCollaborationRequest
}

private struct WordPressError: Decodable {
    let code: String?
    let message: String
}

private enum LegacyAdminKeychain {
    private static let service = "cn.com.shuzijun.yishu.wordpress-admin"
    private static let account = "wordpress-content-manager"

    static func delete(environment: AppServiceEnvironment) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: environment.storageKey(service),
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
