import XCTest
import SwiftUI
import UserNotifications
@testable import Yishu

@MainActor
private final class InboxTestAccount: FanNotificationAccount {
    var notificationContext: FanNotificationContext? = .init(userID: "account-a", sessionGeneration: 1)
    var pages: [FanNotificationPage] = []
    var message: FanNotification?
    var pageError: Error?
    var detailError: Error?
    var readError: Error?
    var pausePage = false
    var pauseDetail = false
    var pauseRead = false
    var requestStarted: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []

    func fetchNotificationPage(cursor: String?) async throws -> FanNotificationPage {
        calls.append("list:\(cursor ?? "first")")
        if let pageError { throw pageError }
        let response = pages.removeFirst()
        if pausePage { pausePage = false; await pause() }
        return response
    }
    func fetchNotification(id: String) async throws -> FanNotification {
        calls.append("get:\(id)")
        if let detailError { throw detailError }
        let response = try XCTUnwrap(message)
        if pauseDetail { pauseDetail = false; await pause() }
        return response
    }
    func markNotificationRead(id: String) async throws -> FanNotification {
        calls.append("read:\(id)")
        if let readError { throw readError }
        let item = try XCTUnwrap(message)
        let response = FanNotification(
            notificationID: item.id, title: item.title, body: item.body, sensitive: item.sensitive,
            createdAt: item.createdAt, expiresAt: item.expiresAt,
            readAt: item.readAt ?? item.createdAt.addingTimeInterval(30)
        )
        if pauseRead { pauseRead = false; await pause() }
        return response
    }
    private func pause() async {
        await withCheckedContinuation { continuation = $0; requestStarted?() }
    }
    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
final class FanNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ number: Int = 1, read: Bool = false, expired: Bool = false) -> FanNotification {
        FanNotification(
            notificationID: String(format: "11111111-2222-4333-8444-%012d", number),
            title: "管理员消息 \(number)", body: "这是一条只有收件人才能查看的消息。", sensitive: true,
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(expired ? -1 : 3600),
            readAt: read ? now.addingTimeInterval(-20) : nil
        )
    }
    private func page(_ items: [FanNotification], cursor: String? = nil, unread: Int? = nil) -> FanNotificationPage {
        FanNotificationPage(notifications: items, nextCursor: cursor, unreadCount: unread ?? items.filter { $0.readAt == nil }.count)
    }
    private func store() -> FanNotificationStore { FanNotificationStore(now: { self.now }) }

    func testInboxValidationRejectsUntrustedIDsAndPaginationTokens() {
        XCTAssertEqual(FanNotificationValidation.canonicalID(message().id), message().id)
        for invalid in ["https://example.com", "../account", "not-an-id", message().id.uppercased().replacingOccurrences(of: "11111111", with: "AAAAAAAA")] {
            XCTAssertNil(FanNotificationValidation.canonicalID(invalid))
        }
        for cursor in ["1", "9223372036854775807"] { XCTAssertTrue(FanNotificationValidation.isValidCursor(cursor)) }
        for cursor in ["0", "01", "-1", "1&recipient=other", "9223372036854775808"] {
            XCTAssertFalse(FanNotificationValidation.isValidCursor(cursor))
        }
        XCTAssertFalse(FanNotificationValidation.isValid(page([message(), message()])))
        XCTAssertFalse(FanNotificationValidation.isValid(page([], cursor: "2")))
        XCTAssertFalse(FanNotificationValidation.isValid(page([message()], unread: -1)))
    }

    func testInboxCanReadWithoutAnyNotificationPermissionOrDeviceAndGETNeverMarksRead() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        let inbox = store()
        await inbox.refresh(using: account)
        XCTAssertEqual(inbox.notifications, [message()])
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(account.calls, ["list:first"], "读取云消息不需要APNs token、通知偏好或已读写入")
    }

    func testInboxPaginationDeduplicatesAndNetworkFailureCanRetry() async {
        let account = InboxTestAccount()
        account.pages = [page([message(3)], cursor: "30", unread: 3), page([message(3), message(2)], cursor: "20", unread: 3)]
        let inbox = store()
        await inbox.refresh(using: account)
        account.pageError = URLError(.notConnectedToInternet)
        await inbox.loadMore(using: account)
        XCTAssertNotNil(inbox.errorMessage)
        XCTAssertEqual(inbox.notifications.count, 1)
        account.pageError = nil
        await inbox.loadMore(using: account)
        XCTAssertEqual(inbox.notifications.map(\.id), [message(3).id, message(2).id])
        XCTAssertEqual(inbox.nextCursor, "20")
        XCTAssertNil(inbox.errorMessage)
        account.pages = [page([message(1)], cursor: "30")]
        await inbox.loadMore(using: account)
        XCTAssertNotNil(inbox.errorMessage, "游标倒退或循环不得形成无限分页")
    }

    func testOpeningAuthenticatedDetailExplicitlyMarksReadAndUpdatesList() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        account.message = message()
        let inbox = store()
        await inbox.refresh(using: account)
        await inbox.open(id: message().id, using: account)
        XCTAssertEqual(account.calls, ["list:first", "get:\(message().id)", "read:\(message().id)"])
        XCTAssertNotNil(inbox.detail?.readAt)
        XCTAssertNotNil(inbox.notifications.first?.readAt)
        XCTAssertEqual(inbox.unreadCount, 0)
    }

    func testAlreadyReadDetailMergesListWithoutAnotherReadWrite() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        account.message = message(read: true)
        let inbox = store()
        await inbox.refresh(using: account)
        await inbox.open(id: message().id, using: account)
        XCTAssertEqual(account.calls.count, 2)
        XCTAssertNotNil(inbox.notifications.first?.readAt)
        XCTAssertEqual(inbox.unreadCount, 0)
        account.pages = [page([message()])]
        inbox.closeDetail()
        await inbox.refresh(using: account)
        XCTAssertEqual(account.calls.count, 3)
        XCTAssertNotNil(inbox.notifications.first?.readAt, "迟到的未读快照不得撤销本机已确认的已读")
        XCTAssertEqual(inbox.unreadCount, 0)
    }

    func testExpiredMissingOrIneligibleMessageNeverShowsBodyOrMarksRead() async {
        for failure in ["expired", "missing", "forbidden"] {
            let account = InboxTestAccount()
            account.message = message(expired: failure == "expired")
            if failure == "missing" { account.detailError = FanNotificationError.notFound }
            if failure == "forbidden" { account.detailError = FanNotificationError.signInRequired }
            let inbox = store()
            await inbox.open(id: message().id, using: account)
            XCTAssertNil(inbox.detail)
            XCTAssertNotNil(inbox.detailErrorMessage)
            XCTAssertFalse(account.calls.contains { $0.hasPrefix("read:") })
        }
    }

    func testLateListReplyCannotRestoreSignedOutOrSwitchedAccount() async {
        for nextUser in [nil, "account-b"] as [String?] {
            let account = InboxTestAccount()
            account.pages = [page([message()])]
            account.pausePage = true
            let started = expectation(description: "旧账号列表请求开始")
            account.requestStarted = { started.fulfill() }
            let inbox = store()
            let task = Task { await inbox.refresh(using: account) }
            await fulfillment(of: [started], timeout: 2)
            account.notificationContext = nextUser.map { .init(userID: $0, sessionGeneration: 2) }
            inbox.updateContext(account.notificationContext)
            account.resume()
            await task.value
            XCTAssertTrue(inbox.notifications.isEmpty)
            XCTAssertEqual(inbox.unreadCount, 0)
        }
    }

    func testEnvironmentSwitchClearsInboxAndRejectsLateReplyForMatchingIdentity() async {
        for original in AppServiceEnvironment.allCases {
            let destination: AppServiceEnvironment = original == .production ? .review : .production
            let account = InboxTestAccount()
            account.notificationContext = .init(userID: "same-synthetic-id", sessionGeneration: 1, environment: original)
            account.pages = [page([message(1)])]
            let inbox = store()
            await inbox.refresh(using: account)
            XCTAssertEqual(inbox.notifications.count, 1)

            account.pages = [page([message(2)])]
            account.pausePage = true
            let started = expectation(description: "Original environment request began")
            account.requestStarted = { started.fulfill() }
            let pending = Task { await inbox.refresh(using: account) }
            await fulfillment(of: [started], timeout: 2)
            // Deliberately preserve user ID and generation: environment alone must fence this reply.
            account.notificationContext = .init(userID: "same-synthetic-id", sessionGeneration: 1, environment: destination)
            inbox.updateContext(account.notificationContext)
            XCTAssertTrue(inbox.notifications.isEmpty)
            XCTAssertEqual(inbox.unreadCount, 0)
            account.resume()
            await pending.value
            XCTAssertTrue(inbox.notifications.isEmpty)
            account.pages = [page([message(3)])]
            await inbox.refresh(using: account)
            XCTAssertEqual(inbox.notifications.map(\.id), [message(3).id])
        }
    }

    func testLateDetailReplyCannotMarkReadAfterAccountSwitch() async {
        let account = InboxTestAccount()
        account.message = message()
        account.pauseDetail = true
        let started = expectation(description: "旧账号详情请求开始")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        let task = Task { await inbox.open(id: message().id, using: account) }
        await fulfillment(of: [started], timeout: 2)
        account.notificationContext = .init(userID: "account-b", sessionGeneration: 2)
        inbox.updateContext(account.notificationContext)
        account.resume()
        await task.value
        XCTAssertNil(inbox.detail)
        XCTAssertEqual(account.calls.count, 1)
    }

    func testConcurrentReadIsSingleFlightAndUnreadCountCannotDecrementTwice() async {
        let account = InboxTestAccount()
        account.pages = [page([message(), message(2)])]
        account.message = message()
        account.pauseRead = true
        let started = expectation(description: "显式已读写入等待响应")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        await inbox.refresh(using: account)
        let task = Task { await inbox.open(id: message().id, using: account) }
        await fulfillment(of: [started], timeout: 2)
        await inbox.markCurrentDetailRead(using: account)
        XCTAssertEqual(account.calls.filter { $0.hasPrefix("read:") }.count, 1)
        account.resume()
        await task.value
        XCTAssertEqual(inbox.unreadCount, 1)
    }

    func testReadFailureKeepsBodyOnlyForTransientFailureAndCanRetry() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        account.message = message()
        account.readError = URLError(.timedOut)
        let inbox = store()
        await inbox.refresh(using: account)
        await inbox.open(id: message().id, using: account)
        XCTAssertNotNil(inbox.detail)
        XCTAssertNotNil(inbox.readErrorMessage)
        account.readError = nil
        await inbox.markCurrentDetailRead(using: account)
        XCTAssertNotNil(inbox.detail?.readAt)
        XCTAssertNil(inbox.readErrorMessage)
        account.message = message(2)
        account.readError = FanNotificationError.signInRequired
        await inbox.open(id: message(2).id, using: account)
        XCTAssertNil(inbox.detail)
        XCTAssertTrue(inbox.notifications.isEmpty, "资格失效必须清空旧消息而非只显示写入错误")
    }

    func testListAuthorizationFailureClearsExistingMessages() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        let inbox = store()
        await inbox.refresh(using: account)
        account.pageError = FanNotificationError.signInRequired
        await inbox.refresh(using: account)
        XCTAssertTrue(inbox.notifications.isEmpty)
        XCTAssertEqual(inbox.unreadCount, 0)
    }

    func testPushTapRetainsOnlyCanonicalIDAndDoesNotFollowAccountSwitch() throws {
        let suite = "InboxTapTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = PushNotificationCoordinator(defaults: defaults, registrationClient: InboxTestRegistrar())
        coordinator.receiveNotification(userInfo: ["notificationID": "https://example.com", "body": "不可信正文"], opened: true)
        XCTAssertNil(coordinator.pendingNotification)
        coordinator.receiveNotification(userInfo: ["notificationID": message().id, "url": "https://example.com"], opened: true)
        XCTAssertEqual(coordinator.pendingNotification?.id, message().id)
        coordinator.accountContextDidChange(to: "account-a")
        XCTAssertNotNil(coordinator.pendingNotification, "未登录时点开的ID可以等待首次认证")
        coordinator.accountContextDidChange(to: "account-b")
        XCTAssertNil(coordinator.pendingNotification)
    }

    func testLateReadReceiptCannotRepopulateDifferentAccount() async {
        let account = InboxTestAccount()
        account.message = message()
        account.pauseRead = true
        let started = expectation(description: "旧账号已读回执等待响应")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        let task = Task { await inbox.open(id: message().id, using: account) }
        await fulfillment(of: [started], timeout: 2)
        account.notificationContext = .init(userID: "account-b", sessionGeneration: 2)
        inbox.updateContext(account.notificationContext)
        account.resume()
        await task.value
        XCTAssertNil(inbox.detail)
        XCTAssertTrue(inbox.notifications.isEmpty)
        XCTAssertEqual(inbox.unreadCount, 0)
    }

    func testMessageExpiresWhileOpenAndIsRemovedFromMemoryPresentation() async {
        var currentTime = now
        let inbox = FanNotificationStore(now: { currentTime })
        let account = InboxTestAccount()
        account.message = message(read: true)
        await inbox.open(id: message().id, using: account)
        XCTAssertNotNil(inbox.detail)
        currentTime = now.addingTimeInterval(3601)
        inbox.expireDetailIfNeeded()
        XCTAssertNil(inbox.detail)
        XCTAssertNotNil(inbox.detailErrorMessage)
    }

    func testInboxTextFitsPhoneAndIPadWidthsAndExpandsForDynamicType() {
        let item = FanNotification(
            notificationID: message().id, title: String(repeating: "消息标题", count: 15),
            body: String(repeating: "完整消息正文内容", count: 30), sensitive: true,
            createdAt: now, expiresAt: now.addingTimeInterval(3600), readAt: nil
        )
        for width: CGFloat in [320, 390, 744, 1024, 1366] {
            let standard = UIHostingController(rootView: FanNotificationDetailText(item: item).environment(\.dynamicTypeSize, .large))
            let accessible = UIHostingController(rootView: FanNotificationDetailText(item: item).environment(\.dynamicTypeSize, .accessibility5))
            let constraint = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let standardSize = standard.sizeThatFits(in: constraint)
            let accessibleSize = accessible.sizeThatFits(in: constraint)
            XCTAssertTrue(standardSize.height.isFinite && accessibleSize.height.isFinite)
            XCTAssertGreaterThan(standardSize.height, 40)
            XCTAssertGreaterThan(accessibleSize.height, standardSize.height, "大字体必须向下自然展开，不能固定高度裁掉正文")
            XCTAssertLessThanOrEqual(accessibleSize.width, min(width, 760) + 1, "横屏/竖屏内容必须保持在可用宽度内")
        }
    }

    func testConcurrentForegroundRefreshesShareOneRequestAndDetailStopsListPolling() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        account.message = message(read: true)
        account.pausePage = true
        let started = expectation(description: "首个消息箱刷新开始")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        let task = Task { await inbox.refresh(using: account) }
        await fulfillment(of: [started], timeout: 2)
        await inbox.refresh(using: account)
        await inbox.refresh(using: account)
        XCTAssertEqual(account.calls.count, 1, "根页面、账号页与消息箱前台刷新不得并发请求相同账号锁")
        account.resume()
        await task.value
        await inbox.open(id: message().id, using: account)
        await inbox.refresh(using: account)
        XCTAssertEqual(account.calls.count, 2, "正在阅读详情时只刷新详情，不额外争抢列表锁")
    }

    func testExpiredListMessagesArePrunedWithoutNetworkAccess() async {
        var currentTime = now
        let inbox = FanNotificationStore(now: { currentTime })
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        await inbox.refresh(using: account)
        currentTime = now.addingTimeInterval(3601)
        inbox.purgeExpiredMessages()
        XCTAssertTrue(inbox.notifications.isEmpty)
        XCTAssertEqual(inbox.unreadCount, 0)
        XCTAssertEqual(account.calls, ["list:first"])
    }

    func testDetailWaitsForInFlightListInsteadOfRacingRecipientLock() async {
        let account = InboxTestAccount()
        account.pages = [page([message()])]
        account.message = message(read: true)
        account.pausePage = true
        let started = expectation(description: "列表持有请求")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        let listTask = Task { await inbox.refresh(using: account) }
        await fulfillment(of: [started], timeout: 2)
        let waiting = expectation(description: "详情正在等候列表")
        let observation = inbox.$isLoadingDetail.dropFirst().filter { $0 }.sink { _ in waiting.fulfill() }
        let detailTask = Task { await inbox.open(id: message().id, using: account) }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(account.calls, ["list:first"])
        account.resume()
        await listTask.value
        await detailTask.value
        observation.cancel()
        XCTAssertEqual(account.calls, ["list:first", "get:\(message().id)"])
        XCTAssertNotNil(inbox.detail)
    }

    func testDuplicateDetailForegroundRequestsShareOneAuthenticatedRead() async {
        let account = InboxTestAccount()
        account.message = message()
        account.pauseDetail = true
        let started = expectation(description: "详情请求尚未返回")
        account.requestStarted = { started.fulfill() }
        let inbox = store()
        let task = Task { await inbox.open(id: message().id, using: account) }
        await fulfillment(of: [started], timeout: 2)
        await inbox.open(id: message().id, using: account)
        await inbox.open(id: message().id, using: account)
        XCTAssertEqual(account.calls, ["get:\(message().id)"])
        account.resume()
        await task.value
        XCTAssertEqual(account.calls, ["get:\(message().id)", "read:\(message().id)"])
        XCTAssertNotNil(inbox.detail?.readAt)
    }

    func testPaginationCannotRestoreAcknowledgedUnreadSnapshot() async {
        let account = InboxTestAccount()
        account.pages = [page([message(3)], cursor: "30", unread: 3)]
        account.message = message(3, read: true)
        let inbox = store()
        await inbox.refresh(using: account)
        await inbox.open(id: message(3).id, using: account)
        XCTAssertEqual(inbox.unreadCount, 2)
        inbox.closeDetail()
        account.pages = [page([message(3), message(2)], cursor: "20", unread: 3)]
        await inbox.loadMore(using: account)
        XCTAssertEqual(inbox.unreadCount, 2, "分页旧快照与刷新采用相同已读协调规则")
        XCTAssertNotNil(inbox.notifications.first?.readAt)
        XCTAssertEqual(inbox.notifications.map(\.id), [message(3).id, message(2).id])
    }
}

@MainActor
private struct InboxTestRegistrar: PushDeviceRegistrationClient {
    func register() {}
    func unregister() {}
}
