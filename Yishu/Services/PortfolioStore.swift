import Foundation

enum ContentOrigin: Equatable {
    case bundled
    case cached
    case network
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

    private let baseURL = URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2")!
    private var prefetchTask: Task<Void, Never>?

    init() {
        if let cache = Self.loadCache(), !cache.portfolios.isEmpty {
            portfolios = cache.portfolios
            heroImages = cache.heroImages ?? ContentCatalog.heroImages
            launchPosters = cache.launchPosters ?? ContentCatalog.launchPosters
            showreel = cache.showreel ?? ContentCatalog.showreel
            dramas = cache.dramas ?? ContentCatalog.dramas
            lastUpdated = cache.updatedAt
            contentOrigin = .cached
        }
    }

    var syncStatus: String {
        if isRefreshing { return "正在同步" }
        switch contentOrigin {
        case .network:
            return "内容已同步"
        case .cached:
            return "上次同步内容"
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
        guard manifest.schemaVersion == 1, !manifest.portfolios.isEmpty else { return }
        portfolios = manifest.portfolios
        heroImages = manifest.heroImages
        launchPosters = manifest.launchPosters ?? launchPosters
        showreel = manifest.showreel
        dramas = manifest.dramas
        lastUpdated = manifest.updatedAt
        contentOrigin = .network
        statusMessage = nil
        Self.persistCache(
            portfolios: manifest.portfolios,
            heroImages: manifest.heroImages,
            launchPosters: manifest.launchPosters ?? launchPosters,
            showreel: manifest.showreel,
            dramas: manifest.dramas,
            updatedAt: manifest.updatedAt
        )
        prefetchImages(
            in: manifest.portfolios,
            dramas: manifest.dramas,
            posterURL: manifest.showreel.posterURL,
            heroImages: manifest.heroImages,
            launchPosters: manifest.launchPosters ?? launchPosters
        )
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let manifest = try await fetchContentManifest()
            guard manifest.schemaVersion == 1, !manifest.portfolios.isEmpty else {
                throw URLError(.zeroByteResource)
            }
            portfolios = manifest.portfolios
            heroImages = manifest.heroImages
            launchPosters = manifest.launchPosters ?? launchPosters
            showreel = manifest.showreel
            dramas = manifest.dramas
            lastUpdated = manifest.updatedAt
            contentOrigin = .network
            statusMessage = nil
            Self.persistCache(
                portfolios: manifest.portfolios,
                heroImages: manifest.heroImages,
                launchPosters: manifest.launchPosters ?? launchPosters,
                showreel: manifest.showreel,
                dramas: manifest.dramas,
                updatedAt: manifest.updatedAt
            )
            prefetchImages(
                in: manifest.portfolios,
                dramas: manifest.dramas,
                posterURL: manifest.showreel.posterURL,
                heroImages: manifest.heroImages,
                launchPosters: manifest.launchPosters ?? launchPosters
            )
        } catch {
            do {
                let remotePortfolios = try await fetchPortfolios()
                guard !remotePortfolios.isEmpty else { throw URLError(.zeroByteResource) }
                portfolios = remotePortfolios
                lastUpdated = Date()
                contentOrigin = .network
                statusMessage = "内容接口升级中，照片已同步"
                Self.persistCache(
                    portfolios: remotePortfolios,
                    heroImages: heroImages,
                    launchPosters: launchPosters,
                    showreel: showreel,
                    dramas: dramas,
                    updatedAt: lastUpdated ?? Date()
                )
                prefetchImages(
                    in: remotePortfolios,
                    dramas: dramas,
                    posterURL: showreel.posterURL,
                    heroImages: heroImages,
                    launchPosters: launchPosters
                )
            } catch {
                statusMessage = contentOrigin == .bundled
                    ? "网络不可用，当前显示离线基础内容"
                    : "网络不可用，继续显示上次同步内容"
            }
        }
    }

    private func prefetchImages(
        in portfolios: [Portfolio],
        dramas: [DramaWork],
        posterURL: URL,
        heroImages: [URL],
        launchPosters: [LaunchPosterContent]
    ) {
        let priorityURLs = Self.uniqueURLs(
            heroImages + launchPosters.map(\.imageURL) + [posterURL]
        )
        let prioritySet = Set(priorityURLs)
        let remainingURLs = Self.uniqueURLs(
            portfolios.flatMap { portfolio in
                portfolio.images.map(\.url) + [portfolio.coverURL].compactMap { $0 }
            } + dramas.map(\.imageURL)
        ).filter { !prioritySet.contains($0) }

        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            // The first carousel transition occurs after five seconds. Fetch
            // every hero concurrently so a cold launch never turns into a
            // placeholder while the next slide is arriving.
            await withTaskGroup(of: Void.self) { group in
                for url in priorityURLs {
                    group.addTask {
                        await Self.prefetch(url)
                    }
                }
            }

            for url in remainingURLs {
                guard !Task.isCancelled else { return }
                await Self.prefetch(url)
            }
        }
    }

    nonisolated private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    nonisolated private static func prefetch(_ url: URL) async {
        guard !Task.isCancelled else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        guard URLCache.shared.cachedResponse(for: request) == nil else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func loadCache() -> PortfolioCacheEnvelope? {
        guard let url = cacheFileURL(createDirectory: false),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PortfolioCacheEnvelope.self, from: data)
    }

    private static func persistCache(
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
                    updatedAt: updatedAt
                )
              ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func cacheFileURL(createDirectory: Bool) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let directory = applicationSupport.appending(path: "Yishu", directoryHint: .isDirectory)
        if createDirectory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
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
                guard let full = URL(string: item.sourceURL) else { return nil }
                let preferred = item.mediaDetails?.sizes?["large"]?.sourceURL
                    ?? item.mediaDetails?.sizes?["medium_large"]?.sourceURL
                    ?? item.sourceURL
                guard let display = URL(string: preferred) else { return nil }
                return PortfolioImage(
                    id: item.id,
                    url: display,
                    fullSizeURL: full,
                    altText: item.altText.isEmpty ? post.title.rendered : item.altText
                )
            }

            guard let pageURL = URL(string: post.link) else { continue }
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
            return ("旗袍", "庭院、窗影与东方女性的克制", "QIPAO · STORY")
        }
        return (rawTitle, "易姝影像作品", "PORTFOLIO")
    }
}

private struct PortfolioCacheEnvelope: Codable {
    let portfolios: [Portfolio]
    let heroImages: [URL]?
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent?
    let dramas: [DramaWork]?
    let updatedAt: Date
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
            subtitle: "庭院、窗影与东方女性的克制",
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
