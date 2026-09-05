import SwiftUI

struct FanNotificationAccountEntry: View {
    @ObservedObject var account: FanAccountStore
    @ObservedObject private var inbox: FanNotificationStore

    init(account: FanAccountStore) {
        self.account = account
        inbox = account.notificationStore
    }

    var body: some View {
        if account.notificationContext != nil {
            NavigationLink {
                FanNotificationInboxView(inbox: inbox)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label("消息箱", systemImage: "tray")
                    Spacer(minLength: 8)
                    if inbox.unreadCount > 0 {
                        Text("\(inbox.unreadCount) 条未读")
                            .font(.caption)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(14)
                .frame(minHeight: 44)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fan-notification-inbox-entry")
            .task(id: account.notificationContext) { await inbox.refresh(using: account) }
        }
    }
}

struct FanNotificationInboxView: View {
    @EnvironmentObject private var account: FanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var inbox: FanNotificationStore
    var initialNotificationID: String?
    @State private var selectedID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if account.notificationContext == nil {
                    ContentUnavailableView("暂时无法查看消息", systemImage: "lock", description: Text("请先登录并完成账号资料。"))
                } else if inbox.isLoading && inbox.notifications.isEmpty {
                    ProgressView("正在读取消息")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if inbox.notifications.isEmpty && inbox.errorMessage == nil {
                    ContentUnavailableView("暂无消息", systemImage: "tray", description: Text("管理员发给你的消息会显示在这里。无需开启系统通知也可查看。"))
                } else {
                    ForEach(inbox.notifications) { item in
                        Button { selectedID = item.id } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if item.readAt == nil {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(AppTheme.gold)
                                            .accessibilityLabel("未读")
                                    }
                                    Text(verbatim: item.title)
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(verbatim: item.body)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(3)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(16)
                            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fan-message-\(item.id)")
                    }
                }
                if let error = inbox.errorMessage {
                    Text(error).font(.callout).foregroundStyle(AppTheme.warning)
                    Button("重试读取消息") { Task { await inbox.refresh(using: account) } }
                        .frame(minHeight: 44)
                }
                if inbox.nextCursor != nil {
                    Button {
                        Task { await inbox.loadMore(using: account) }
                    } label: {
                        if inbox.isLoadingMore { ProgressView("正在读取更多消息") }
                        else { Text("加载更多消息") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(inbox.isLoadingMore || inbox.isLoading)
                    .accessibilityIdentifier("fan-messages-load-more")
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.ink)
        .foregroundStyle(AppTheme.warmWhite)
        .navigationTitle("消息箱")
        .navigationBarTitleDisplayMode(.inline)
        .stableDetailTabBar()
        .refreshable { await inbox.refresh(using: account) }
        .task(id: inbox.notifications.map(\.expiresAt).min()) {
            guard let expiry = inbox.notifications.map(\.expiresAt).min() else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
            catch { return }
            inbox.purgeExpiredMessages()
        }
        .task(id: account.notificationContext) {
            await inbox.refresh(using: account)
            if account.notificationContext != nil, let initialNotificationID {
                selectedID = initialNotificationID
            }
        }
        .onChange(of: account.notificationContext) { _, _ in selectedID = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await inbox.refresh(using: account) } }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedID != nil && account.notificationContext != nil },
            set: { if !$0 { selectedID = nil; inbox.closeDetail() } }
        )) {
            if let selectedID { FanNotificationDetailView(inbox: inbox, notificationID: selectedID) }
        }
    }
}

struct FanNotificationDetailText: View {
    let item: FanNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(AppTheme.muted)
            Text(verbatim: item.body)
                .font(.body)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

private struct FanNotificationDetailView: View {
    @EnvironmentObject private var account: FanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var inbox: FanNotificationStore
    let notificationID: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = inbox.detail, item.id == notificationID, account.notificationContext != nil {
                    FanNotificationDetailText(item: item)
                    if let error = inbox.readErrorMessage {
                        Text(error).font(.caption).foregroundStyle(AppTheme.warning)
                        Button("重试同步已读") { Task { await inbox.markCurrentDetailRead(using: account) } }
                            .frame(minHeight: 44)
                    }
                } else if inbox.isLoadingDetail {
                    ProgressView("正在读取消息")
                } else {
                    ContentUnavailableView("无法显示这条消息", systemImage: "envelope.badge", description: Text(inbox.detailErrorMessage ?? "消息已过期或当前账号无法查看。"))
                    Button("重试读取") { Task { await inbox.open(id: notificationID, using: account) } }
                        .frame(minHeight: 44)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.ink)
        .foregroundStyle(AppTheme.warmWhite)
        .navigationTitle("消息详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: notificationID) { await inbox.open(id: notificationID, using: account) }
        .task(id: inbox.detail?.expiresAt) {
            guard let expiry = inbox.detail?.expiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
            catch { return }
            inbox.expireDetailIfNeeded()
        }
        .onDisappear { inbox.closeDetail() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await inbox.open(id: notificationID, using: account) } }
        }
        .accessibilityIdentifier("fan-message-detail")
    }
}
