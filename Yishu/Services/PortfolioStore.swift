import Foundation

enum ContentOrigin: Equatable {
    case bundled
    case cached
    case network
}

enum ProtectedContentState: Equatable {
    case locked
    case loading
    case available
    case unavailable
}

private enum PremiumContentError: Error {
    case credentialRejected
    case verifierUnavailable
    case serverUnavailable
}

private final class ProtectedContentSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == "www.shuzijun.com.cn",
              request.url?.port == nil || request.url?.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class PortfolioStore: ObservableObject {
    @Published private(set) var portfolios: [Portfolio] = Portfolio.fallback
    @Published private(set) var heroImages: [URL] = ContentCatalog.heroImages
    @Published private(set) var launchPosters: [LaunchPosterContent] = ContentCatalog.launchPosters
    @Published private(set) var showreel: ShowreelContent = ContentCatalog.showreel
    @Published private(set) var dramas: [DramaWork] = ContentCatalog.dramas
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var contentOrigin: ContentOrigin = .bundled
    @Published private(set) var protectedContentState: ProtectedContentState = .locked

    private let baseURL = URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2")!
    private let protectedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration,
            delegate: ProtectedContentSessionDelegate(),
            delegateQueue: nil
        )
    }()
    init() {}

    /// Disk reads and JSON decoding stay off the main actor. The subsequent
    /// network refresh replaces this snapshot with the latest public content.
    func restoreCachedContent() async {
        guard contentOrigin == .bundled else { return }
        let cache = await Task.detached(priority: .userInitiated) {
            Self.loadCache()
        }.value
        guard contentOrigin == .bundled,
              let cache,
              !cache.portfolios.isEmpty else { return }
        portfolios = cache.portfolios
        heroImages = cache.heroImages ?? ContentCatalog.heroImages
        launchPosters = cache.launchPosters ?? ContentCatalog.launchPosters
        showreel = cache.showreel ?? ContentCatalog.showreel
        dramas = cache.dramas ?? ContentCatalog.dramas
        lastUpdated = cache.updatedAt
        contentOrigin = .cached
    }

    var syncStatus: String {
        if isRefreshing { return "正在同步" }
        switch contentOrigin {
        case .network:
            return lastUpdated == nil ? "内容已同步" : "内容更新于"
        case .cached:
            return lastUpdated == nil ? "上次同步内容" : "上次更新于"
        case .bundled:
            return "离线基础内容"
        }
    }

    var activeLaunchPoster: LaunchPosterContent? {
        launchPosters
            .filter { $0.isActive() }
            .max { $0.startsAt < $1.startsAt }
    }

    func applyPublishedManifest(_ manifest: AppContentManifest) {
        guard manifest.schemaVersion == 1,
              !manifest.portfolios.isEmpty,
              ContentSecurityPolicy.isTrusted(manifest) else { return }
        portfolios = manifest.portfolios
        heroImages = manifest.heroImages
        launchPosters = manifest.launchPosters ?? launchPosters
        showreel = manifest.showreel
        dramas = manifest.dramas
        lastUpdated = manifest.updatedAt
        contentOrigin = .network
        protectedContentState = .available
        statusMessage = nil
    }

    /// Premium manifests can contain short-lived signed URLs. They are applied
    /// only in memory and are never written to the app cache or device backup.
    func refreshPremiumContent(with transactionJWS: String) async {
        guard (100...16_384).contains(transactionJWS.count) else {
            protectedContentState = .unavailable
            statusMessage = "Apple 订阅凭证不完整，请恢复购买后重试。"
            return
        }
        protectedContentState = .loading
        do {
            let manifest = try await fetchPremiumContentManifest(transactionJWS: transactionJWS)
            guard manifest.schemaVersion == 1,
                  !manifest.portfolios.isEmpty,
                  ContentSecurityPolicy.isTrusted(manifest) else {
                throw URLError(.secureConnectionFailed)
            }
            applyPublishedManifest(manifest)
        } catch PremiumContentError.verifierUnavailable {
            protectedContentState = .unavailable
            statusMessage = "订阅已确认，但完整内容服务尚未就绪。"
        } catch PremiumContentError.credentialRejected {
            protectedContentState = .unavailable
            statusMessage = "Apple 订阅凭证未通过服务器校验，请恢复购买后重试。"
        } catch {
            protectedContentState = .unavailable
            statusMessage = "订阅已确认，受保护照片暂时无法载入。"
        }
    }

    /// Immediately removes protected URLs when a subscription expires or an
    /// administrator signs out, before the public preview refresh completes.
    func discardProtectedContent() {
        protectedContentState = .locked
        portfolios = portfolios.map { portfolio in
            let preview = Array(portfolio.images.prefix(PhotoAccessPolicy.freePreviewCount))
            return Portfolio(
                id: portfolio.id,
                title: portfolio.title,
                subtitle: portfolio.subtitle,
                eyebrow: portfolio.eyebrow,
                slug: portfolio.slug,
                websiteURL: portfolio.websiteURL,
                coverURL: preview.first?.url ?? portfolio.coverURL,
                images: preview,
                totalImageCount: portfolio.displayImageCount
            )
        }
        URLCache.shared.removeAllCachedResponses()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let manifest = try await fetchContentManifest()
            guard manifest.schemaVersion == 1,
                  !manifest.portfolios.isEmpty,
                  ContentSecurityPolicy.isTrusted(manifest) else {
                throw URLError(.zeroByteResource)
            }
            portfolios = manifest.portfolios
            heroImages = manifest.heroImages
            launchPosters = manifest.launchPosters ?? launchPosters
            showreel = manifest.showreel
            dramas = manifest.dramas
            lastUpdated = manifest.updatedAt
            contentOrigin = .network
            protectedContentState = .locked
            statusMessage = nil
            Self.persistCacheInBackground(
                portfolios: manifest.portfolios,
                heroImages: manifest.heroImages,
                launchPosters: manifest.launchPosters ?? launchPosters,
                showreel: manifest.showreel,
                dramas: manifest.dramas,
                updatedAt: manifest.updatedAt
            )
        } catch {
            do {
                let remotePortfolios = try await fetchPortfolios()
                guard !remotePortfolios.isEmpty else { throw URLError(.zeroByteResource) }
                portfolios = remotePortfolios
                lastUpdated = Date()
                contentOrigin = .network
                statusMessage = "内容接口升级中，照片已同步"
                Self.persistCacheInBackground(
                    portfolios: remotePortfolios,
                    heroImages: heroImages,
                    launchPosters: launchPosters,
                    showreel: showreel,
                    dramas: dramas,
                    updatedAt: lastUpdated ?? Date()
                )
            } catch {
                statusMessage = contentOrigin == .bundled
                    ? "网络不可用，当前显示离线基础内容"
                    : "网络不可用，继续显示上次同步内容"
            }
        }
    }

    nonisolated private static func loadCache() -> PortfolioCacheEnvelope? {
        guard let url = cacheFileURL(createDirectory: false),
              let data = try? Data(contentsOf: url),
              data.count <= 5 * 1024 * 1024,
              let cache = try? JSONDecoder().decode(PortfolioCacheEnvelope.self, from: data),
              cache.isPublicPreview,
              ContentSecurityPolicy.isTrusted(cache) else { return nil }
        return cache
    }

    private static func persistCacheInBackground(
        portfolios: [Portfolio],
        heroImages: [URL],
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        Task.detached(priority: .utility) {
            Self.persistCache(
                portfolios: portfolios,
                heroImages: heroImages,
                launchPosters: launchPosters,
                showreel: showreel,
                dramas: dramas,
                updatedAt: updatedAt
            )
        }
    }

    nonisolated private static func persistCache(
        portfolios: [Portfolio],
        heroImages: [URL],
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        guard let url = cacheFileURL(createDirectory: true),
              let data = try? JSONEncoder().encode(
                PortfolioCacheEnvelope(
                    portfolios: portfolios,
                    heroImages: heroImages,
                    launchPosters: launchPosters,
                    showreel: showreel,
                    dramas: dramas,
                    updatedAt: updatedAt,
                    isPublicPreview: true
                )
              ) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var protectedURL = url
            try protectedURL.setResourceValues(resourceValues)
        } catch {
            // A failed cache write must never prevent the live catalog from loading.
        }
    }

    nonisolated private static func cacheFileURL(createDirectory: Bool) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let directory = applicationSupport.appending(path: "Yishu", directoryHint: .isDirectory)
        if createDirectory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return directory.appending(path: "portfolio-cache.json")
    }

    private func fetchPortfolios() async throws -> [Portfolio] {
        let url = baseURL.appending(path: "portfolio").appending(
            queryItems: [
                URLQueryItem(name: "per_page", value: "20"),
                URLQueryItem(name: "orderby", value: "date"),
                URLQueryItem(name: "order", value: "asc")
            ]
        )
        let posts: [WPPortfolio] = try await request(url)
        var result: [Portfolio] = []

        for post in posts {
            let mediaURL = baseURL.appending(path: "media").appending(
                queryItems: [
                    URLQueryItem(name: "parent", value: String(post.id)),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "orderby", value: "id"),
                    URLQueryItem(name: "order", value: "asc")
                ]
            )
            let media: [WPMedia] = try await request(mediaURL)
            let images = media.compactMap { item -> PortfolioImage? in
                guard let full = URL(string: item.sourceURL),
                      ContentSecurityPolicy.isTrustedMediaURL(full) else { return nil }
                let preferred = item.mediaDetails?.sizes?["large"]?.sourceURL
                    ?? item.mediaDetails?.sizes?["medium_large"]?.sourceURL
                    ?? item.sourceURL
                guard let display = URL(string: preferred),
                      ContentSecurityPolicy.isTrustedMediaURL(display) else { return nil }
                return PortfolioImage(
                    id: item.id,
                    url: display,
                    fullSizeURL: full,
                    altText: item.altText.isEmpty ? post.title.rendered : item.altText
                )
            }

            guard let pageURL = URL(string: post.link),
                  ContentSecurityPolicy.isTrustedWebsiteURL(pageURL) else { continue }
            let metadata = Self.metadata(for: post.title.rendered)
            result.append(
                Portfolio(
                    id: post.id,
                    title: metadata.title,
                    subtitle: metadata.subtitle,
                    eyebrow: metadata.eyebrow,
                    slug: post.slug,
                    websiteURL: pageURL,
                    coverURL: images.first?.url,
                    images: images
                )
            )
        }

        let order = ["婚纱": 0, "新中式": 1, "旗袍": 2]
        return result.sorted { order[$0.title, default: 99] < order[$1.title, default: 99] }
    }

    private func fetchContentManifest() async throws -> AppContentManifest {
        var request = URLRequest(url: ContentCatalog.appContentURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("Yishu-iOS/2.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 5 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AppContentManifest.self, from: data)
        guard ContentSecurityPolicy.isTrusted(manifest) else { throw URLError(.secureConnectionFailed) }
        return manifest
    }

    private func fetchPremiumContentManifest(transactionJWS: String) async throws -> AppContentManifest {
        var request = URLRequest(url: ContentCatalog.premiumAppContentURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(transactionJWS)", forHTTPHeaderField: "Authorization")
        request.setValue("Yishu-iOS/2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await protectedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PremiumContentError.serverUnavailable
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw PremiumContentError.credentialRejected
        case 503:
            throw PremiumContentError.verifierUnavailable
        default:
            throw PremiumContentError.serverUnavailable
        }
        guard data.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppContentManifest.self, from: data)
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Revalidate on user-initiated refreshes while still benefiting from
        // HTTP cache validation when the remote catalog has not changed.
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("Yishu-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 5 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func metadata(for rawTitle: String) -> (title: String, subtitle: String, eyebrow: String) {
        if rawTitle.contains("婚纱") {
            return ("婚纱", "在柔光里，留下誓约般的静谧", "WEDDING · PORTRAIT")
        }
        if rawTitle.contains("新中式") {
            return ("新中式", "古意与当代表达之间的留白", "NEW CHINESE · EDITORIAL")
        }
        if rawTitle.contains("旗袍") {
            return ("旗袍", "庭院、窗影与东方美学", "QIPAO · STORY")
        }
        return (rawTitle, "易姝影像作品", "PORTFOLIO")
    }
}

enum ContentSecurityPolicy {
    private static let trustedMediaHosts: Set<String> = [
        "www.shuzijun.com.cn",
        "img.shuzijun.com.cn",
        "shuzijun.com.cn",
    ]

    private static let trustedDestinationHosts: Set<String> = [
        "novelquickapp.com",
        "www.novelquickapp.com",
        "xhslink.com",
        "www.xhslink.com",
        "v.douyin.com",
        "www.douyin.com",
        "www.xiaohongshu.com",
    ]

    static func isTrusted(_ manifest: AppContentManifest) -> Bool {
        manifest.heroImages.allSatisfy(isTrustedMediaURL)
            && (manifest.launchPosters ?? []).allSatisfy { isTrustedMediaURL($0.imageURL) }
            && isTrustedMediaURL(manifest.showreel.videoURL)
            && isTrustedMediaURL(manifest.showreel.posterURL)
            && manifest.dramas.allSatisfy {
                isTrustedMediaURL($0.imageURL) && isTrustedDestinationURL($0.destinationURL)
            }
            && manifest.portfolios.allSatisfy(isTrusted)
    }

    fileprivate static func isTrusted(_ cache: PortfolioCacheEnvelope) -> Bool {
        (cache.heroImages ?? []).allSatisfy(isTrustedMediaURL)
            && (cache.launchPosters ?? []).allSatisfy { isTrustedMediaURL($0.imageURL) }
            && (cache.showreel.map {
                isTrustedMediaURL($0.videoURL) && isTrustedMediaURL($0.posterURL)
            } ?? true)
            && (cache.dramas ?? []).allSatisfy {
                isTrustedMediaURL($0.imageURL) && isTrustedDestinationURL($0.destinationURL)
            }
            && cache.portfolios.allSatisfy(isTrusted)
    }

    static func isTrustedMediaURL(_ url: URL) -> Bool {
        isSecure(url) && trustedMediaHosts.contains(url.host?.lowercased() ?? "")
    }

    static func isTrustedWebsiteURL(_ url: URL) -> Bool {
        isTrustedMediaURL(url)
    }

    private static func isTrustedDestinationURL(_ url: URL) -> Bool {
        isSecure(url) && trustedDestinationHosts.contains(url.host?.lowercased() ?? "")
    }

    private static func isTrusted(_ portfolio: Portfolio) -> Bool {
        isTrustedWebsiteURL(portfolio.websiteURL)
            && (portfolio.totalImageCount.map { $0 >= portfolio.images.count && $0 <= 300 } ?? true)
            && (portfolio.coverURL.map(isTrustedMediaURL) ?? true)
            && portfolio.images.allSatisfy {
                isTrustedMediaURL($0.url) && isTrustedMediaURL($0.fullSizeURL)
            }
    }

    private static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
    }
}

fileprivate struct PortfolioCacheEnvelope: Codable {
    let portfolios: [Portfolio]
    let heroImages: [URL]?
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent?
    let dramas: [DramaWork]?
    let updatedAt: Date
    let isPublicPreview: Bool
}

private struct WPPortfolio: Decodable {
    let id: Int
    let slug: String
    let link: String
    let title: RenderedText
}

private struct RenderedText: Decodable {
    let rendered: String
}

private struct WPMedia: Decodable {
    let id: Int
    let sourceURL: String
    let altText: String
    let mediaDetails: MediaDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case altText = "alt_text"
        case mediaDetails = "media_details"
    }
}

