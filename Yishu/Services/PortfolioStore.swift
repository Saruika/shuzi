import Foundation

enum ContentOrigin: Equatable {
    case bundled
    case cached
    case network
}

/// Only fresh, authenticated metadata may introduce a launch poster. A slow
/// connection skips the poster instead of showing retired/cached copy. The
/// cancelled request cannot later replace an already presented poster.
enum LaunchPosterFreshContentLoader {
    static func load(
        timeout: Duration = .seconds(4),
        fetch: @escaping @MainActor () async throws -> AppContentManifest
    ) async throws -> AppContentManifest {
        try await withThrowingTaskGroup(of: AppContentManifest.self) { group in
            group.addTask { try await fetch() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let manifest = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return manifest
        }
    }
}

/// Keeps the About page useful when an older or partially configured content
/// manifest does not yet provide a dedicated portrait. Every candidate remains
/// a remote URL, so this fallback does not reintroduce protected photo assets
/// into the App bundle or persistent image storage.
enum AboutPortraitSelectionPolicy {
    static func select(
        configuredURL: URL?,
        heroImages: [URL],
        portfolios: [Portfolio]
    ) -> URL? {
        configuredURL
            ?? heroImages.first
            ?? portfolios.lazy.compactMap(\.coverURL).first
    }
}

/// Chooses one active launch poster per process launch. The order is derived
/// only from server-owned fields, so it remains deterministic across devices;
/// the persisted previous identifier prevents consecutive repetition without
/// persisting any protected image data.
enum LaunchPosterSelectionPolicy {
    static func activeCandidates(
        in posters: [LaunchPosterContent],
        at date: Date = .now
    ) -> [LaunchPosterContent] {
        posters
            .filter { $0.isActive(at: date) }
            .sorted {
                if $0.startsAt != $1.startsAt { return $0.startsAt < $1.startsAt }
                return $0.id < $1.id
            }
    }

    static func select(
        from posters: [LaunchPosterContent],
        at date: Date = .now,
        previousID: String?
    ) -> LaunchPosterContent? {
        let candidates = activeCandidates(in: posters, at: date)
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1,
              let previousID,
              let previousIndex = candidates.firstIndex(where: { $0.id == previousID }) else {
            return candidates[0]
        }
        return candidates[(previousIndex + 1) % candidates.count]
    }
}

@MainActor
final class PortfolioStore: ObservableObject {
    nonisolated private static let cacheQueue = DispatchQueue(
        label: "cn.com.shuzijun.yishu.content-metadata", qos: .utility
    )
    nonisolated private static let cachedManifestPreviewImageCount = 3
    nonisolated private static let lastLaunchPosterIDKey = "cn.com.shuzijun.yishu.last-launch-poster-id"
    @Published private(set) var portfolios: [Portfolio] = Portfolio.fallback
    /// Only the authenticated content editor consumes this collection. Hidden
    /// albums must never enter browse, search, favourites or the disk snapshot.
    @Published private(set) var managedPortfolios: [Portfolio] = []
    @Published private(set) var heroImages: [URL] = ContentCatalog.heroImages
    /// The value explicitly published by an administrator. Keep it separate
    /// from the effective display fallback so editing an unrelated field never
    /// turns a temporary hero fallback into permanent About-page content.
    @Published private(set) var configuredAboutPortraitURL: URL? = ContentCatalog.aboutPortraitURL
    @Published private(set) var aboutPortraitURL: URL? = AboutPortraitSelectionPolicy.select(
        configuredURL: ContentCatalog.aboutPortraitURL,
        heroImages: ContentCatalog.heroImages,
        portfolios: Portfolio.fallback
    )
    @Published private(set) var launchPosters: [LaunchPosterContent] = ContentCatalog.launchPosters
    @Published private(set) var showreel: ShowreelContent? = ContentCatalog.showreel
    @Published private(set) var dramas: [DramaWork] = ContentCatalog.dramas
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var contentOrigin: ContentOrigin = .bundled
    private var contentRefreshID: UUID?
    private var cacheRestoreGeneration = UUID()
    let serviceEnvironment: AppServiceEnvironment
    private var isRetired = false

