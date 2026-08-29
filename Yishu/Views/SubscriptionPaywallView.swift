import SwiftUI
import StoreKit

struct SubscriptionPaywallView: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var legalDocument: SubscriptionLegalDocument?
    @State private var showManageSubscriptions = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.ink.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 26) {
                        hero
                        benefits
                        purchaseSection
                        legalDisclosure
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(AppTheme.warmWhite)
                }
            }
            .sheet(item: $legalDocument) { document in
                SubscriptionLegalView(document: document)
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        }
        .preferredColorScheme(.dark)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Image(systemName: subscription.hasFullPhotoAccess ? "checkmark.seal.fill" : "photo.stack.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(AppTheme.gold)
                .frame(width: 82, height: 82)
                .background(AppTheme.gold.opacity(0.1), in: Circle())

            Text(subscription.hasFullPhotoAccess ? "全部作品已解锁" : "解锁全部影像作品")
                .font(.editorial(34))
                .multilineTextAlignment(.center)

            Text(subscription.hasFullPhotoAccess
                 ? "感谢你的支持，订阅有效期间可以浏览全部相册照片。"
                 : "每个相册可免费预览 3 张照片，订阅后即可浏览所有完整作品。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            benefit("photo.on.rectangle.angled", "解锁所有相册与完整照片")
            Divider().overlay(.white.opacity(0.08))
            benefit("arrow.triangle.2.circlepath", "订阅期间持续获得新作品")
            Divider().overlay(.white.opacity(0.08))
            benefit("lock.shield", "仅限 App 内浏览，不支持保存或截屏")
        }
        .padding(.horizontal, 18)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 16))
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.gold)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppTheme.warmWhite)
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if subscription.hasFullPhotoAccess {
                Label("订阅已生效", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.gold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(AppTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                if subscription.hasActiveSubscription {
                    Button("管理订阅") { showManageSubscriptions = true }
                        .buttonStyle(SubscriptionSecondaryButtonStyle())
                }
            } else {
                Button {
                    Task { await subscription.purchaseMonthly() }
                } label: {
                    HStack {
                        if subscription.isPurchasing {
                            ProgressView().tint(AppTheme.ink)
                        }
                        Text(subscription.isPurchasing
                             ? "正在连接 Apple…"
                             : "订阅 · \(subscription.localizedMonthlyPrice)/月")
                    }
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!subscription.canPurchase)
                .opacity(subscription.canPurchase ? 1 : 0.55)
            }

            Button("恢复购买") {
                Task { await subscription.restorePurchases() }
            }
            .buttonStyle(SubscriptionSecondaryButtonStyle())
            .disabled(subscription.isPurchasing)

            if subscription.monthlyProduct == nil, !subscription.isLoading {
                Button("重新连接 App Store") {
                    Task { await subscription.refresh() }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.gold)
            }

#if DEBUG
            Button(subscription.hasFullPhotoAccess ? "开发测试：恢复访客状态" : "开发测试：模拟订阅成功") {
                subscription.toggleDebugAccess()
            }
            .font(.caption)
            .foregroundStyle(AppTheme.gold.opacity(0.85))
#endif

            if let message = subscription.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
    }

    private var legalDisclosure: some View {
        VStack(spacing: 12) {
            Text("自动续期订阅，每月一个计费周期。确认购买后将通过 Apple 账户扣款；除非在当前周期结束至少 24 小时前取消，否则订阅会自动续期。可随时在 Apple 账户的订阅设置中管理或取消。实际价格以购买确认页面显示为准。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            HStack(spacing: 22) {
                Button("订阅条款") { legalDocument = .terms }
                Button("隐私政策") { legalDocument = .privacy }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.gold)
        }
    }
}

private struct SubscriptionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.warmWhite)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(configuration.isPressed ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum SubscriptionLegalDocument: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }
    var title: String { self == .terms ? "订阅条款" : "隐私政策" }
}

private struct SubscriptionLegalView: View {
    let document: SubscriptionLegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(document == .terms ? termsText : privacyText)
                    .font(.body)
                    .foregroundStyle(AppTheme.warmWhite)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var termsText: String {
        """
        易姝完整作品订阅为按月自动续期服务。订阅有效期间，用户可以在本 App 内浏览全部已发布相册照片，以及订阅期间新增的作品内容。

        确认购买后，费用将由 Apple 账户收取。订阅以一个月为周期自动续期；除非在当前订阅周期结束至少 24 小时前取消，否则 Apple 会为下一周期续费。续费价格以 Apple 显示的价格为准。

        用户可以在 iPhone“设置”中的 Apple 账户订阅页面管理或取消订阅。取消后，完整作品访问权限会保留至当前已付费周期结束。已收藏的记录不会删除，但不再有效的订阅无法继续打开锁定照片。

        作品仅授权在本 App 内个人浏览，不代表转让照片版权、肖像权或下载、复制、传播权限。
        """
    }

    private var privacyText: String {
        """
        易姝 App 不直接收集或保存银行卡、付款密码等支付信息。订阅购买、付款验证、恢复购买和续期均由 Apple 的 App Store 与 StoreKit 处理。

        App 只读取 Apple 提供的订阅有效状态，用于决定是否解锁完整照片。收藏与最近浏览记录默认保存在本机。管理员登录凭证保存在系统钥匙串中，仅用于经授权的内容维护。

        作品照片仅用于 App 内展示，并配置截屏、录屏与保存保护。网络请求仍可能产生服务运行所必需的基础日志，例如时间、设备网络地址与错误信息。

        如需咨询隐私或订阅问题，可通过 App“关于”页面中的合作联系入口与我们联系。
        """
    }
}
