import Foundation

/// Centralizes the transport boundary for content and administrator traffic.
/// Credentials must never be allowed to follow an HTTP redirect, even when the
/// destination appears to use the same host name.
enum AppNetworkSecurityPolicy {
    static let contentHost = "www.shuzijun.com.cn"

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
        guard isTrustedHTTPSOrigin(url),
              isTrustedHTTPSOrigin(expected),
              let url else { return false }
        return url.path == expected.path
            && url.query == expected.query
    }

    static func isTrustedAdminAPIURL(_ url: URL?) -> Bool {
        guard isTrustedHTTPSOrigin(url), let url else { return false }
        return url.path == "/wp-json" || url.path.hasPrefix("/wp-json/")
    }

    static func isJSONMIMEType(_ rawValue: String?) -> Bool {
        guard let normalized = rawValue?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else { return false }
        return normalized == "application/json" || normalized.hasSuffix("+json")
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
        resourceTimeout: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(
            configuration: configuration,
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }
}