    init(environment: AppServiceEnvironment = .production) {
        serviceEnvironment = environment
        resetToInitialContent()
    }

    private func resetToInitialContent() {
        managedPortfolios = []
        let usesProductionCatalog = serviceEnvironment == .production
        portfolios = usesProductionCatalog ? Portfolio.fallback : []
        heroImages = usesProductionCatalog ? ContentCatalog.heroImages : []
        configuredAboutPortraitURL = usesProductionCatalog ? ContentCatalog.aboutPortraitURL : nil
        aboutPortraitURL = AboutPortraitSelectionPolicy.select(
            configuredURL: configuredAboutPortraitURL,
            heroImages: heroImages,
            portfolios: portfolios
        )
        launchPosters = usesProductionCatalog ? ContentCatalog.launchPosters : []
        showreel = usesProductionCatalog ? ContentCatalog.showreel : nil
        dramas = usesProductionCatalog ? ContentCatalog.dramas : []
    }

    @discardableResult
    func beginContentRefresh() -> UUID {
        let refreshID = UUID()
        guard !isRetired else { return refreshID }
        contentRefreshID = refreshID
        isRefreshing = true
        statusMessage = nil
        return refreshID
    }

    @discardableResult
    func completeContentRefresh(_ refreshID: UUID, with manifest: AppContentManifest) -> Bool {
        guard !isRetired, contentRefreshID == refreshID else { return false }
        guard ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment) else {
            failContentRefresh(refreshID)
            return false
        }
        contentRefreshID = nil
        isRefreshing = false
        applyPublishedManifest(manifest)
        AppDiagnostics.shared.recordCatalogRefresh(
            succeeded: true,
            portfolioCount: manifest.portfolios.count,
            imageCount: manifest.portfolios.reduce(0) { $0 + $1.images.count }
        )
        return true
    }

    func failContentRefresh(_ refreshID: UUID) {
        guard contentRefreshID == refreshID else { return }
        contentRefreshID = nil
        isRefreshing = false
        statusMessage = contentOrigin == .bundled
            ? "暂时无法连接内容服务，请稍后下拉重试"
            : "本次同步失败，当前继续显示上次已验证的内容"
        AppDiagnostics.shared.recordCatalogRefresh(succeeded: false)
    }

    func cancelContentRefresh(_ refreshID: UUID) {
        guard contentRefreshID == refreshID else { return }
        contentRefreshID = nil
        isRefreshing = false
    }

