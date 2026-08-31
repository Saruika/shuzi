import Foundation
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
    case invalidResponse
    case invalidFile
    case fileTooLarge
    case unsupportedFileType
    case networkUnavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "管理员账号或访问码不正确。"
        case .insufficientPermission:
            return "账号已验证，但没有内容管理权限。"
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
        case .server(let message):
            return message
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

@MainActor
final class AdminSessionStore: ObservableObject {
    @Published private(set) var role: AppUserRole = .visitor
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedCredential = false
    @Published var errorMessage: String?

    private var credential: AdminCredential?
    private let apiRoot = URL(string: "https://shuzijun.com.cn/wp-json")!
    private let session: URLSession

    var isAuthenticated: Bool {
        if case .administrator = role { return true }
        return false
    }

    init() {
        session = SecureURLSessionFactory.make(
            requestTimeout: 120,
            resourceTimeout: 180
        )
        credential = AdminKeychain.load()
        hasSavedCredential = credential != nil
    }

    func restoreSession() async {
        guard credential != nil, !isAuthenticated else { return }
        do {
            let session: AdminSessionResponse = try await authorizedJSON(
                path: "shuzijun/v1/app-admin/session",
                method: "GET"
            )
            role = .administrator(displayName: session.displayName)
            errorMessage = nil
        } catch AdminAPIError.invalidCredentials {
            AdminKeychain.delete()
            credential = nil
            hasSavedCredential = false
            role = .visitor
            errorMessage = nil
        } catch {
            role = .visitor
            errorMessage = nil
        }
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

        isWorking = true
        defer { isWorking = false }
        let candidate = AdminCredential(username: cleanUsername, applicationPassword: cleanPassword)
        let previousCredential = credential
        credential = candidate
        do {
            let session: AdminSessionResponse = try await authorizedJSON(
                path: "shuzijun/v1/app-admin/session",
                method: "GET"
            )
            try AdminKeychain.save(candidate)
            hasSavedCredential = true
            role = .administrator(displayName: session.displayName)
            errorMessage = nil
        } catch {
            credential = previousCredential
            hasSavedCredential = previousCredential != nil
            role = .visitor
            errorMessage = (error as? AdminAPIError)?.errorDescription
                ?? AdminAPIError.networkUnavailable.errorDescription
        }
    }

    func signOut() {
        AdminKeychain.delete()
        credential = nil
        hasSavedCredential = false
        role = .visitor
        errorMessage = nil
    }

    func upload(data: Data, filename: String, mimeType: String) async throws -> UploadedMedia {
        guard !data.isEmpty else { throw AdminAPIError.invalidFile }
        guard data.count <= AdminUploadPolicy.maximumByteCount else { throw AdminAPIError.fileTooLarge }
        guard let safeMIMEType = AdminUploadPolicy.normalizedMIMEType(mimeType) else {
            throw AdminAPIError.unsupportedFileType
        }
        let safeFilename = try AdminUploadPolicy.sanitizedFilename(filename, mimeType: safeMIMEType)
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(safeFilename)\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.upload(for: request, from: data)
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL) else {
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
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(safeFilename)\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL) else {
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
        guard ContentSecurityPolicy.isTrusted(manifest) else { throw AdminAPIError.invalidResponse }
        return manifest
    }

    func fetchContent() async throws -> AppContentManifest {
        let manifest: AppContentManifest = try await authorizedJSON(
            path: "shuzijun/v1/app-content",
            method: "GET"
        )
        guard ContentSecurityPolicy.isTrusted(manifest) else { throw AdminAPIError.invalidResponse }
        return manifest
    }

