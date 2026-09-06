import Foundation

/// Explicit workspaces, never selected from a token, remote manifest or reviewer's identity.
/// The review backend must be provisioned and verified before a UI entry is enabled.
enum AppServiceEnvironment: String, CaseIterable, Sendable {
    case production
    case review

    var displayName: String {
        switch self {
        case .production: "正式环境"
        case .review: "审核演示环境"
        }
    }

    var apiHost: String {
        switch self {
        case .production: "shuzijun.com.cn"
        case .review: "review.shuzijun.com.cn"
        }
    }

    var mediaHost: String {
        switch self {
        case .production: "www.shuzijun.com.cn"
        case .review: "review.shuzijun.com.cn"
        }
    }

    var apiRoot: URL { AppURL.make("https://\(apiHost)/wp-json") }
    var mediaUploadRoot: URL { AppURL.make("https://\(mediaHost)/wp-json") }
    var mediaUploadURL: URL { mediaUploadRoot.appending(path: "wp/v2/media") }

    /// Preserve existing production keys; never migrate production credentials to review.
    func storageKey(_ productionKey: String) -> String {
        self == .production ? productionKey : "review.\(productionKey)"
    }

    func allowsAPIURL(_ url: URL?) -> Bool {
        guard matchesOrigin(url, host: apiHost), let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let encodedPath = components.percentEncodedPath.lowercased()
        // Reject ambiguous path separators/traversal before adding Authorization.
        guard !["%2f", "%5c", "%2e", "%25"].contains(where: encodedPath.contains),
              !url.path.contains("\\"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return url.path == "/wp-json" || url.path.hasPrefix("/wp-json/")
    }

    func allowsMediaUploadURL(_ url: URL?) -> Bool {
        guard matchesOrigin(url, host: mediaHost), let url else { return false }
        return url.path == "/wp-json/wp/v2/media" && url.query == nil
    }

    private func matchesOrigin(_ url: URL?, host: String) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == host
            && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && url.fragment == nil
    }
}
