import SwiftUI
import UserNotifications

struct MeView: View {
    @EnvironmentObject private var notifications: NotificationStore

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    navigationCard
                    notificationCard
                    privacyNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await notifications.refreshAuthorizationStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MY YI SHU")
                .font(.system(size: 10, weight: .semibold))
                .tracking(3.2)
                .foregroundStyle(AppTheme.gold)
            Text("我的")
                .font(.editorial(40))
            Text("收藏、通知与艺人资料")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private var navigationCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                FavoritesView()
            } label: {
                row("我的收藏", detail: "照片与最近浏览", icon: "heart")
            }
            Divider().overlay(.white.opacity(0.08))
            NavigationLink {
                AboutView()
            } label: {
                row("关于易姝", detail: "资料、合作与官方平台", icon: "person.crop.rectangle")
            }
        }
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("作品与直播提醒", systemImage: "bell")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(notifications.isAuthorized ? AppTheme.gold : AppTheme.muted)
            }

            if notifications.isAuthorized {
                Toggle("抖音 / 小红书新作品", isOn: Binding(
                    get: { notifications.preferences.newWorks },
                    set: { notifications.preferences.newWorks = $0 }
                ))
                Toggle("直播开始提醒", isOn: Binding(
                    get: { notifications.preferences.live },
                    set: { notifications.preferences.live = $0 }
                ))
                .tint(AppTheme.gold)
            } else {
                Text("我们不会在首次启动时索取权限。开启后仍可在这里分别控制提醒类型。")
                    .font(.caption)
                    .lineSpacing(4)
                    .foregroundStyle(AppTheme.muted)
                Button {
                    Task { await notifications.requestAuthorization() }
                } label: {
                    Text("开启系统通知")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(AppTheme.ink)
                }
            }

            if let error = notifications.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(17)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 8))
        .tint(AppTheme.gold)
    }

    private var privacyNote: some View {
        Label("通知令牌只用于你选择的易姝作品与直播提醒，不用于广告追踪。", systemImage: "lock.shield")
            .font(.caption2)
            .lineSpacing(4)
            .foregroundStyle(AppTheme.muted)
    }

    private func row(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.gold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(16)
        .contentShape(Rectangle())
        .foregroundStyle(.white)
    }

    private var statusText: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional: "已开启"
        case .denied: "系统已关闭"
        case .notDetermined: "尚未开启"
        default: "受系统管理"
        }
    }
}
