import Foundation

struct Portfolio: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let subtitle: String
    let eyebrow: String
    let slug: String
    let websiteURL: URL
    let coverURL: URL?
    let images: [PortfolioImage]
    var totalImageCount: Int? = nil
    // Optional for compatibility with previously published manifests/caches.
    var isVisible: Bool? = nil

    var isVisibleToViewers: Bool { isVisible ?? true }

    var displayImageCount: Int {
        max(images.count, totalImageCount ?? images.count)
    }
}

struct PortfolioImage: Identifiable, Hashable, Codable {
    let id: Int
    let url: URL
    let fullSizeURL: URL
    let altText: String
}

struct DramaWork: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var imageURL: URL
    var destinationURL: URL
}

struct ShowreelContent: Hashable, Codable {
    var eyebrow: String
    var title: String
    var summary: String
    var durationLabel: String
    var videoURL: URL
    var posterURL: URL
    var tags: [String]
}

enum LaunchPosterDefaultCopy {
    static let eyebrow = "东方美学"
    static let title = "易姝"
    static let subtitle = "很高兴，在这里遇见你。"
}

struct LaunchPosterContent: Identifiable, Hashable, Codable {
    var id: String
    var isEnabled: Bool
    var imageURL: URL
    var eyebrow: String
    var title: String
    var subtitle: String
    var startsAt: Date
    var endsAt: Date
    var displaySeconds: Double

    static func newDraft(
        imageURL: URL,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LaunchPosterContent {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 30, to: start)
            ?? start.addingTimeInterval(30 * 86_400)
        return LaunchPosterContent(
            id: UUID().uuidString.lowercased(),
            isEnabled: true,
            imageURL: imageURL,
            eyebrow: LaunchPosterDefaultCopy.eyebrow,
            title: LaunchPosterDefaultCopy.title,
            subtitle: LaunchPosterDefaultCopy.subtitle,
            startsAt: start,
            endsAt: end,
            displaySeconds: 2.5
        )
    }

    func isActive(at date: Date = .now) -> Bool {
        isEnabled && startsAt <= date && date < endsAt
    }
}

enum AppContentAudience: String, Codable {
    case administrator
    case viewer
}

struct AppContentManifest: Codable {
    let schemaVersion: Int
    let updatedAt: Date
    let heroImages: [URL]
    let aboutPortraitURL: URL?
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent?
    let dramas: [DramaWork]
    let portfolios: [Portfolio]
    let contentAudience: AppContentAudience?

    init(schemaVersion: Int, updatedAt: Date, heroImages: [URL], aboutPortraitURL: URL?,
         launchPosters: [LaunchPosterContent]?, showreel: ShowreelContent?,
         dramas: [DramaWork], portfolios: [Portfolio], contentAudience: AppContentAudience? = nil) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.heroImages = heroImages
        self.aboutPortraitURL = aboutPortraitURL
        self.launchPosters = launchPosters
        self.showreel = showreel
        self.dramas = dramas
        self.portfolios = portfolios
        self.contentAudience = contentAudience
    }
}

/// Treats the CMS response as untrusted input even after TLS and host checks.
/// These limits mirror the publishing API and keep a damaged or compromised
/// manifest from creating unbounded SwiftUI collections or pathological text.
enum ContentManifestPolicy {
    static let currentSchemaVersion = 1
    // Version 4 removes all on-device portrait fallbacks and invalidates older
    // launch-poster metadata so an app upgrade cannot resurrect a retired image.
    static let currentCacheSchemaVersion = 4

    private static let maximumHeroCount = 5
    private static let maximumLaunchPosterCount = 12
    private static let maximumDramaCount = 50
    private static let maximumPortfolioCount = 100
    private static let maximumImagesPerPortfolio = 300
    private static let maximumTotalImageCount = maximumPortfolioCount * maximumImagesPerPortfolio
    private static let latestSupportedTimestamp: TimeInterval = 4_102_444_800 // 2100-01-01 UTC
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func isValid(_ manifest: AppContentManifest) -> Bool {
        manifest.schemaVersion == currentSchemaVersion
            && isValidUpdateDate(manifest.updatedAt)
            && isValidHeroes(manifest.heroImages)
            && isValidLaunchPosters(manifest.launchPosters ?? [])
            && (manifest.showreel.map(isValidShowreel) ?? true)
            && isValidDramas(manifest.dramas)
            && isValidPortfolios(manifest.portfolios)
    }

    static func isSupportedCacheSchemaVersion(_ version: Int?) -> Bool {
        // Access-gated builds reject every pre-gate cache generation so content
        // URLs cannot be restored before an approved account is verified.
        version == currentCacheSchemaVersion
    }

