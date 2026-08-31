import Foundation

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
