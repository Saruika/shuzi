import Foundation

enum ContentOrigin: Equatable {
    case bundled
    case cached
    case network
}

@MainActor
final class PortfolioStore: ObservableObject {
    nonisolated private static let offlinePreviewImageCount = 3
    @Published private(set) var portfolios: [Portfolio] = Portfolio.fallback
    @Published private(set) var heroImages: [URL] = ContentCatalog.heroImages
    @Published private(set) var aboutPortraitURL: URL? = ContentCatalog.aboutPortraitURL
    @Published private(set) var launchPosters: [LaunchPosterContent] = ContentCatalog.launchPosters
    @Published private(set) var showreel: ShowreelContent = ContentCatalog.showreel
    @Published private(set) var dramas: [DramaWork] = ContentCatalog.dramas
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var contentOrigin: ContentOrigin = .bundled
    private let contentSession: URLSession

    init() {
        contentSession = SecureURLSessionFactory.make(
            requestTimeout: 20,
            resourceTimeout: 30
        )
    }

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
        aboutPortraitURL = cache.aboutPortraitURL ?? ContentCatalog.aboutPortraitURL
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
        aboutPortraitURL = manifest.aboutPortraitURL
        launchPosters = manifest.launchPosters ?? launchPosters
        showreel = manifest.showreel
        dramas = manifest.dramas
        lastUpdated = manifest.updatedAt
        contentOrigin = .network
        statusMessage = nil
        Self.persistCacheInBackground(
            portfolios: manifest.portfolios,
            heroImages: manifest.heroImages,
            aboutPortraitURL: manifest.aboutPortraitURL,
            launchPosters: manifest.launchPosters ?? launchPosters,
            showreel: manifest.showreel,
            dramas: manifest.dramas,
            updatedAt: manifest.updatedAt
        )
    }

    /// Fetch the versioned manifest before freezing the launch-poster snapshot.
    /// A short timeout keeps cold starts responsive; cached content remains the
    /// fallback when the device is offline.
    func refreshLaunchContent() async -> Bool {
        do {
            let manifest = try await fetchContentManifest(timeoutInterval: 3)
            guard manifest.schemaVersion == 1,
                  !manifest.portfolios.isEmpty,
                  ContentSecurityPolicy.isTrusted(manifest) else { return false }
            applyPublishedManifest(manifest)
            return true
        } catch {
            return false
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let manifest = try await fetchContentManifest(maxAttempts: 2)
            guard manifest.schemaVersion == 1,
                  !manifest.portfolios.isEmpty,
                  ContentSecurityPolicy.isTrusted(manifest) else {
                throw URLError(.zeroByteResource)
            }
            portfolios = manifest.portfolios
            heroImages = manifest.heroImages
            aboutPortraitURL = manifest.aboutPortraitURL
            launchPosters = manifest.launchPosters ?? launchPosters
            showreel = manifest.showreel
            dramas = manifest.dramas
            lastUpdated = manifest.updatedAt
            contentOrigin = .network
            statusMessage = nil
            Self.persistCacheInBackground(
                portfolios: manifest.portfolios,
                heroImages: manifest.heroImages,
                aboutPortraitURL: manifest.aboutPortraitURL,
                launchPosters: manifest.launchPosters ?? launchPosters,
                showreel: manifest.showreel,
                dramas: manifest.dramas,
                updatedAt: manifest.updatedAt
            )
        } catch {
            statusMessage = contentOrigin == .bundled
                ? "网络不可用，当前显示离线基础内容"
                : "网络不可用，继续显示上次同步内容"
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
        aboutPortraitURL: URL?,
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        Task.detached(priority: .utility) {
            Self.persistCache(
                portfolios: portfolios,
                heroImages: heroImages,
                aboutPortraitURL: aboutPortraitURL,
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
        aboutPortraitURL: URL?,
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        // Keep only a small offline preview on disk. The complete live gallery
        // remains an in-memory response and is refreshed whenever the App opens.
        let cachedPortfolios = portfolios.map { portfolio in
            let preview = Array(portfolio.images.prefix(offlinePreviewImageCount))
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
        guard let url = cacheFileURL(createDirectory: true),
              let data = try? JSONEncoder().encode(
                PortfolioCacheEnvelope(
                    portfolios: cachedPortfolios,
                    heroImages: heroImages,
                    aboutPortraitURL: aboutPortraitURL,
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

    private func fetchContentManifest(
        timeoutInterval: TimeInterval = 20,
        maxAttempts: Int = 1
    ) async throws -> AppContentManifest {
        var latestError: Error = URLError(.unknown)

        for attempt in 0..<max(1, maxAttempts) {
            do {
                return try await requestContentManifest(timeoutInterval: timeoutInterval)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestError = error
                guard attempt + 1 < maxAttempts, Self.isRetryableNetworkError(error) else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw latestError
    }

    private func requestContentManifest(timeoutInterval: TimeInterval) async throws -> AppContentManifest {
        var request = URLRequest(url: ContentCatalog.publishedManifestURL)
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Yishu-iOS/2.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await contentSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                http.url,
                expected: ContentCatalog.publishedManifestURL
              ) else {
            throw URLError(.secureConnectionFailed)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 5 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        guard AppNetworkSecurityPolicy.isJSONMIMEType(http.value(forHTTPHeaderField: "Content-Type")) else {
            throw URLError(.cannotDecodeContentData)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AppContentManifest.self, from: data)
        guard ContentSecurityPolicy.isTrusted(manifest) else { throw URLError(.secureConnectionFailed) }
        return manifest
    }

    nonisolated private static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable,
            .dataNotAllowed,
        ].contains(urlError.code)
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
            && (manifest.aboutPortraitURL.map(isTrustedMediaURL) ?? true)
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
            && (cache.aboutPortraitURL.map(isTrustedMediaURL) ?? true)
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

    static func matchesRequestedMediaURL(_ responseURL: URL?, requestedURL: URL) -> Bool {
        guard let responseURL,
              isTrustedMediaURL(requestedURL),
              isTrustedMediaURL(responseURL) else { return false }
        return responseURL.scheme?.lowercased() == requestedURL.scheme?.lowercased()
            && responseURL.host?.lowercased() == requestedURL.host?.lowercased()
            && (responseURL.port ?? 443) == (requestedURL.port ?? 443)
            && responseURL.path == requestedURL.path
            && responseURL.query == requestedURL.query
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
            && url.fragment == nil
    }
}

fileprivate struct PortfolioCacheEnvelope: Codable {
    let portfolios: [Portfolio]
    let heroImages: [URL]?
    let aboutPortraitURL: URL?
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent?
    let dramas: [DramaWork]?
    let updatedAt: Date
    let isPublicPreview: Bool
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
