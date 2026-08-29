import Foundation
import Security

enum FanCommunityError: LocalizedError {
    case invalidResponse
    case unavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "互动服务返回了无法识别的数据。"
        case .unavailable:
            "互动空间暂时不可用，请稍后再试。"
        case .server(let message):
            message
        }
    }
}

private final class FanCommunityURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
final class FanCommunityStore: ObservableObject {
    @Published private(set) var content: FanCommunityManifest?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?
    @Published var receiptMessage: String?

    private let endpoint = URL(string: "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/fan-community")!
    private let session: URLSession
    let installationID: String

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration,
            delegate: FanCommunityURLSessionDelegate(),
            delegateQueue: nil
        )
        installationID = FanInstallationKeychain.loadOrCreate()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await requestManifest(path: "", method: "GET")
            errorMessage = nil
        } catch {
            if content == nil {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func react(to postID: String, reactionID: String) async {
        await performManifestMutation(
            path: "reactions",
            body: ReactionRequest(postID: postID, reactionID: reactionID)
        )
    }

    func vote(in pollID: String, optionID: String) async {
        await performManifestMutation(
            path: "votes",
            body: VoteRequest(pollID: pollID, optionID: optionID)
        )
    }

    func sendLetter(nickname: String, message: String, consent: Bool) async throws -> FanLetterReceipt {
        guard !isSubmitting else { throw FanCommunityError.unavailable }
        isSubmitting = true
        defer { isSubmitting = false }
        let request = LetterRequest(
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            consent: consent
        )
        let receipt: FanLetterReceipt = try await requestJSON(path: "letters", method: "POST", body: request)
        receiptMessage = receipt.message
        errorMessage = nil
        return receipt
    }

    func registerPushToken(_ token: String, preferences: NotificationPreferences, environment: String) async throws {
        let body = PushDeviceRequest(token: token, environment: environment, preferences: preferences)
        let _: PushDeviceResponse = try await requestJSON(path: "devices", method: "POST", body: body)
    }

    private func performManifestMutation<T: Encodable>(path: String, body: T) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            content = try await requestManifest(path: path, method: "POST", body: body)
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func requestManifest<T: Encodable>(path: String, method: String, body: T) async throws -> FanCommunityManifest {
        let manifest: FanCommunityManifest = try await requestJSON(path: path, method: method, body: body)
        return try validate(manifest)
    }

    private func requestManifest(path: String, method: String) async throws -> FanCommunityManifest {
        let manifest: FanCommunityManifest = try await requestJSON(path: path, method: method)
        return try validate(manifest)
    }

    private func requestJSON<T: Decodable>(path: String, method: String) async throws -> T {
        var request = makeRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return try decode(T.self, data: data, response: response)
    }

    private func requestJSON<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> T {
        var request = makeRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return try decode(T.self, data: data, response: response)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = path.isEmpty ? endpoint : endpoint.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Yishu-iOS/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue(installationID, forHTTPHeaderField: "X-Yishu-Installation")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard data.count <= 2 * 1024 * 1024,
              let http = response as? HTTPURLResponse else {
            throw FanCommunityError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(FanServerError.self, from: data)
            if http.statusCode == 404 || http.statusCode == 503 {
                throw FanCommunityError.unavailable
            }
            throw FanCommunityError.server(serverError?.message ?? "操作失败（HTTP \(http.statusCode)）。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FanCommunityError.invalidResponse
        }
    }

    private func validate(_ manifest: FanCommunityManifest) throws -> FanCommunityManifest {
        guard manifest.schemaVersion == 1,
              manifest.posts.count <= 100,
              manifest.polls.count <= 30,
              manifest.posts.allSatisfy({
                  !$0.text.isEmpty && $0.text.count <= 500 && FanCommunityLinkPolicy.isTrusted($0.externalURL)
              }),
              manifest.polls.allSatisfy({ $0.options.count >= 2 && $0.options.count <= 4 }) else {
            throw FanCommunityError.invalidResponse
        }
        return manifest
    }

    private func displayMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? FanCommunityError.unavailable.errorDescription!
    }
}

private struct ReactionRequest: Encodable {
    let postID: String
    let reactionID: String
}

private struct VoteRequest: Encodable {
    let pollID: String
    let optionID: String
}

private struct LetterRequest: Encodable {
    let nickname: String
    let message: String
    let consent: Bool
}

private struct PushDeviceRequest: Encodable {
    let token: String
    let environment: String
    let preferences: NotificationPreferences
}

private struct PushDeviceResponse: Decodable {
    let registered: Bool
}

private struct FanServerError: Decodable {
    let message: String
}

private enum FanInstallationKeychain {
    private static let service = "cn.com.shuzijun.yishu.fan-interaction"
    private static let account = "installation-id"

    static func loadOrCreate() -> String {
        if let existing = load(), UUID(uuidString: existing) != nil { return existing }
        let value = UUID().uuidString.lowercased()
        save(value)
        return value
    }

    private static func load() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
}
