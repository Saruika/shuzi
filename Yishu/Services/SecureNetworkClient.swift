import Foundation

enum AppNetworkIdentity {
    enum Source: String, CaseIterable { case fan, admin, collaboration, image, publicExperience = "public-experience" }

    static func userAgent(for source: Source) -> String {
        "\(userAgent) (\(source.rawValue))"
    }
    static let userAgent = userAgent(version: Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    static func userAgent(version: String?) -> String {
        let version = version ?? ""
        let valid = !version.isEmpty && version.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
        return "Yishu-iOS/\(valid ? version : "unknown")"
    }
}

enum AppURL {
    private static let invalidURL = URL(fileURLWithPath: "/__invalid_app_url__")

    /// Keeps static app URLs non-optional without turning a malformed value into a launch crash.
    /// Network policies reject the local sentinel if a configured value ever becomes invalid.
    static func make(_ rawValue: String) -> URL {
        URL(string: rawValue) ?? invalidURL
    }
}

/// Centralizes the transport boundary for content and administrator traffic.
/// Credentials must never be allowed to follow an HTTP redirect, even when the
/// destination appears to use the same host name.
enum AppNetworkSecurityPolicy {
    static let contentHost = "www.shuzijun.com.cn"
    static let apiHost = "shuzijun.com.cn"
    private static let allowedImageMIMETypes: Set<String> = [
        "image/avif",
        "image/heic",
        "image/heif",
        "image/jpeg",
        "image/png",
        "image/webp",
    ]

    static func isTrustedHTTPSOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == contentHost
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.fragment == nil
    }

    static func matchesPublishedContentEndpoint(_ url: URL?, expected: URL) -> Bool {
        guard isTrustedAPIOrigin(url),
              isTrustedAPIOrigin(expected),
              let url else { return false }
        return url.path == expected.path
            && url.query == expected.query
    }

    static func isTrustedAdminAPIURL(_ url: URL?) -> Bool {
        guard isTrustedAPIOrigin(url), let url else { return false }
        return url.path == "/wp-json" || url.path.hasPrefix("/wp-json/")
    }

    static func isTrustedAdminMediaUploadURL(_ url: URL?) -> Bool {
        guard isTrustedHTTPSOrigin(url), let url else { return false }
        return url.path == "/wp-json/wp/v2/media" && url.query == nil
    }

    static func isTrustedAdminRequestURL(_ url: URL?) -> Bool {
        isTrustedAdminAPIURL(url) || isTrustedAdminMediaUploadURL(url)
    }

    private static func isTrustedAPIOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == apiHost
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.fragment == nil
    }

    static func isJSONMIMEType(_ rawValue: String?) -> Bool {
        guard let normalized = normalizedMIMEType(rawValue) else { return false }
        return normalized == "application/json" || normalized.hasSuffix("+json")
    }

    static func isImageMIMEType(_ rawValue: String?) -> Bool {
        guard let normalized = normalizedMIMEType(rawValue) else { return false }
        return allowedImageMIMETypes.contains(normalized)
    }

    static func permitsResponseLength(_ expectedLength: Int64, maximumBytes: Int64) -> Bool {
        guard maximumBytes > 0 else { return false }
        return expectedLength == NSURLSessionTransferSizeUnknown
            || (expectedLength > 0 && expectedLength <= maximumBytes)
    }

    private static func normalizedMIMEType(_ rawValue: String?) -> String? {
        guard let normalized = rawValue?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else { return nil }
        return normalized
    }
}

final class RejectingRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum SecureURLSessionFactory {
    static func make(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        waitsForConnectivity: Bool = true
    ) -> URLSession {
        URLSession(
            configuration: configuration(requestTimeout: requestTimeout,
                                         resourceTimeout: resourceTimeout,
                                         waitsForConnectivity: waitsForConnectivity),
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    static func configuration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        waitsForConnectivity: Bool = true
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}

/// Receives Foundation's Data chunks, with a hard limit enforced before each
/// append (including unknown/chunked or decompressed response lengths). No disk
/// cache or temporary download file. Each request owns and invalidates its session.
/// The lock protects state shared by cancellation and the serial delegate queue.
final class BoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias ResponseValidator = @Sendable (HTTPURLResponse) throws -> Void
    typealias RedirectValidator = @Sendable (URLRequest, Int) -> Bool
    private let maximumBytes: Int
    private let validate: ResponseValidator
    private let allowsRedirect: RedirectValidator
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancelled = false
    private var redirectCount = 0 // Accessed only by the serial delegate queue.

    init(maximumBytes: Int, validate: @escaping ResponseValidator,
                 allowsRedirect: @escaping RedirectValidator) {
        self.maximumBytes = maximumBytes
        self.validate = validate
        self.allowsRedirect = allowsRedirect
    }

    static func data(for request: URLRequest, configuration: URLSessionConfiguration,
                     maximumBytes: Int, validate: @escaping ResponseValidator,
                     allowsRedirect: @escaping RedirectValidator = { _, _ in false }) async throws
        -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let loader = BoundedResponseLoader(maximumBytes: maximumBytes, validate: validate,
                                           allowsRedirect: allowsRedirect)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                loader.start(request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let session = self.session
        self.session = nil
        body = Data()
        response = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try validate(http)
            guard http.expectedContentLength <= Int64(maximumBytes) else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            lock.lock()
            let active = continuation != nil && !cancelled
            if active { self.response = http }
            lock.unlock()
            completionHandler(active ? .allow : .cancel)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil, !cancelled else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<(Data, HTTPURLResponse), Error>
        if let error { result = .failure(error) }
        else if let response { result = .success((body, response)) }
        else { result = .failure(URLError(.badServerResponse)) }
        lock.unlock()
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        completionHandler(allowsRedirect(request, redirectCount) ? request : nil)
    }
}