    /// Disk reads and JSON decoding stay off the main actor. The subsequent
    /// authenticated refresh replaces this snapshot with the latest approved content.
    func restoreCachedContent(allowVideo: Bool) async {
        guard !isRetired, contentOrigin == .bundled else { return }
        let generation = cacheRestoreGeneration
        let environment = serviceEnvironment
        let cache = await withCheckedContinuation { continuation in
            Self.cacheQueue.async { continuation.resume(returning: Self.loadCache(environment: environment)) }
        }
        guard !isRetired, !Task.isCancelled, generation == cacheRestoreGeneration,
              contentOrigin == .bundled,
              let cache else { return }
        portfolios = cache.portfolios.filter(\.isVisibleToViewers)
        heroImages = cache.heroImages ?? (serviceEnvironment == .production ? ContentCatalog.heroImages : [])
        configuredAboutPortraitURL = cache.aboutPortraitURL ?? (serviceEnvironment == .production ? ContentCatalog.aboutPortraitURL : nil)
        aboutPortraitURL = AboutPortraitSelectionPolicy.select(
            configuredURL: configuredAboutPortraitURL,
            heroImages: heroImages,
            portfolios: portfolios
        )
        launchPosters = cache.launchPosters ?? []
        showreel = allowVideo ? cache.showreel : nil
        dramas = allowVideo ? (cache.dramas ?? []) : []
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

    func selectLaunchPosterForColdLaunch(
        at date: Date = .now,
        defaults: UserDefaults = .standard,
        allowsBundledPreview: Bool = false
    ) -> LaunchPosterContent? {
        guard !isRetired, contentOrigin == .network || allowsBundledPreview else { return nil }
        let selected = LaunchPosterSelectionPolicy.select(
            from: launchPosters,
            at: date,
            previousID: defaults.string(forKey: serviceEnvironment.storageKey(Self.lastLaunchPosterIDKey))
        )
        if let selected {
            defaults.set(selected.id, forKey: serviceEnvironment.storageKey(Self.lastLaunchPosterIDKey))
        }
        return selected
    }

    func applyPublishedManifest(_ manifest: AppContentManifest) {
        guard !isRetired, manifest.schemaVersion == 1,
              ContentSecurityPolicy.isTrusted(manifest, environment: serviceEnvironment) else { return }
        cacheRestoreGeneration = UUID()
        managedPortfolios = manifest.contentAudience == .administrator ? manifest.portfolios : []
        portfolios = manifest.portfolios.filter(\.isVisibleToViewers)
        heroImages = manifest.heroImages
        configuredAboutPortraitURL = manifest.aboutPortraitURL
        aboutPortraitURL = AboutPortraitSelectionPolicy.select(
            configuredURL: configuredAboutPortraitURL,
            heroImages: manifest.heroImages,
            portfolios: portfolios
        )
        // Missing/empty managed posters must never revive bundled or retired copy.
        launchPosters = manifest.launchPosters ?? []
        showreel = manifest.showreel
        dramas = manifest.dramas
        lastUpdated = manifest.updatedAt
        contentOrigin = .network
        statusMessage = nil
        Self.persistCacheInBackground(
            environment: serviceEnvironment,
            portfolios: portfolios,
            heroImages: manifest.heroImages,
            aboutPortraitURL: configuredAboutPortraitURL,
            launchPosters: launchPosters,
            showreel: manifest.showreel,
            dramas: manifest.dramas,
            updatedAt: manifest.updatedAt
        )
    }

    /// Permission changes are authoritative before the replacement network
    /// response arrives. This method only removes content; granting a permission
    /// still requires a fresh, server-authorized manifest.
    func enforcePermissionScope(canViewFullGallery: Bool, canViewVideo: Bool) {
        guard !isRetired else { return }
        var didReduceScope = false
        if !canViewFullGallery {
            portfolios = Self.permissionScopedPreviewPortfolios(from: portfolios)
            didReduceScope = true
        }
        if !canViewVideo {
            showreel = nil
            dramas = []
            didReduceScope = true
        }

        guard didReduceScope, let lastUpdated else { return }
        Self.persistCacheInBackground(
            environment: serviceEnvironment,
            portfolios: portfolios,
            heroImages: heroImages,
            aboutPortraitURL: configuredAboutPortraitURL,
            launchPosters: launchPosters,
            showreel: showreel,
            dramas: dramas,
            updatedAt: lastUpdated
        )
    }

    func discardProtectedContent() {
        cacheRestoreGeneration = UUID()
        contentRefreshID = nil
        isRefreshing = false
        resetToInitialContent()
        lastUpdated = nil
        statusMessage = nil
        contentOrigin = .bundled
        Self.removeCacheInBackground(environment: serviceEnvironment)
    }

    func retireForEnvironmentSwitch() {
        guard !isRetired else { return }
        isRetired = true
        discardProtectedContent()
    }

#if DEBUG
    /// Gives layout tests a deterministic multi-page album without changing
    /// release content or reaching the live publishing service.
    func configureMultiImageGalleryForVisualTestingIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(
            "-use-multi-image-gallery-for-visual-testing"
        ), let firstPortfolio = portfolios.first else { return }

        let visualTestImages = Portfolio.fallback.compactMap(\.images.first)
        guard visualTestImages.count >= 3 else { return }

        portfolios[0] = Portfolio(
            id: firstPortfolio.id,
            title: firstPortfolio.title,
            subtitle: firstPortfolio.subtitle,
            eyebrow: firstPortfolio.eyebrow,
            slug: firstPortfolio.slug,
            websiteURL: firstPortfolio.websiteURL,
            coverURL: visualTestImages[0].url,
            images: visualTestImages,
            totalImageCount: visualTestImages.count
        )
    }
#endif