    static func isValidCache(
        schemaVersion: Int?,
        portfolios: [Portfolio],
        heroImages: [URL]?,
        launchPosters: [LaunchPosterContent]?,
        showreel: ShowreelContent?,
        dramas: [DramaWork]?,
        updatedAt: Date
    ) -> Bool {
        isSupportedCacheSchemaVersion(schemaVersion)
            && isValidUpdateDate(updatedAt)
            && isValidPortfolios(portfolios)
            && (heroImages.map(isValidHeroes) ?? true)
            && (launchPosters.map(isValidLaunchPosters) ?? true)
            && (showreel.map(isValidShowreel) ?? true)
            && (dramas.map(isValidDramas) ?? true)
    }

    private static func isValidUpdateDate(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite && timestamp >= 0 && timestamp <= latestSupportedTimestamp
    }

    private static func isValidHeroes(_ heroes: [URL]) -> Bool {
        (1...maximumHeroCount).contains(heroes.count)
            && hasUniqueElements(heroes)
    }

    private static func isValidLaunchPosters(_ posters: [LaunchPosterContent]) -> Bool {
        guard posters.count <= maximumLaunchPosterCount,
              hasUniqueElements(posters.map(\.id)) else { return false }
        return posters.allSatisfy { poster in
            isValidIdentifier(poster.id)
                && isValidText(poster.eyebrow, maximum: 120)
                && isValidText(poster.title, maximum: 160, required: true)
                && isValidText(poster.subtitle, maximum: 240)
                && poster.startsAt.timeIntervalSince1970.isFinite
                && poster.endsAt.timeIntervalSince1970.isFinite
                && poster.startsAt < poster.endsAt
                && poster.displaySeconds.isFinite
                && (1.5...5.0).contains(poster.displaySeconds)
        }
    }

    private static func isValidShowreel(_ showreel: ShowreelContent) -> Bool {
        showreel.tags.count <= 8
            && hasUniqueElements(showreel.tags)
            && isValidText(showreel.eyebrow, maximum: 120)
            && isValidText(showreel.title, maximum: 160)
            && isValidText(showreel.summary, maximum: 500)
            && isValidText(showreel.durationLabel, maximum: 20)
            && showreel.tags.allSatisfy { isValidText($0, maximum: 80, required: true) }
    }

    private static func isValidDramas(_ dramas: [DramaWork]) -> Bool {
        guard dramas.count <= maximumDramaCount,
              hasUniqueElements(dramas.map(\.id)) else { return false }
        return dramas.allSatisfy { drama in
            isValidIdentifier(drama.id)
                && isValidText(drama.title, maximum: 200, required: true)
        }
    }

    private static func isValidPortfolios(_ portfolios: [Portfolio]) -> Bool {
        guard portfolios.count <= maximumPortfolioCount,
              hasUniqueElements(portfolios.map(\.id)) else { return false }

        var loadedImageCount = 0
        for portfolio in portfolios {
            guard portfolio.id > 0,
                  isValidText(portfolio.title, maximum: 240, required: true),
                  isValidText(portfolio.subtitle, maximum: 500),
                  isValidText(portfolio.eyebrow, maximum: 160),
                  isValidText(portfolio.slug, maximum: 200, required: true),
                  portfolio.images.count <= maximumImagesPerPortfolio,
                  hasUniqueElements(portfolio.images.map(\.id)),
                  portfolio.images.allSatisfy({ image in
                      image.id > 0 && isValidText(image.altText, maximum: 500)
                  }) else { return false }

            if let totalImageCount = portfolio.totalImageCount {
                guard totalImageCount >= portfolio.images.count,
                      totalImageCount <= maximumImagesPerPortfolio else { return false }
            }
            loadedImageCount += portfolio.images.count
            guard loadedImageCount <= maximumTotalImageCount else { return false }
        }
        return true
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard isValidText(identifier, maximum: 80, required: true) else { return false }
        return identifier.unicodeScalars.allSatisfy(identifierCharacters.contains)
    }

    private static func isValidText(
        _ value: String,
        maximum: Int,
        required: Bool = false
    ) -> Bool {
        guard value.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasUniqueElements<Element: Hashable>(_ values: [Element]) -> Bool {
        Set(values).count == values.count
    }
}

enum ContentCatalog {
    /// The App consumes this versioned manifest contract rather than any CMS-specific models.
    /// The compatibility endpoint can move to a CDN without changing the client data model.
    static let publishedManifestURL = AppURL.make(
        "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-content"
    )
    static let heroImages = [
        AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-magnolia-hero-01-nas-1943-20260829.jpg"),
        AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-magnolia-hero-02-nas-1938-20260829.jpg"),
        AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-magnolia-hero-03-nas-1940-20260829.jpg"),
        AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-magnolia-hero-04-nas-1942-20260829.jpg"),
        AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/08/yishu-magnolia-hero-05-nas-1939-20260829.jpg"),
    ]
    static let aboutPortraitURL: URL? = nil
    private static let launchPosterBaseURL =
        "https://www.shuzijun.com.cn/wp-content/uploads/2026/09"

