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
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "管理员账号或访问码不正确。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .fileTooLarge:
            return "文件不能超过 60 MB，请先压缩视频后再上传。"
        case .server(let message):
            return message
        }
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

    var isAuthenticated: Bool {
        if case .administrator = role { return true }
        return false
    }

    init() {
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("attachment; filename=\"\(filename)\"", forHTTPHeaderField: "Content-Disposition")
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        return try decodeResponse(UploadedMedia.self, data: responseData, response: response)
    }

    func upload(fileURL: URL, filename: String, mimeType: String) async throws -> UploadedMedia {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 60 * 1024 * 1024 else { throw AdminAPIError.fileTooLarge }
        var request = try authorizedRequest(path: "wp/v2/media", method: "POST")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("attachment; filename=\"\(filename)\"", forHTTPHeaderField: "Content-Disposition")
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        return try decodeResponse(UploadedMedia.self, data: responseData, response: response)
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
        return try await authorizedJSON(
            path: "shuzijun/v1/app-content",
            method: "POST",
            body: body
        )
    }

    func updateGallery(portfolioID: Int, mediaIDs: [Int]) async throws -> AppContentManifest {
        let body = try JSONEncoder().encode(GalleryUpdate(mediaIDs: mediaIDs))
        let response: GalleryUpdateResponse = try await authorizedJSON(
            path: "shuzijun/v1/app-content/portfolio/\(portfolioID)/gallery",
            method: "POST",
            body: body
        )
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
        return try await authorizedJSON(
            path: "shuzijun/v1/app-content/portfolio",
            method: "POST",
            body: body
        )
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        return request
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
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