    func updateGallery(portfolioID: Int, mediaIDs: [Int]) async throws -> AppContentManifest {
        let body = try JSONEncoder().encode(GalleryUpdate(mediaIDs: mediaIDs))
        let response: GalleryUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-content/portfolio/\(portfolioID)/gallery",
            method: "POST",
            body: body
        )
        guard ContentSecurityPolicy.isTrusted(response.content) else { throw AdminAPIError.invalidResponse }
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
        guard ContentSecurityPolicy.isTrusted(result.content) else { throw AdminAPIError.invalidResponse }
        return result
    }

    func fetchFanDirectory() async throws -> AdminFanDirectory {
        let directory: AdminFanDirectory = try await authorizedJSON(
            path: "shuzijun/v1/app-admin/fans",
            method: "GET"
        )
        guard directory.users.count <= 100,
              directory.permissionCatalog.count <= 20,
              Set(directory.users.map(\.userID)).count == directory.users.count,
              Set(directory.permissionCatalog.map(\.code)).count
                == directory.permissionCatalog.count,
              directory.users.allSatisfy({ user in
                  UUID(uuidString: user.userID) != nil
                      && FanAccountValidation.normalizedIdentityCode(user.identityCode)
                        == user.identityCode
                      && FanAccountValidation.normalizedDouyinID(user.douyinID)
                        == user.douyinID
                      && FanAccountStatus(rawValue: user.status) != nil
              }) else {
            throw AdminAPIError.invalidResponse
        }
        return directory
    }

    func updateFanAccess(
        userID: String,
        permissions: [String],
        status: String
    ) async throws -> AdminFanUser {
        guard let uuid = UUID(uuidString: userID)?.uuidString.lowercased(),
              uuid == userID.lowercased(),
              permissions.count <= 20,
              Set(permissions).count == permissions.count,
              permissions.allSatisfy({ permission in
                  permission.range(
                    of: #"^[a-z][a-z0-9_]{0,63}$"#,
                    options: .regularExpression
                  ) != nil
              }),
              FanAccountStatus(rawValue: status) != nil else {
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
        guard response.user.userID.lowercased() == uuid else {
            throw AdminAPIError.invalidResponse
        }
        return response.user
    }

    private func authorizedJSON<T: Decodable>(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> T {
        var request = try authorizedRequest(path: path, method: method)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AdminAPIError.networkUnavailable
        }
        return try decodeResponse(T.self, data: data, response: response)
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        guard let credential else { throw AdminAPIError.invalidCredentials }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("?"),
              !path.contains("#"),
              ["GET", "POST"].contains(method) else {
            throw AdminAPIError.invalidResponse
        }
        let token = Data("\(credential.username):\(credential.applicationPassword)".utf8).base64EncodedString()
        let endpoint = apiRoot.appending(path: path)
        guard AppNetworkSecurityPolicy.isTrustedAdminAPIURL(endpoint) else {
            throw AdminAPIError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Yishu-iOS-Admin/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard data.count <= 8 * 1024 * 1024 else { throw AdminAPIError.invalidResponse }
        guard let http = response as? HTTPURLResponse,
              AppNetworkSecurityPolicy.isTrustedAdminAPIURL(http.url) else {
            throw AdminAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw AdminAPIError.invalidCredentials
            }
            if http.statusCode == 403 {
                throw AdminAPIError.insufficientPermission
            }
            let isJSON = AppNetworkSecurityPolicy.isJSONMIMEType(
                http.value(forHTTPHeaderField: "Content-Type")
            )
            let serverError = isJSON ? try? JSONDecoder().decode(WordPressError.self, from: data) : nil
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
}

private struct AdminCredential: Codable {
    let username: String
    let applicationPassword: String
}

private struct AdminSessionResponse: Decodable {
    let displayName: String
}

private struct AppContentUpdate: Encodable {
    let heroImages: [URL]
    let aboutPortraitURL: URL?
    let launchPosters: [LaunchPosterContent]
    let showreel: ShowreelContent
    let dramas: [DramaWork]
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

private struct AdminFanAccessUpdate: Encodable {
    let permissions: [String]
    let status: String
}

private struct AdminFanAccessUpdateResponse: Decodable {
    let user: AdminFanUser
}

private struct WordPressError: Decodable {
    let message: String
}

private enum AdminKeychain {
    private static let service = "cn.com.shuzijun.yishu.wordpress-admin"
    private static let account = "wordpress-content-manager"

    static func load() -> AdminCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AdminCredential.self, from: data)
    }

    static func save(_ credential: AdminCredential) throws {
        let data = try JSONEncoder().encode(credential)
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
        guard status == errSecSuccess else {
            throw AdminAPIError.server("无法把访问码保存到设备 Keychain。")
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
