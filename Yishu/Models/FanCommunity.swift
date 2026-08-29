import Foundation

enum FanPostKind: String, Codable, CaseIterable {
    case note
    case douyin
    case xiaohongshu
    case live

    var title: String {
        switch self {
        case .note: "易姝动态"
        case .douyin: "抖音新作品"
        case .xiaohongshu: "小红书新作品"
        case .live: "直播提醒"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "sparkles"
        case .douyin: "play.rectangle.fill"
        case .xiaohongshu: "book.pages.fill"
        case .live: "dot.radiowaves.left.and.right"
        }
    }
}

struct FanFeatureFlags: Codable, Equatable {
    var reactionsEnabled: Bool
    var pollsEnabled: Bool
    var lettersEnabled: Bool
}

struct FanReaction: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let systemImage: String
    let count: Int
    let isSelected: Bool
}

struct FanPost: Identifiable, Codable, Equatable {
    let id: String
    let kind: FanPostKind
    let authorName: String
    let managerLabel: String
    let text: String
    let externalURL: URL?
    let publishedAt: Date
    let reactions: [FanReaction]
}

struct FanPollOption: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let voteCount: Int
    let isSelected: Bool
}

struct FanPoll: Identifiable, Codable, Equatable {
    let id: String
    let question: String
    let isOpen: Bool
    let publishedAt: Date
    let options: [FanPollOption]

    var totalVotes: Int { options.reduce(0) { $0 + $1.voteCount } }
}

struct FanCommunityManifest: Codable, Equatable {
    let schemaVersion: Int
    let updatedAt: Date
    let features: FanFeatureFlags
    let posts: [FanPost]
    let polls: [FanPoll]
    let lettersNotice: String
}

struct FanLetterReceipt: Codable, Equatable {
    let accepted: Bool
    let receiptID: String
    let message: String
}

struct NotificationPreferences: Codable, Equatable {
    var newWorks: Bool = true
    var live: Bool = true
}

struct FanModerationConfiguration: Codable, Equatable {
    var blockTerms: [String]
    var reviewTerms: [String]
    let isReady: Bool
}

struct FanLetterAdminItem: Identifiable, Codable, Equatable {
    let id: Int
    let receiptID: String
    let nickname: String
    let message: String
    let status: String
    let moderationBucket: String
    let submittedAt: Date
}

struct FanCommunityAdminDashboard: Codable, Equatable {
    var features: FanFeatureFlags
    var moderation: FanModerationConfiguration
    var posts: [FanPost]
    var polls: [FanPoll]
    var letters: [FanLetterAdminItem]
    let pushReady: Bool
    let activePushDevices: Int
    let sourceStatus: [String: FanSourceStatus]?
}

struct FanSourceStatus: Codable, Equatable {
    let ready: Bool?
    let initialized: Bool?
    let lastChecked: Date?
    let lastSuccess: Date?
    let lastError: String?
}

enum FanCommunityLinkPolicy {
    private static let allowedHosts: Set<String> = [
        "douyin.com",
        "www.douyin.com",
        "v.douyin.com",
        "live.douyin.com",
        "iesdouyin.com",
        "www.iesdouyin.com",
        "xiaohongshu.com",
        "www.xiaohongshu.com",
        "xhslink.com",
        "www.xhslink.com",
    ]

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "https"
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
            && allowedHosts.contains(url.host?.lowercased() ?? "")
    }
}
