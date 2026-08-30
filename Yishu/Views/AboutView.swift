import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var localWeather: LocalWeatherStore
    @EnvironmentObject private var portfolioStore: PortfolioStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    if horizontalSizeClass == .regular, proxy.size.width >= 760 {
                        let availableWidth = min(max(0, proxy.size.width - 48), 1_164)
                        let portraitWidth = min(580, max(320, availableWidth * 0.52))
                        let detailsWidth = max(300, availableWidth - portraitWidth - 24)

                        HStack(alignment: .top, spacing: 24) {
                            portrait
                                .frame(width: portraitWidth)
                            profileDetails
                                .frame(width: detailsWidth)
                                .padding(.top, 48)
                        }
                        .frame(width: availableWidth, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 0) {
                            portrait
                                .frame(maxWidth: 720)
                                .frame(maxWidth: .infinity)
                            profileDetails
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, 84, for: .scrollContent)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var profileDetails: some View {
        VStack(spacing: 0) {
            biography
            profileActions
            links
            copyrightNotice
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(AppTheme.gold)
                Text("易姝")
                    .font(.editorial(48))
                Text("短剧演员 / 模特 / 视频创作者")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .padding(22)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }

    private var biography: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("关于")
                .font(.editorial(32))
                .accessibilityIdentifier("about-heading")
            Text("专注于短剧表演、时尚摄影与艺术创作。希望通过克制而真实的情绪、东方气质与镜头表现，让每个角色留下属于自己的余韵。")
                .font(.system(size: 16))
                .lineSpacing(9)
                .foregroundStyle(.white.opacity(0.76))

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

            HStack(spacing: 0) {
                stat("演员", "身份")
                Divider().overlay(.white.opacity(0.14))
                stat("浙江 · 杭州", "所在地")
                Divider().overlay(.white.opacity(0.14))
                stat("合作中", "状态")
            }
            .frame(height: 68)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.gold)

            Text("本 App 展示的照片与影像均已取得合法展示授权，相关著作权、肖像权及其他权利归各自权利人所有。未经书面许可，不得下载、复制、截图传播、转载、改编、二次创作或用于商业用途。")
                .font(.system(size: 13))
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

    private var adminAccess: some View {
        NavigationLink {
            AdminView()
        } label: {
            HStack(spacing: 5) {
                Text(admin.isAuthenticated ? "内容管理" : "管理员入口")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(admin.isAuthenticated ? 0.42 : 0.22))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("about-admin-entry")
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, localWeather.attributionLegalURL == nil ? 70 : 12)
    }

    @ViewBuilder
    private var weatherAttribution: some View {
        if let legalURL = localWeather.attributionLegalURL {
            Link(destination: legalURL) {
                HStack(spacing: 14) {
                    AsyncImage(url: localWeather.attributionMarkURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            Text(localWeather.weatherProviderName)
                                .font(.system(size: 12, weight: .semibold))
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
                .padding(.vertical, 12)
                .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 70)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 7) {
            Text(value)
                .font(.editorial(17))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func contactLink(_ title: String, detail: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.055), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
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
            .background(AppTheme.elevatedInk, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
