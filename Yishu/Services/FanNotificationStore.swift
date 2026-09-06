import Foundation
import Combine

struct FanNotification: Decodable, Identifiable, Equatable {
    let notificationID: String
    let title: String
    let body: String
    let sensitive: Bool
    let createdAt: Date
    let expiresAt: Date
    let readAt: Date?
    var id: String { notificationID }
}

struct FanNotificationPage: Decodable {
    let notifications: [FanNotification]
    let nextCursor: String?
    let unreadCount: Int
}

struct FanNotificationResponse: Decodable {
    let notification: FanNotification
}

struct FanNotificationContext: Equatable, Hashable {
    let userID: String
    let sessionGeneration: UInt64
    let environment: AppServiceEnvironment

    init(userID: String, sessionGeneration: UInt64, environment: AppServiceEnvironment = .production) {
        self.userID = userID
        self.sessionGeneration = sessionGeneration
        self.environment = environment
    }
}

struct PendingFanNotification: Identifiable, Equatable {
    let id: String
}

#if DEBUG
// Synthetic text only. This path exists solely in Debug UI test builds and
// cannot obtain a fan session, access photos, or authorize any production API.
enum FanNotificationUITestFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-notification-inbox-ui-fixture")
    }
    static var message: FanNotification {
        FanNotification(
            notificationID: "11111111-2222-4333-8444-555555555555",
            title: "消息箱界面测试", body: "这是用于验证受保护消息页面的虚构文本。仅可接收和阅读，没有发送、回复或私聊功能。",
            sensitive: true, createdAt: Date().addingTimeInterval(-60),
            expiresAt: Date().addingTimeInterval(3600), readAt: Date().addingTimeInterval(-30)
        )
    }
}
#endif

enum FanNotificationValidation {
    static func canonicalID(_ raw: String) -> String? {
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }
        return raw
    }

    static func isValidCursor(_ raw: String) -> Bool {
        guard raw.range(of: #"^[1-9][0-9]{0,18}$"#, options: .regularExpression) != nil,
              let value = UInt64(raw), value <= UInt64(Int64.max) else { return false }
        return true
    }

    static func isValid(_ item: FanNotification) -> Bool {
        canonicalID(item.id) != nil
            && (1...60).contains(item.title.count)
            && (1...240).contains(item.body.count)
            && !item.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !item.body.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && item.expiresAt > item.createdAt
            && item.readAt.map { $0 >= item.createdAt } != false
    }

    static func isValid(_ page: FanNotificationPage) -> Bool {
        page.notifications.count <= 50
            && Set(page.notifications.map(\.id)).count == page.notifications.count
            && page.notifications.allSatisfy(isValid)
            && page.nextCursor.map(isValidCursor) != false
            && (page.nextCursor == nil || !page.notifications.isEmpty)
            && page.unreadCount >= 0
    }
}

enum FanNotificationError: LocalizedError {
    case unavailable
    case notFound
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: "暂时无法读取消息，请检查网络后重试。"
        case .notFound: "这条消息已过期或当前账号无法查看。"
        case .signInRequired: "请使用已完成资料的有效账号登录后查看消息。"
        }
    }
}

@MainActor
protocol FanNotificationAccount: AnyObject {
    var notificationContext: FanNotificationContext? { get }
    func fetchNotificationPage(cursor: String?) async throws -> FanNotificationPage
    func fetchNotification(id: String) async throws -> FanNotification
    func markNotificationRead(id: String) async throws -> FanNotification
}

/// Receive-only, volatile account-scoped state. GET never mutates read status.
/// Every network result is fenced by both the account session and the request
/// generation; a late reply cannot repopulate a signed-out or switched account.
@MainActor
final class FanNotificationStore: ObservableObject {
    @Published private(set) var notifications: [FanNotification] = []
    @Published private(set) var unreadCount = 0
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var detail: FanNotification?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detailErrorMessage: String?
    @Published private(set) var readErrorMessage: String?
    private var context: FanNotificationContext?
    private var listGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private var consumedCursors = Set<String>()
    private var acknowledgedReads: [String: Date] = [:]
    private var readingID: String?
    private var openingID: String?
    private var listWaiters: [CheckedContinuation<Void, Never>] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func updateContext(_ newContext: FanNotificationContext?) {
        guard context != newContext else { return }
        context = newContext
        listGeneration &+= 1
        detailGeneration &+= 1
        notifications = []
        unreadCount = 0
        nextCursor = nil
        consumedCursors = []
        acknowledgedReads = [:]
        readingID = nil
        openingID = nil
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        detail = nil
        isLoadingDetail = false
        detailErrorMessage = nil
        readErrorMessage = nil
        releaseListWaiters()
    }