    private static func removeCacheInBackground(environment: AppServiceEnvironment) {
        Self.cacheQueue.async {
            guard let url = Self.cacheFileURL(createDirectory: false, environment: environment) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func loadCache(environment: AppServiceEnvironment) -> PortfolioCacheEnvelope? {
        guard let url = cacheFileURL(createDirectory: false, environment: environment),
              let data = try? Data(contentsOf: url),
              data.count <= 5 * 1024 * 1024,
              let cache = try? JSONDecoder().decode(PortfolioCacheEnvelope.self, from: data),
              cache.isAuthorizedPreview,
              ContentSecurityPolicy.isTrusted(cache, environment: environment) else { return nil }
        return cache
    }

    private static func persistCacheInBackground(
        environment: AppServiceEnvironment,
        portfolios: [Portfolio],
        heroImages: [URL],
        aboutPortraitURL: URL?,
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent?,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        Self.cacheQueue.async {
            Self.persistCache(
                environment: environment,
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
        environment: AppServiceEnvironment,
        portfolios: [Portfolio],
        heroImages: [URL],
        aboutPortraitURL: URL?,
        launchPosters: [LaunchPosterContent],
        showreel: ShowreelContent?,
        dramas: [DramaWork],
        updatedAt: Date
    ) {
        // Persist only a small authorized metadata snapshot (IDs, text and
        // URLs). No image bytes are encoded or written to disk; the complete
        // live gallery remains an in-memory response.
        let cachedPortfolios = permissionScopedPreviewPortfolios(from: portfolios)
        guard let url = cacheFileURL(createDirectory: true, environment: environment),
              let data = try? JSONEncoder().encode(
                PortfolioCacheEnvelope(
                    cacheSchemaVersion: ContentManifestPolicy.currentCacheSchemaVersion,
                    portfolios: cachedPortfolios,
                    heroImages: heroImages,
                    aboutPortraitURL: aboutPortraitURL,
                    launchPosters: launchPosters,
                    showreel: showreel,
                    dramas: dramas,
                    updatedAt: updatedAt,
                    isAuthorizedPreview: true
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

    nonisolated private static func permissionScopedPreviewPortfolios(
        from portfolios: [Portfolio]
    ) -> [Portfolio] {
        portfolios.filter(\.isVisibleToViewers).map { portfolio in
            let preview = Array(portfolio.images.prefix(cachedManifestPreviewImageCount))
            return Portfolio(
                id: portfolio.id,
                title: portfolio.title,
                subtitle: portfolio.subtitle,
                eyebrow: portfolio.eyebrow,
                slug: portfolio.slug,
                websiteURL: portfolio.websiteURL,
                coverURL: preview.first?.url ?? portfolio.coverURL,
                images: preview,
                totalImageCount: portfolio.displayImageCount,
                isVisible: portfolio.isVisible
            )
        }
    }

    nonisolated private static func cacheFileURL(createDirectory: Bool, environment: AppServiceEnvironment) -> URL? {
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
        return directory.appending(path: environment.storageKey("portfolio-cache.json"))
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
        isTrusted(manifest, environment: .production)
    }

    static func isTrusted(_ manifest: AppContentManifest, environment: AppServiceEnvironment) -> Bool {
        let isTrustedMediaURL: (URL) -> Bool = { Self.isTrustedMediaURL($0, environment: environment) }
        return ContentManifestPolicy.isValid(manifest)
            && manifest.heroImages.allSatisfy(isTrustedMediaURL)
            && (manifest.aboutPortraitURL.map(isTrustedMediaURL) ?? true)
            && (manifest.launchPosters ?? []).allSatisfy { isTrustedMediaURL($0.imageURL) }
            && (manifest.showreel.map {
                isTrustedMediaURL($0.videoURL) && isTrustedMediaURL($0.posterURL)
            } ?? true)
            && manifest.dramas.allSatisfy {
                isTrustedMediaURL($0.imageURL) && isTrustedDestinationURL($0.destinationURL)
            }
            && manifest.portfolios.allSatisfy { isTrusted($0, environment: environment) }
    }

    fileprivate static func isTrusted(_ cache: PortfolioCacheEnvelope, environment: AppServiceEnvironment) -> Bool {
        let isTrustedMediaURL: (URL) -> Bool = { Self.isTrustedMediaURL($0, environment: environment) }
        return ContentManifestPolicy.isValidCache(
            schemaVersion: cache.cacheSchemaVersion,
            portfolios: cache.portfolios,
            heroImages: cache.heroImages,
            launchPosters: cache.launchPosters,
            showreel: cache.showreel,
            dramas: cache.dramas,
            updatedAt: cache.updatedAt
        )
            && (cache.heroImages ?? []).allSatisfy(isTrustedMediaURL)
            && (cache.aboutPortraitURL.map(isTrustedMediaURL) ?? true)
            && (cache.launchPosters ?? []).allSatisfy { isTrustedMediaURL($0.imageURL) }
            && (cache.showreel.map {
                isTrustedMediaURL($0.videoURL) && isTrustedMediaURL($0.posterURL)
            } ?? true)
            && (cache.dramas ?? []).allSatisfy {
                isTrustedMediaURL($0.imageURL) && isTrustedDestinationURL($0.destinationURL)
            }
            && cache.portfolios.allSatisfy { isTrusted($0, environment: environment) }
    }

    static func isTrustedMediaURL(_ url: URL) -> Bool {
        isTrustedMediaURL(url, environment: .production)
    }

    static func isTrustedMediaURL(_ url: URL, environment: AppServiceEnvironment) -> Bool {
        let hosts = environment == .production ? trustedMediaHosts : [environment.mediaHost]
        return isSecure(url)
            && url.absoluteString.utf8.count <= 2_048
            && hosts.contains(url.host?.lowercased() ?? "")
    }

    static func matchesRequestedMediaURL(_ responseURL: URL?, requestedURL: URL) -> Bool {
        matchesRequestedMediaURL(responseURL, requestedURL: requestedURL, environment: .production)
    }

    static func matchesRequestedMediaURL(_ responseURL: URL?, requestedURL: URL, environment: AppServiceEnvironment) -> Bool {
        guard let responseURL,
              isTrustedMediaURL(requestedURL, environment: environment),
              isTrustedMediaURL(responseURL, environment: environment) else { return false }
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
        isSecure(url)
            && url.absoluteString.utf8.count <= 2_048
            && trustedDestinationHosts.contains(url.host?.lowercased() ?? "")
    }

    private static func isTrusted(_ portfolio: Portfolio, environment: AppServiceEnvironment) -> Bool {
        let isTrustedMediaURL: (URL) -> Bool = { Self.isTrustedMediaURL($0, environment: environment) }
        return isTrustedMediaURL(portfolio.websiteURL)
            && portfolio.websiteURL.path.hasPrefix("/portfolio/")
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
    let cacheSchemaVersion: Int?
    let portfolios: [Portfolio]
    let heroImages: [URL]?
    let aboutPortraitURL: URL?
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent?
    let dramas: [DramaWork]?
    let updatedAt: Date
    let isAuthorizedPreview: Bool
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
        let imageURL = AppURL.make(image)
        return Portfolio(
            id: id,
            title: title,
            subtitle: subtitle,
            eyebrow: eyebrow,
            slug: slug,
            websiteURL: AppURL.make("https://www.shuzijun.com.cn/portfolio/\(slug)/"),
            coverURL: imageURL,
            images: [PortfolioImage(id: mediaID, url: imageURL, fullSizeURL: imageURL, altText: title)]
        )
    }
}
