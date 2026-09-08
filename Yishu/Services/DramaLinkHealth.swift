import Foundation

enum DramaLinkHealth: Equatable {
    case available, expired, unverified

    var message: String {
        switch self {
        case .available: return "链接检查通过"
        case .expired: return "红果链接暂时失效，请稍后再试。管理员更换链接后，重新打开 App 即可刷新。"
        case .unverified: return "暂时无法确认链接是否可用，请检查网络后重试。未将你跳转到未知页面。"
        }
    }
}

enum DramaLinkPolicy {
    static func isHongguo(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && ["novelquickapp.com", "www.novelquickapp.com"].contains(url.host?.lowercased() ?? "")
            && url.absoluteString.utf8.count <= 8192
    }

    /// A 200 status alone is not success: the expired share endpoint returns JSON 404.
    static func evaluate(status: Int, body: Data, requireActor: Bool = false) -> DramaLinkHealth {
        if status == 404 || status == 410 { return .expired }
        guard status == 200, body.count <= 524_288 else { return .unverified }
        if let error = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = error["message"] as? String,
           message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "404 not found" {
            return .expired
        }
        guard let html = String(data: body, encoding: .utf8),
              let start = html.range(of: "window._ROUTER_DATA = "),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = html[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let loaders = root["loaderData"] as? [String: Any] else { return .unverified }
        for value in loaders.values {
            guard let page = value as? [String: Any], let data = page["pageData"] as? [String: Any],
                  let response = data["BaseResp"] as? [String: Any],
                  response["StatusCode"] as? Int == 0 else { continue }
            if let actor = data["actor_data"] as? [String: Any],
               actor["actor_name"] as? String == "易姝",
               let works = actor["works"] as? [[String: Any]],
               works.contains(where: { ($0["series_title"] as? String)?.isEmpty == false }) {
                return .available
            }
            // Per-series links must contain an actual series title, not an empty actor-page placeholder.
            if !requireActor, let series = data["series_data"] as? [String: Any],
               let title = series["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .available
            }
        }
        return .unverified
    }

    static func replacing(_ works: [DramaWork], from: URL, to: URL) -> [DramaWork] {
        works.map { work in
            DramaWork(id: work.id, title: work.title, imageURL: work.imageURL,
                      destinationURL: work.destinationURL == from ? to : work.destinationURL)
        }
    }

    /// Legacy manifests have no separate social-profile field. Only reuse an
    /// unambiguous shared entry; never select an arbitrary per-series link.
    static func profileCandidate(in works: [DramaWork]) -> URL {
        let groups = Dictionary(grouping: works.filter { isHongguo($0.destinationURL) }, by: \.destinationURL)
            .filter { $0.value.count > 1 }
        return groups.count == 1 ? (groups.first?.key ?? ContentCatalog.hongguoURL) : ContentCatalog.hongguoURL
    }
}

private final class DramaLinkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0 // URLSession's serial delegate queue owns this state.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, DramaLinkPolicy.isHongguo(url) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

enum DramaLinkChecker {
    static func check(_ url: URL, requireActor: Bool = false) async -> DramaLinkHealth {
        guard !Task.isCancelled, DramaLinkPolicy.isHongguo(url) else { return .unverified }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: DramaLinkRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  DramaLinkPolicy.isHongguo(finalURL), http.expectedContentLength <= 524_288 else { return .unverified }
            if http.statusCode == 404 || http.statusCode == 410 { return .expired }
            guard http.statusCode == 200 else { return .unverified }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 524_288 else { return .unverified }
                data.append(byte)
            }
            return DramaLinkPolicy.evaluate(status: http.statusCode, body: data, requireActor: requireActor)
        } catch { return .unverified }
    }
}