    func refresh(using account: any FanNotificationAccount) async {
        updateContext(account.notificationContext)
        guard let expected = context, !isLoading, !isLoadingMore,
              !isLoadingDetail, detail == nil, readingID == nil else { return }
        listGeneration &+= 1
        let generation = listGeneration
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        defer {
            if listGeneration == generation { isLoading = false; releaseListWaiters() }
        }
        do {
            let page = try await account.fetchNotificationPage(cursor: nil)
            guard accepts(account, expected: expected), listGeneration == generation, !Task.isCancelled else { return }
            guard FanNotificationValidation.isValid(page) else { throw FanNotificationError.unavailable }
            let reconciledUnread = reconciledUnreadCount(in: page)
            notifications = page.notifications.filter { $0.expiresAt > now() }.map(reconcileReadState)
            unreadCount = reconciledUnread
            nextCursor = page.nextCursor
            consumedCursors = []
        } catch {
            guard accepts(account, expected: expected), listGeneration == generation, !Task.isCancelled else { return }
            _ = clearForAccessFailure(error)
            errorMessage = safeMessage(error)
        }
    }

    func loadMore(using account: any FanNotificationAccount) async {
        updateContext(account.notificationContext)
        guard let expected = context, let cursor = nextCursor,
              !isLoading, !isLoadingMore, !isLoadingDetail, detail == nil,
              !consumedCursors.contains(cursor) else { return }
        let generation = listGeneration
        isLoadingMore = true
        errorMessage = nil
        defer {
            if listGeneration == generation { isLoadingMore = false; releaseListWaiters() }
        }
        do {
            let page = try await account.fetchNotificationPage(cursor: cursor)
            guard accepts(account, expected: expected), listGeneration == generation, !Task.isCancelled else { return }
            guard FanNotificationValidation.isValid(page), page.nextCursor != cursor,
                  page.nextCursor.map({ !consumedCursors.contains($0) && (UInt64($0) ?? 0) < (UInt64(cursor) ?? 0) }) != false else {
                throw FanNotificationError.unavailable
            }
            let existingIDs = Set(notifications.map(\.id))
            let reconciledUnread = reconciledUnreadCount(in: page)
            notifications += page.notifications.filter { !existingIDs.contains($0.id) && $0.expiresAt > now() }.map(reconcileReadState)
            consumedCursors.insert(cursor)
            nextCursor = page.nextCursor
            unreadCount = reconciledUnread
        } catch {
            guard accepts(account, expected: expected), listGeneration == generation, !Task.isCancelled else { return }
            _ = clearForAccessFailure(error)
            errorMessage = safeMessage(error)
        }
    }

    func open(id: String, using account: any FanNotificationAccount) async {
        updateContext(account.notificationContext)
        // SwiftUI's task and foreground callback may ask for the same detail
        // together. Share the active read instead of racing the recipient lock.
        guard !(isLoadingDetail && openingID == id), readingID != id else { return }
        closeDetail()
        guard let expected = context, FanNotificationValidation.canonicalID(id) != nil else {
            detailErrorMessage = FanNotificationError.signInRequired.errorDescription
            return
        }
        let generation = detailGeneration
        openingID = id
        isLoadingDetail = true
        defer {
            if detailGeneration == generation { isLoadingDetail = false; openingID = nil }
        }
        if isLoading || isLoadingMore {
            await withCheckedContinuation { listWaiters.append($0) }
        }
        guard accepts(account, expected: expected), detailGeneration == generation, !Task.isCancelled else { return }
        do {
            let item = try await account.fetchNotification(id: id)
            guard accepts(account, expected: expected), detailGeneration == generation, !Task.isCancelled else { return }
            guard item.id == id, FanNotificationValidation.isValid(item) else { throw FanNotificationError.unavailable }
            guard item.expiresAt > now() else { throw FanNotificationError.notFound }
            let previousListItem = notifications.first { $0.id == item.id }
            detail = reconcileReadState(item)
            if let index = notifications.firstIndex(where: { $0.id == item.id }), let detail {
                if previousListItem?.readAt == nil && detail.readAt != nil {
                    unreadCount = max(0, unreadCount - 1)
                }
                notifications[index] = detail
            }
            // The detail has now been fetched for the current recipient. Only
            // this explicit opening action can write the idempotent read receipt.
            await markCurrentDetailRead(using: account)
        } catch {
            guard accepts(account, expected: expected), detailGeneration == generation, !Task.isCancelled else { return }
            _ = clearForAccessFailure(error)
            detail = nil
            detailErrorMessage = safeMessage(error)
        }
    }

