import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @Environment(LocalWeatherStore.self) private var localWeather
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @EnvironmentObject private var fanAccount: FanAccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var presentsAdminAccess = false

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                Group {
                    if usesTwoColumnLayout {
                        HStack(alignment: .top, spacing: 24) {
                            portrait
                                .frame(maxWidth: .infinity)
                            profileDetails
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                        }
                        .frame(maxWidth: 1_164)
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 0) {
                            portrait
                                .frame(maxWidth: 720)
                                .frame(maxWidth: .infinity)
                            profileDetails
                                .frame(maxWidth: 720)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .floatingTabBarScrollClearance()
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $presentsAdminAccess) {
            SecureCaptureSurface(
                owner: .fullScreenPresentation,
                onExit: { presentsAdminAccess = false }
            ) {
                AdminAccessView()
                    .environmentObject(admin)
                    .environmentObject(portfolioStore)
            }
        }
    }

    private var usesTwoColumnLayout: Bool {
        !dynamicTypeSize.isAccessibilitySize
            && (horizontalSizeClass == .regular || verticalSizeClass == .compact)
    }

    private var profileDetails: some View {
        VStack(spacing: 0) {
            biography
            profileActions
            links
            fanAccountAccess
            copyrightNotice
            privacyAccess
            adminAccess
            weatherAttribution
        }
    }

    private var portrait: some View {
        ZStack(alignment: .bottomLeading) {
            if let portraitURL = portfolioStore.aboutPortraitURL {
                ArtworkImage(url: portraitURL, contentMode: .fit)
                    .accessibilityLabel("易姝形象照")
                    .accessibilityIdentifier("about-portrait")
            } else {
                Image("AboutPortrait")
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("易姝形象照")
                    .accessibilityIdentifier("about-portrait")
            }
            LinearGradient(colors: [.clear, AppTheme.ink], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text("YI SHU")
                    .font(.caption2.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(AppTheme.gold)
                Text("易姝")
                    .font(.system(.largeTitle, design: .serif))
                Text("短剧演员 / 模特 / 视频创作者")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        AppTheme.warmWhite,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .padding(22)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }

    private var biography: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("关于")
                .font(.system(.title, design: .serif))
                .accessibilityIdentifier("about-heading")
                .accessibilityAddTraits(.isHeader)
            Text("专注于短剧表演、时尚摄影与艺术创作。希望通过克制而真实的情绪、东方气质与镜头表现，让每个角色留下属于自己的余韵。")
                .font(.body)
                .lineSpacing(9)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    PillLabel(text: "短剧表演")
                    PillLabel(text: "古装造型")
                    PillLabel(text: "情绪表达")
                    PillLabel(text: "平面拍摄")
                    PillLabel(text: "品牌合作")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        PillLabel(text: "短剧表演")
                        PillLabel(text: "古装造型")
                        PillLabel(text: "情绪表达")
                        PillLabel(text: "平面拍摄")
                        PillLabel(text: "品牌合作")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            PillLabel(text: "短剧表演")
                            PillLabel(text: "古装造型")
                            PillLabel(text: "情绪表达")
                        }
                        HStack(spacing: 8) {
                            PillLabel(text: "平面拍摄")
                            PillLabel(text: "品牌合作")
                        }
                    }
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    stat("演员", "身份")
                    Divider().overlay(.white.opacity(0.14))
                    stat("浙江 · 杭州", "所在地")
                    Divider().overlay(.white.opacity(0.14))
                    stat("合作中", "状态")
                }
            } else {
                HStack(spacing: 0) {
                    stat("演员", "身份")
                    Divider().overlay(.white.opacity(0.14))
                    stat("浙江 · 杭州", "所在地")
                    Divider().overlay(.white.opacity(0.14))
                    stat("合作中", "状态")
                }
                .frame(minHeight: 68)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 38)
    }

    private var profileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { profileActionButtons }
            VStack(spacing: 10) { profileActionButtons }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var profileActionButtons: some View {
        ShareLink(
            item: ContentCatalog.websiteURL,
            subject: Text("易姝｜演员与模特作品集"),
            message: Text("易姝的演员 Showreel、写真作品与公开出演短剧")
        ) {
            Label("分享艺人主页", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }

        NavigationLink {
            CollaborationInquiryView()
        } label: {
            Label("发送合作邀约", systemImage: "envelope")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.warmWhite, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(AppTheme.ink)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-collaboration")
    }

    private var links: some View {
        VStack(spacing: 10) {
            contactLink("工作联系", detail: "369476120@qq.com", icon: "envelope", url: ContentCatalog.emailURL)
            contactLink("小红书", detail: "一只梳子君", icon: "sparkles", url: ContentCatalog.xiaohongshuURL)
            contactLink("抖音", detail: "一只梳子君", icon: "play.circle", url: ContentCatalog.douyinURL)
            contactLink("红果短剧", detail: "易姝", icon: "film.stack", url: ContentCatalog.hongguoURL)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var copyrightNotice: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("版权与授权", systemImage: "c.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.gold)
                .accessibilityAddTraits(.isHeader)

            Text("本 App 展示的照片与影像均已取得合法展示授权，相关著作权、肖像权及其他权利归各自权利人所有。未经书面许可，不得下载、复制、截图传播、转载、改编、二次创作或用于商业用途。")
                .font(.footnote)
                .lineSpacing(6)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                CollaborationInquiryView()
            } label: {
                HStack(spacing: 6) {
                    Text("申请内容使用授权")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.warmWhite)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(AppTheme.gold.opacity(0.18), lineWidth: 0.8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var fanAccountAccess: some View {
        NavigationLink {
            FanAccountView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: fanAccount.isAuthenticated
                      ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                    .font(.title3)
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.055), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(fanAccount.profile?.displayName ?? "粉丝账号")
                        .font(.subheadline.weight(.semibold))
                    Text(fanAccount.profile?.identityCode ?? "注册身份码 · 获取远程权限")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(15)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-fan-account")
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var adminAccess: some View {
        Button {
            presentsAdminAccess = true
        } label: {
            HStack(spacing: 5) {
                Text("管理员入口")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-admin-entry")
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var privacyAccess: some View {
        NavigationLink {
            PrivacyPolicyView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.body)
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.055), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("隐私政策与数据选择")
                        .font(.footnote.weight(.semibold))
                    Text("查看数据用途 · 账号可在 App 内永久删除")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
                .foregroundStyle(AppTheme.warmWhite)
                .padding(14)
                .frame(minHeight: 44)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-privacy-policy")
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var weatherAttribution: some View {
        Link(destination: localWeather.attributionLegalURL) {
            HStack(spacing: 14) {
                AsyncImage(url: localWeather.attributionMarkURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Text(localWeather.weatherProviderName)
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(width: 108, height: 28, alignment: .leading)
                Spacer()
                Text("天气数据与许可")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(.horizontal, 15)
            .frame(minHeight: 48)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-weather-legal-link")
        .accessibilityHint("打开 Apple Weather 数据来源与许可页")
        .padding(.horizontal, 16)
        .padding(.bottom, 70)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 7) {
            Text(value)
                .font(.system(.headline, design: .serif))
            Text(label)
                .font(.caption2.weight(.medium))
                .tracking(1.2)
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 0)
    }

    private func contactLink(_ title: String, detail: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.055), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(AppTheme.warmWhite)
            .padding(15)
            .frame(minHeight: 48)
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
