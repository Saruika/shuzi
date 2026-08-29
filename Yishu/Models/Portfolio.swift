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

    func isActive(at date: Date = .now) -> Bool {
        isEnabled && startsAt <= date && date < endsAt
    }
}

struct AppContentManifest: Codable {
    let schemaVersion: Int
    let updatedAt: Date
    let heroImages: [URL]
    let launchPosters: [LaunchPosterContent]?
    let showreel: ShowreelContent
    let dramas: [DramaWork]
    let portfolios: [Portfolio]
}

enum ContentCatalog {
    static let appContentURL = URL(string: "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/app-content")!
    static let heroImages = [
        URL(string: "https://img.shuzijun.com.cn/images/hero-mobile-1.webp")!,
        URL(string: "https://img.shuzijun.com.cn/images/hero-mobile-2.webp")!,
        URL(string: "https://img.shuzijun.com.cn/images/hero-mobile-3.webp")!,
    ]
    static let launchPosters = [
        LaunchPosterContent(
            id: "evergreen",
            isEnabled: true,
            imageURL: heroImages[0],
            eyebrow: "YI SHU",
            title: "易姝",
            subtitle: "镜头之内，自有叙事。",
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
        videoURL: URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/showreel/hls-20260826a/master.m3u8")!,
        posterURL: URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/showreel/yishu-showreel-poster.jpg?v=20260825e")!,
        tags: ["古装", "情绪表达", "镜头表现"]
    )
    static let showreelURL = showreel.videoURL
    static let websiteURL = URL(string: "https://www.shuzijun.com.cn/")!
    static let collaborationEmailAddress = "369476120@qq.com"
    static let emailURL = URL(string: "mailto:369476120@qq.com")!
    static let collaborationEmailURL = URL(
        string: "mailto:369476120@qq.com?subject=%E6%98%93%E5%A7%9D%E5%90%88%E4%BD%9C%E9%82%80%E7%BA%A6&body=%E6%82%A8%E5%A5%BD%EF%BC%8C%E6%88%91%E6%83%B3%E5%92%A8%E8%AF%A2%E6%98%93%E5%A7%9D%E7%9A%84%E6%BC%94%E5%87%BA%E6%88%96%E6%8B%8D%E6%91%84%E5%90%88%E4%BD%9C%E3%80%82"
    )!
    static let qqMailWebURL = URL(string: "https://mail.qq.com/")!
    static let xiaohongshuURL = URL(string: "https://xhslink.com/m/API2hEV4WME")!
    static let douyinURL = URL(string: "https://v.douyin.com/8T9JGm_WtwQ/")!
    static let hongguoURL = URL(string: "https://novelquickapp.com/s/wHlfrwqog1g/")!

    static let dramas: [DramaWork] = [
        DramaWork(
            id: "jingchunye",
            title: "京春夜",
            imageURL: URL(string: "https://img.shuzijun.com.cn/images/drama-jingchunye.webp")!,
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "wangshengjiudian",
            title: "往生酒店",
            imageURL: URL(string: "https://img.shuzijun.com.cn/images/drama-wangshengjiudian.webp")!,
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "nianxiadidi",
            title: "年下弟弟俯首称臣",
            imageURL: URL(string: "https://img.shuzijun.com.cn/images/drama-nianxiadidi.webp")!,
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "xinhunye",
            title: "新婚夜，我和姐姐上错婚车嫁对郎",
            imageURL: URL(string: "https://img.shuzijun.com.cn/images/drama-xinhunye.webp")!,
            destinationURL: hongguoURL
        ),
        DramaWork(
            id: "ouyangxiu",
            title: "遇见，我的欧阳修大人",
            imageURL: URL(string: "https://img.shuzijun.com.cn/images/drama-ouyangxiu.webp")!,
            destinationURL: hongguoURL
        )
    ]
}