    static let launchPosters = [
        LaunchPosterContent(
            id: "hanfu-lantern-01",
            isEnabled: true,
            imageURL: AppURL.make(
                "\(launchPosterBaseURL)/yishu-launch-hanfu-lantern-01-mobile-20260902b.jpg"
            ),
            eyebrow: LaunchPosterDefaultCopy.eyebrow,
            title: LaunchPosterDefaultCopy.title,
            subtitle: LaunchPosterDefaultCopy.subtitle,
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 4_102_444_800),
            displaySeconds: 2.5
        ),
        LaunchPosterContent(
            id: "hanfu-lantern-02",
            isEnabled: true,
            imageURL: AppURL.make(
                "\(launchPosterBaseURL)/yishu-launch-hanfu-lantern-02-mobile-20260902b.jpg"
            ),
            eyebrow: LaunchPosterDefaultCopy.eyebrow,
            title: LaunchPosterDefaultCopy.title,
            subtitle: LaunchPosterDefaultCopy.subtitle,
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 4_102_444_800),
            displaySeconds: 2.5
        ),
        LaunchPosterContent(
            id: "hanfu-lantern-03",
            isEnabled: true,
            imageURL: AppURL.make(
                "\(launchPosterBaseURL)/yishu-launch-hanfu-lantern-03-mobile-20260902b.jpg"
            ),
            eyebrow: LaunchPosterDefaultCopy.eyebrow,
            title: LaunchPosterDefaultCopy.title,
            subtitle: LaunchPosterDefaultCopy.subtitle,
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 4_102_444_800),
            displaySeconds: 2.5
        )
    ]
    static let showreel = ShowreelContent(
        eyebrow: "ACTOR SHOWREEL · 2026",
        title: "21 秒演员展映",
        summary: "温柔 · 克制 · 东方韵味",
        durationLabel: "00:21",
        videoURL: AppURL.make(
            "https://www.shuzijun.com.cn/wp-content/uploads/showreel/hls-20260826a/master.m3u8"
        ),
        posterURL: AppURL.make(
            "https://www.shuzijun.com.cn/wp-content/uploads/showreel/yishu-showreel-poster.jpg?v=20260825e"
        ),
        tags: ["古装", "情绪表达", "镜头表现"]
    )
    static let showreelURL = showreel.videoURL
    static let websiteURL = AppURL.make("https://www.shuzijun.com.cn/")
    static let privacyPolicyURL = AppURL.make("https://www.shuzijun.com.cn/app-privacy/")
    static let collaborationEmailAddress = "369476120@qq.com"
    static let privacyContactEmailAddress = "support@shuzijun.com.cn"
    static let emailURL = AppURL.make("mailto:369476120@qq.com")
    static let privacyEmailURL = AppURL.make("mailto:\(privacyContactEmailAddress)")
    static let collaborationEmailURL = AppURL.make(
        "mailto:369476120@qq.com?subject=%E6%98%93%E5%A7%9D%E5%90%88%E4%BD%9C%E9%82%80%E7%BA%A6&body=%E6%82%A8%E5%A5%BD%EF%BC%8C%E6%88%91%E6%83%B3%E5%92%A8%E8%AF%A2%E6%98%93%E5%A7%9D%E7%9A%84%E6%BC%94%E5%87%BA%E6%88%96%E6%8B%8D%E6%91%84%E5%90%88%E4%BD%9C%E3%80%82"
    )
    static let qqMailWebURL = AppURL.make("https://mail.qq.com/")
    static let xiaohongshuURL = AppURL.make("https://xhslink.com/m/API2hEV4WME")
    static let douyinURL = AppURL.make("https://v.douyin.com/8T9JGm_WtwQ/")
    static let hongguoURL = AppURL.make("https://novelquickapp.com/s/qcN1w-iokyY/")

    static let dramas: [DramaWork] = [
        DramaWork(
            id: "jingchunye",
            title: "京春夜",
            imageURL: AppURL.make("https://img.shuzijun.com.cn/images/drama-jingchunye.webp"),
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "wangshengjiudian",
            title: "往生酒店",
            imageURL: AppURL.make("https://img.shuzijun.com.cn/images/drama-wangshengjiudian.webp"),
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "nianxiadidi",
            title: "年下弟弟俯首称臣",
            imageURL: AppURL.make("https://img.shuzijun.com.cn/images/drama-nianxiadidi.webp"),
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "xinhunye",
            title: "新婚夜，我和姐姐上错婚车嫁对郎",
            imageURL: AppURL.make("https://img.shuzijun.com.cn/images/drama-xinhunye.webp"),
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "ouyangxiu",
            title: "遇见，我的欧阳修大人",
            imageURL: AppURL.make("https://img.shuzijun.com.cn/images/drama-ouyangxiu.webp"),
            destinationURL: hongguoURL
        )
    ]
}
