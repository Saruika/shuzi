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
    case invalidResponse
    case fileTooLarge
    case unsupportedFileType
    case networkUnavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "管理员账号或访问码不正确。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
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

private final class AdminURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "www.shuzijun.com.cn",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class AdminSessionStore: ObservableObject {
    @Published private(set) var role: AppUserRole = .visitor
    @Published private(set) var isWorking = false
    @Published private(set) var hasSavedCredential = false
    @Published var errorMessage: String?

    private var credential: AdminCredential?
    private let apiRoot = URL(string: "https://www.shuzijun.com.cn/wp-json")!
    private let session: URLSession

    private static let allowedUploadMIMETypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "image/webp",
        "video/mp4",
        "video/quicktime",
    ]

    var isAuthenticated: Bool {
        if case .administrator = role { return true }
        return false
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        session = URLSession(
            configuration: configuration,
            delegate: AdminURLSessionDelegate(),
            delegateQueue: nil
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
        guard !cleanUsername.isEmpty, !cleanPassword.isEmpty else {
            errorMessage = "请输入管理员账号和访问码。"
            return
        }

        isWorking = true
        defer { isWorking = false }
        let candidate = AdminCredential(username: cleanUsername, applicationPassword: cleanPassword)
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
            credential = nil
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
        guard data.count <= 60 * 1024 * 1024 else { throw AdminAPIError.fileTooLarge }
        let safeMIMEType = try validatedMIMEType(mimeType)
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(sanitizedFilename(filename))\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let (responseData, response) = try await session.upload(for: request, from: data)
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL) else {
            throw AdminAPIError.invalidResponse
        }
        return media
    }

    func upload(fileURL: URL, filename: String, mimeType: String) async throws -> UploadedMedia {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 60 * 1024 * 1024 else { throw AdminAPIError.fileTooLarge }
        let safeMIMEType = try validatedMIMEType(mimeType)
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(safeMIMEType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "attachment; filename=\"\(sanitizedFilename(filename))\"",
            forHTTPHeaderField: "Content-Disposition"
        )
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        let media = try decodeResponse(UploadedMedia.self, data: responseData, response: response)
        guard ContentSecurityPolicy.isTrustedMediaURL(media.sourceURL) else {
            throw AdminAPIError.invalidResponse
        }
        return media
    }

    func publish(
        heroImages: [URL],
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork]
    ) async throws -> AppContentManifest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(
            AppContentUpdate(
                heroImages: heroImages,
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
        let (data, response) = try await session.data(for: request)
        return try decodeResponse(T.self, data: data, response: response)
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        guard let credential else { throw AdminAPIError.invalidCredentials }
        let token = Data("\(credential.username):\(credential.applicationPassword)".utf8).base64EncodedString()
        var request = URLRequest(url: apiRoot.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Yishu-iOS-Admin/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard data.count <= 8 * 1024 * 1024 else { throw AdminAPIError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw AdminAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AdminAPIError.invalidCredentials
            }
            let serverError = try? JSONDecoder().decode(WordPressError.self, from: data)
            throw AdminAPIError.server(serverError?.message ?? "发布失败（HTTP \(http.statusCode)）。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func validatedMIMEType(_ mimeType: String) throws -> String {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard Self.allowedUploadMIMETypes.contains(normalized) else {
            throw AdminAPIError.unsupportedFileType
        }
        return normalized
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let basename = (filename as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleanedScalars = basename.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let cleaned = String(cleanedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "upload.bin" : String(cleaned.prefix(120))
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