private struct MediaDetails: Decodable {
    let sizes: [String: MediaSize]?
}

private struct MediaSize: Decodable {
    let sourceURL: String

    enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return components.url!
    }
}

private extension Portfolio {
    static let fallback: [Portfolio] = [
        makeFallback(
            id: 6,
            title: "婚纱",
            subtitle: "在柔光里，留下誓约般的静谧",
            eyebrow: "WEDDING · PORTRAIT",
            slug: "%e5%a9%9a%e7%ba%b1",
            mediaID: 18,
            image: "https://www.shuzijun.com.cn/wp-content/uploads/2026/03/2023-12-19-024812-685x1024.jpg"
        ),
        makeFallback(
            id: 7,
            title: "新中式",
            subtitle: "古意与当代表达之间的留白",
            eyebrow: "NEW CHINESE · EDITORIAL",
            slug: "%e6%96%b0%e4%b8%ad%e5%bc%8f",
            mediaID: 33,
            image: "https://www.shuzijun.com.cn/wp-content/uploads/2026/03/1_1-683x1024.jpg"
        ),
        makeFallback(
            id: 39,
            title: "旗袍",
            subtitle: "庭院、窗影与东方美学",
            eyebrow: "QIPAO · STORY",
            slug: "qipao",
            mediaID: 40,
            image: "https://www.shuzijun.com.cn/wp-content/uploads/2026/08/01-qipao-green-garden-768x1024.jpg"
        )
    ]

    static func makeFallback(
        id: Int,
        title: String,
        subtitle: String,
        eyebrow: String,
        slug: String,
        mediaID: Int,
        image: String
    ) -> Portfolio {
        let imageURL = URL(string: image)!
        return Portfolio(
            id: id,
            title: title,
            subtitle: subtitle,
            eyebrow: eyebrow,
            slug: slug,
            websiteURL: URL(string: "https://www.shuzijun.com.cn/portfolio/\(slug)/")!,
            coverURL: imageURL,
            images: [PortfolioImage(id: mediaID, url: imageURL, fullSizeURL: imageURL, altText: title)]
        )
    }
}