    func markCurrentDetailRead(using account: any FanNotificationAccount) async {
        guard let expected = context, accepts(account, expected: expected),
              let item = detail, item.expiresAt > now(), item.readAt == nil, readingID == nil else { return }
        let generation = detailGeneration
        readingID = item.id
        defer { if detailGeneration == generation { readingID = nil } }
        do {
            let read = try await account.markNotificationRead(id: item.id)
            guard accepts(account, expected: expected), detailGeneration == generation,
                  detail?.id == item.id, !Task.isCancelled else { return }
            guard read.id == item.id, FanNotificationValidation.isValid(read), read.readAt != nil,
                  read.expiresAt > now() else { throw FanNotificationError.unavailable }
            // An older list GET may still be in flight. Its unread snapshot
            // must not overwrite this newer explicit read acknowledgement.
            listGeneration &+= 1
            isLoading = false
            isLoadingMore = false
            releaseListWaiters()
            if acknowledgedReads[read.id] == nil { unreadCount = max(0, unreadCount - 1) }
            detail = reconcileReadState(read)
            if let index = notifications.firstIndex(where: { $0.id == read.id }) {
                notifications[index] = read
            }
            readErrorMessage = nil
        } catch {
            guard accepts(account, expected: expected), detailGeneration == generation, !Task.isCancelled else { return }
            if clearForAccessFailure(error) {
                detailErrorMessage = safeMessage(error)
                return
            }
            if case FanNotificationError.notFound = error {
                detail = nil
                detailErrorMessage = safeMessage(error)
                return
            }
            readErrorMessage = "消息已打开，但已读状态暂未同步。可重试同步。"
        }
    }

    func closeDetail() {
        detailGeneration &+= 1
        detail = nil
        isLoadingDetail = false
        detailErrorMessage = nil
        readErrorMessage = nil
        readingID = nil
        openingID = nil
    }

    func expireDetailIfNeeded() {
        guard let detail, detail.expiresAt <= now() else { return }
        closeDetail()
        purgeExpiredMessages()
        detailErrorMessage = FanNotificationError.notFound.errorDescription
    }

    func purgeExpiredMessages() {
        let expired = notifications.filter { $0.expiresAt <= now() }
        unreadCount = max(0, unreadCount - expired.filter { $0.readAt == nil }.count)
        notifications.removeAll { $0.expiresAt <= now() }
        for item in expired { acknowledgedReads.removeValue(forKey: item.id) }
    }

    private func releaseListWaiters() {
        let pending = listWaiters
        listWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func accepts(_ account: any FanNotificationAccount, expected: FanNotificationContext) -> Bool {
        context == expected && account.notificationContext == expected
    }

    private func reconcileReadState(_ item: FanNotification) -> FanNotification {
        let readAt = item.readAt ?? acknowledgedReads[item.id]
        if let readAt { acknowledgedReads[item.id] = readAt }
        return FanNotification(
            notificationID: item.id, title: item.title, body: item.body, sensitive: item.sensitive,
            createdAt: item.createdAt, expiresAt: item.expiresAt, readAt: readAt
        )
    }

    private func reconciledUnreadCount(in page: FanNotificationPage) -> Int {
        let staleUnread = page.notifications.filter {
            $0.readAt == nil && (acknowledgedReads[$0.id] != nil || $0.expiresAt <= now())
        }.count
        return max(0, page.unreadCount - staleUnread)
    }

    private func clearForAccessFailure(_ error: Error) -> Bool {
        let denied: Bool
        switch error {
        case FanNotificationError.signInRequired, FanAccountError.sessionExpired,
             FanAccountError.accountSuspended, FanAccountError.approvalRejected:
            denied = true
        default: denied = false
        }
        if denied { updateContext(nil) }
        return denied
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? FanNotificationError { return error.errorDescription ?? "无法读取消息。" }
        if case FanAccountError.sessionExpired = error { return FanNotificationError.signInRequired.errorDescription ?? "请重新登录。" }
        return FanNotificationError.unavailable.errorDescription ?? "无法读取消息。"
    }
}
