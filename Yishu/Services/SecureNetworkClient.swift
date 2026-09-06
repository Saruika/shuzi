import Foundation

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
        return URLSession(
            configuration: configuration,
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }
}
