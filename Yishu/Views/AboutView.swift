import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var admin: AdminSessionStore
    @EnvironmentObject private var localWeather: LocalWeatherStore

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    portrait
                    biography
                    profileActions
                    links
                    adminAccess
                    weatherAttribution
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 84, for: .scrollContent)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var portrait: some View {
        ZStack(alignment: .bottomLeading) {
            Image("AboutPortrait")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .aspectRatio(9 / 16, contentMode: .fit)
                .accessibilityLabel("易姝形象照")
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
            }
            .padding(22)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var biography: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("关于")
                .font(.editorial(32))
            Text("专注于短剧表演、时尚摄影与艺术创作。希望通过克制而真实的情绪、东方气质与镜头表现，让每个角色留下属于自己的余韵。")
                .font(.system(size: 16))
                .lineSpacing(9)
                .foregroundStyle(.white.opacity(0.76))

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    PillLabel(text: "短剧表演")
                    PillLabel(text: "古装造型")
                    PillLabel(text: "情绪表达")
                    PillLabel(text: "平面拍摄")
                    PillLabel(text: "品牌合作")
                }
            }
            .scrollIndicators(.hidden)

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
    }

    private var links: some View {
        VStack(spacing: 10) {
            contactLink("工作联系", detail: "369476120@qq.com", icon: "envelope", url: ContentCatalog.emailURL)
            contactLink("小红书", detail: "一只梳子君", icon: "sparkles", url: ContentCatalog.xiaohongshuURL)
            contactLink("抖音", detail: "一只梳子君", icon: "play.circle", url: ContentCatalog.douyinURL)
            contactLink("红果短剧", detail: "易姝", icon: "film.stack", url: ContentCatalog.hongguoURL)
            contactLink("官方网站", detail: "shuzijun.com.cn", icon: "globe.asia.australia", url: ContentCatalog.websiteURL)
        }
        .padding(.horizontal, 16)
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
                            Text("MET Norway")
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
